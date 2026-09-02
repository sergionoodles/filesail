#pragma once

#include <QByteArray>
#include <QFile>
#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QThreadPool>

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
    void readRequests();
    void handleRequest(const QByteArray &line);
    void writeResponse(const QJsonObject &response);
    void enqueueOperation(int id, QThreadPool &pool,
                          std::function<QJsonObject(const CancellationToken &)> operation,
                          bool cancellable = true);
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
    QHash<QString, qsizetype> m_directoryWatchCounts;
    QHash<int, CancellationToken> m_cancellationTokens;
    qsizetype m_activeJobs = 0;
    bool m_inputClosed = false;
};
