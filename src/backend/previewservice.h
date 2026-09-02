#pragma once

#include <QJsonObject>
#include <QObject>
#include <QHash>
#include <QJsonArray>
#include <QStringList>

#include "cancellation.h"

#include <functional>

class QTimer;

class PreviewService final : public QObject
{
    Q_OBJECT

public:
    explicit PreviewService(QObject *parent = nullptr);
    QJsonObject capabilities() const;
    void thumbnails(int requestId, const QJsonObject &params, const CancellationToken &token,
                   std::function<void(QJsonObject)> completed);
    void cancelThumbnail(int requestId);
    QJsonObject text(const QJsonObject &params, const CancellationToken &token = {}) const;
    QJsonObject archive(const QJsonObject &params, const CancellationToken &token = {}) const;

private:
    static QString localRegularFile(const QJsonObject &params, QString *error);
    static QString cachedThumbnail(const QString &path, const QString &flavor);

private slots:
    void tumblerReady(uint handle, const QStringList &uris);
    void tumblerError(uint handle, const QStringList &uris, int code, const QString &message);
    void tumblerFinished(uint handle);

private:
    struct ThumbnailRequest {
        int requestId = -1;
        uint tumblerHandle = 0;
        QString flavor;
        QJsonArray items;
        CancellationToken token;
        std::function<void(QJsonObject)> completed;
    };

    void finishThumbnail(int requestId);
    QHash<int, ThumbnailRequest> m_thumbnailRequests;
    QHash<uint, int> m_tumblerRequests;
};
