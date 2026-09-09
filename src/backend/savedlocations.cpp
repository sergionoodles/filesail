#include "savedlocations.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLockFile>
#include <QSaveFile>
#include <QStandardPaths>
#include <QUuid>
#include <QUrl>

namespace {
constexpr qint64 maximumConfigBytes = 1024 * 1024;
constexpr int maximumEntries = 1000;

QJsonObject failure(const QString &message)
{
    return {{"ok", false}, {"error", message}};
}

QJsonObject success(const QJsonObject &locations)
{
    return {{"ok", true}, {"locations", locations}};
}

QString configFilePath()
{
    return QDir(SavedLocations::configDirectoryPath()).filePath("locations.json");
}

bool safePath(const QString &path)
{
    return !path.isEmpty() && !path.contains(QChar::Null) && QDir::isAbsolutePath(path)
        && QFile::decodeName(QFile::encodeName(path)) == path;
}

bool validCollection(const QString &collection)
{
    return collection == "projects" || collection == "bookmarks";
}

bool ensureDirectory(QString *error)
{
    const QString directory = SavedLocations::configDirectoryPath();
    if (!QDir().mkpath(directory)) {
        *error = QStringLiteral("Could not create locations directory: %1").arg(directory);
        return false;
    }
    QFile::setPermissions(directory, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    return true;
}

bool validateEntry(const QJsonValue &value, QJsonObject *entry, QString *error)
{
    if (!value.isObject()) {
        *error = "Invalid saved location record";
        return false;
    }
    const QJsonObject object = value.toObject();
    const QString id = object.value("id").toString();
    const QString label = object.value("label").toString();
    const QString path = object.value("path").toString();
    if (QUuid(id).isNull() || label.isEmpty() || label.toUcs4().size() > 255 || label.contains(QChar::Null)
        || !safePath(path)) {
        *error = "Invalid saved location record";
        return false;
    }
    *entry = {{"id", id}, {"label", label}, {"path", QDir::cleanPath(path)},
              {"available", QFileInfo(path).isDir()}};
    return true;
}

bool readSnapshot(QJsonObject *snapshot, QString *error)
{
    const QString path = configFilePath();
    if (!QFileInfo::exists(path)) {
        *snapshot = {{"version", 1}, {"projects", QJsonArray()}, {"bookmarks", QJsonArray()}};
        return true;
    }
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) {
        *error = QStringLiteral("Could not read saved locations: %1").arg(file.errorString());
        return false;
    }
    if (file.size() > maximumConfigBytes) {
        *error = "Saved locations file exceeds 1 MiB limit";
        return false;
    }
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(file.read(maximumConfigBytes + 1), &parseError);
    if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
        *error = "Saved locations file is malformed";
        return false;
    }
    const QJsonObject object = document.object();
    const int version = object.value("version").toInt(-1);
    if (version != 1) {
        *error = version > 1 ? "Saved locations file has an unsupported newer version"
                             : "Saved locations file has an unsupported version";
        return false;
    }
    QJsonObject result{{"version", 1}};
    for (const QString &collection : {QStringLiteral("projects"), QStringLiteral("bookmarks")}) {
        if (!object.value(collection).isArray()) {
            *error = "Saved locations file is malformed";
            return false;
        }
        const QJsonArray records = object.value(collection).toArray();
        if (records.size() > maximumEntries) {
            *error = "Saved locations collection exceeds 1,000 entries";
            return false;
        }
        QJsonArray normalized;
        QSet<QString> ids;
        QSet<QString> paths;
        for (const QJsonValue &value : records) {
            QJsonObject entry;
            if (!validateEntry(value, &entry, error) || ids.contains(entry.value("id").toString())
                || paths.contains(entry.value("path").toString())) {
                if (error->isEmpty())
                    *error = "Saved locations file contains duplicate records";
                return false;
            }
            ids.insert(entry.value("id").toString());
            paths.insert(entry.value("path").toString());
            normalized.append(entry);
        }
        result.insert(collection, normalized);
    }
    *snapshot = result;
    return true;
}

bool writeSnapshot(const QJsonObject &snapshot, QString *error)
{
    QJsonObject disk{{"version", 1}};
    for (const QString &collection : {QStringLiteral("projects"), QStringLiteral("bookmarks")}) {
        QJsonArray records;
        for (const QJsonValue &value : snapshot.value(collection).toArray()) {
            QJsonObject record = value.toObject();
            record.remove("available");
            records.append(record);
        }
        disk.insert(collection, records);
    }
    const QByteArray encoded = QJsonDocument(disk).toJson(QJsonDocument::Compact);
    if (encoded.size() > maximumConfigBytes) {
        *error = "Saved locations file exceeds 1 MiB limit";
        return false;
    }
    QSaveFile file(configFilePath());
    if (!file.open(QIODevice::WriteOnly)) {
        *error = QStringLiteral("Could not write saved locations: %1").arg(file.errorString());
        return false;
    }
    file.setPermissions(QFile::ReadOwner | QFile::WriteOwner);
    if (file.write(encoded) < 0 || !file.commit()) {
        *error = QStringLiteral("Could not save saved locations: %1").arg(file.errorString());
        return false;
    }
    return true;
}

QString canonicalDirectory(const QJsonValue &value, QString *error)
{
    if (!value.isString() || value.toString().trimmed().isEmpty()) {
        *error = "Missing or invalid path";
        return {};
    }
    const QString raw = value.toString();
    QString path = raw;
    if (raw.startsWith("file:")) {
        const QUrl url(raw, QUrl::StrictMode);
        if (!url.isValid() || !url.isLocalFile() || (!url.host().isEmpty() && url.host() != "localhost")
            || !url.userInfo().isEmpty() || !url.query().isEmpty() || !url.fragment().isEmpty()) {
            *error = "path must be an absolute local path";
            return {};
        }
        path = url.toLocalFile();
    }
    path = QDir::cleanPath(path);
    if (!safePath(path) || !QFileInfo(path).isDir()) {
        *error = QStringLiteral("Not a directory: %1").arg(path);
        return {};
    }
    const QString canonical = QFileInfo(path).canonicalFilePath();
    if (canonical.isEmpty() || !safePath(canonical)) {
        *error = "Could not canonicalize directory";
        return {};
    }
    return canonical;
}
} // namespace

QString SavedLocations::configDirectoryPath()
{
    return QDir(QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation)).filePath("filesail");
}

QJsonObject SavedLocations::list()
{
    QString error;
    QJsonObject snapshot;
    return readSnapshot(&snapshot, &error) ? success(snapshot) : failure(error);
}

QJsonObject SavedLocations::add(const QJsonObject &params)
{
    const QString collection = params.value("collection").toString();
    if (!validCollection(collection))
        return failure("Invalid locations collection");
    QString error;
    const QString path = canonicalDirectory(params.value("path"), &error);
    if (!error.isEmpty())
        return failure(error);
    if (!ensureDirectory(&error))
        return failure(error);
    QLockFile lock(configFilePath() + ".lock");
    lock.setStaleLockTime(0);
    if (!lock.tryLock(5000))
        return failure("Could not lock saved locations");
    QJsonObject snapshot;
    if (!readSnapshot(&snapshot, &error))
        return failure(error);
    QJsonArray records = snapshot.value(collection).toArray();
    for (const QJsonValue &value : records) {
        if (value.toObject().value("path").toString() == path)
            return success(snapshot);
    }
    if (records.size() >= maximumEntries)
        return failure("Saved locations collection exceeds 1,000 entries");
    const QString label = QFileInfo(path).fileName().isEmpty() ? QStringLiteral("/") : QFileInfo(path).fileName();
    records.append(QJsonObject{{"id", QUuid::createUuid().toString(QUuid::WithoutBraces)},
                               {"label", label}, {"path", path}, {"available", true}});
    snapshot.insert(collection, records);
    return writeSnapshot(snapshot, &error) ? success(snapshot) : failure(error);
}

QJsonObject SavedLocations::remove(const QJsonObject &params)
{
    const QString collection = params.value("collection").toString();
    const QString id = params.value("id").toString();
    if (!validCollection(collection) || QUuid(id).isNull())
        return failure("Invalid saved location");
    QString error;
    if (!ensureDirectory(&error))
        return failure(error);
    QLockFile lock(configFilePath() + ".lock");
    lock.setStaleLockTime(0);
    if (!lock.tryLock(5000))
        return failure("Could not lock saved locations");
    QJsonObject snapshot;
    if (!readSnapshot(&snapshot, &error))
        return failure(error);
    QJsonArray records;
    bool removed = false;
    for (const QJsonValue &value : snapshot.value(collection).toArray()) {
        if (value.toObject().value("id").toString() == id)
            removed = true;
        else
            records.append(value);
    }
    if (removed) {
        snapshot.insert(collection, records);
        if (!writeSnapshot(snapshot, &error))
            return failure(error);
    }
    return success(snapshot);
}
