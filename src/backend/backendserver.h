#pragma once

#include <QByteArray>
#include <QFile>
#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QThreadPool>

#include <functional>

class QFileSystemWatcher;
class QSocketNotifier;

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
                          std::function<QJsonObject()> operation);
    QJsonObject addDirectoryWatch(const QJsonObject &params);
    QJsonObject removeDirectoryWatch(const QJsonObject &params);
    void finishInput();

    QFile m_output;
    QByteArray m_requestBuffer;
    QSocketNotifier *m_notifier = nullptr;
    QFileSystemWatcher *m_watcher = nullptr;
    QThreadPool m_readPool;
    QThreadPool m_mutationPool;
    QHash<QString, qsizetype> m_directoryWatchCounts;
    qsizetype m_activeJobs = 0;
    bool m_inputClosed = false;
};
