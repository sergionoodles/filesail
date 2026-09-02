#include "backendserver.h"

#include "fileoperations.h"
#include "logging.h"
#include "savedlocations.h"
#include "previewservice.h"

#include <QCoreApplication>
#include <QDir>
#include <QFileInfo>
#include <QFileSystemWatcher>
#include <QFutureWatcher>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSocketNotifier>
#include <QTimer>
#include <QUrl>
#include <QtConcurrentRun>

#include <cerrno>
#include <exception>
#include <unistd.h>

namespace {
constexpr qsizetype maximumRequestBytes = 8 * 1024 * 1024;
constexpr qsizetype maximumActiveJobs = 64;

QJsonObject failure(const QString &message)
{
    return {{"ok", false}, {"error", message}};
}

QString watchPath(const QJsonObject &params, bool mustExist, QString *error)
{
    const QJsonValue value = params.value("path");
    if (!value.isString() || value.toString().trimmed().isEmpty()) {
        *error = "Missing or invalid path";
        return {};
    }

    const QString raw = value.toString();
    QString path = raw;
    if (raw.startsWith("file:")) {
        const QUrl url(raw, QUrl::StrictMode);
        if (!url.isValid() || !url.isLocalFile()
            || (!url.host().isEmpty() && url.host() != "localhost")
            || !url.userInfo().isEmpty() || !url.query().isEmpty()
            || !url.fragment().isEmpty()) {
            *error = "path must be an absolute local path";
            return {};
        }
        path = url.toLocalFile();
    }
    if (path.isEmpty() || path.contains(QChar::Null) || !QDir::isAbsolutePath(path)) {
        *error = "path must be an absolute local path";
        return {};
    }

    path = QDir::cleanPath(path);
    const QFileInfo info(path);
    if (mustExist && (!info.exists() || !info.isDir())) {
        *error = QStringLiteral("Not a directory: %1").arg(path);
        return {};
    }

    const QString canonicalPath = info.canonicalFilePath();
    return canonicalPath.isEmpty() ? path : canonicalPath;
}
}

BackendServer::BackendServer(QObject *parent)
    : QObject(parent)
{
    m_readPool.setMaxThreadCount(2);
    m_mutationPool.setMaxThreadCount(1);
    m_previewService = new PreviewService(this);
}

bool BackendServer::start()
{
    if (!m_output.open(STDOUT_FILENO, QIODevice::WriteOnly | QIODevice::Text,
                       QFileDevice::DontCloseHandle))
        return false;

    m_watcher = new QFileSystemWatcher(this);
    connect(m_watcher, &QFileSystemWatcher::directoryChanged, this, [this](const QString &path) {
        filesailLog(LogLevel::Debug, "backend", QStringLiteral("directoryChanged %1").arg(path));
        writeResponse({{"event", "directoryChanged"}, {"path", path}});
        if (m_directoryWatchCounts.contains(path)
            && !m_watcher->directories().contains(path)) {
            const bool restored = QFileInfo(path).isDir() && m_watcher->addPath(path);
            if (!restored) {
                m_directoryWatchCounts.remove(path);
                filesailLog(LogLevel::Warn, "backend",
                            QStringLiteral("directoryWatchLost %1").arg(path));
                writeResponse({{"event", "directoryWatchLost"}, {"path", path}});
            }
        }
    });

    m_locationsWatcher = new QFileSystemWatcher(this);
    m_locationsDebounce = new QTimer(this);
    m_locationsDebounce->setSingleShot(true);
    m_locationsDebounce->setInterval(100);
    connect(m_locationsDebounce, &QTimer::timeout, this, &BackendServer::emitSavedLocationsChanged);
    connect(m_locationsWatcher, &QFileSystemWatcher::directoryChanged, this, [this](const QString &) {
        ensureSavedLocationsWatch();
        m_locationsDebounce->start();
    });
    ensureSavedLocationsWatch();

    m_notifier = new QSocketNotifier(STDIN_FILENO, QSocketNotifier::Read, this);
    connect(m_notifier, &QSocketNotifier::activated, this, [this] { readRequests(); });
    return true;
}

void BackendServer::readRequests()
{
    char bytes[64 * 1024];
    const ssize_t count = ::read(STDIN_FILENO, bytes, sizeof(bytes));
    if (count == 0) {
        if (!m_requestBuffer.trimmed().isEmpty())
            writeResponse({{"id", -1}, {"ok", false}, {"error", "Incomplete JSON request"}});
        m_requestBuffer.clear();
        finishInput();
        return;
    }
    if (count < 0) {
        if (errno != EINTR && errno != EAGAIN)
            finishInput();
        return;
    }

    m_requestBuffer.append(bytes, count);
    if (m_requestBuffer.size() > maximumRequestBytes && !m_requestBuffer.contains('\n')) {
        writeResponse({{"id", -1}, {"ok", false}, {"error", "Request exceeds 8 MiB limit"}});
        m_requestBuffer.clear();
        finishInput();
        return;
    }

    qsizetype newline = -1;
    qsizetype consumed = 0;
    while ((newline = m_requestBuffer.indexOf('\n', consumed)) >= 0) {
        const QByteArray frame = m_requestBuffer.mid(consumed, newline - consumed).trimmed();
        consumed = newline + 1;
        if (frame.size() > maximumRequestBytes) {
            writeResponse({{"id", -1}, {"ok", false}, {"error", "Request exceeds 8 MiB limit"}});
        } else if (!frame.isEmpty()) {
            handleRequest(frame);
        }
    }
    if (consumed > 0)
        m_requestBuffer.remove(0, consumed);
}

void BackendServer::handleRequest(const QByteArray &line)
{
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(line, &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        writeResponse({{"id", -1}, {"ok", false}, {"error", "Invalid JSON request"}});
        return;
    }

    const QJsonObject request = document.object();
    const int id = request.value("id").toInt(-1);
    const QString method = request.value("method").toString();
    const QJsonObject params = request.value("params").toObject();
    filesailLog(LogLevel::Debug, "backend",
                QStringLiteral("request id=%1 method=%2").arg(id).arg(method));

    if (method == "list") {
        enqueueOperation(id, m_readPool, [params](const CancellationToken &token) { return FileOperations::listDirectory(params, token); });
    } else if (method == "completeDirectories") {
        enqueueOperation(id, m_readPool, [params](const CancellationToken &token) { return FileOperations::completeDirectories(params, token); });
    } else if (method == "locations.list") {
        ensureSavedLocationsWatch();
        enqueueOperation(id, m_readPool, [](const CancellationToken &) { return SavedLocations::list(); }, false);
    } else if (method == "locations.add") {
        ensureSavedLocationsWatch();
        enqueueOperation(id, m_mutationPool, [params](const CancellationToken &) { return SavedLocations::add(params); }, false);
    } else if (method == "locations.remove") {
        ensureSavedLocationsWatch();
        enqueueOperation(id, m_mutationPool, [params](const CancellationToken &) { return SavedLocations::remove(params); }, false);
    } else if (method == "mkdir") {
        enqueueOperation(id, m_mutationPool, [params](const CancellationToken &) { return FileOperations::createDirectory(params); }, false);
    } else if (method == "rename") {
        enqueueOperation(id, m_mutationPool, [params](const CancellationToken &) { return FileOperations::renamePath(params); }, false);
    } else if (method == "trash") {
        enqueueOperation(id, m_mutationPool, [params](const CancellationToken &) { return FileOperations::trashPaths(params); }, false);
    } else if (method == "copy") {
        enqueueOperation(id, m_mutationPool, [params](const CancellationToken &) { return FileOperations::copyPaths(params); }, false);
    } else if (method == "move") {
        enqueueOperation(id, m_mutationPool, [params](const CancellationToken &) { return FileOperations::movePaths(params); }, false);
    } else if (method == "open") {
        enqueueOperation(id, m_readPool, [params](const CancellationToken &) { return FileOperations::openPath(params); }, false);
    } else if (method == "terminal") {
        enqueueOperation(id, m_readPool, [params](const CancellationToken &) { return FileOperations::openTerminal(params); }, false);
    } else if (method == "previewCapabilities") {
        QJsonObject result = m_previewService->capabilities(); result.insert("id", id); writeResponse(result);
    } else if (method == "thumbnailBatch") {
        if (m_activeJobs >= maximumActiveJobs) {
            writeResponse({{"id", id}, {"ok", false}, {"error", "Backend job queue is full"}});
            return;
        }
        const CancellationToken token = std::make_shared<std::atomic_bool>(false);
        m_cancellationTokens.insert(id, token);
        ++m_activeJobs;
        m_previewService->thumbnails(id, params, token, [this, id, token](QJsonObject result) {
            const bool canceled = cancellationRequested(token);
            m_cancellationTokens.remove(id);
            if (!canceled) { result.insert("id", id); writeResponse(result); }
            --m_activeJobs;
            if (m_inputClosed && m_activeJobs == 0) QCoreApplication::quit();
        });
    } else if (method == "textPreview") {
        enqueueOperation(id, m_readPool, [this, params](const CancellationToken &token) { return m_previewService->text(params, token); });
    } else if (method == "archivePreview") {
        enqueueOperation(id, m_readPool, [this, params](const CancellationToken &token) { return m_previewService->archive(params, token); });
    } else if (method == "cancelPreview") {
        const int requestId = params.value("requestId").toInt(-1);
        if (const auto token = m_cancellationTokens.value(requestId)) {
            token->store(true, std::memory_order_relaxed);
            m_previewService->cancelThumbnail(requestId);
        }
        writeResponse({{"id", id}, {"ok", true}});
    } else if (method == "cancel") {
        const int requestId = params.value("requestId").toInt(-1);
        if (const auto token = m_cancellationTokens.value(requestId)) {
            token->store(true, std::memory_order_relaxed);
            m_previewService->cancelThumbnail(requestId);
        }
        writeResponse({{"id", id}, {"ok", true}});
    } else {
        QJsonObject result;
        if (method == "watch")
            result = addDirectoryWatch(params);
        else if (method == "unwatch")
            result = removeDirectoryWatch(params);
        else
            result = failure(QStringLiteral("Unknown method: %1").arg(method));
        result.insert("id", id);
        writeResponse(result);
    }
}

void BackendServer::writeResponse(const QJsonObject &response)
{
    if (response.contains(QStringLiteral("ok")) && !response.value(QStringLiteral("ok")).toBool()) {
        filesailLog(LogLevel::Warn, "backend",
                    QStringLiteral("id=%1 error=%2")
                        .arg(response.value(QStringLiteral("id")).toInt(-1))
                        .arg(response.value(QStringLiteral("error")).toString()));
    }
    m_output.write(QJsonDocument(response).toJson(QJsonDocument::Compact));
    m_output.write("\n");
    m_output.flush();
}

void BackendServer::ensureSavedLocationsWatch()
{
    const QString path = SavedLocations::configDirectoryPath();
    if (!QDir().mkpath(path))
        return;
    QFile::setPermissions(path, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    if (!m_locationsWatcher->directories().contains(path))
        m_locationsWatcher->addPath(path);
}

void BackendServer::emitSavedLocationsChanged()
{
    ensureSavedLocationsWatch();
    writeResponse({{"event", "savedLocationsChanged"}});
}

void BackendServer::enqueueOperation(int id, QThreadPool &pool,
                                     std::function<QJsonObject(const CancellationToken &)> operation,
                                     bool cancellable)
{
    if (m_activeJobs >= maximumActiveJobs) {
        QJsonObject result = failure("Backend job queue is full");
        result.insert("id", id);
        writeResponse(result);
        return;
    }

    auto *watcher = new QFutureWatcher<QJsonObject>(this);
    const CancellationToken token = cancellable ? std::make_shared<std::atomic_bool>(false) : CancellationToken{};
    if (cancellable)
        m_cancellationTokens.insert(id, token);
    ++m_activeJobs;
    connect(watcher, &QFutureWatcher<QJsonObject>::finished, this, [this, watcher, id, token, cancellable] {
        QJsonObject result = watcher->result();
        const bool canceled = cancellationRequested(token);
        if (cancellable) m_cancellationTokens.remove(id);
        if (!canceled) { result.insert("id", id); writeResponse(result); }
        watcher->deleteLater();

        --m_activeJobs;
        if (m_inputClosed && m_activeJobs == 0)
            QCoreApplication::quit();
    });
    watcher->setFuture(QtConcurrent::run(&pool, [operation = std::move(operation), token] {
        try {
            return operation(token);
        } catch (const std::exception &exception) {
            return failure(QStringLiteral("Backend operation failed: %1")
                               .arg(QString::fromLocal8Bit(exception.what())));
        } catch (...) {
            return failure("Backend operation failed unexpectedly");
        }
    }));
}

QJsonObject BackendServer::addDirectoryWatch(const QJsonObject &params)
{
    QString error;
    const QString path = watchPath(params, true, &error);
    if (!error.isEmpty())
        return failure(error);

    auto count = m_directoryWatchCounts.find(path);
    if (count == m_directoryWatchCounts.end()) {
        if (!m_watcher->addPath(path))
            return failure(QStringLiteral("Could not watch directory: %1").arg(path));
        m_directoryWatchCounts.insert(path, 1);
    } else {
        if (!m_watcher->directories().contains(path) && !m_watcher->addPath(path))
            return failure(QStringLiteral("Could not restore directory watch: %1").arg(path));
        ++count.value();
    }
    return {{"ok", true}, {"path", path}};
}

QJsonObject BackendServer::removeDirectoryWatch(const QJsonObject &params)
{
    QString error;
    const QString path = watchPath(params, false, &error);
    if (!error.isEmpty())
        return failure(error);

    auto count = m_directoryWatchCounts.find(path);
    if (count == m_directoryWatchCounts.end())
        return failure(QStringLiteral("Directory is not watched: %1").arg(path));

    if (--count.value() == 0) {
        m_watcher->removePath(path);
        m_directoryWatchCounts.erase(count);
    }
    return {{"ok", true}, {"path", path}};
}

void BackendServer::finishInput()
{
    filesailLog(LogLevel::Debug, "backend",
                QStringLiteral("stdin closed, %1 job(s) remaining").arg(m_activeJobs));
    m_inputClosed = true;
    if (m_notifier)
        m_notifier->setEnabled(false);
    if (m_activeJobs == 0)
        QCoreApplication::quit();
}
