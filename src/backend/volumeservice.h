#pragma once

#include <QHash>
#include <QDBusConnection>
#include <QDBusObjectPath>
#include <QJsonObject>
#include <QObject>
#include <QSet>
#include <QStringList>
#include <QVariantMap>

#include <functional>

class QDBusPendingCallWatcher;
class QDBusServiceWatcher;
class QTimer;

class VolumeService final : public QObject
{
    Q_OBJECT

public:
    explicit VolumeService(QString backendInstance, QObject *parent = nullptr);
    VolumeService(QString backendInstance, QDBusConnection bus, QString serviceName,
                  QObject *parent = nullptr);

    QJsonObject snapshot() const;
    void handleRequest(int id, const QString &method, const QJsonObject &params);
    QStringList targetMountPoints(const QJsonObject &params) const;
    bool mutationConflicts(const QJsonObject &params) const;

signals:
    void snapshotChanged(const QJsonObject &snapshot);
    void responseReady(int id, const QJsonObject &response);
    void operationChanged(const QString &targetId, const QString &state);

private:
    using InterfaceMap = QHash<QString, QVariantMap>;
    struct VolumeRef {
        QString blockPath;
        QString drivePath;
        QString filesystemPath;
        QString encryptedPath;
        QString cleartextPath;
        QStringList mountPoints;
        bool locked = false;
    };
    struct Reservation {
        QString id;
        QString kind;
        QString targetId;
        QString driveId;
        QStringList mountPoints;
        qint64 expiresAt = 0;
        bool inUse = false;
    };

private slots:
    void scheduleRefresh();
    void interfacesRemoved(const QDBusObjectPath &path, const QStringList &interfaces);

private:
    void refresh();
    void applyManagedObjects(const QVariant &value);
    void rebuildSnapshot();
    void setUnavailable(const QString &message);
    QString opaqueId(const QString &prefix, const QString &objectPath);
    QString objectForId(const QString &id) const;
    VolumeRef resolveVolume(const QString &volumeId) const;
    QStringList siblingDrivePaths(const QString &drivePath) const;
    QStringList validMountPoints(const QVariant &value, bool *representable = nullptr) const;
    bool eligibleBlock(const QString &path, const QVariantMap &block, QString *drivePath) const;
    QJsonObject makeError(const QString &code, const QString &message,
                          const QString &remoteError = {}, const QJsonObject &details = {}) const;
    QJsonObject dbusError(const QString &context, const QString &remoteName,
                          const QString &message, const QJsonObject &details = {}) const;
    void callMethod(int id, const QString &objectPath, const QString &interface,
                    const QString &method, const QVariantList &arguments,
                    std::function<void(const QVariantList &)> success,
                    QJsonObject detail = {}, QString reservationId = {});
    void confirmUnmounted(const QString &filesystemPath, std::function<void(bool)> callback);
    void readMountPoints(const QString &filesystemPath,
                         std::function<void(bool, const QStringList &)> callback);
    void mount(int id, const QJsonObject &params);
    void unlock(int id, const QJsonObject &params);
    void prepareRemoval(int id, const QJsonObject &params);
    void cancelRemoval(int id, const QJsonObject &params);
    void unmount(int id, const QJsonObject &params);
    void safeRemove(int id, const QJsonObject &params);
    void safeRemoveNext(int id, const QString &drivePath, const QString &reservationId,
                        QStringList filesystemPaths, QStringList completedVolumeIds);
    void safeLockNext(int id, const QString &drivePath, const QString &reservationId,
                      QStringList encryptedPaths, QStringList completedVolumeIds);
    void finishSafeRemove(int id, const QString &drivePath, const QString &reservationId,
                          const QStringList &completedVolumeIds);
    bool takeReservation(const QJsonObject &params, const QString &kind, const QString &targetId,
                         Reservation *reservation, QJsonObject *error, bool consume);
    void releaseExpiredReservations();

    QString m_backendInstance;
    QDBusConnection m_bus;
    QString m_serviceName;
    quint64 m_revision = 0;
    quint64 m_identityGeneration = 0;
    bool m_available = false;
    QString m_unavailableReason;
    QJsonObject m_snapshot;
    QHash<QString, InterfaceMap> m_objects;
    QHash<QString, QString> m_objectIds;
    QHash<QString, QString> m_idObjects;
    QHash<QString, Reservation> m_reservations;
    QHash<int, QString> m_requestActionKeys;
    QSet<QString> m_activeActionKeys;
    QTimer *m_refreshTimer = nullptr;
    QDBusServiceWatcher *m_serviceWatcher = nullptr;
    bool m_refreshing = false;
    bool m_refreshAgain = false;
};
