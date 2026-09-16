#pragma once

#include <QJsonObject>
#include <QObject>
#include <QHash>
#include <QJsonArray>
#include <QStringList>
#include <QSet>

#include "cancellation.h"

#include <functional>

class QTimer;
class QThreadPool;

class PreviewService final : public QObject
{
    Q_OBJECT

public:
    explicit PreviewService(QObject *parent = nullptr);
    QJsonObject capabilities() const;
    void thumbnails(int requestId, const QJsonObject &params, QThreadPool &readPool,
                   const CancellationToken &token,
                   std::function<void(QJsonObject)> completed);
    void cancelThumbnail(int requestId);
    QJsonObject text(const QJsonObject &params, const CancellationToken &token = {}) const;
    QJsonObject archive(const QJsonObject &params, const CancellationToken &token = {}) const;

private:
    static QString localRegularFile(const QJsonObject &params, QString *error);

private slots:
    void tumblerReady(uint handle, const QStringList &uris);
    void tumblerError(uint handle, const QStringList &uris, int code, const QString &message);
    void tumblerFinished(uint handle);

signals:
    void eventReady(const QJsonObject &event);

private:
    struct ThumbnailSource {
        QString path;
        QString uri;
        QString mimeType;
    };
    struct ThumbnailRequest {
        int requestId = -1;
        quint64 generation = 0;
        uint tumblerHandle = 0;
        QString flavor;
        QString priority;
        QJsonArray items;
        QList<ThumbnailSource> sources;
        CancellationToken token;
        std::function<void(QJsonObject)> completed;
        bool incremental = false;
        bool finished = false;
        bool finalValidationStarted = false;
        int pendingValidation = 0;
        QSet<int> published;
        QSet<int> validating;
    };

    void finishThumbnail(int requestId);
    void startThumbnailValidation(int requestId, const QList<int> &indices, bool publish);
    QHash<int, ThumbnailRequest> m_thumbnailRequests;
    QHash<uint, int> m_tumblerRequests;
    QHash<uint, QStringList> m_earlyTumblerReady;
    QSet<uint> m_earlyTumblerFinished;
    QThreadPool *m_readPool = nullptr;
    quint64 m_nextThumbnailGeneration = 1;
};
