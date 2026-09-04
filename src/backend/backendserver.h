#pragma once

#include <QByteArray>
#include <QFile>
#include <QHash>
#include <QJsonObject>
#include <QQueue>
#include <QObject>
#include <QThreadPool>
#include <QSet>

#include "cancellation.h"

#include <functional>

class QFileSystemWatcher;
class QSocketNotifier;
class QTimer;
class PreviewService;

class BackendServer final : public QObject
{
    Q_OBJECT

public:
    explicit BackendServer(QObject *parent = nullptr);
    bool start();

private:
    using ProgressCallback = std::function<void(const QJsonObject &)>;
    using Operation = std::function<QJsonObject(const CancellationToken &, const ProgressCallback &)>;

    struct MutationJob {
        int id = -1;
        QString method;
        QJsonObject params;
        quint64 queueSequence = 0;
        Operation operation;
        QJsonObject progress;
        QString state = QStringLiteral("queued");
    };

    void readRequests();
    void handleRequest(const QByteArray &line);
    void writeResponse(const QJsonObject &response);
    void enqueueOperation(int id, QThreadPool &pool,
                          std::function<QJsonObject(const CancellationToken &)> operation,
                          bool cancellable = true, bool preview = false);
    void enqueueMutation(int id, const QString &method, const QJsonObject &params,
                         Operation operation);
    void startNextMutation();
    void emitOperationChanged(int id);
    QJsonObject operationSnapshot(const MutationJob &job) const;
    QJsonObject listOperations() const;
    void ensurePreviewService();
    void schedulePreviewServiceIdle();
    QJsonObject addDirectoryWatch(const QJsonObject &params);
    QJsonObject removeDirectoryWatch(const QJsonObject &params);
    void ensureSavedLocationsWatch();
    void emitSavedLocationsChanged();
    void finishInput();

    QFile m_output;
    QByteArray m_requestBuffer;
    QSocketNotifier *m_notifier = nullptr;
    QFileSystemWatcher *m_watcher = nullptr;
    QFileSystemWatcher *m_locationsWatcher = nullptr;
    QTimer *m_locationsDebounce = nullptr;
    QThreadPool m_readPool;
    QThreadPool m_mutationPool;
    PreviewService *m_previewService = nullptr;
    QTimer *m_previewIdleTimer = nullptr;
    QSet<int> m_previewJobs;
    QHash<QString, qsizetype> m_directoryWatchCounts;
    QHash<int, CancellationToken> m_cancellationTokens;
    QHash<int, MutationJob> m_mutationJobs;
    QQueue<int> m_mutationQueue;
    QString m_backendInstance;
    quint64 m_nextOperationSequence = 1;
    quint64 m_eventSequence = 0;
    bool m_mutationRunning = false;
    qsizetype m_activeJobs = 0;
    bool m_inputClosed = false;
};
