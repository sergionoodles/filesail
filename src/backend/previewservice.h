#pragma once

#include <QJsonObject>
#include <QObject>
#include <QSet>

class QEventLoop;

class PreviewService final : public QObject
{
    Q_OBJECT

public:
    explicit PreviewService(QObject *parent = nullptr);
    QJsonObject capabilities() const;
    QJsonObject thumbnails(const QJsonObject &params);
    QJsonObject text(const QJsonObject &params) const;
    QJsonObject archive(const QJsonObject &params) const;

private:
    static QString localRegularFile(const QJsonObject &params, QString *error);
    static QString cachedThumbnail(const QString &path, const QString &flavor);

private slots:
    void tumblerReady(uint handle, const QStringList &uris);
    void tumblerError(uint handle, const QStringList &uris, int code, const QString &message);
    void tumblerFinished(uint handle);

private:
    uint m_tumblerHandle = 0;
    QEventLoop *m_tumblerWaitLoop = nullptr;
    QSet<QString> m_tumblerReadyUris;
    QSet<QString> m_tumblerErrorUris;
};
