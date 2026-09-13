#include "volumeservice.h"

#include "logging.h"

#include <QCryptographicHash>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusInterface>
#include <QDBusMetaType>
#include <QDBusObjectPath>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDBusServiceWatcher>
#include <QDBusVariant>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QTimer>
#include <QUuid>

#include <algorithm>
#include <memory>

namespace {
constexpr auto serviceName = "org.freedesktop.UDisks2";
constexpr auto managerPath = "/org/freedesktop/UDisks2";
constexpr auto objectManagerInterface = "org.freedesktop.DBus.ObjectManager";
constexpr auto managerInterface = "org.freedesktop.UDisks2.Manager";
constexpr auto propertiesInterface = "org.freedesktop.DBus.Properties";
constexpr auto driveInterface = "org.freedesktop.UDisks2.Drive";
constexpr auto blockInterface = "org.freedesktop.UDisks2.Block";
constexpr auto filesystemInterface = "org.freedesktop.UDisks2.Filesystem";
constexpr auto encryptedInterface = "org.freedesktop.UDisks2.Encrypted";
constexpr auto partitionInterface = "org.freedesktop.UDisks2.Partition";
constexpr int dbusTimeoutMilliseconds = 120000;
constexpr int reservationLifetimeMilliseconds = 30000;
constexpr qsizetype maximumObjects = 4096;
constexpr qsizetype maximumMountPoints = 32;
constexpr qsizetype maximumText = 1024;

using DBusPropertyMap = QMap<QString, QVariantMap>;
using DBusManagedObjects = QMap<QDBusObjectPath, DBusPropertyMap>;

QString boundedText(const QString &value, qsizetype maximum = maximumText)
{
    QString result = value.left(maximum);
    result.remove(QChar::Null);
    return result;
}

QString stringProperty(const QVariantMap &map, const char *name)
{
    return boundedText(map.value(QString::fromLatin1(name)).toString(), 256);
}

bool boolProperty(const QVariantMap &map, const char *name)
{
    return map.value(QString::fromLatin1(name)).toBool();
}

qulonglong unsignedProperty(const QVariantMap &map, const char *name)
{
    return map.value(QString::fromLatin1(name)).toULongLong();
}

QString pathProperty(const QVariantMap &map, const char *name)
{
    const QVariant value = map.value(QString::fromLatin1(name));
    if (value.canConvert<QDBusObjectPath>())
        return value.value<QDBusObjectPath>().path();
    return value.toString();
}

QVariantMap emptyOptions()
{
    return {};
}

bool containsPath(const QString &parent, const QString &child)
{
    if (parent.isEmpty() || child.isEmpty() || !QDir::isAbsolutePath(parent)
        || !QDir::isAbsolutePath(child))
        return false;
    const QString cleanParent = QDir::cleanPath(parent);
    const QString cleanChild = QDir::cleanPath(child);
    return cleanChild == cleanParent
        || cleanChild.startsWith(cleanParent == QStringLiteral("/")
                                     ? cleanParent : cleanParent + QLatin1Char('/'));
}

QStringList operationPaths(const QJsonObject &params)
{
    QStringList paths;
    const auto append = [&paths](const QJsonValue &value) {
        if (value.isString() && QDir::isAbsolutePath(value.toString()))
            paths.append(QDir::cleanPath(value.toString()));
    };
    append(params.value(QStringLiteral("path")));
    append(params.value(QStringLiteral("parent")));
    append(params.value(QStringLiteral("targetDirectory")));
    for (const QJsonValue &value : params.value(QStringLiteral("paths")).toArray()) append(value);
    return paths;
}

QString baseDeviceName(const QVariant &value)
{
    QByteArray bytes;
    if (value.canConvert<QByteArray>())
        bytes = value.toByteArray();
    else
        bytes = value.toString().toLocal8Bit();
    if (!bytes.isEmpty() && bytes.endsWith('\0'))
        bytes.chop(1);
    return QFileInfo(QFile::decodeName(bytes)).fileName();
}

}

Q_DECLARE_METATYPE(DBusPropertyMap)
Q_DECLARE_METATYPE(DBusManagedObjects)

VolumeService::VolumeService(QString backendInstance, QObject *parent)
    : VolumeService(std::move(backendInstance), QDBusConnection::systemBus(),
                    QString::fromLatin1(serviceName), parent)
{
}

VolumeService::VolumeService(QString backendInstance, QDBusConnection bus,
                             QString configuredServiceName, QObject *parent)
    : QObject(parent)
    , m_backendInstance(std::move(backendInstance))
    , m_bus(std::move(bus))
    , m_serviceName(std::move(configuredServiceName))
{
    qDBusRegisterMetaType<DBusPropertyMap>();
    qDBusRegisterMetaType<DBusManagedObjects>();

    m_refreshTimer = new QTimer(this);
    m_refreshTimer->setSingleShot(true);
    m_refreshTimer->setInterval(75);
    connect(m_refreshTimer, &QTimer::timeout, this, &VolumeService::refresh);

    m_serviceWatcher = new QDBusServiceWatcher(m_serviceName, m_bus,
        QDBusServiceWatcher::WatchForOwnerChange, this);
    connect(m_serviceWatcher, &QDBusServiceWatcher::serviceOwnerChanged, this,
            [this](const QString &, const QString &, const QString &newOwner) {
        m_objects.clear();
        m_objectIds.clear();
        m_idObjects.clear();
        m_reservations.clear();
        m_requestActionKeys.clear();
        m_activeActionKeys.clear();
        if (newOwner.isEmpty())
            setUnavailable(QStringLiteral("UDisks2 is not available"));
        else
            scheduleRefresh();
    });
    connect(this, &VolumeService::responseReady, this, [this](int id, const QJsonObject &) {
        const QString key = m_requestActionKeys.take(id);
        if (!key.isEmpty()) m_activeActionKeys.remove(key);
    });

    m_bus.connect(m_serviceName, QString::fromLatin1(managerPath),
                QString::fromLatin1(objectManagerInterface), QStringLiteral("InterfacesAdded"),
                this, SLOT(scheduleRefresh()));
    m_bus.connect(m_serviceName, QString::fromLatin1(managerPath),
                QString::fromLatin1(objectManagerInterface), QStringLiteral("InterfacesRemoved"),
                this, SLOT(interfacesRemoved(QDBusObjectPath,QStringList)));
    m_bus.connect(m_serviceName, QString(),
                QString::fromLatin1(propertiesInterface), QStringLiteral("PropertiesChanged"),
                this, SLOT(scheduleRefresh()));
    scheduleRefresh();
}

void VolumeService::scheduleRefresh()
{
    if (m_refreshing) {
        m_refreshAgain = true;
        return;
    }
    m_refreshTimer->start();
}

void VolumeService::interfacesRemoved(const QDBusObjectPath &path, const QStringList &)
{
    const QString suffix = QLatin1Char(':') + path.path();
    for (auto it = m_objectIds.begin(); it != m_objectIds.end();) {
        if (it.key().endsWith(suffix)) {
            m_idObjects.remove(it.value());
            it = m_objectIds.erase(it);
        } else {
            ++it;
        }
    }
    scheduleRefresh();
}

void VolumeService::refresh()
{
    if (m_refreshing)
        return;
    if (!m_bus.isConnected()) {
        setUnavailable(QStringLiteral("The system D-Bus is not available"));
        return;
    }
    m_refreshing = true;
    QDBusInterface manager(m_serviceName, QString::fromLatin1(managerPath),
                           QString::fromLatin1(objectManagerInterface), m_bus);
    manager.setTimeout(dbusTimeoutMilliseconds);
    auto *watcher = new QDBusPendingCallWatcher(manager.asyncCall(QStringLiteral("GetManagedObjects")), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, watcher] {
        QDBusPendingReply<DBusManagedObjects> reply = *watcher;
        watcher->deleteLater();
        m_refreshing = false;
        if (reply.isError()) {
            setUnavailable(boundedText(reply.error().message()));
        } else {
            applyManagedObjects(QVariant::fromValue(reply.value()));
        }
        if (m_refreshAgain) {
            m_refreshAgain = false;
            scheduleRefresh();
        }
    });
}

void VolumeService::applyManagedObjects(const QVariant &value)
{
    const DBusManagedObjects managed = value.value<DBusManagedObjects>();
    if (managed.size() > maximumObjects) {
        setUnavailable(QStringLiteral("UDisks2 returned too many objects"));
        return;
    }
    QHash<QString, InterfaceMap> next;
    for (auto object = managed.cbegin(); object != managed.cend(); ++object) {
        InterfaceMap interfaces;
        for (auto interface = object.value().cbegin(); interface != object.value().cend(); ++interface)
            interfaces.insert(interface.key(), interface.value());
        next.insert(object.key().path(), interfaces);
    }
    const QString version = stringProperty(next.value(QString::fromLatin1(managerPath))
        .value(QString::fromLatin1(managerInterface)), "Version");
    if (!version.isEmpty() && !version.startsWith(QStringLiteral("2."))) {
        setUnavailable(QStringLiteral("The installed UDisks API version is not supported"));
        return;
    }
    m_objects = std::move(next);
    m_available = true;
    m_unavailableReason.clear();
    rebuildSnapshot();
}

QString VolumeService::opaqueId(const QString &prefix, const QString &objectPath)
{
    const QString key = prefix + QLatin1Char(':') + objectPath;
    if (m_objectIds.contains(key))
        return m_objectIds.value(key);
    const QByteArray digest = QCryptographicHash::hash(
        (m_backendInstance + QLatin1Char(':') + key + QLatin1Char(':')
         + QString::number(++m_identityGeneration)).toUtf8(), QCryptographicHash::Sha256)
                                  .toBase64(QByteArray::Base64UrlEncoding | QByteArray::OmitTrailingEquals)
                                  .left(18);
    const QString id = prefix + QLatin1Char('-') + QString::fromLatin1(digest);
    m_objectIds.insert(key, id);
    m_idObjects.insert(id, objectPath);
    return id;
}

QString VolumeService::objectForId(const QString &id) const
{
    const QString path = m_idObjects.value(id);
    return m_objects.contains(path) ? path : QString();
}

QStringList VolumeService::validMountPoints(const QVariant &value, bool *representable) const
{
    if (representable)
        *representable = true;
    QList<QByteArray> points;
    if (value.canConvert<QList<QByteArray>>())
        points = value.value<QList<QByteArray>>();
    else if (value.userType() == qMetaTypeId<QDBusArgument>())
        points = qdbus_cast<QList<QByteArray>>(value.value<QDBusArgument>());
    if (points.size() > maximumMountPoints) {
        if (representable)
            *representable = false;
        points = points.mid(0, maximumMountPoints);
    }
    QStringList result;
    for (QByteArray bytes : points) {
        if (bytes.endsWith('\0'))
            bytes.chop(1);
        if (bytes.contains('\0')) {
            if (representable) *representable = false;
            continue;
        }
        const QString decoded = QFile::decodeName(bytes);
        if (decoded.isEmpty() || !QDir::isAbsolutePath(decoded)
            || QFile::encodeName(decoded) != bytes) {
            if (representable) *representable = false;
            continue;
        }
        result.append(QDir::cleanPath(decoded));
    }
    result.removeDuplicates();
    return result;
}

bool VolumeService::eligibleBlock(const QString &, const QVariantMap &block, QString *drivePath) const
{
    if (boolProperty(block, "HintIgnore") || boolProperty(block, "HintSystem"))
        return false;
    const QString cryptoBacking = pathProperty(block, "CryptoBackingDevice");
    QVariantMap backingBlock;
    if (!cryptoBacking.isEmpty() && cryptoBacking != QStringLiteral("/")) {
        backingBlock = m_objects.value(cryptoBacking).value(QString::fromLatin1(blockInterface));
        if (backingBlock.isEmpty() || boolProperty(backingBlock, "HintSystem")
            || boolProperty(backingBlock, "HintIgnore"))
            return false;
    }
    QString drive = pathProperty(block, "Drive");
    if ((drive.isEmpty() || drive == QStringLiteral("/")) && !backingBlock.isEmpty())
        drive = pathProperty(backingBlock, "Drive");
    if (drive.isEmpty() || drive == QStringLiteral("/") || !m_objects.contains(drive))
        return false;
    const QVariantMap driveProperties = m_objects.value(drive).value(QString::fromLatin1(driveInterface));
    if (driveProperties.isEmpty())
        return false;
    const QString seat = stringProperty(driveProperties, "Seat");
    if (!seat.isEmpty() && seat != QStringLiteral("seat0"))
        return false;
    const QString bus = stringProperty(driveProperties, "ConnectionBus").toLower();
    const QStringList media = driveProperties.value(QStringLiteral("MediaCompatibility")).toStringList();
    const bool externalBus = bus == QStringLiteral("usb") || bus == QStringLiteral("mmc")
        || bus == QStringLiteral("firewire") || bus == QStringLiteral("ieee1394");
    const bool mediaDevice = std::any_of(media.cbegin(), media.cend(), [](const QString &item) {
        return item.contains(QStringLiteral("flash"), Qt::CaseInsensitive)
            || item.contains(QStringLiteral("sd"), Qt::CaseInsensitive)
            || item.contains(QStringLiteral("mmc"), Qt::CaseInsensitive)
            || item.contains(QStringLiteral("optical"), Qt::CaseInsensitive);
    });
    if (!boolProperty(driveProperties, "Removable") && !boolProperty(driveProperties, "Ejectable")
        && !boolProperty(driveProperties, "CanPowerOff") && !externalBus && !mediaDevice)
        return false;
    *drivePath = drive;
    return true;
}

void VolumeService::rebuildSnapshot()
{
    QHash<QString, QJsonArray> volumesByDrive;
    QHash<QString, qulonglong> sizesByDrive;
    QSet<QString> visibleDrives;

    for (auto object = m_objects.cbegin(); object != m_objects.cend(); ++object) {
        const QVariantMap block = object.value().value(QString::fromLatin1(blockInterface));
        if (block.isEmpty())
            continue;
        QString drivePath;
        if (!eligibleBlock(object.key(), block, &drivePath))
            continue;

        const QVariantMap filesystem = object.value().value(QString::fromLatin1(filesystemInterface));
        const QVariantMap encrypted = object.value().value(QString::fromLatin1(encryptedInterface));
        const QVariantMap partition = object.value().value(QString::fromLatin1(partitionInterface));
        const bool locked = !encrypted.isEmpty()
            && pathProperty(encrypted, "CleartextDevice") == QStringLiteral("/");
        if (!encrypted.isEmpty() && !locked)
            continue; // The cleartext block is the user-visible unlocked volume.
        const QString fsType = stringProperty(block, "IdType");
        const bool mountable = !filesystem.isEmpty();
        const QVariantMap drive = m_objects.value(drivePath).value(QString::fromLatin1(driveInterface));
        if (!mountable && !locked && fsType.isEmpty() && partition.isEmpty()) {
            const QStringList compatibility = drive.value(QStringLiteral("MediaCompatibility")).toStringList();
            const bool optical = std::any_of(compatibility.cbegin(), compatibility.cend(), [](const QString &item) {
                return item.contains(QStringLiteral("optical"), Qt::CaseInsensitive);
            });
            if (!optical || !boolProperty(drive, "MediaAvailable") || !boolProperty(drive, "Ejectable"))
                continue;
        }

        bool representable = true;
        const QStringList mountPoints = validMountPoints(filesystem.value(QStringLiteral("MountPoints")),
                                                         &representable);
        QString label = stringProperty(block, "HintName");
        if (label.isEmpty()) label = stringProperty(block, "IdLabel");
        if (label.isEmpty()) label = stringProperty(partition, "Name");
        if (label.isEmpty()) label = (stringProperty(drive, "Vendor") + QLatin1Char(' ')
                                      + stringProperty(drive, "Model")).trimmed();
        if (label.isEmpty()) label = baseDeviceName(block.value(QStringLiteral("PreferredDevice")));
        if (label.isEmpty()) label = QStringLiteral("External Drive");

        const QString volumeId = opaqueId(QStringLiteral("volume"), object.key());
        QJsonArray mounts;
        for (const QString &point : mountPoints) mounts.append(point);
        QJsonObject volume{
            {QStringLiteral("volumeId"), volumeId},
            {QStringLiteral("label"), boundedText(label, 256)},
            {QStringLiteral("filesystemType"), fsType},
            {QStringLiteral("sizeBytes"), QString::number(unsignedProperty(block, "Size"))},
            {QStringLiteral("mountPoints"), mounts},
            {QStringLiteral("mounted"), !mountPoints.isEmpty()},
            {QStringLiteral("locked"), locked},
            {QStringLiteral("readOnly"), boolProperty(block, "ReadOnly")},
            {QStringLiteral("mountable"), mountable},
            {QStringLiteral("navigable"), representable && !mountPoints.isEmpty()},
            {QStringLiteral("status"), !representable ? QStringLiteral("path_unrepresentable")
                : locked ? QStringLiteral("locked") : !mountPoints.isEmpty() ? QStringLiteral("mounted")
                : mountable ? QStringLiteral("unmounted") : QStringLiteral("unsupported")}
        };
        const qulonglong partitionNumber = unsignedProperty(partition, "Number");
        if (partitionNumber > 0)
            volume.insert(QStringLiteral("partitionNumber"), QString::number(partitionNumber));
        volumesByDrive[drivePath].append(volume);
        sizesByDrive[drivePath] += unsignedProperty(block, "Size");
        visibleDrives.insert(drivePath);
    }

    QJsonArray drives;
    QStringList sortedDrives = visibleDrives.values();
    std::sort(sortedDrives.begin(), sortedDrives.end());
    for (const QString &path : std::as_const(sortedDrives)) {
        const QVariantMap drive = m_objects.value(path).value(QString::fromLatin1(driveInterface));
        QString label = (stringProperty(drive, "Vendor") + QLatin1Char(' ')
                         + stringProperty(drive, "Model")).trimmed();
        if (label.isEmpty()) label = stringProperty(drive, "Media");
        if (label.isEmpty()) label = QStringLiteral("External Drive");
        const QString bus = stringProperty(drive, "ConnectionBus").toLower();
        const QStringList compatibility = drive.value(QStringLiteral("MediaCompatibility")).toStringList();
        QString kind = bus == QStringLiteral("usb") ? QStringLiteral("usb") : QStringLiteral("drive");
        for (const QString &media : compatibility) {
            if (media.contains(QStringLiteral("sd"), Qt::CaseInsensitive)
                || media.contains(QStringLiteral("mmc"), Qt::CaseInsensitive)) kind = QStringLiteral("card");
            if (media.contains(QStringLiteral("optical"), Qt::CaseInsensitive)) kind = QStringLiteral("optical");
        }
        QJsonArray affectedDriveIds;
        for (const QString &siblingPath : siblingDrivePaths(path))
            affectedDriveIds.append(opaqueId(QStringLiteral("drive"), siblingPath));
        drives.append(QJsonObject{
            {QStringLiteral("driveId"), opaqueId(QStringLiteral("drive"), path)},
            {QStringLiteral("label"), boundedText(label, 256)},
            {QStringLiteral("kind"), kind},
            {QStringLiteral("sizeBytes"), QString::number(sizesByDrive.value(path))},
            {QStringLiteral("removable"), boolProperty(drive, "Removable")},
            {QStringLiteral("ejectable"), boolProperty(drive, "Ejectable")},
            {QStringLiteral("canPowerOff"), boolProperty(drive, "CanPowerOff")},
            {QStringLiteral("siblingGroup"), stringProperty(drive, "SiblingId").isEmpty()
                ? QString() : opaqueId(QStringLiteral("sibling"), stringProperty(drive, "SiblingId"))},
            {QStringLiteral("affectedSiblingCount"), siblingDrivePaths(path).size()},
            {QStringLiteral("affectedDriveIds"), affectedDriveIds},
            {QStringLiteral("volumes"), volumesByDrive.value(path)}
        });
    }

    ++m_revision;
    m_snapshot = {
        {QStringLiteral("available"), m_available},
        {QStringLiteral("protocolVersion"), 1},
        {QStringLiteral("backendInstance"), m_backendInstance},
        {QStringLiteral("revision"), QString::number(m_revision)},
        {QStringLiteral("drives"), drives}
    };
    if (!m_unavailableReason.isEmpty())
        m_snapshot.insert(QStringLiteral("unavailableReason"), m_unavailableReason);
    releaseExpiredReservations();
    emit snapshotChanged(m_snapshot);
}

void VolumeService::setUnavailable(const QString &message)
{
    m_available = false;
    m_unavailableReason = boundedText(message);
    m_objects.clear();
    m_reservations.clear();
    rebuildSnapshot();
}

QJsonObject VolumeService::snapshot() const
{
    if (!m_snapshot.isEmpty())
        return m_snapshot;
    return {{QStringLiteral("available"), false}, {QStringLiteral("protocolVersion"), 1},
            {QStringLiteral("backendInstance"), m_backendInstance},
            {QStringLiteral("revision"), QStringLiteral("0")},
            {QStringLiteral("drives"), QJsonArray()},
            {QStringLiteral("unavailableReason"), QStringLiteral("Checking for removable drives…")}};
}

QStringList VolumeService::targetMountPoints(const QJsonObject &params) const
{
    const QString kind = params.value(QStringLiteral("targetKind")).toString();
    const QString targetId = params.value(QStringLiteral("targetId")).toString();
    QStringList result;
    if (kind == QStringLiteral("volume"))
        return resolveVolume(targetId).mountPoints;
    if (kind != QStringLiteral("drive"))
        return result;
    const QString drivePath = objectForId(targetId);
    const QStringList drivePaths = siblingDrivePaths(drivePath);
    for (auto object = m_objects.cbegin(); object != m_objects.cend(); ++object) {
        const QVariantMap block = object.value().value(QString::fromLatin1(blockInterface));
        QString eligibleDrive;
        if (eligibleBlock(object.key(), block, &eligibleDrive) && drivePaths.contains(eligibleDrive))
            result.append(validMountPoints(object.value().value(QString::fromLatin1(filesystemInterface))
                                           .value(QStringLiteral("MountPoints"))));
    }
    result.removeDuplicates();
    return result;
}

bool VolumeService::mutationConflicts(const QJsonObject &params) const
{
    const QStringList paths = operationPaths(params);
    for (const Reservation &reservation : m_reservations) {
        if (!reservation.inUse && reservation.expiresAt <= QDateTime::currentMSecsSinceEpoch())
            continue;
        for (const QString &mount : reservation.mountPoints) {
            for (const QString &path : paths) {
                if (containsPath(mount, path))
                    return true;
            }
        }
    }
    return false;
}

VolumeService::VolumeRef VolumeService::resolveVolume(const QString &volumeId) const
{
    VolumeRef result;
    result.blockPath = objectForId(volumeId);
    if (result.blockPath.isEmpty())
        return {};
    const InterfaceMap interfaces = m_objects.value(result.blockPath);
    const QVariantMap block = interfaces.value(QString::fromLatin1(blockInterface));
    QString drive;
    if (!eligibleBlock(result.blockPath, block, &drive))
        return {};
    result.drivePath = drive;
    if (interfaces.contains(QString::fromLatin1(filesystemInterface)))
        result.filesystemPath = result.blockPath;
    if (interfaces.contains(QString::fromLatin1(encryptedInterface))) {
        result.encryptedPath = result.blockPath;
        result.cleartextPath = pathProperty(interfaces.value(QString::fromLatin1(encryptedInterface)),
                                            "CleartextDevice");
        result.locked = result.cleartextPath.isEmpty() || result.cleartextPath == QStringLiteral("/");
    }
    result.mountPoints = validMountPoints(
        interfaces.value(QString::fromLatin1(filesystemInterface)).value(QStringLiteral("MountPoints")));
    return result;
}

QStringList VolumeService::siblingDrivePaths(const QString &drivePath) const
{
    if (drivePath.isEmpty())
        return {};
    QStringList result{drivePath};
    const QString siblingId = stringProperty(
        m_objects.value(drivePath).value(QString::fromLatin1(driveInterface)), "SiblingId");
    if (siblingId.isEmpty())
        return result;
    for (auto object = m_objects.cbegin(); object != m_objects.cend(); ++object) {
        if (object.key() == drivePath
            || stringProperty(object.value().value(QString::fromLatin1(driveInterface)), "SiblingId") != siblingId)
            continue;
        bool hasEligibleBlock = false;
        for (auto blockObject = m_objects.cbegin(); blockObject != m_objects.cend(); ++blockObject) {
            const QVariantMap block = blockObject.value().value(QString::fromLatin1(blockInterface));
            QString eligibleDrive;
            if (eligibleBlock(blockObject.key(), block, &eligibleDrive) && eligibleDrive == object.key()) {
                hasEligibleBlock = true;
                break;
            }
        }
        if (hasEligibleBlock)
            result.append(object.key());
    }
    std::sort(result.begin(), result.end());
    return result;
}

QJsonObject VolumeService::makeError(const QString &code, const QString &message,
                                     const QString &remoteError, const QJsonObject &details) const
{
    QJsonObject detail = details;
    if (!remoteError.isEmpty()) detail.insert(QStringLiteral("remoteError"), boundedText(remoteError));
    QJsonObject result{{QStringLiteral("ok"), false}, {QStringLiteral("error"), message},
                       {QStringLiteral("errorCode"), code}};
    if (!detail.isEmpty()) result.insert(QStringLiteral("details"), detail);
    return result;
}

QJsonObject VolumeService::dbusError(const QString &context, const QString &remoteName,
                                     const QString &message, const QJsonObject &details) const
{
    QString code = QStringLiteral("system_error");
    if (remoteName.endsWith(QStringLiteral("DeviceBusy"))) code = QStringLiteral("device_busy");
    else if (remoteName.endsWith(QStringLiteral("NotAuthorizedCanObtain"))) code = QStringLiteral("authentication_required");
    else if (remoteName.endsWith(QStringLiteral("NotAuthorizedDismissed"))) code = QStringLiteral("authentication_cancelled");
    else if (remoteName.endsWith(QStringLiteral("NotAuthorized"))) code = QStringLiteral("not_authorized");
    else if (remoteName.endsWith(QStringLiteral("AlreadyMounted"))) code = QStringLiteral("already_mounted");
    else if (remoteName.endsWith(QStringLiteral("NotMounted"))) code = QStringLiteral("not_mounted");
    else if (remoteName.endsWith(QStringLiteral("MountedByOtherUser"))) code = QStringLiteral("mounted_by_other_user");
    else if (remoteName.endsWith(QStringLiteral("OptionNotPermitted"))) code = QStringLiteral("option_not_permitted");
    else if (remoteName.endsWith(QStringLiteral("AlreadyUnmounting"))) code = QStringLiteral("already_unmounting");
    else if (remoteName.endsWith(QStringLiteral("WouldWakeup"))) code = QStringLiteral("would_wake");
    else if (remoteName.endsWith(QStringLiteral("Cancelled"))) code = QStringLiteral("cancelled");
    else if (remoteName.endsWith(QStringLiteral("NotSupported"))) code = QStringLiteral("unsupported");
    else if (remoteName.endsWith(QStringLiteral("TimedOut"))
             || remoteName == QStringLiteral("org.freedesktop.DBus.Error.Timeout")
             || remoteName == QStringLiteral("org.freedesktop.DBus.Error.NoReply")) code = QStringLiteral("timeout");
    else if (remoteName == QStringLiteral("org.freedesktop.DBus.Error.ServiceUnknown")
             || remoteName == QStringLiteral("org.freedesktop.DBus.Error.NameHasNoOwner")
             || remoteName == QStringLiteral("org.freedesktop.DBus.Error.Disconnected")) code = QStringLiteral("service_unavailable");
    else if (remoteName == QStringLiteral("org.freedesktop.DBus.Error.UnknownObject")) code = QStringLiteral("device_removed");
    else if (context == QStringLiteral("Unlock")) code = QStringLiteral("unlock_failed");
    QJsonObject enriched = details;
    enriched.insert(QStringLiteral("systemMessage"), boundedText(message));
    QString friendly = QStringLiteral("The drive operation failed");
    if (code == QStringLiteral("device_busy")) friendly = QStringLiteral("The drive is in use. Close files and applications using it, then try again.");
    else if (code == QStringLiteral("authentication_cancelled")) friendly = QStringLiteral("Authentication was cancelled. The drive was not changed.");
    else if (code == QStringLiteral("not_authorized")) friendly = QStringLiteral("You are not authorized to change this drive.");
    else if (code == QStringLiteral("unsupported")) friendly = QStringLiteral("This filesystem or drive operation is not supported.");
    else if (code == QStringLiteral("device_removed")) friendly = QStringLiteral("The drive was disconnected before the operation finished.");
    else if (code == QStringLiteral("timeout")) friendly = QStringLiteral("The operation timed out. Refresh the drive state before trying again.");
    return makeError(code, friendly, remoteName, enriched);
}

void VolumeService::callMethod(int id, const QString &objectPath, const QString &interface,
                               const QString &method, const QVariantList &arguments,
                               std::function<void(const QVariantList &)> success,
                               QJsonObject detail, QString reservationId)
{
    QDBusInterface target(m_serviceName, objectPath, interface, m_bus);
    target.setTimeout(dbusTimeoutMilliseconds);
    auto *watcher = new QDBusPendingCallWatcher(target.asyncCallWithArgumentList(method, arguments), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, watcher, id, success = std::move(success), detail, method, reservationId,
             objectPath] {
        QDBusPendingReply<> reply = *watcher;
        const QDBusMessage message = watcher->reply();
        watcher->deleteLater();
        if (reply.isError()) {
            if (method == QStringLiteral("Unmount")
                && reply.error().name().endsWith(QStringLiteral("NotMounted"))) {
                success({});
                scheduleRefresh();
                return;
            }
            if (method == QStringLiteral("Mount")
                && reply.error().name().endsWith(QStringLiteral("AlreadyMounted"))) {
                readMountPoints(objectPath, [this, id, success](bool valid, const QStringList &points) {
                    if (valid && !points.isEmpty()) success({points.first()});
                    else emit responseReady(id, makeError(QStringLiteral("already_mounted"),
                        QStringLiteral("The volume is mounted, but no usable mount path is available")));
                });
                scheduleRefresh();
                return;
            }
            if (!reservationId.isEmpty())
                m_reservations.remove(reservationId);
            filesailLog(LogLevel::Warn, "volumes", QStringLiteral("%1 failed: %2").arg(method, reply.error().name()));
            emit responseReady(id, dbusError(method, reply.error().name(), reply.error().message(), detail));
            scheduleRefresh();
            return;
        }
        success(message.arguments());
        scheduleRefresh();
    });
}

void VolumeService::confirmUnmounted(const QString &filesystemPath,
                                     std::function<void(bool)> callback)
{
    readMountPoints(filesystemPath, [callback = std::move(callback)](bool valid,
                                                                     const QStringList &points) {
        callback(valid && points.isEmpty());
    });
}

void VolumeService::readMountPoints(const QString &filesystemPath,
                                    std::function<void(bool, const QStringList &)> callback)
{
    QDBusInterface properties(m_serviceName, filesystemPath,
                              QString::fromLatin1(propertiesInterface),
                              m_bus);
    properties.setTimeout(dbusTimeoutMilliseconds);
    auto *watcher = new QDBusPendingCallWatcher(properties.asyncCall(
        QStringLiteral("Get"), QString::fromLatin1(filesystemInterface), QStringLiteral("MountPoints")), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, watcher, callback = std::move(callback)] {
        QDBusPendingReply<QDBusVariant> reply = *watcher;
        watcher->deleteLater();
        if (reply.isError()) {
            callback(false, {});
            scheduleRefresh();
            return;
        }
        callback(true, validMountPoints(reply.value().variant()));
    });
}

void VolumeService::handleRequest(int id, const QString &method, const QJsonObject &params)
{
    if (!m_available) {
        emit responseReady(id, makeError(QStringLiteral("service_unavailable"),
                                         QStringLiteral("Removable-drive support is unavailable")));
        return;
    }
    QString drivePath;
    if (params.value(QStringLiteral("volumeId")).isString())
        drivePath = resolveVolume(params.value(QStringLiteral("volumeId")).toString()).drivePath;
    else if (params.value(QStringLiteral("driveId")).isString())
        drivePath = objectForId(params.value(QStringLiteral("driveId")).toString());
    else if (params.value(QStringLiteral("targetKind")).toString() == QStringLiteral("drive"))
        drivePath = objectForId(params.value(QStringLiteral("targetId")).toString());
    else if (params.value(QStringLiteral("targetKind")).toString() == QStringLiteral("volume"))
        drivePath = resolveVolume(params.value(QStringLiteral("targetId")).toString()).drivePath;
    const QString siblingId = stringProperty(
        m_objects.value(drivePath).value(QString::fromLatin1(driveInterface)), "SiblingId");
    const QString actionKey = siblingId.isEmpty() ? drivePath : QStringLiteral("sibling:") + siblingId;
    if (!actionKey.isEmpty() && m_activeActionKeys.contains(actionKey)) {
        emit responseReady(id, makeError(QStringLiteral("already_in_progress"),
                                         QStringLiteral("Another operation is already using this drive")));
        return;
    }
    if (!actionKey.isEmpty() && method != QStringLiteral("volumes.cancelRemoval")) {
        m_activeActionKeys.insert(actionKey);
        m_requestActionKeys.insert(id, actionKey);
    }

    if (method == QStringLiteral("volumes.mount")) mount(id, params);
    else if (method == QStringLiteral("volumes.unlock")) unlock(id, params);
    else if (method == QStringLiteral("volumes.prepareRemoval")) prepareRemoval(id, params);
    else if (method == QStringLiteral("volumes.cancelRemoval")) cancelRemoval(id, params);
    else if (method == QStringLiteral("volumes.unmount")) unmount(id, params);
    else if (method == QStringLiteral("drives.safeRemove")) safeRemove(id, params);
    else emit responseReady(id, makeError(QStringLiteral("unsupported"), QStringLiteral("Unknown volume method")));
}

void VolumeService::mount(int id, const QJsonObject &params)
{
    const QString volumeId = params.value(QStringLiteral("volumeId")).toString();
    const VolumeRef volume = resolveVolume(volumeId);
    if (volume.blockPath.isEmpty()) {
        emit responseReady(id, makeError(QStringLiteral("device_removed"), QStringLiteral("The volume is no longer available")));
        return;
    }
    for (const Reservation &reservation : std::as_const(m_reservations)) {
        const QString reservedDrivePath = objectForId(reservation.driveId);
        const QString reservedSiblingId = stringProperty(
            m_objects.value(reservedDrivePath).value(QString::fromLatin1(driveInterface)), "SiblingId");
        const QString volumeSiblingId = stringProperty(
            m_objects.value(volume.drivePath).value(QString::fromLatin1(driveInterface)), "SiblingId");
        if (reservation.driveId == opaqueId(QStringLiteral("drive"), volume.drivePath)
            || (!reservedSiblingId.isEmpty() && reservedSiblingId == volumeSiblingId)) {
            emit responseReady(id, makeError(QStringLiteral("already_in_progress"),
                                             QStringLiteral("This drive is being prepared for removal")));
            return;
        }
    }
    if (!volume.mountPoints.isEmpty()) {
        emit responseReady(id, {{QStringLiteral("ok"), true}, {QStringLiteral("mountPath"), volume.mountPoints.first()},
                                {QStringLiteral("volumeId"), volumeId}, {QStringLiteral("state"), QStringLiteral("mounted")}});
        return;
    }
    if (volume.filesystemPath.isEmpty()) {
        emit responseReady(id, makeError(QStringLiteral("unsupported"), QStringLiteral("This volume cannot be mounted")));
        return;
    }
    emit operationChanged(volumeId, QStringLiteral("Mounting"));
    callMethod(id, volume.filesystemPath, QString::fromLatin1(filesystemInterface), QStringLiteral("Mount"),
               {emptyOptions()}, [this, id, volumeId](const QVariantList &arguments) {
        const QString path = arguments.value(0).toString();
        if (path.isEmpty() || !QDir::isAbsolutePath(path) || path.contains(QChar::Null)) {
            emit responseReady(id, makeError(QStringLiteral("path_unrepresentable"),
                                             QStringLiteral("The mounted path cannot be represented safely")));
            return;
        }
        emit responseReady(id, {{QStringLiteral("ok"), true}, {QStringLiteral("mountPath"), QDir::cleanPath(path)},
                                {QStringLiteral("volumeId"), volumeId}, {QStringLiteral("state"), QStringLiteral("mounted")}});
    }, {{QStringLiteral("volumeId"), volumeId}});
}

void VolumeService::unlock(int id, const QJsonObject &params)
{
    const QString volumeId = params.value(QStringLiteral("volumeId")).toString();
    const QString passphrase = params.value(QStringLiteral("passphrase")).toString();
    const VolumeRef volume = resolveVolume(volumeId);
    if (volume.blockPath.isEmpty()) {
        emit responseReady(id, makeError(QStringLiteral("device_removed"), QStringLiteral("The encrypted volume is no longer available")));
        return;
    }
    for (const Reservation &reservation : std::as_const(m_reservations)) {
        const QString reservedDrivePath = objectForId(reservation.driveId);
        const QString reservedSiblingId = stringProperty(
            m_objects.value(reservedDrivePath).value(QString::fromLatin1(driveInterface)), "SiblingId");
        const QString volumeSiblingId = stringProperty(
            m_objects.value(volume.drivePath).value(QString::fromLatin1(driveInterface)), "SiblingId");
        if (reservation.driveId == opaqueId(QStringLiteral("drive"), volume.drivePath)
            || (!reservedSiblingId.isEmpty() && reservedSiblingId == volumeSiblingId)) {
            emit responseReady(id, makeError(QStringLiteral("already_in_progress"),
                                             QStringLiteral("This drive is being prepared for removal")));
            return;
        }
    }
    if (volume.encryptedPath.isEmpty() || !volume.locked || passphrase.isEmpty()) {
        emit responseReady(id, makeError(QStringLiteral("unlock_failed"), QStringLiteral("The encrypted volume cannot be unlocked")));
        return;
    }
    const bool mountAfter = params.value(QStringLiteral("mount")).toBool(true);
    emit operationChanged(volumeId, QStringLiteral("Unlocking"));
    callMethod(id, volume.encryptedPath, QString::fromLatin1(encryptedInterface), QStringLiteral("Unlock"),
               {passphrase, emptyOptions()}, [this, id, mountAfter](const QVariantList &arguments) {
        const QString clearPath = arguments.value(0).value<QDBusObjectPath>().path();
        if (clearPath.isEmpty() || clearPath == QStringLiteral("/")) {
            emit responseReady(id, makeError(QStringLiteral("unlock_failed"), QStringLiteral("The encrypted volume did not expose an unlocked device")));
            return;
        }
        const QString clearId = opaqueId(QStringLiteral("volume"), clearPath);
        if (!mountAfter) {
            emit responseReady(id, {{QStringLiteral("ok"), true}, {QStringLiteral("volumeId"), clearId},
                                    {QStringLiteral("state"), QStringLiteral("unlocked")}});
            return;
        }
        auto attempts = std::make_shared<int>(0);
        auto waitForCleartext = std::make_shared<std::function<void()>>();
        *waitForCleartext = [this, id, clearId, attempts, waitForCleartext] {
            if (!objectForId(clearId).isEmpty()) {
                mount(id, {{QStringLiteral("volumeId"), clearId}});
                return;
            }
            if (++*attempts > 20) {
                emit responseReady(id, makeError(QStringLiteral("unlock_failed"),
                    QStringLiteral("The unlocked filesystem did not become available")));
                return;
            }
            scheduleRefresh();
            QTimer::singleShot(150, this, *waitForCleartext);
        };
        QTimer::singleShot(100, this, *waitForCleartext);
    }, {{QStringLiteral("volumeId"), volumeId}});
}

void VolumeService::releaseExpiredReservations()
{
    const qint64 now = QDateTime::currentMSecsSinceEpoch();
    for (auto it = m_reservations.begin(); it != m_reservations.end();) {
        if (!it->inUse && it->expiresAt <= now) it = m_reservations.erase(it); else ++it;
    }
}

void VolumeService::prepareRemoval(int id, const QJsonObject &params)
{
    releaseExpiredReservations();
    const QString kind = params.value(QStringLiteral("targetKind")).toString();
    const QString targetId = params.value(QStringLiteral("targetId")).toString();
    QString drivePath;
    QStringList mountPoints;
    if (kind == QStringLiteral("volume")) {
        const VolumeRef volume = resolveVolume(targetId);
        if (volume.blockPath.isEmpty()) {
            emit responseReady(id, makeError(QStringLiteral("device_removed"), QStringLiteral("The volume is no longer available")));
            return;
        }
        drivePath = volume.drivePath;
        mountPoints = volume.mountPoints;
    } else if (kind == QStringLiteral("drive")) {
        drivePath = objectForId(targetId);
        if (drivePath.isEmpty()) {
            emit responseReady(id, makeError(QStringLiteral("device_removed"), QStringLiteral("The drive is no longer available")));
            return;
        }
        const QStringList drivePaths = siblingDrivePaths(drivePath);
        const QString targetSiblingId = stringProperty(
            m_objects.value(drivePath).value(QString::fromLatin1(driveInterface)), "SiblingId");
        for (auto object = m_objects.cbegin(); object != m_objects.cend(); ++object) {
            const QVariantMap block = object.value().value(QString::fromLatin1(blockInterface));
            const QString blockDrivePath = pathProperty(block, "Drive");
            const QString blockSiblingId = stringProperty(
                m_objects.value(blockDrivePath).value(QString::fromLatin1(driveInterface)), "SiblingId");
            if (!targetSiblingId.isEmpty() && blockSiblingId == targetSiblingId
                && boolProperty(block, "HintSystem")) {
                emit responseReady(id, makeError(QStringLiteral("option_not_permitted"),
                    QStringLiteral("This hardware also contains a protected system volume and cannot be safely powered off here")));
                return;
            }
        }
        if (params.value(QStringLiteral("expectedAffectedDriveIds")).isArray()) {
            QStringList expected;
            for (const QJsonValue &value : params.value(QStringLiteral("expectedAffectedDriveIds")).toArray())
                expected.append(value.toString());
            QStringList observed;
            for (const QString &path : drivePaths)
                observed.append(opaqueId(QStringLiteral("drive"), path));
            std::sort(expected.begin(), expected.end());
            std::sort(observed.begin(), observed.end());
            if (expected != observed) {
                emit responseReady(id, makeError(QStringLiteral("device_removed"),
                    QStringLiteral("The related drives changed. Review the device list and try again.")));
                return;
            }
        }
        for (auto object = m_objects.cbegin(); object != m_objects.cend(); ++object) {
            const QVariantMap block = object.value().value(QString::fromLatin1(blockInterface));
            QString eligibleDrive;
            if (eligibleBlock(object.key(), block, &eligibleDrive) && drivePaths.contains(eligibleDrive))
                mountPoints.append(validMountPoints(object.value().value(QString::fromLatin1(filesystemInterface)).value(QStringLiteral("MountPoints"))));
        }
    } else {
        emit responseReady(id, makeError(QStringLiteral("system_error"), QStringLiteral("Invalid removal target")));
        return;
    }
    for (const Reservation &existing : std::as_const(m_reservations)) {
        if (existing.driveId == opaqueId(QStringLiteral("drive"), drivePath)) {
            emit responseReady(id, makeError(QStringLiteral("already_in_progress"), QStringLiteral("A drive operation is already in progress")));
            return;
        }
    }
    Reservation reservation;
    reservation.id = QStringLiteral("reservation-") + QUuid::createUuid().toString(QUuid::WithoutBraces);
    reservation.kind = kind;
    reservation.targetId = targetId;
    reservation.driveId = opaqueId(QStringLiteral("drive"), drivePath);
    reservation.mountPoints = mountPoints;
    reservation.mountPoints.removeDuplicates();
    reservation.expiresAt = QDateTime::currentMSecsSinceEpoch() + reservationLifetimeMilliseconds;
    m_reservations.insert(reservation.id, reservation);
    QTimer::singleShot(reservationLifetimeMilliseconds, this, [this, reservationId = reservation.id] {
        const auto it = m_reservations.find(reservationId);
        if (it != m_reservations.end() && !it->inUse
            && it->expiresAt <= QDateTime::currentMSecsSinceEpoch())
            m_reservations.erase(it);
    });
    QJsonArray points; for (const QString &point : std::as_const(reservation.mountPoints)) points.append(point);
    QJsonArray affectedDrives;
    for (const QString &path : siblingDrivePaths(drivePath))
        affectedDrives.append(opaqueId(QStringLiteral("drive"), path));
    emit responseReady(id, {{QStringLiteral("ok"), true}, {QStringLiteral("reservationId"), reservation.id},
                            {QStringLiteral("mountPoints"), points}, {QStringLiteral("driveId"), reservation.driveId},
                            {QStringLiteral("affectedDriveIds"), affectedDrives},
                            {QStringLiteral("expiresInMs"), reservationLifetimeMilliseconds}});
}

bool VolumeService::takeReservation(const QJsonObject &params, const QString &kind,
                                    const QString &targetId, Reservation *reservation,
                                    QJsonObject *error, bool consume)
{
    releaseExpiredReservations();
    const QString id = params.value(QStringLiteral("reservationId")).toString();
    const auto it = m_reservations.find(id);
    if (it == m_reservations.end()) {
        *error = makeError(QStringLiteral("reservation_expired"), QStringLiteral("Drive preparation expired. Try again."));
        return false;
    }
    if (it->kind != kind || it->targetId != targetId) {
        *error = makeError(QStringLiteral("option_not_permitted"), QStringLiteral("The removal reservation does not match this target"));
        return false;
    }
    *reservation = *it;
    if (consume) m_reservations.erase(it);
    return true;
}

void VolumeService::cancelRemoval(int id, const QJsonObject &params)
{
    const QString reservationId = params.value(QStringLiteral("reservationId")).toString();
    if (m_reservations.value(reservationId).inUse) {
        emit responseReady(id, makeError(QStringLiteral("already_in_progress"),
                                         QStringLiteral("The drive operation is already in progress")));
        return;
    }
    const bool released = m_reservations.remove(reservationId) > 0;
    emit responseReady(id, {{QStringLiteral("ok"), true}, {QStringLiteral("released"), released}});
}

void VolumeService::unmount(int id, const QJsonObject &params)
{
    const QString volumeId = params.value(QStringLiteral("volumeId")).toString();
    Reservation reservation; QJsonObject error;
    if (!takeReservation(params, QStringLiteral("volume"), volumeId, &reservation, &error, false)) {
        emit responseReady(id, error); return;
    }
    m_reservations[reservation.id].inUse = true;
    const VolumeRef volume = resolveVolume(volumeId);
    if (volume.blockPath.isEmpty()) {
        m_reservations.remove(reservation.id);
        emit responseReady(id, makeError(QStringLiteral("device_removed"), QStringLiteral("The volume is no longer available"))); return;
    }
    if (volume.mountPoints.isEmpty()) {
        m_reservations.remove(reservation.id);
        emit responseReady(id, {{QStringLiteral("ok"), true}, {QStringLiteral("volumeId"), volumeId},
                                {QStringLiteral("state"), QStringLiteral("unmounted")}}); return;
    }
    emit operationChanged(volumeId, QStringLiteral("Unmounting"));
    callMethod(id, volume.filesystemPath, QString::fromLatin1(filesystemInterface), QStringLiteral("Unmount"),
               {emptyOptions()}, [this, id, volumeId, filesystemPath = volume.filesystemPath,
                                   reservationId = reservation.id](const QVariantList &) {
        confirmUnmounted(filesystemPath, [this, id, volumeId, reservationId](bool unmounted) {
            m_reservations.remove(reservationId);
            if (!unmounted) {
                emit responseReady(id, makeError(QStringLiteral("still_mounted"),
                    QStringLiteral("The volume still reports a mounted filesystem"), {},
                    {{QStringLiteral("volumeId"), volumeId}}));
                return;
            }
            emit responseReady(id, {{QStringLiteral("ok"), true}, {QStringLiteral("volumeId"), volumeId},
                                    {QStringLiteral("state"), QStringLiteral("unmounted")}});
        });
    }, {{QStringLiteral("volumeId"), volumeId}}, reservation.id);
}

void VolumeService::safeRemove(int id, const QJsonObject &params)
{
    const QString driveId = params.value(QStringLiteral("driveId")).toString();
    Reservation reservation; QJsonObject error;
    if (!takeReservation(params, QStringLiteral("drive"), driveId, &reservation, &error, false)) {
        emit responseReady(id, error); return;
    }
    m_reservations[reservation.id].inUse = true;
    const QString drivePath = objectForId(driveId);
    if (drivePath.isEmpty()) {
        m_reservations.remove(reservation.id);
        emit responseReady(id, makeError(QStringLiteral("device_removed"), QStringLiteral("The drive is no longer available"))); return;
    }
    QStringList filesystems;
    const QStringList drivePaths = siblingDrivePaths(drivePath);
    for (auto object = m_objects.cbegin(); object != m_objects.cend(); ++object) {
        const QVariantMap block = object.value().value(QString::fromLatin1(blockInterface));
        QString eligibleDrive;
        if (eligibleBlock(object.key(), block, &eligibleDrive) && drivePaths.contains(eligibleDrive)
            && object.value().contains(QString::fromLatin1(filesystemInterface))
            && !validMountPoints(object.value().value(QString::fromLatin1(filesystemInterface)).value(QStringLiteral("MountPoints"))).isEmpty())
            filesystems.append(object.key());
    }
    std::sort(filesystems.begin(), filesystems.end());
    safeRemoveNext(id, drivePath, reservation.id, filesystems, {});
}

void VolumeService::safeRemoveNext(int id, const QString &drivePath, const QString &reservationId,
                                   QStringList filesystemPaths, QStringList completedVolumeIds)
{
    if (filesystemPaths.isEmpty()) {
        QStringList encryptedPaths;
        const QStringList drivePaths = siblingDrivePaths(drivePath);
        for (auto object = m_objects.cbegin(); object != m_objects.cend(); ++object) {
            const QVariantMap block = object.value().value(QString::fromLatin1(blockInterface));
            const QVariantMap encrypted = object.value().value(QString::fromLatin1(encryptedInterface));
            QString eligibleDrive;
            if (eligibleBlock(object.key(), block, &eligibleDrive) && drivePaths.contains(eligibleDrive)
                && !encrypted.isEmpty()
                && pathProperty(encrypted, "CleartextDevice") != QStringLiteral("/"))
                encryptedPaths.append(object.key());
        }
        std::sort(encryptedPaths.begin(), encryptedPaths.end());
        safeLockNext(id, drivePath, reservationId, encryptedPaths, completedVolumeIds);
        return;
    }
    const QString filesystemPath = filesystemPaths.takeFirst();
    const QString volumeId = opaqueId(QStringLiteral("volume"), filesystemPath);
    emit operationChanged(opaqueId(QStringLiteral("drive"), drivePath), QStringLiteral("Unmounting"));
    QDBusInterface target(m_serviceName, filesystemPath,
                          QString::fromLatin1(filesystemInterface), m_bus);
    target.setTimeout(dbusTimeoutMilliseconds);
    auto *watcher = new QDBusPendingCallWatcher(target.asyncCall(QStringLiteral("Unmount"), emptyOptions()), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, watcher, id, drivePath, reservationId, filesystemPaths, completedVolumeIds,
             volumeId, filesystemPath]() mutable {
        QDBusPendingReply<> reply = *watcher; watcher->deleteLater();
        if (reply.isError()) {
            m_reservations.remove(reservationId);
            QJsonArray completed; for (const QString &item : std::as_const(completedVolumeIds)) completed.append(item);
            QJsonArray remaining;
            remaining.append(volumeId);
            for (const QString &path : std::as_const(filesystemPaths))
                remaining.append(opaqueId(QStringLiteral("volume"), path));
            QJsonObject detail{{QStringLiteral("driveId"), opaqueId(QStringLiteral("drive"), drivePath)},
                               {QStringLiteral("volumeId"), volumeId}, {QStringLiteral("completedVolumeIds"), completed},
                               {QStringLiteral("remainingMountedVolumeIds"), remaining}};
            emit responseReady(id, dbusError(QStringLiteral("safeRemove"), reply.error().name(), reply.error().message(), detail));
            scheduleRefresh();
            return;
        }
        confirmUnmounted(filesystemPath, [this, id, drivePath, reservationId, filesystemPaths,
                                          completedVolumeIds, volumeId](bool unmounted) mutable {
            if (!unmounted) {
                m_reservations.remove(reservationId);
                QJsonArray completed; for (const QString &item : completedVolumeIds) completed.append(item);
                emit responseReady(id, makeError(QStringLiteral("still_mounted"),
                    QStringLiteral("A filesystem still reports mounted after unmounting"), {},
                    {{QStringLiteral("driveId"), opaqueId(QStringLiteral("drive"), drivePath)},
                     {QStringLiteral("volumeId"), volumeId}, {QStringLiteral("completedVolumeIds"), completed}}));
                return;
            }
            completedVolumeIds.append(volumeId);
            safeRemoveNext(id, drivePath, reservationId, filesystemPaths, completedVolumeIds);
        });
    });
}

void VolumeService::safeLockNext(int id, const QString &drivePath, const QString &reservationId,
                                 QStringList encryptedPaths, QStringList completedVolumeIds)
{
    if (encryptedPaths.isEmpty()) {
        finishSafeRemove(id, drivePath, reservationId, completedVolumeIds);
        return;
    }
    const QString encryptedPath = encryptedPaths.takeFirst();
    emit operationChanged(opaqueId(QStringLiteral("drive"), drivePath), QStringLiteral("Locking"));
    QDBusInterface target(m_serviceName, encryptedPath,
                          QString::fromLatin1(encryptedInterface), m_bus);
    target.setTimeout(dbusTimeoutMilliseconds);
    auto *watcher = new QDBusPendingCallWatcher(target.asyncCall(QStringLiteral("Lock"), emptyOptions()), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this,
            [this, watcher, id, drivePath, reservationId, encryptedPaths, completedVolumeIds]() mutable {
        QDBusPendingReply<> reply = *watcher; watcher->deleteLater();
        if (reply.isError()) {
            m_reservations.remove(reservationId);
            QJsonArray completed; for (const QString &item : completedVolumeIds) completed.append(item);
            emit responseReady(id, dbusError(QStringLiteral("lock"), reply.error().name(),
                reply.error().message(), {{QStringLiteral("driveId"), opaqueId(QStringLiteral("drive"), drivePath)},
                                          {QStringLiteral("completedVolumeIds"), completed}}));
            scheduleRefresh();
            return;
        }
        safeLockNext(id, drivePath, reservationId, encryptedPaths, completedVolumeIds);
    });
}

void VolumeService::finishSafeRemove(int id, const QString &drivePath, const QString &reservationId,
                                     const QStringList &completedVolumeIds)
{
    const QVariantMap drive = m_objects.value(drivePath).value(QString::fromLatin1(driveInterface));
    QString method;
    QString action = QStringLiteral("unmount");
    if (boolProperty(drive, "Ejectable")) { method = QStringLiteral("Eject"); action = QStringLiteral("eject"); }
    else if (boolProperty(drive, "CanPowerOff")) { method = QStringLiteral("PowerOff"); action = QStringLiteral("powerOff"); }
    if (!method.isEmpty())
        emit operationChanged(opaqueId(QStringLiteral("drive"), drivePath),
                              method == QStringLiteral("Eject") ? QStringLiteral("Ejecting")
                                                                 : QStringLiteral("Powering off"));
    auto success = [this, id, reservationId, action, completedVolumeIds](const QVariantList &) {
        m_reservations.remove(reservationId);
        QJsonArray completed; for (const QString &item : completedVolumeIds) completed.append(item);
        emit responseReady(id, {{QStringLiteral("ok"), true}, {QStringLiteral("action"), action},
                                {QStringLiteral("completedVolumeIds"), completed}});
    };
    if (method.isEmpty()) { success({}); scheduleRefresh(); return; }
    QJsonArray completed;
    for (const QString &item : completedVolumeIds) completed.append(item);
    callMethod(id, drivePath, QString::fromLatin1(driveInterface), method, {emptyOptions()}, success,
               {{QStringLiteral("driveId"), opaqueId(QStringLiteral("drive"), drivePath)},
                {QStringLiteral("completedVolumeIds"), completed},
                {QStringLiteral("dataVolumesUnmounted"), true}}, reservationId);
}
