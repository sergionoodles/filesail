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
constexpr qsizetype maximumActiveJobs = 256;

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
    while ((newline = m_requestBuffer.indexOf('\n')) >= 0) {
        const QByteArray frame = m_requestBuffer.first(newline).trimmed();
        m_requestBuffer.remove(0, newline + 1);
        if (frame.size() > maximumRequestBytes) {
            writeResponse({{"id", -1}, {"ok", false}, {"error", "Request exceeds 8 MiB limit"}});
        } else if (!frame.isEmpty()) {
            handleRequest(frame);
        }
    }
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
        enqueueOperation(id, m_readPool, [params] { return FileOperations::listDirectory(params); });
    } else if (method == "locations.list") {
        ensureSavedLocationsWatch();
        enqueueOperation(id, m_readPool, [] { return SavedLocations::list(); });
    } else if (method == "locations.add") {
        ensureSavedLocationsWatch();
        enqueueOperation(id, m_mutationPool, [params] { return SavedLocations::add(params); });
    } else if (method == "locations.remove") {
        ensureSavedLocationsWatch();
        enqueueOperation(id, m_mutationPool, [params] { return SavedLocations::remove(params); });
    } else if (method == "mkdir") {
        enqueueOperation(id, m_mutationPool, [params] { return FileOperations::createDirectory(params); });
    } else if (method == "rename") {
        enqueueOperation(id, m_mutationPool, [params] { return FileOperations::renamePath(params); });
    } else if (method == "trash") {
        enqueueOperation(id, m_mutationPool, [params] { return FileOperations::trashPaths(params); });
    } else if (method == "copy") {
        enqueueOperation(id, m_mutationPool, [params] { return FileOperations::copyPaths(params); });
    } else if (method == "move") {
        enqueueOperation(id, m_mutationPool, [params] { return FileOperations::movePaths(params); });
    } else if (method == "open") {
        enqueueOperation(id, m_readPool, [params] { return FileOperations::openPath(params); });
    } else if (method == "terminal") {
        enqueueOperation(id, m_readPool, [params] { return FileOperations::openTerminal(params); });
    } else if (method == "previewCapabilities") {
        QJsonObject result = m_previewService->capabilities(); result.insert("id", id); writeResponse(result);
    } else if (method == "thumbnailBatch") {
        QJsonObject result = m_previewService->thumbnails(params); result.insert("id", id); writeResponse(result);
    } else if (method == "textPreview") {
        enqueueOperation(id, m_readPool, [this, params] { return m_previewService->text(params); });
    } else if (method == "archivePreview") {
        enqueueOperation(id, m_readPool, [this, params] { return m_previewService->archive(params); });
    } else if (method == "cancelPreview") {
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
                                     std::function<QJsonObject()> operation)
{
    if (m_activeJobs >= maximumActiveJobs) {
        QJsonObject result = failure("Backend job queue is full");
        result.insert("id", id);
        writeResponse(result);
        return;
    }

    auto *watcher = new QFutureWatcher<QJsonObject>(this);
    ++m_activeJobs;
    connect(watcher, &QFutureWatcher<QJsonObject>::finished, this, [this, watcher, id] {
        QJsonObject result = watcher->result();
        result.insert("id", id);
        writeResponse(result);
        watcher->deleteLater();

        --m_activeJobs;
        if (m_inputClosed && m_activeJobs == 0)
            QCoreApplication::quit();
    });
    watcher->setFuture(QtConcurrent::run(&pool, [operation = std::move(operation)] {
        try {
            return operation();
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
