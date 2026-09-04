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
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QMetaObject>
#include <QSocketNotifier>
#include <QTimer>
#include <QUuid>
#include <QUrl>
#include <QVector>
#include <QtConcurrentRun>

#include <algorithm>
#include <cerrno>
#include <exception>
#include <unistd.h>

namespace {
constexpr qsizetype maximumRequestBytes = 8 * 1024 * 1024;
constexpr qsizetype maximumActiveJobs = 64;
constexpr int previewIdleMilliseconds = 15000;

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
    , m_backendInstance(QUuid::createUuid().toString(QUuid::WithoutBraces))
{
    m_readPool.setMaxThreadCount(2);
    m_mutationPool.setMaxThreadCount(1);
    m_previewIdleTimer = new QTimer(this);
    m_previewIdleTimer->setSingleShot(true);
    m_previewIdleTimer->setInterval(previewIdleMilliseconds);
    connect(m_previewIdleTimer, &QTimer::timeout, this, [this] {
        if (!m_previewJobs.isEmpty() || !m_previewService)
            return;
        filesailLog(LogLevel::Debug, "preview", "destroying idle preview service");
        delete m_previewService;
        m_previewService = nullptr;
    });
}

void BackendServer::ensurePreviewService()
{
    if (m_previewService)
        return;
    filesailLog(LogLevel::Debug, "preview", "creating preview service on demand");
    m_previewService = new PreviewService(this);
}

void BackendServer::schedulePreviewServiceIdle()
{
    if (m_previewService && m_previewJobs.isEmpty())
        m_previewIdleTimer->start();
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
        enqueueMutation(id, method, params, [params](const CancellationToken &, const ProgressCallback &) { return SavedLocations::add(params); });
    } else if (method == "locations.remove") {
        ensureSavedLocationsWatch();
        enqueueMutation(id, method, params, [params](const CancellationToken &, const ProgressCallback &) { return SavedLocations::remove(params); });
    } else if (method == "mkdir") {
        enqueueMutation(id, method, params, [params](const CancellationToken &, const ProgressCallback &) { return FileOperations::createDirectory(params); });
    } else if (method == "rename") {
        enqueueMutation(id, method, params, [params](const CancellationToken &, const ProgressCallback &) { return FileOperations::renamePath(params); });
    } else if (method == "trash") {
        enqueueMutation(id, method, params, [params](const CancellationToken &, const ProgressCallback &) { return FileOperations::trashPaths(params); });
    } else if (method == "copy") {
        enqueueMutation(id, method, params, [params](const CancellationToken &token, const ProgressCallback &progress) {
            return FileOperations::copyPaths(params, token, progress);
        });
    } else if (method == "move") {
        enqueueMutation(id, method, params, [params](const CancellationToken &token, const ProgressCallback &progress) {
            return FileOperations::movePaths(params, token, progress);
        });
    } else if (method == "setExecutable") {
        enqueueMutation(id, method, params, [params](const CancellationToken &, const ProgressCallback &) { return FileOperations::setExecutable(params); });
    } else if (method == "open") {
        enqueueOperation(id, m_readPool, [params](const CancellationToken &) { return FileOperations::openPath(params); }, false);
    } else if (method == "terminal") {
        enqueueOperation(id, m_readPool, [params](const CancellationToken &) { return FileOperations::openTerminal(params); }, false);
    } else if (method == "previewCapabilities") {
        ensurePreviewService();
        m_previewIdleTimer->stop();
        QJsonObject result = m_previewService->capabilities(); result.insert("id", id); writeResponse(result);
        schedulePreviewServiceIdle();
    } else if (method == "thumbnailBatch") {
        if (m_activeJobs >= maximumActiveJobs) {
            writeResponse({{"id", id}, {"ok", false}, {"error", "Backend job queue is full"}});
            return;
        }
        ensurePreviewService();
        m_previewIdleTimer->stop();
        const CancellationToken token = std::make_shared<std::atomic_bool>(false);
        m_cancellationTokens.insert(id, token);
        m_previewJobs.insert(id);
        filesailLog(LogLevel::Debug, "preview",
                    QStringLiteral("job acquire count=%1").arg(m_previewJobs.size()));
        ++m_activeJobs;
        m_previewService->thumbnails(id, params, token, [this, id, token](QJsonObject result) {
            const bool canceled = cancellationRequested(token);
            m_cancellationTokens.remove(id);
            m_previewJobs.remove(id);
            filesailLog(LogLevel::Debug, "preview",
                        QStringLiteral("job release count=%1").arg(m_previewJobs.size()));
            if (!canceled) { result.insert("id", id); writeResponse(result); }
            --m_activeJobs;
            schedulePreviewServiceIdle();
            if (m_inputClosed && m_activeJobs == 0) QCoreApplication::quit();
        });
    } else if (method == "operations.list") {
        QJsonObject result = listOperations();
        result.insert("id", id);
        writeResponse(result);
    } else if (method == "textPreview") {
        ensurePreviewService();
        enqueueOperation(id, m_readPool, [this, params](const CancellationToken &token) { return m_previewService->text(params, token); }, true, true);
    } else if (method == "archivePreview") {
        ensurePreviewService();
        enqueueOperation(id, m_readPool, [this, params](const CancellationToken &token) { return m_previewService->archive(params, token); }, true, true);
    } else if (method == "cancelPreview") {
        const int requestId = params.value("requestId").toInt(-1);
        if (const auto token = m_cancellationTokens.value(requestId)) {
            token->store(true, std::memory_order_relaxed);
            if (m_previewJobs.contains(requestId) && m_previewService)
                m_previewService->cancelThumbnail(requestId);
        }
        writeResponse({{"id", id}, {"ok", true}});
    } else if (method == "cancel") {
        const int requestId = params.value("requestId").toInt(-1);
        if (const auto token = m_cancellationTokens.value(requestId)) {
            token->store(true, std::memory_order_relaxed);
            if (m_previewJobs.contains(requestId) && m_previewService)
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

void BackendServer::enqueueMutation(int id, const QString &method, const QJsonObject &params,
                                    Operation operation)
{
    constexpr qsizetype maximumMutationJobs = 32;
    if (m_activeJobs >= maximumActiveJobs || m_mutationJobs.size() >= maximumMutationJobs) {
        QJsonObject result = failure("Backend mutation queue is full");
        result.insert("id", id);
        writeResponse(result);
        return;
    }
    if (m_mutationJobs.contains(id)) {
        QJsonObject result = failure("Duplicate backend operation id");
        result.insert("id", id);
        writeResponse(result);
        return;
    }

    MutationJob job;
    job.id = id;
    job.method = method;
    job.params = params;
    job.queueSequence = m_nextOperationSequence++;
    job.operation = std::move(operation);
    m_mutationJobs.insert(id, std::move(job));
    m_mutationQueue.enqueue(id);
    ++m_activeJobs;
    emitOperationChanged(id);
    startNextMutation();
}

void BackendServer::startNextMutation()
{
    if (m_mutationRunning || m_mutationQueue.isEmpty())
        return;

    const int id = m_mutationQueue.dequeue();
    auto iterator = m_mutationJobs.find(id);
    if (iterator == m_mutationJobs.end()) {
        startNextMutation();
        return;
    }

    iterator->state = QStringLiteral("running");
    iterator->progress = QJsonObject{{"phase", "preparing"}};
    emitOperationChanged(id);
    m_mutationRunning = true;

    const Operation operation = iterator->operation;
    const ProgressCallback progress = [this, id](const QJsonObject &update) {
        // File operations run on the worker pool. All protocol writes and
        // operation registry mutations remain on the backend event thread.
        QMetaObject::invokeMethod(this, [this, id, update] {
            auto iterator = m_mutationJobs.find(id);
            if (iterator == m_mutationJobs.end() || iterator->state != "running")
                return;
            for (auto updateIterator = update.constBegin(); updateIterator != update.constEnd(); ++updateIterator)
                iterator->progress.insert(updateIterator.key(), updateIterator.value());
            emitOperationChanged(id);
        }, Qt::QueuedConnection);
    };

    auto *watcher = new QFutureWatcher<QJsonObject>(this);
    connect(watcher, &QFutureWatcher<QJsonObject>::finished, this, [this, watcher, id] {
        QJsonObject result = watcher->result();
        result.insert("id", id);
        writeResponse(result);
        watcher->deleteLater();

        m_mutationJobs.remove(id);
        m_mutationRunning = false;
        --m_activeJobs;
        startNextMutation();
        if (m_inputClosed && m_activeJobs == 0)
            QCoreApplication::quit();
    });
    watcher->setFuture(QtConcurrent::run(&m_mutationPool, [operation, progress] {
        try {
            const CancellationToken token;
            return operation(token, progress);
        } catch (const std::exception &exception) {
            return failure(QStringLiteral("Backend operation failed: %1")
                               .arg(QString::fromLocal8Bit(exception.what())));
        } catch (...) {
            return failure("Backend operation failed unexpectedly");
        }
    }));
}

QJsonObject BackendServer::operationSnapshot(const MutationJob &job) const
{
    QJsonObject operation{
        {"id", job.id},
        {"method", job.method},
        {"state", job.state},
        {"queueSequence", static_cast<qint64>(job.queueSequence)},
        {"progress", job.progress},
    };
    if (job.params.value("paths").isArray())
        operation.insert("paths", job.params.value("paths"));
    if (job.params.value("targetDirectory").isString())
        operation.insert("targetDirectory", job.params.value("targetDirectory"));
    return operation;
}

void BackendServer::emitOperationChanged(int id)
{
    const auto iterator = m_mutationJobs.constFind(id);
    if (iterator == m_mutationJobs.constEnd())
        return;
    writeResponse({
        {"event", "operationChanged"},
        {"backendInstance", m_backendInstance},
        {"eventSequence", static_cast<qint64>(++m_eventSequence)},
        {"operation", operationSnapshot(iterator.value())},
    });
}

QJsonObject BackendServer::listOperations() const
{
    QVector<const MutationJob *> jobs;
    jobs.reserve(m_mutationJobs.size());
    for (const MutationJob &job : m_mutationJobs)
        jobs.append(&job);
    std::sort(jobs.begin(), jobs.end(), [](const MutationJob *left, const MutationJob *right) {
        return left->queueSequence < right->queueSequence;
    });

    QJsonArray operations;
    for (const MutationJob *job : jobs)
        operations.append(operationSnapshot(*job));
    return {
        {"ok", true},
        {"backendInstance", m_backendInstance},
        {"eventSequence", static_cast<qint64>(m_eventSequence)},
        {"operations", operations},
    };
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
                                     bool cancellable, bool preview)
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
    if (preview) {
        m_previewIdleTimer->stop();
        m_previewJobs.insert(id);
        filesailLog(LogLevel::Debug, "preview",
                    QStringLiteral("job acquire count=%1").arg(m_previewJobs.size()));
    }
    ++m_activeJobs;
    connect(watcher, &QFutureWatcher<QJsonObject>::finished, this, [this, watcher, id, token, cancellable, preview] {
        QJsonObject result = watcher->result();
        const bool canceled = cancellationRequested(token);
        if (cancellable) m_cancellationTokens.remove(id);
        if (preview) {
            m_previewJobs.remove(id);
            filesailLog(LogLevel::Debug, "preview",
                        QStringLiteral("job release count=%1").arg(m_previewJobs.size()));
        }
        if (!canceled) { result.insert("id", id); writeResponse(result); }
        watcher->deleteLater();

        --m_activeJobs;
        if (preview) schedulePreviewServiceIdle();
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
