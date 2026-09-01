#include "fileoperations.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QMimeDatabase>
#include <QMutex>
#include <QProcess>
#include <QSet>
#include <QUuid>
#include <QUrl>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <system_error>
#include <utility>

#include <fcntl.h>
#include <linux/fs.h>
#include <sys/syscall.h>
#include <unistd.h>

namespace {

QMutex activeStagesMutex;
QSet<QString> activeStages;

class ActiveStage
{
public:
    explicit ActiveStage(QString path)
        : m_path(std::move(path))
    {
        const QMutexLocker locker(&activeStagesMutex);
        activeStages.insert(m_path);
    }

    ~ActiveStage()
    {
        const QMutexLocker locker(&activeStagesMutex);
        activeStages.remove(m_path);
    }

    ActiveStage(const ActiveStage &) = delete;
    ActiveStage &operator=(const ActiveStage &) = delete;

private:
    QString m_path;
};

bool isActiveStage(const QString &path)
{
    const QMutexLocker locker(&activeStagesMutex);
    return activeStages.contains(path);
}

QJsonObject failure(const QString &message, const QJsonObject &values = {})
{
    QJsonObject result(values);
    result.insert("ok", false);
    result.insert("error", message);
    return result;
}

QJsonObject success(const QJsonObject &values = {})
{
    QJsonObject result(values);
    result.insert("ok", true);
    return result;
}

QString validateLocalPath(const QJsonValue &value, const QString &label, QString *error)
{
    if (!value.isString() || value.toString().trimmed().isEmpty()) {
        *error = QStringLiteral("Missing or invalid %1").arg(label);
        return {};
    }

    const QString raw = value.toString();
    const QString path = raw.startsWith("file:") ? QUrl(raw).toLocalFile() : raw;
    if (path.isEmpty() || path.contains(QChar::Null) || !QDir::isAbsolutePath(path)) {
        *error = QStringLiteral("%1 must be an absolute local path").arg(label);
        return {};
    }
    return QDir::cleanPath(path);
}

QString requiredPath(const QJsonObject &params, const QString &key, QString *error)
{
    return validateLocalPath(params.value(key), key, error);
}

bool validLeafName(const QString &name)
{
    return !name.isEmpty() && name != "." && name != ".."
        && !name.contains('/') && !name.contains(QChar::Null);
}

QString destinationFor(const QString &source, const QString &targetDirectory)
{
    return QDir(targetDirectory).filePath(QFileInfo(source).fileName());
}

std::filesystem::path fileSystemPath(const QString &path)
{
    const QByteArray encoded = QFile::encodeName(path);
    return std::filesystem::path(encoded.constData());
}

QString qtPath(const std::filesystem::path &path)
{
    return QFile::decodeName(path.c_str());
}

bool entryExists(const QString &path)
{
    std::error_code error;
    const auto status = std::filesystem::symlink_status(fileSystemPath(path), error);
    return !error && status.type() != std::filesystem::file_type::not_found;
}

bool setCopiedMetadata(const std::filesystem::path &source,
                       const std::filesystem::path &destination,
                       const std::filesystem::file_status &status,
                       QString *error)
{
    std::error_code ec;
    std::filesystem::permissions(destination, status.permissions(),
                                 std::filesystem::perm_options::replace, ec);
    if (ec) {
        *error = QStringLiteral("Could not preserve permissions: %1")
                     .arg(QString::fromStdString(ec.message()));
        return false;
    }

    const auto modified = std::filesystem::last_write_time(source, ec);
    if (ec) {
        *error = QStringLiteral("Could not read modification time: %1")
                     .arg(QString::fromStdString(ec.message()));
        return false;
    }
    std::filesystem::last_write_time(destination, modified, ec);
    if (ec) {
        *error = QStringLiteral("Could not preserve modification time: %1")
                     .arg(QString::fromStdString(ec.message()));
        return false;
    }
    return true;
}

bool removeOne(const QString &path, QString *error);

// Copy contract: preserve regular files, directories and symlinks. Permissions
// and modification times are preserved for regular files and directories.
// Device nodes, sockets, FIFOs and other special entries are rejected instead
// of being followed or silently converted.
bool copyEntry(const std::filesystem::path &source,
               const std::filesystem::path &destination,
               QString *error,
               bool *created = nullptr)
{
    if (created)
        *created = false;
    std::error_code ec;
    const auto status = std::filesystem::symlink_status(source, ec);
    if (ec) {
        *error = QString::fromStdString(ec.message());
        return false;
    }

    if (std::filesystem::is_symlink(status)) {
        const auto target = std::filesystem::read_symlink(source, ec);
        if (!ec)
            std::filesystem::create_symlink(target, destination, ec);
        if (ec) {
            *error = QStringLiteral("Could not copy symbolic link: %1")
                         .arg(QString::fromStdString(ec.message()));
            return false;
        }
        if (created)
            *created = true;
        return true;
    }

    if (std::filesystem::is_regular_file(status)) {
        QFile sourceFile(qtPath(source));
        if (!sourceFile.open(QIODevice::ReadOnly)) {
            *error = QStringLiteral("Could not open source file: %1")
                         .arg(sourceFile.errorString());
            return false;
        }

        QFile destinationFile(qtPath(destination));
        if (!destinationFile.open(QIODevice::WriteOnly | QIODevice::NewOnly)) {
            *error = QStringLiteral("Could not create destination file: %1")
                         .arg(destinationFile.errorString());
            return false;
        }
        if (created)
            *created = true;

        QByteArray buffer(256 * 1024, Qt::Uninitialized);
        while (true) {
            const qint64 bytesRead = sourceFile.read(buffer.data(), buffer.size());
            if (bytesRead < 0) {
                *error = QStringLiteral("Could not read source file: %1")
                             .arg(sourceFile.errorString());
                return false;
            }
            if (bytesRead == 0)
                break;

            qint64 offset = 0;
            while (offset < bytesRead) {
                const qint64 bytesWritten = destinationFile.write(
                    buffer.constData() + offset, bytesRead - offset);
                if (bytesWritten <= 0) {
                    *error = QStringLiteral("Could not write destination file: %1")
                                 .arg(destinationFile.errorString());
                    return false;
                }
                offset += bytesWritten;
            }
        }
        if (!destinationFile.flush()) {
            *error = QStringLiteral("Could not flush destination file: %1")
                         .arg(destinationFile.errorString());
            return false;
        }
        destinationFile.close();
        return setCopiedMetadata(source, destination, status, error);
    }

    if (std::filesystem::is_directory(status)) {
        if (!std::filesystem::create_directory(destination, ec)) {
            *error = QString::fromStdString(ec ? ec.message() : "Could not create directory");
            return false;
        }
        if (created)
            *created = true;

        std::filesystem::directory_iterator iterator(source, ec);
        const std::filesystem::directory_iterator end;
        while (!ec && iterator != end) {
            const auto childDestination = destination / iterator->path().filename();
            if (!copyEntry(iterator->path(), childDestination, error))
                return false;
            iterator.increment(ec);
        }
        if (ec) {
            *error = QStringLiteral("Could not enumerate directory: %1")
                         .arg(QString::fromStdString(ec.message()));
            return false;
        }
        return setCopiedMetadata(source, destination, status, error);
    }

    *error = QStringLiteral("Unsupported filesystem entry: %1").arg(qtPath(source));
    return false;
}

enum class RenameResult {
    Renamed,
    AlreadyExists,
    CrossDevice,
    Failed,
};

RenameResult renameNoReplace(const QString &source, const QString &destination, QString *error)
{
    const QByteArray encodedSource = QFile::encodeName(source);
    const QByteArray encodedDestination = QFile::encodeName(destination);
    if (::syscall(SYS_renameat2, AT_FDCWD, encodedSource.constData(), AT_FDCWD,
                  encodedDestination.constData(), RENAME_NOREPLACE) == 0) {
        return RenameResult::Renamed;
    }

    const int code = errno;
    if (code == EEXIST || code == ENOTEMPTY)
        return RenameResult::AlreadyExists;
    if (code == EXDEV)
        return RenameResult::CrossDevice;
    if (code == ENOSYS || code == EINVAL || code == EOPNOTSUPP) {
        *error = QStringLiteral("Atomic no-replace rename is not supported by this filesystem");
        return RenameResult::Failed;
    }
    *error = QString::fromLocal8Bit(std::strerror(code));
    return RenameResult::Failed;
}

bool isSameOrDescendant(const QString &source, const QString &destination)
{
    const QString canonicalSource = QFileInfo(source).canonicalFilePath();
    const QString normalizedSource = QDir::cleanPath(
        canonicalSource.isEmpty() ? QFileInfo(source).absoluteFilePath() : canonicalSource);
    const QString normalizedDestination = QDir::cleanPath(destination);
    const QString sourcePrefix = normalizedSource.endsWith('/')
        ? normalizedSource
        : normalizedSource + '/';
    return normalizedDestination == normalizedSource
        || normalizedDestination.startsWith(sourcePrefix);
}

bool copyOne(const QString &source, const QString &destination, QString *error)
{
    if (entryExists(destination)) {
        *error = QStringLiteral("Destination already exists: %1").arg(destination);
        return false;
    }

    const QFileInfo destinationInfo(destination);
    const QString stage = destinationInfo.dir().filePath(
        QStringLiteral(".filesail-copy-%1")
            .arg(QUuid::createUuid().toString(QUuid::WithoutBraces)));
    const ActiveStage activeStage(stage);
    bool stageCreated = false;
    if (!copyEntry(fileSystemPath(source), fileSystemPath(stage), error, &stageCreated)) {
        QString cleanupError;
        if (stageCreated && !removeOne(stage, &cleanupError)) {
            *error += QStringLiteral("; staging cleanup failed at %1: %2")
                          .arg(stage, cleanupError);
        }
        return false;
    }

    const RenameResult result = renameNoReplace(stage, destination, error);
    if (result == RenameResult::Renamed)
        return true;

    QString cleanupError;
    const bool cleanupFailed = !removeOne(stage, &cleanupError);
    if (result == RenameResult::AlreadyExists)
        *error = QStringLiteral("Destination already exists: %1").arg(destination);
    else if (result == RenameResult::CrossDevice)
        *error = QStringLiteral("Could not commit staged copy across filesystems");
    if (cleanupFailed) {
        *error += QStringLiteral("; staging cleanup failed at %1: %2")
                      .arg(stage, cleanupError);
    }
    return false;
}

bool removeOne(const QString &path, QString *error)
{
    std::error_code ec;
    std::filesystem::remove_all(fileSystemPath(path), ec);
    if (ec) {
        *error = QString::fromStdString(ec.message());
        return false;
    }
    return true;
}

bool moveOne(const QString &source, const QString &destination, QString *error,
             bool *destinationCommitted)
{
    *destinationCommitted = false;
    const RenameResult result = renameNoReplace(source, destination, error);
    if (result == RenameResult::Renamed) {
        *destinationCommitted = true;
        return true;
    }
    if (result == RenameResult::AlreadyExists) {
        *error = QStringLiteral("Destination already exists: %1").arg(destination);
        return false;
    }
    if (result != RenameResult::CrossDevice)
        return false;

    // Cross-device moves cannot be renamed. Copy first and remove only after success.
    if (!copyOne(source, destination, error))
        return false;
    *destinationCommitted = true;
    if (!removeOne(source, error)) {
        *error = QStringLiteral("Copied to %1, but the source could not be fully removed; the destination was kept. %2")
                     .arg(destination, *error);
        return false;
    }
    return true;
}

QJsonObject transferPaths(const QJsonObject &params, bool move)
{
    QString error;
    QString targetDirectory = requiredPath(params, "targetDirectory", &error);
    if (!error.isEmpty())
        return failure(error);
    if (!QFileInfo(targetDirectory).isDir())
        return failure(QStringLiteral("Not a directory: %1").arg(targetDirectory));
    const QString canonicalTarget = QFileInfo(targetDirectory).canonicalFilePath();
    if (!canonicalTarget.isEmpty())
        targetDirectory = canonicalTarget;

    if (!params.value("paths").isArray())
        return failure("paths must be an array");
    const QJsonArray paths = params.value("paths").toArray();
    if (paths.isEmpty())
        return failure("No source paths supplied");

    QJsonArray completed;
    for (const QJsonValue &value : paths) {
        error.clear();
        const QString source = validateLocalPath(value, "source path", &error);
        if (!error.isEmpty())
            return failure(error, {{"completed", completed}});
        if (!entryExists(source))
            return failure(QStringLiteral("Path does not exist: %1").arg(source), {{"completed", completed}});

        const QString destination = destinationFor(source, targetDirectory);
        std::error_code statusError;
        const auto sourceStatus = std::filesystem::symlink_status(fileSystemPath(source), statusError);
        if (statusError)
            return failure(QStringLiteral("Could not inspect %1: %2")
                               .arg(source, QString::fromStdString(statusError.message())),
                           {{"completed", completed}});
        if (std::filesystem::is_directory(sourceStatus)
            && isSameOrDescendant(source, destination))
            return failure(QStringLiteral("Cannot transfer a folder into itself: %1").arg(source),
                           {{"completed", completed}});
        bool destinationCommitted = false;
        const bool ok = move ? moveOne(source, destination, &error, &destinationCommitted)
                             : copyOne(source, destination, &error);
        if (!ok) {
            QJsonObject details{{"completed", completed}};
            if (move && destinationCommitted) {
                details.insert("partial", QJsonArray{QJsonObject{
                    {"source", source},
                    {"destination", destination},
                    {"state", "destinationCommittedSourceRemovalFailed"},
                }});
            }
            return failure(QStringLiteral("%1: %2").arg(source, error), details);
        }
        completed.append(destination);
    }
    return success({{"paths", completed}});
}

} // namespace

namespace FileOperations {

QJsonObject listDirectory(const QJsonObject &params)
{
    QString error;
    const QString requestedPath = requiredPath(params, "path", &error);
    if (!error.isEmpty())
        return failure(error);

    QFileInfo rootInfo(requestedPath);
    const QString path = rootInfo.canonicalFilePath().isEmpty()
        ? rootInfo.absoluteFilePath()
        : rootInfo.canonicalFilePath();
    QDir directory(path);
    if (!rootInfo.isDir() || !directory.exists())
        return failure(QStringLiteral("Directory does not exist: %1").arg(path));

    const bool showHidden = params.value("showHidden").toBool(false);
    const QString query = params.value("filter").toString().trimmed();
    QFileInfoList entries;
    std::error_code enumerationError;
    std::filesystem::directory_iterator iterator(fileSystemPath(path), enumerationError);
    const std::filesystem::directory_iterator end;
    while (!enumerationError && iterator != end) {
        const QFileInfo info(qtPath(iterator->path()));
        const QString name = info.fileName();
        // Active staging entries are an internal implementation detail and
        // must not appear during concurrent directory refreshes. Matching
        // user-owned names remain visible once they are not active stages.
        if (!isActiveStage(info.absoluteFilePath())
            && (showHidden || !info.isHidden())
            && (query.isEmpty() || name.contains(query, Qt::CaseInsensitive))) {
            entries.append(info);
        }
        iterator.increment(enumerationError);
    }
    if (enumerationError)
        return failure(QStringLiteral("Could not enumerate directory %1: %2")
                           .arg(path, QString::fromStdString(enumerationError.message())));

    const QString sortBy = params.value("sortBy").toString("name");
    const bool descending = params.value("descending").toBool(false);
    std::sort(entries.begin(), entries.end(), [&](const QFileInfo &left, const QFileInfo &right) {
        if (left.isDir() != right.isDir())
            return left.isDir();

        int comparison = 0;
        if (sortBy == "size")
            comparison = left.size() < right.size() ? -1 : left.size() > right.size() ? 1 : 0;
        else if (sortBy == "modified")
            comparison = left.lastModified() < right.lastModified() ? -1 : left.lastModified() > right.lastModified() ? 1 : 0;
        else if (sortBy == "type")
            comparison = QString::compare(left.suffix(), right.suffix(), Qt::CaseInsensitive);
        if (comparison == 0)
            comparison = QString::localeAwareCompare(left.fileName(), right.fileName());
        return descending ? comparison > 0 : comparison < 0;
    });

    QMimeDatabase mimeDatabase;
    QJsonArray jsonEntries;
    for (const QFileInfo &info : entries) {
        const auto mime = info.isDir()
            ? mimeDatabase.mimeTypeForName("inode/directory")
            : mimeDatabase.mimeTypeForFile(info, QMimeDatabase::MatchExtension);
        const QString iconName = !mime.iconName().isEmpty() ? mime.iconName()
                                                            : mime.genericIconName();
        jsonEntries.append(QJsonObject{
            {"name", info.fileName()},
            {"path", info.absoluteFilePath()},
            {"url", QUrl::fromLocalFile(info.absoluteFilePath()).toString()},
            {"isDirectory", info.isDir()},
            {"isSymlink", info.isSymLink()},
            {"isHidden", info.isHidden()},
            {"isReadable", info.isReadable()},
            {"isWritable", info.isWritable()},
            {"size", static_cast<double>(info.size())},
            {"modified", info.lastModified().toUTC().toString(Qt::ISODateWithMs)},
            {"mimeType", mime.name()},
            {"iconName", info.isDir() ? QStringLiteral("folder") : iconName},
        });
    }

    return success({
        {"path", path},
        {"parentPath", QDir(path).absolutePath() == "/" ? "/" : QFileInfo(path).dir().absolutePath()},
        {"entries", jsonEntries},
    });
}

QJsonObject createDirectory(const QJsonObject &params)
{
    QString error;
    const QString parent = requiredPath(params, "parent", &error);
    const QString name = params.value("name").toString().trimmed();
    if (!error.isEmpty())
        return failure(error);
    if (!validLeafName(name))
        return failure("Folder name must be a single non-empty path component");

    const QString path = QDir(parent).filePath(name);
    if (!QDir().mkdir(path))
        return failure(QStringLiteral("Could not create folder: %1").arg(path));
    return success({{"path", path}});
}

QJsonObject renamePath(const QJsonObject &params)
{
    QString error;
    const QString source = requiredPath(params, "path", &error);
    const QString name = params.value("name").toString().trimmed();
    if (!error.isEmpty())
        return failure(error);
    if (!validLeafName(name))
        return failure("New name must be a single non-empty path component");
    if (!entryExists(source))
        return failure(QStringLiteral("Path does not exist: %1").arg(source));

    const QFileInfo info(source);
    const QString destination = info.dir().filePath(name);
    const RenameResult result = renameNoReplace(source, destination, &error);
    if (result == RenameResult::AlreadyExists)
        return failure(QStringLiteral("Destination already exists: %1").arg(destination));
    if (result != RenameResult::Renamed)
        return failure(QStringLiteral("Could not rename %1: %2").arg(source, error));
    return success({{"path", destination}});
}

QJsonObject trashPaths(const QJsonObject &params)
{
    if (!params.value("paths").isArray())
        return failure("paths must be an array");
    const QJsonArray paths = params.value("paths").toArray();
    if (paths.isEmpty())
        return failure("No paths supplied");

    QJsonArray trashed;
    for (const QJsonValue &value : paths) {
        QString error;
        const QString path = validateLocalPath(value, "trash path", &error);
        if (!error.isEmpty())
            return failure(error, {{"completed", trashed}});
        if (path == "/")
            return failure("Refusing to move the filesystem root to Trash", {{"completed", trashed}});
        QString trashPath;
        if (!QFile::moveToTrash(path, &trashPath))
            return failure(QStringLiteral("Could not move to trash: %1").arg(path),
                           {{"completed", trashed}});
        trashed.append(trashPath);
    }
    return success({{"paths", trashed}});
}

QJsonObject copyPaths(const QJsonObject &params)
{
    return transferPaths(params, false);
}

QJsonObject movePaths(const QJsonObject &params)
{
    return transferPaths(params, true);
}

QJsonObject openPath(const QJsonObject &params)
{
    QString error;
    const QString path = requiredPath(params, "path", &error);
    if (!error.isEmpty())
        return failure(error);
    if (!QFileInfo::exists(path))
        return failure(QStringLiteral("Path does not exist: %1").arg(path));

    const QString uri = QUrl::fromLocalFile(path).toString();
    QProcess opener;
    opener.setProgram(QStringLiteral("xdg-open"));
    opener.setArguments({uri});
    opener.setStandardInputFile(QProcess::nullDevice());
    opener.setStandardOutputFile(QProcess::nullDevice());
    opener.setStandardErrorFile(QProcess::nullDevice());
    if (!opener.startDetached())
        return failure("Could not start xdg-open");
    return success();
}

} // namespace FileOperations
