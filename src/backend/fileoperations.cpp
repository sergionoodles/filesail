#include "fileoperations.h"
#include "foldercontext.h"
#include "logging.h"

#include <QDateTime>
#include <QCollator>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QMimeDatabase>
#include <QMutex>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSet>
#include <QStandardPaths>
#include <QStringConverter>
#include <QTextStream>
#include <QThread>
#include <QUuid>
#include <QUrl>
#include <QVector>

#include <algorithm>
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <limits>
#include <system_error>
#include <utility>
#include <vector>

#include <fcntl.h>
#include <linux/fs.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/xattr.h>
#include <unistd.h>

namespace {

QMutex activeStagesMutex;
QSet<QString> activeStages;

int developmentTransferDelayMs()
{
    static const int delayMs = [] {
        bool valid = false;
        const int configured = qEnvironmentVariableIntValue("FILESAIL_DEV_TRANSFER_DELAY_MS", &valid);
        return valid ? qBound(0, configured, 10000) : 0;
    }();
    return delayMs;
}

bool developmentTransferPause(const CancellationToken &token, int multiplier = 1)
{
    int remaining = developmentTransferDelayMs() * std::max(1, multiplier);
    while (remaining > 0) {
        if (cancellationRequested(token))
            return false;
        const int slice = std::min(remaining, 10);
        QThread::msleep(static_cast<unsigned long>(slice));
        remaining -= slice;
    }
    return !cancellationRequested(token);
}

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

class ScopedFileDescriptor
{
public:
    explicit ScopedFileDescriptor(int descriptor = -1)
        : m_descriptor(descriptor)
    {
    }

    ~ScopedFileDescriptor()
    {
        if (m_descriptor >= 0)
            ::close(m_descriptor);
    }

    ScopedFileDescriptor(const ScopedFileDescriptor &) = delete;
    ScopedFileDescriptor &operator=(const ScopedFileDescriptor &) = delete;

    int get() const { return m_descriptor; }

private:
    int m_descriptor;
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

bool isRoundTrippableLocalPath(const QString &path)
{
    return QFile::decodeName(QFile::encodeName(path)) == path;
}

QString validateLocalPath(const QJsonValue &value, const QString &label, QString *error)
{
    if (!value.isString() || value.toString().trimmed().isEmpty()) {
        *error = QStringLiteral("Missing or invalid %1").arg(label);
        return {};
    }

    const QString raw = value.toString();
    QString path = raw;
    if (raw.startsWith("file:")) {
        const QUrl url(raw, QUrl::StrictMode);
        if (!url.isValid() || !url.isLocalFile()
            || (!url.host().isEmpty() && url.host() != "localhost")
            || !url.userInfo().isEmpty() || !url.query().isEmpty()
            || !url.fragment().isEmpty()) {
            *error = QStringLiteral("%1 must be an absolute local path").arg(label);
            return {};
        }
        path = url.toLocalFile();
    }
    if (path.isEmpty() || path.contains(QChar::Null) || !QDir::isAbsolutePath(path)) {
        *error = QStringLiteral("%1 must be an absolute local path").arg(label);
        return {};
    }
    path = QDir::cleanPath(path);
    if (!isRoundTrippableLocalPath(path)) {
        *error = QStringLiteral("%1 cannot be represented safely in the current locale").arg(label);
        return {};
    }
    return path;
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

bool isRoundTrippableFileSystemPath(const std::filesystem::path &path)
{
    return fileSystemPath(qtPath(path)) == path;
}

bool entryExists(const QString &path)
{
    std::error_code error;
    const auto status = std::filesystem::symlink_status(fileSystemPath(path), error);
    return !error && status.type() != std::filesystem::file_type::not_found;
}

bool sameFile(const struct stat &left, const struct stat &right)
{
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
}

bool lstatPath(const std::filesystem::path &path, struct stat *status, QString *error)
{
    if (::lstat(path.c_str(), status) == 0)
        return true;
    *error = QString::fromLocal8Bit(std::strerror(errno));
    return false;
}

// Symbolic mode string in `ls -l` style (for example `drwxr-xr-x`). Symlinks
// are reported as links, matching lstat semantics. Setuid/setgid/sticky bits
// are intentionally rendered as plain `x`/`-` to keep the display compact.
QString symbolicPermissions(const QFileInfo &info)
{
    struct stat status;
    if (::lstat(QFile::encodeName(info.absoluteFilePath()).constData(), &status) != 0)
        return {};
    const mode_t mode = status.st_mode;
    QString result;
    result.reserve(10);
    result += S_ISDIR(mode) ? u'd' : (S_ISLNK(mode) ? u'l' : u'-');
    result += (mode & S_IRUSR) ? u'r' : u'-';
    result += (mode & S_IWUSR) ? u'w' : u'-';
    result += (mode & S_IXUSR) ? u'x' : u'-';
    result += (mode & S_IRGRP) ? u'r' : u'-';
    result += (mode & S_IWGRP) ? u'w' : u'-';
    result += (mode & S_IXGRP) ? u'x' : u'-';
    result += (mode & S_IROTH) ? u'r' : u'-';
    result += (mode & S_IWOTH) ? u'w' : u'-';
    result += (mode & S_IXOTH) ? u'x' : u'-';
    return result;
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

bool copyPosixAclAttribute(int sourceDescriptor, const std::filesystem::path &destination,
                           const char *attribute, QString *error)
{
    const ssize_t length = ::fgetxattr(sourceDescriptor, attribute, nullptr, 0);
    if (length < 0 && errno != ENODATA && errno != ENOTSUP && errno != EOPNOTSUPP) {
        *error = QStringLiteral("Could not read source ACL: %1")
                     .arg(QString::fromLocal8Bit(std::strerror(errno)));
        return false;
    }
    if (length < 0) {
        if (::removexattr(destination.c_str(), attribute) == 0 || errno == ENODATA
            || errno == ENOTSUP || errno == EOPNOTSUPP)
            return true;
        *error = QStringLiteral("Could not clear inherited destination ACL: %1")
                     .arg(QString::fromLocal8Bit(std::strerror(errno)));
        return false;
    }

    std::vector<char> value(static_cast<size_t>(length));
    if (length > 0 && ::fgetxattr(sourceDescriptor, attribute, value.data(), value.size()) != length) {
        *error = QStringLiteral("Could not read source ACL: %1")
                     .arg(QString::fromLocal8Bit(std::strerror(errno)));
        return false;
    }
    if (::setxattr(destination.c_str(), attribute, value.data(), value.size(), 0) != 0) {
        *error = QStringLiteral("Could not preserve ACL: %1")
                     .arg(QString::fromLocal8Bit(std::strerror(errno)));
        return false;
    }
    return true;
}

bool copyPosixAcls(int sourceDescriptor, const std::filesystem::path &destination,
                   bool directory, QString *error)
{
    if (!copyPosixAclAttribute(sourceDescriptor, destination, "system.posix_acl_access", error))
        return false;
    return !directory || copyPosixAclAttribute(sourceDescriptor, destination,
                                                "system.posix_acl_default", error);
}

bool removeOne(const QString &path, QString *error);

struct TransferProgress {
    FileOperations::ProgressCallback callback;
    qint64 bytesDone = 0;
    qint64 currentFileBytesDone = 0;
    qint64 currentFileBytesTotal = -1;
    qint64 bytesTotal = 0;
    qint64 entriesDone = 0;
    qint64 entriesTotal = 0;
    int topLevelDone = 0;
    int topLevelTotal = 0;
    bool totalsReady = false;
    QElapsedTimer reportTimer;
    bool hasReported = false;
    bool hasReportedFile = false;

    void report(const QString &phase, const QString &currentPath, bool force = false)
    {
        if (!callback || (!force && hasReported && reportTimer.elapsed() < 200))
            return;
        const bool fileActive = phase == QStringLiteral("transferring")
            && currentFileBytesTotal >= 0;
        callback({
            {"phase", phase},
            {"currentPath", currentPath},
            {"bytesDone", QString::number(bytesDone)},
            {"bytesTotal", QString::number(bytesTotal)},
            {"currentFileBytesDone", QString::number(fileActive ? currentFileBytesDone : 0)},
            {"currentFileBytesTotal", QString::number(fileActive ? currentFileBytesTotal : 0)},
            {"currentFileActive", fileActive},
            {"entriesDone", static_cast<qint64>(entriesDone)},
            {"entriesTotal", entriesTotal},
            {"topLevelDone", topLevelDone},
            {"topLevelTotal", topLevelTotal},
            {"overallProgressActive", totalsReady && (bytesTotal > 0 || entriesTotal > 0)},
            {"totalsEstimated", totalsReady},
        });
        reportTimer.restart();
        hasReported = true;
    }

    void scanEntry(const QString &path, qint64 bytes)
    {
        ++entriesTotal;
        if (bytes > 0) {
            const qint64 available = std::numeric_limits<qint64>::max() - bytesTotal;
            bytesTotal += std::min(bytes, available);
        }
        report("scanning", path);
    }

    void beginFile(const QString &path, qint64 size)
    {
        currentFileBytesDone = 0;
        currentFileBytesTotal = std::max<qint64>(0, size);
        report("transferring", path, !hasReportedFile);
        hasReportedFile = true;
    }

    void bytesWritten(qint64 bytes, const QString &path)
    {
        bytesDone += bytes;
        currentFileBytesDone += bytes;
        report("transferring", path);
    }

    void entryCompleted(const QString &path)
    {
        ++entriesDone;
        currentFileBytesDone = 0;
        currentFileBytesTotal = -1;
        report("transferring", path);
    }

    void topLevelCompleted(const QString &path)
    {
        ++topLevelDone;
        report("transferring", path);
    }
};

enum class TransferResult { Success, Cancelled, Failed };

TransferResult scanEntry(const std::filesystem::path &source, QString *error,
                         TransferProgress *progress, const QString &logicalSource,
                         const CancellationToken &token)
{
    if (cancellationRequested(token))
        return TransferResult::Cancelled;

    struct stat initialStatus {};
    if (!lstatPath(source, &initialStatus, error))
        return TransferResult::Failed;
    if (S_ISREG(initialStatus.st_mode)) {
        progress->scanEntry(logicalSource, std::max<qint64>(0, initialStatus.st_size));
        return TransferResult::Success;
    }
    if (S_ISLNK(initialStatus.st_mode)) {
        progress->scanEntry(logicalSource, 0);
        return TransferResult::Success;
    }
    if (!S_ISDIR(initialStatus.st_mode)) {
        *error = QStringLiteral("Unsupported filesystem entry: %1").arg(qtPath(source));
        return TransferResult::Failed;
    }

    const ScopedFileDescriptor sourceDescriptor(
        ::open(source.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
    if (sourceDescriptor.get() < 0) {
        *error = QStringLiteral("Could not open source directory: %1")
                     .arg(QString::fromLocal8Bit(std::strerror(errno)));
        return TransferResult::Failed;
    }
    struct stat opened {};
    if (::fstat(sourceDescriptor.get(), &opened) != 0 || !S_ISDIR(opened.st_mode)
        || !sameFile(initialStatus, opened)) {
        *error = QStringLiteral("Source directory changed while scanning");
        return TransferResult::Failed;
    }
    progress->scanEntry(logicalSource, 0);

    const QByteArray openedSourceName = QByteArray("/proc/self/fd/")
        + QByteArray::number(sourceDescriptor.get());
    const std::filesystem::path openedSource(openedSourceName.constData());
    std::error_code ec;
    std::filesystem::directory_iterator iterator(openedSource, ec);
    const std::filesystem::directory_iterator end;
    while (!ec && iterator != end) {
        if (cancellationRequested(token))
            return TransferResult::Cancelled;
        const QString childName = isRoundTrippableFileSystemPath(iterator->path().filename())
            ? qtPath(iterator->path().filename()) : QString();
        const QString childLogicalSource = QDir(logicalSource).filePath(childName);
        const TransferResult result = scanEntry(iterator->path(), error, progress,
                                                childLogicalSource, token);
        if (result != TransferResult::Success)
            return result;
        iterator.increment(ec);
    }
    if (ec) {
        *error = QStringLiteral("Could not enumerate directory while scanning: %1")
                     .arg(QString::fromStdString(ec.message()));
        return TransferResult::Failed;
    }
    return cancellationRequested(token) ? TransferResult::Cancelled : TransferResult::Success;
}

// Copy contract: preserve regular files, directories and symlinks. Permissions
// and modification times are preserved for regular files and directories.
// Device nodes, sockets, FIFOs and other special entries are rejected instead
// of being followed or silently converted.
TransferResult copyEntry(const std::filesystem::path &source,
               const std::filesystem::path &destination,
               QString *error,
               bool *created = nullptr,
               TransferProgress *progress = nullptr,
               const QString &logicalSource = {},
               const CancellationToken &token = {})
{
    if (created)
        *created = false;
    if (cancellationRequested(token))
        return TransferResult::Cancelled;
    std::error_code ec;
    struct stat initialStatus {};
    if (!lstatPath(source, &initialStatus, error))
        return TransferResult::Failed;
    const std::filesystem::file_status status(
        std::filesystem::file_type::unknown,
        static_cast<std::filesystem::perms>(initialStatus.st_mode & 07777));

    if (S_ISLNK(initialStatus.st_mode)) {
        const auto target = std::filesystem::read_symlink(source, ec);
        struct stat after {};
        if (!ec && (!lstatPath(source, &after, error) || !sameFile(initialStatus, after))) {
            if (error->isEmpty())
                *error = "Symbolic link changed while copying";
            return TransferResult::Failed;
        }
        if (!ec)
            std::filesystem::create_symlink(target, destination, ec);
        if (ec) {
            *error = QStringLiteral("Could not copy symbolic link: %1")
                         .arg(QString::fromStdString(ec.message()));
            return TransferResult::Failed;
        }
        if (created)
            *created = true;
        if (cancellationRequested(token))
            return TransferResult::Cancelled;
        if (progress)
            progress->entryCompleted(logicalSource);
        return TransferResult::Success;
    }

    if (S_ISREG(initialStatus.st_mode)) {
        const ScopedFileDescriptor sourceDescriptor(
            ::open(source.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
        if (sourceDescriptor.get() < 0) {
            *error = QStringLiteral("Could not open source file: %1")
                         .arg(QString::fromLocal8Bit(std::strerror(errno)));
            return TransferResult::Failed;
        }
        struct stat opened {};
        if (::fstat(sourceDescriptor.get(), &opened) != 0 || !S_ISREG(opened.st_mode)
            || !sameFile(initialStatus, opened)) {
            *error = "Source file changed while copying";
            return TransferResult::Failed;
        }

        QFile sourceFile;
        if (!sourceFile.open(sourceDescriptor.get(), QIODevice::ReadOnly,
                             QFileDevice::DontCloseHandle)) {
            *error = QStringLiteral("Could not open source file: %1")
                         .arg(sourceFile.errorString());
            return TransferResult::Failed;
        }

        const ScopedFileDescriptor destinationDescriptor(::open(
            destination.c_str(), O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR));
        if (destinationDescriptor.get() < 0) {
            *error = QStringLiteral("Could not create destination file: %1")
                         .arg(QString::fromLocal8Bit(std::strerror(errno)));
            return TransferResult::Failed;
        }
        QFile destinationFile;
        if (!destinationFile.open(destinationDescriptor.get(), QIODevice::WriteOnly,
                                  QFileDevice::DontCloseHandle)) {
            *error = QStringLiteral("Could not create destination file: %1")
                         .arg(destinationFile.errorString());
            return TransferResult::Failed;
        }
        if (created)
            *created = true;
        if (cancellationRequested(token))
            return TransferResult::Cancelled;

        if (progress)
            progress->beginFile(logicalSource, opened.st_size);

        QByteArray buffer(256 * 1024, Qt::Uninitialized);
        while (true) {
            if (cancellationRequested(token))
                return TransferResult::Cancelled;
            const qint64 bytesRead = sourceFile.read(buffer.data(), buffer.size());
            if (bytesRead < 0) {
                *error = QStringLiteral("Could not read source file: %1")
                             .arg(sourceFile.errorString());
                return TransferResult::Failed;
            }
            if (bytesRead == 0)
                break;

            qint64 offset = 0;
            while (offset < bytesRead) {
                if (cancellationRequested(token))
                    return TransferResult::Cancelled;
                const qint64 bytesWritten = destinationFile.write(
                    buffer.constData() + offset, bytesRead - offset);
                if (bytesWritten <= 0) {
                    *error = QStringLiteral("Could not write destination file: %1")
                                 .arg(destinationFile.errorString());
                    return TransferResult::Failed;
                }
                offset += bytesWritten;
                if (progress)
                    progress->bytesWritten(bytesWritten, logicalSource);
            }
            if (!developmentTransferPause(token))
                return TransferResult::Cancelled;
        }
        if (!destinationFile.flush()) {
            *error = QStringLiteral("Could not flush destination file: %1")
                         .arg(destinationFile.errorString());
            return TransferResult::Failed;
        }
        destinationFile.close();
        if (cancellationRequested(token))
            return TransferResult::Cancelled;
        const bool metadataCopied = setCopiedMetadata(source, destination, status, error)
            && copyPosixAcls(sourceDescriptor.get(), destination, false, error);
        if (metadataCopied && progress)
            progress->entryCompleted(logicalSource);
        if (metadataCopied && !developmentTransferPause(token))
            return TransferResult::Cancelled;
        return metadataCopied ? TransferResult::Success : TransferResult::Failed;
    }

    if (S_ISDIR(initialStatus.st_mode)) {
        const ScopedFileDescriptor sourceDescriptor(
            ::open(source.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW));
        if (sourceDescriptor.get() < 0) {
            *error = QStringLiteral("Could not open source directory: %1")
                         .arg(QString::fromLocal8Bit(std::strerror(errno)));
            return TransferResult::Failed;
        }
        struct stat opened {};
        if (::fstat(sourceDescriptor.get(), &opened) != 0 || !S_ISDIR(opened.st_mode)
            || !sameFile(initialStatus, opened)) {
            *error = "Source directory changed while copying";
            return TransferResult::Failed;
        }
        if (cancellationRequested(token))
            return TransferResult::Cancelled;
        if (::mkdir(destination.c_str(), S_IRWXU) != 0) {
            *error = QStringLiteral("Could not create directory: %1")
                         .arg(QString::fromLocal8Bit(std::strerror(errno)));
            return TransferResult::Failed;
        }
        if (created)
            *created = true;

        if (progress)
            progress->report("transferring", logicalSource);

        const QByteArray openedSourceName = QByteArray("/proc/self/fd/")
            + QByteArray::number(sourceDescriptor.get());
        const std::filesystem::path openedSource(openedSourceName.constData());
        std::filesystem::directory_iterator iterator(openedSource, ec);
        const std::filesystem::directory_iterator end;
        while (!ec && iterator != end) {
            if (cancellationRequested(token))
                return TransferResult::Cancelled;
            const auto childDestination = destination / iterator->path().filename();
            // Do not turn an unrepresentable filename into a potentially
            // colliding display path. The copy itself remains supported, but
            // progress falls back to the nearest safe logical ancestor.
            const QString childName = isRoundTrippableFileSystemPath(iterator->path().filename())
                ? qtPath(iterator->path().filename()) : QString();
            const QString childLogicalSource = QDir(logicalSource).filePath(childName);
            const TransferResult childResult = copyEntry(iterator->path(), childDestination, error,
                                                         nullptr, progress, childLogicalSource, token);
            if (childResult != TransferResult::Success)
                return childResult;
            iterator.increment(ec);
        }
        if (ec) {
            *error = QStringLiteral("Could not enumerate directory: %1")
                         .arg(QString::fromStdString(ec.message()));
            return TransferResult::Failed;
        }
        if (cancellationRequested(token))
            return TransferResult::Cancelled;
        const bool metadataCopied = setCopiedMetadata(source, destination, status, error)
            && copyPosixAcls(sourceDescriptor.get(), destination, true, error);
        if (metadataCopied && progress)
            progress->entryCompleted(logicalSource);
        if (metadataCopied && !developmentTransferPause(token))
            return TransferResult::Cancelled;
        return metadataCopied ? TransferResult::Success : TransferResult::Failed;
    }

    *error = QStringLiteral("Unsupported filesystem entry: %1").arg(qtPath(source));
    return TransferResult::Failed;
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

TransferResult copyOne(const QString &source, const QString &destination, QString *error,
                       TransferProgress *progress, const QString &logicalSource,
                       const CancellationToken &token, QJsonArray *recovery)
{
    if (cancellationRequested(token))
        return TransferResult::Cancelled;
    if (entryExists(destination)) {
        *error = QStringLiteral("Destination already exists: %1").arg(destination);
        return TransferResult::Failed;
    }

    const QFileInfo destinationInfo(destination);
    const QString stage = destinationInfo.dir().filePath(
        QStringLiteral(".filesail-copy-%1")
            .arg(QUuid::createUuid().toString(QUuid::WithoutBraces)));
    const ActiveStage activeStage(stage);
    bool stageCreated = false;
    const TransferResult copyResult = copyEntry(fileSystemPath(source), fileSystemPath(stage), error,
                                                &stageCreated, progress, logicalSource, token);
    if (copyResult != TransferResult::Success) {
        if (progress)
            progress->report("cleaningUp", logicalSource, true);
        QString cleanupError;
        if (stageCreated && !removeOne(stage, &cleanupError)) {
            if (recovery)
                recovery->append(QJsonObject{{"source", logicalSource}, {"destination", destination},
                    {"recoveryPath", stage}, {"kind", "destinationStagingCleanupFailed"},
                    {"error", cleanupError}});
            *error = QStringLiteral("Staging cleanup failed at %1: %2").arg(stage, cleanupError);
            return TransferResult::Failed;
        }
        return copyResult;
    }

    if (cancellationRequested(token)) {
        if (progress)
            progress->report("cleaningUp", logicalSource, true);
        QString cleanupError;
        if (!removeOne(stage, &cleanupError)) {
            if (recovery)
                recovery->append(QJsonObject{{"source", logicalSource}, {"destination", destination},
                    {"recoveryPath", stage}, {"kind", "destinationStagingCleanupFailed"},
                    {"error", cleanupError}});
            *error = QStringLiteral("Staging cleanup failed at %1: %2").arg(stage, cleanupError);
            return TransferResult::Failed;
        }
        return TransferResult::Cancelled;
    }
    if (progress)
        progress->report("committing", logicalSource, true);
    const RenameResult result = renameNoReplace(stage, destination, error);
    if (result == RenameResult::Renamed)
        return TransferResult::Success;

    QString cleanupError;
    const bool cleanupFailed = !removeOne(stage, &cleanupError);
    if (result == RenameResult::AlreadyExists)
        *error = QStringLiteral("Destination already exists: %1").arg(destination);
    else if (result == RenameResult::CrossDevice)
        *error = QStringLiteral("Could not commit staged copy across filesystems");
    if (cleanupFailed) {
        if (recovery)
            recovery->append(QJsonObject{{"source", logicalSource}, {"destination", destination},
                {"recoveryPath", stage}, {"kind", "destinationStagingCleanupFailed"},
                {"error", cleanupError}});
        *error += QStringLiteral("; staging cleanup failed at %1: %2").arg(stage, cleanupError);
    }
    return TransferResult::Failed;
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

TransferResult moveOne(const QString &source, const QString &destination, QString *error,
                       bool *destinationCommitted, TransferProgress *progress,
                       const QString &logicalSource, const CancellationToken &token,
                       QJsonArray *recovery)
{
    *destinationCommitted = false;
    if (cancellationRequested(token))
        return TransferResult::Cancelled;
    if (progress)
        progress->report("committing", logicalSource, true);
    // Atomic renames otherwise complete before a development UI can paint its
    // running state. This is still zero-cost unless the development hook is set.
    if (!developmentTransferPause(token, 10))
        return TransferResult::Cancelled;
    const RenameResult result = renameNoReplace(source, destination, error);
    if (result == RenameResult::Renamed) {
        *destinationCommitted = true;
        if (progress)
            progress->entryCompleted(logicalSource);
        return TransferResult::Success;
    }
    if (result == RenameResult::AlreadyExists) {
        *error = QStringLiteral("Destination already exists: %1").arg(destination);
        return TransferResult::Failed;
    }
    if (result != RenameResult::CrossDevice)
        return TransferResult::Failed;

    // Move the source to a private sibling first. This pins the root entry so
    // a concurrent replacement of the original pathname can never be removed
    // after a cross-device copy succeeds.
    const QFileInfo sourceInfo(source);
    const QString stagedSource = sourceInfo.dir().filePath(
        QStringLiteral(".filesail-move-%1")
            .arg(QUuid::createUuid().toString(QUuid::WithoutBraces)));
    const ActiveStage activeStage(stagedSource);
    if (renameNoReplace(source, stagedSource, error) != RenameResult::Renamed)
        return TransferResult::Failed;

    struct stat stagedStatus {};
    if (!lstatPath(fileSystemPath(stagedSource), &stagedStatus, error)) {
        QString rollbackError;
        if (progress) progress->report("restoringSource", logicalSource, true);
        if (renameNoReplace(stagedSource, source, &rollbackError) != RenameResult::Renamed && recovery)
            recovery->append(QJsonObject{{"source", source}, {"destination", destination},
                {"recoveryPath", stagedSource}, {"kind", "sourceRollbackFailed"}, {"error", rollbackError}});
        return TransferResult::Failed;
    }

    const TransferResult copyResult = copyOne(stagedSource, destination, error, progress,
                                              logicalSource, token, recovery);
    if (copyResult != TransferResult::Success) {
        QString rollbackError;
        if (progress) progress->report("restoringSource", logicalSource, true);
        if (renameNoReplace(stagedSource, source, &rollbackError) != RenameResult::Renamed) {
            if (recovery)
                recovery->append(QJsonObject{{"source", source}, {"destination", destination},
                    {"recoveryPath", stagedSource}, {"kind", "sourceRollbackFailed"},
                    {"error", rollbackError}});
            *error = QStringLiteral("Source remains staged at %1: %2").arg(stagedSource, rollbackError);
            return TransferResult::Failed;
        }
        return copyResult;
    }
    *destinationCommitted = true;
    if (progress)
        progress->report("cleaningUp", logicalSource, true);
    struct stat currentStagedStatus {};
    if (!lstatPath(fileSystemPath(stagedSource), &currentStagedStatus, error)
        || !sameFile(stagedStatus, currentStagedStatus)) {
        *error = QStringLiteral("Copied to %1, but the staged source changed and was kept at %2")
                     .arg(destination, stagedSource);
        if (recovery)
            recovery->append(QJsonObject{{"source", source}, {"destination", destination},
                {"recoveryPath", stagedSource}, {"kind", "sourceCleanupIdentityChanged"}, {"error", *error}});
        return TransferResult::Failed;
    }
    if (!removeOne(stagedSource, error)) {
        *error = QStringLiteral("Copied to %1, but the source could not be fully removed; the destination was kept. %2")
                     .arg(destination, *error);
        if (recovery)
            recovery->append(QJsonObject{{"source", source}, {"destination", destination},
                {"recoveryPath", stagedSource}, {"kind", "sourceCleanupFailed"}, {"error", *error}});
        return TransferResult::Failed;
    }
    return TransferResult::Success;
}

QJsonObject transferPaths(const QJsonObject &params, bool move,
                          const CancellationToken &token,
                          const FileOperations::ProgressCallback &progressCallback)
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
    QJsonArray recovery;
    TransferProgress progress;
    progress.callback = progressCallback;
    progress.topLevelTotal = paths.size();
    QVector<QString> sources;
    sources.reserve(paths.size());
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
        sources.append(source);
    }

    progress.report("scanning", {}, true);
    for (const QString &source : std::as_const(sources)) {
        error.clear();
        const TransferResult scanResult = scanEntry(fileSystemPath(source), &error, &progress,
                                                    source, token);
        if (scanResult == TransferResult::Cancelled)
            return failure("Operation cancelled", {{"errorCode", "cancelled"}, {"completed", completed}});
        if (scanResult == TransferResult::Failed)
            return failure(QStringLiteral("%1: %2").arg(source, error), {{"completed", completed}});
    }
    progress.totalsReady = true;
    progress.report("preparing", {}, true);

    for (const QString &source : std::as_const(sources)) {
        if (cancellationRequested(token))
            return failure("Operation cancelled", {{"errorCode", "cancelled"}, {"completed", completed}});
        progress.report("preparing", source, true);
        const QString destination = destinationFor(source, targetDirectory);
        bool destinationCommitted = false;
        const TransferResult result = move
            ? moveOne(source, destination, &error, &destinationCommitted, &progress, source, token, &recovery)
            : copyOne(source, destination, &error, &progress, source, token, &recovery);
        if (result != TransferResult::Success) {
            QJsonObject details{{"completed", completed}};
            if (!recovery.isEmpty()) {
                details.insert("recovery", recovery);
                details.insert("errorCode", "recovery_failed");
                details.insert("cancellationRequested", cancellationRequested(token));
            } else if (result == TransferResult::Cancelled) {
                details.insert("errorCode", "cancelled");
            }
            if (move && destinationCommitted) {
                details.insert("partial", QJsonArray{QJsonObject{
                    {"source", source},
                    {"destination", destination},
                    {"state", "destinationCommittedSourceRemovalFailed"},
                }});
            }
            const QString message = result == TransferResult::Cancelled
                ? QStringLiteral("Operation cancelled")
                : QStringLiteral("%1: %2").arg(source, error);
            return failure(message, details);
        }
        completed.append(destination);
        progress.topLevelCompleted(source);
    }
    return success({{"paths", completed}});
}

} // namespace

namespace FileOperations {

QJsonObject listDirectory(const QJsonObject &params, const CancellationToken &token)
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
    const bool allowLargeDirectory = params.value("allowLargeDirectory").toBool(false);
    const QString query = params.value("filter").toString().trimmed();
    QFileInfoList entries;
    FolderContextAccumulator context(path);
    const bool includeContext = params.value("includeContext").toBool(false);
    std::error_code enumerationError;
    std::filesystem::directory_iterator iterator(fileSystemPath(path), enumerationError);
    const std::filesystem::directory_iterator end;
    constexpr qsizetype largeDirectoryWarningThreshold = 5000;
    constexpr qsizetype maximumConfirmedDirectoryEntries = 50000;
    qsizetype entryCount = 0;
    qsizetype unsafeEntryCount = 0;
    while (!enumerationError && iterator != end) {
        if (cancellationRequested(token))
            return {};
        ++entryCount;
        if (allowLargeDirectory && entryCount > maximumConfirmedDirectoryEntries)
            return failure(QStringLiteral("Directory exceeds the %1-entry safety limit").arg(maximumConfirmedDirectoryEntries));
        if (!allowLargeDirectory && entryCount > largeDirectoryWarningThreshold) {
            return failure(QStringLiteral("Directory contains more than %1 entries; confirmation is required before loading it")
                               .arg(largeDirectoryWarningThreshold),
                           {{"requiresConfirmation", true},
                            {"entryCountAtLeast", static_cast<double>(entryCount)},
                            {"path", path}});
        }
        if (!isRoundTrippableFileSystemPath(iterator->path())) {
            ++unsafeEntryCount;
            iterator.increment(enumerationError);
            continue;
        }
        const QFileInfo info(qtPath(iterator->path()));
        const QString name = info.fileName();
        if (includeContext) {
            std::error_code statusError;
            const auto status = iterator->symlink_status(statusError);
            if (!statusError)
                context.add(name, std::filesystem::is_regular_file(status), std::filesystem::is_directory(status));
        }
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
    if (cancellationRequested(token))
        return {};
    QCollator collator;
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
            comparison = collator.compare(left.fileName(), right.fileName());
        return descending ? comparison > 0 : comparison < 0;
    });

    QMimeDatabase mimeDatabase;
    QJsonArray jsonEntries;
    for (const QFileInfo &info : entries) {
        if (cancellationRequested(token))
            return {};
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
            {"isExecutable", info.isExecutable()},
            {"permissions", symbolicPermissions(info)},
            {"size", static_cast<double>(info.size())},
            {"modified", info.lastModified().toUTC().toString(Qt::ISODateWithMs)},
            {"created", info.birthTime().isValid()
                            ? info.birthTime().toUTC().toString(Qt::ISODateWithMs)
                            : QString()},
            {"mimeType", mime.name()},
            {"iconName", info.isDir() ? QStringLiteral("folder") : iconName},
        });
    }

    QJsonObject result{{"path", path},
                       {"parentPath", QDir(path).absolutePath() == "/" ? "/" : QFileInfo(path).dir().absolutePath()},
                       {"entries", jsonEntries},
                       {"unsafeEntryCount", static_cast<double>(unsafeEntryCount)}};
    if (cancellationRequested(token))
        return {};
    if (includeContext)
        result.insert("context", context.result());
    return success(result);
}

QJsonObject completeDirectories(const QJsonObject &params, const CancellationToken &token)
{
    QString error;
    const QString parent = requiredPath(params, "parent", &error);
    if (!error.isEmpty()) return failure(error);
    const QFileInfo parentInfo(parent);
    if (!parentInfo.isDir()) return failure(QStringLiteral("Directory does not exist: %1").arg(parent));
    const QString prefix = params.value("prefix").toString();
    constexpr int maximumResults = 8;
    QVector<QPair<QString, QString>> matches;
    std::error_code enumerationError;
    std::filesystem::directory_iterator iterator(fileSystemPath(parent), enumerationError);
    const std::filesystem::directory_iterator end;
    while (!enumerationError && iterator != end) {
        if (cancellationRequested(token)) return {};
        if (!isRoundTrippableFileSystemPath(iterator->path())) { iterator.increment(enumerationError); continue; }
        const QFileInfo info(qtPath(iterator->path()));
        if (info.isDir() && info.fileName().startsWith(prefix, Qt::CaseInsensitive))
            matches.append({info.fileName(), info.absoluteFilePath()});
        iterator.increment(enumerationError);
    }
    if (enumerationError) return failure(QStringLiteral("Could not enumerate directory %1").arg(parent));
    std::sort(matches.begin(), matches.end(), [](const auto &left, const auto &right) {
        return QString::localeAwareCompare(left.first, right.first) < 0;
    });
    QJsonArray results;
    for (int index = 0; index < std::min<qsizetype>(maximumResults, matches.size()); ++index)
        results.append(QJsonObject{{"name", matches.at(index).first}, {"path", matches.at(index).second}});
    return success({{"entries", results}});
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

QJsonObject trashPaths(const QJsonObject &params, const CancellationToken &token,
                       const ProgressCallback &progressCallback)
{
    if (!params.value("paths").isArray())
        return failure("paths must be an array");
    const QJsonArray paths = params.value("paths").toArray();
    if (paths.isEmpty())
        return failure("No paths supplied");

    QJsonArray trashed;
    TransferProgress progress;
    progress.callback = progressCallback;
    progress.topLevelTotal = paths.size();
    progress.report("preparing", {}, true);
    for (const QJsonValue &value : paths) {
        if (cancellationRequested(token))
            return failure("Operation cancelled", {{"errorCode", "cancelled"}, {"completed", trashed}});
        QString error;
        const QString path = validateLocalPath(value, "trash path", &error);
        if (!error.isEmpty())
            return failure(error, {{"completed", trashed}});
        if (path == "/")
            return failure("Refusing to move the filesystem root to Trash", {{"completed", trashed}});
        progress.report("transferring", path);
        if (!developmentTransferPause(token))
            return failure("Operation cancelled", {{"errorCode", "cancelled"}, {"completed", trashed}});
        QString trashPath;
        if (!QFile::moveToTrash(path, &trashPath))
            return failure(QStringLiteral("Could not move to trash: %1").arg(path),
                           {{"completed", trashed}});
        trashed.append(trashPath);
        progress.topLevelCompleted(path);
    }
    return success({{"paths", trashed}});
}

QJsonObject copyPaths(const QJsonObject &params, const CancellationToken &token,
                      const ProgressCallback &progress)
{
    return transferPaths(params, false, token, progress);
}

QJsonObject movePaths(const QJsonObject &params, const CancellationToken &token,
                      const ProgressCallback &progress)
{
    return transferPaths(params, true, token, progress);
}

QJsonObject setExecutable(const QJsonObject &params)
{
    QString error;
    const QString path = requiredPath(params, "path", &error);
    if (!error.isEmpty())
        return failure(error);
    if (!params.value("executable").isBool())
        return failure("executable must be a boolean");
    const bool executable = params.value("executable").toBool();
    if (!entryExists(path))
        return failure(QStringLiteral("Path does not exist: %1").arg(path));
    // Directories need the execute bit for traversal. Toggling it from a
    // quick file action could lock the user out, so this stays file-only.
    if (QFileInfo(path).isDir())
        return failure(QStringLiteral("Cannot change execution permission of a directory: %1").arg(path));
    constexpr auto execBits = std::filesystem::perms::owner_exec
        | std::filesystem::perms::group_exec | std::filesystem::perms::others_exec;
    std::error_code ec;
    std::filesystem::permissions(fileSystemPath(path), execBits,
                                 executable ? std::filesystem::perm_options::add
                                            : std::filesystem::perm_options::remove,
                                 ec);
    if (ec)
        return failure(QStringLiteral("Could not change execution permission of %1: %2")
                           .arg(path, QString::fromStdString(ec.message())));
    return success({{"path", path}, {"executable", executable}});
}

namespace {

struct ProcessResult {
    bool ok = false;
    QString output;
};

ProcessResult runShortCapture(const QString &program, const QStringList &arguments,
                             const QProcessEnvironment &environment, int timeoutMs)
{
    QProcess query;
    query.setProgram(program);
    query.setArguments(arguments);
    if (!environment.isEmpty())
        query.setProcessEnvironment(environment);
    query.setStandardInputFile(QProcess::nullDevice());
    query.start();
    if (!query.waitForStarted(5000) || !query.waitForFinished(timeoutMs)) {
        query.kill();
        return {};
    }
    if (query.exitStatus() != QProcess::NormalExit || query.exitCode() != 0) {
        return {};
    }
    return {true, QString::fromLocal8Bit(query.readAllStandardOutput())};
}

bool desktopFileLocatable(const QString &id)
{
    return id.endsWith(QStringLiteral(".desktop")) && !id.contains(QLatin1Char('/'))
        && !QStandardPaths::locate(QStandardPaths::GenericDataLocation,
                                   QStringLiteral("applications/") + id)
                .isEmpty();
}

QStringList candidateMimeNames(const QString &path)
{
    QStringList names;
    const QString qtName = QMimeDatabase().mimeTypeForFile(path).name();
    if (!qtName.isEmpty())
        names.append(qtName);
    // xdg-mime consults the same database as `xdg-mime query default`, so its
    // answer stays consistent with the lookup below. Qt's database can name
    // the same content differently.
    if (!QStandardPaths::findExecutable(QStringLiteral("xdg-mime")).isEmpty()) {
        const ProcessResult result = runShortCapture(
            QStringLiteral("xdg-mime"),
            {QStringLiteral("query"), QStringLiteral("filetype"), path}, {}, 5000);
        const QString detected = result.output.trimmed();
        if (result.ok && detected.contains(QLatin1Char('/')) && !names.contains(detected))
            names.append(detected);
    }
    return names;
}

// Nautilus resolves defaults through GIO, which also falls back across
// MIME subclasses (e.g. text/markdown inherits text/plain defaults) where
// xdg-mime reports no default at all. Query GIO first so double-click
// behavior matches. Output quotes are localized; parse the trailing entry ID.
QString defaultDesktopFromGio(const QString &mimeName)
{
    if (mimeName.isEmpty()
        || QStandardPaths::findExecutable(QStringLiteral("gio")).isEmpty())
        return {};
    QProcessEnvironment environment = QProcessEnvironment::systemEnvironment();
    environment.insert(QStringLiteral("LC_ALL"), QStringLiteral("C"));
    const ProcessResult result = runShortCapture(QStringLiteral("gio"),
                                                 {QStringLiteral("mime"), mimeName}, environment,
                                                 5000);
    if (!result.ok)
        return {};
    const QStringList lines = result.output.split(QLatin1Char('\n'));
    for (const QString &line : lines) {
        const QString trimmed = line.trimmed();
        if (!trimmed.startsWith(QStringLiteral("Default application for")))
            continue;
        const QString id = trimmed.section(QLatin1Char(' '), -1).trimmed();
        if (desktopFileLocatable(id))
            return id;
        return {};
    }
    return {};
}

QString defaultDesktopFromXdgMime(const QString &mimeName)
{
    if (mimeName.isEmpty()
        || QStandardPaths::findExecutable(QStringLiteral("xdg-mime")).isEmpty())
        return {};
    const ProcessResult result = runShortCapture(
        QStringLiteral("xdg-mime"),
        {QStringLiteral("query"), QStringLiteral("default"), mimeName}, {}, 5000);
    const QString id = result.output.trimmed();
    if (result.ok && desktopFileLocatable(id))
        return id;
    return {};
}

QString findDefaultDesktopFile(const QStringList &mimeNames)
{
    for (const QString &mimeName : mimeNames) {
        const QString id = defaultDesktopFromGio(mimeName);
        if (!id.isEmpty())
            return id;
    }
    for (const QString &mimeName : mimeNames) {
        const QString id = defaultDesktopFromXdgMime(mimeName);
        if (!id.isEmpty())
            return id;
    }
    return {};
}

// Flag placed between the terminal's own arguments and the wrapped command
// for commands named directly (TERMINAL, gsettings, legacy candidates).
// xdg-terminal-exec and entries parsed from xdg-terminals.list carry their
// own execution argument instead.
QStringList withLegacyExecFlag(QStringList terminal)
{
    const QString program = terminal.takeFirst();
    const QString key = QFileInfo(program).fileName().toLower();
    if (key == QStringLiteral("kitty") || key == QStringLiteral("foot")) {
        // Take the wrapped command directly.
    } else if (key == QStringLiteral("gnome-terminal") || key == QStringLiteral("gnome-console")
               || key == QStringLiteral("console")
               || key == QStringLiteral("pantheon-terminal")) {
        terminal.append(QStringLiteral("--"));
    } else if (key == QStringLiteral("wezterm")) {
        terminal.append(QStringLiteral("start"));
        terminal.append(QStringLiteral("--"));
    } else if (key == QStringLiteral("xfce4-terminal")) {
        terminal.append(QStringLiteral("-x"));
    } else {
        // alacritty, konsole, ghostty, xterm, x-terminal-emulator and most
        // TERMINAL values accept -e.
        terminal.append(QStringLiteral("-e"));
    }
    return QStringList{program} + terminal;
}

QStringList legacyTerminalCandidates()
{
    return {QStringLiteral("x-terminal-emulator"), QStringLiteral("kitty"),
            QStringLiteral("foot"), QStringLiteral("alacritty"), QStringLiteral("wezterm"),
            QStringLiteral("ghostty"), QStringLiteral("konsole"),
            QStringLiteral("gnome-terminal"), QStringLiteral("xfce4-terminal")};
}

// Preferred terminals from ${desktop}-xdg-terminals.list / xdg-terminals.list
// in the XDG config hierarchy: the same source xdg-terminal-exec reads, so a
// configured default (e.g. ghostty on Omarchy) is honored with its own
// execution argument instead of a hardcoded guess.
QStringList configuredTerminalIds()
{
    QStringList configDirs;
    const QString configHome = QStandardPaths::writableLocation(QStandardPaths::ConfigLocation);
    if (!configHome.isEmpty())
        configDirs.append(configHome);
    const QString configDirsEnv = qEnvironmentVariable("XDG_CONFIG_DIRS");
    configDirs += configDirsEnv.isEmpty() ? QStringList{QStringLiteral("/etc/xdg")}
                                          : configDirsEnv.split(QLatin1Char(':'));
    QStringList desktops;
    const QString currentDesktop = qEnvironmentVariable("XDG_CURRENT_DESKTOP").toLower();
    if (!currentDesktop.isEmpty())
        desktops = currentDesktop.split(QLatin1Char(':'), Qt::SkipEmptyParts);
    QStringList ids;
    for (const QString &dir : configDirs) {
        QStringList files;
        for (const QString &desktop : desktops)
            files.append(dir + QLatin1Char('/') + desktop + QStringLiteral("-xdg-terminals.list"));
        files.append(dir + QStringLiteral("/xdg-terminals.list"));
        for (const QString &fileName : files) {
            QFile file(fileName);
            if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
                continue;
            QTextStream stream(&file);
            stream.setEncoding(QStringConverter::Utf8);
            while (!stream.atEnd()) {
                QString id = stream.readLine().trimmed();
                if (id.isEmpty() || id.startsWith(QLatin1Char('#'))
                    || id.startsWith(QLatin1Char('/')) || id.startsWith(QLatin1Char('-')))
                    continue;
                // Entry IDs may carry an action suffix (id.desktop:action);
                // only the entry itself is used here.
                id = id.section(QLatin1Char(':'), 0, 0).trimmed();
                if (!id.endsWith(QStringLiteral(".desktop"))
                    || id.contains(QLatin1Char('/')) || ids.contains(id))
                    continue;
                ids.append(id);
            }
        }
    }
    return ids;
}

QHash<QString, QString> desktopEntryKeys(const QString &fullPath)
{
    QHash<QString, QString> keys;
    QFile file(fullPath);
    if (!file.open(QIODevice::ReadOnly | QIODevice::Text))
        return keys;
    QTextStream stream(&file);
    stream.setEncoding(QStringConverter::Utf8);
    bool inDesktopEntry = false;
    while (!stream.atEnd()) {
        const QString line = stream.readLine().trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        if (line.startsWith(QLatin1Char('[')) && line.endsWith(QLatin1Char(']'))) {
            inDesktopEntry = line == QStringLiteral("[Desktop Entry]");
            continue;
        }
        if (!inDesktopEntry)
            continue;
        const qsizetype separator = line.indexOf(QLatin1Char('='));
        if (separator < 0)
            continue;
        const QString key = line.left(separator).trimmed();
        if (keys.contains(key))
            continue;
        keys.insert(key, line.mid(separator + 1).trimmed());
    }
    return keys;
}

struct DesktopEntry {
    bool valid = false;
    bool terminal = false;
    QString exec;
    QString workingDirectory;
    QString name;
};

DesktopEntry readDesktopEntry(const QString &fileName)
{
    DesktopEntry entry;
    const QString fullPath = QStandardPaths::locate(QStandardPaths::GenericDataLocation,
                                                    QStringLiteral("applications/") + fileName);
    if (fullPath.isEmpty())
        return entry;
    const QHash<QString, QString> keys = desktopEntryKeys(fullPath);
    entry.exec = keys.value(QStringLiteral("Exec"));
    entry.terminal =
        keys.value(QStringLiteral("Terminal")).compare(QStringLiteral("true"),
                                                       Qt::CaseInsensitive)
        == 0;
    entry.workingDirectory = keys.value(QStringLiteral("Path"));
    entry.name = keys.value(QStringLiteral("Name"));
    entry.valid = !entry.exec.isEmpty();
    return entry;
}

struct TerminalEntry {
    bool valid = false;
    QStringList baseArgv;
    QString execArg = QStringLiteral("-e");
};

TerminalEntry readTerminalEntry(const QString &fileName)
{
    TerminalEntry terminal;
    const QString fullPath = QStandardPaths::locate(QStandardPaths::GenericDataLocation,
                                                    QStringLiteral("applications/") + fileName);
    if (fullPath.isEmpty())
        return terminal;
    const QHash<QString, QString> keys = desktopEntryKeys(fullPath);
    if (!keys.value(QStringLiteral("Categories")).split(QLatin1Char(';')).contains(QStringLiteral("TerminalEmulator")))
        return terminal;
    if (keys.contains(QStringLiteral("TryExec"))) {
        const QStringList tryCommand = QProcess::splitCommand(keys.value(QStringLiteral("TryExec")));
        if (tryCommand.isEmpty()
            || QStandardPaths::findExecutable(tryCommand.constFirst()).isEmpty())
            return terminal;
    }
    QStringList baseArgv = QProcess::splitCommand(keys.value(QStringLiteral("Exec")));
    // Terminal launchers take no file field codes; drop any stray ones so a
    // literal "%f" never reaches the emulator.
    baseArgv.removeAll(QStringLiteral("%f"));
    baseArgv.removeAll(QStringLiteral("%F"));
    baseArgv.removeAll(QStringLiteral("%u"));
    baseArgv.removeAll(QStringLiteral("%U"));
    if (baseArgv.isEmpty()
        || QStandardPaths::findExecutable(baseArgv.constFirst()).isEmpty())
        return terminal;
    terminal.baseArgv = baseArgv;
    if (keys.contains(QStringLiteral("X-TerminalArgExec")))
        terminal.execArg = keys.value(QStringLiteral("X-TerminalArgExec"));
    else if (keys.contains(QStringLiteral("X-ExecArg")))
        terminal.execArg = keys.value(QStringLiteral("X-ExecArg"));
    else if (keys.contains(QStringLiteral("ExecArg")))
        terminal.execArg = keys.value(QStringLiteral("ExecArg"));
    terminal.valid = true;
    return terminal;
}

QStringList terminalFromGsettings()
{
    if (QStandardPaths::findExecutable(QStringLiteral("gsettings")).isEmpty())
        return {};
    const ProcessResult result = runShortCapture(
        QStringLiteral("gsettings"),
        {QStringLiteral("get"),
         QStringLiteral("org.gnome.desktop.default-applications.terminal"),
         QStringLiteral("exec")},
        {}, 5000);
    QString value = result.output.trimmed();
    if (!result.ok || value.isEmpty())
        return {};
    if (value.startsWith(QLatin1Char('\'')) && value.endsWith(QLatin1Char('\'')) && value.size() >= 2)
        value = value.mid(1, value.size() - 2);
    const QStringList command = QProcess::splitCommand(value);
    if (command.isEmpty()
        || QStandardPaths::findExecutable(command.constFirst()).isEmpty())
        return {};
    return withLegacyExecFlag(command);
}

// Terminal prefix argv (program first, execution flag last); the wrapped
// application argv is appended by the caller. Order mirrors GLib/Nautilus,
// which ignores TERMINAL and delegates to xdg-terminal-exec: the standard
// launcher first, then its config parsed directly, then an explicit TERMINAL
// override, then the GNOME default, then legacy candidates.
QStringList resolveTerminalPrefix(QString *error)
{
    if (!QStandardPaths::findExecutable(QStringLiteral("xdg-terminal-exec")).isEmpty()) {
        filesailLog(LogLevel::Debug, "open", QStringLiteral("terminal: xdg-terminal-exec"));
        return {QStringLiteral("xdg-terminal-exec")};
    }
    for (const QString &id : configuredTerminalIds()) {
        const TerminalEntry terminal = readTerminalEntry(id);
        if (!terminal.valid)
            continue;
        QStringList prefix = terminal.baseArgv;
        if (!terminal.execArg.isEmpty())
            prefix.append(terminal.execArg);
        filesailLog(LogLevel::Debug, "open",
                    QStringLiteral("terminal: configured entry %1").arg(id));
        return prefix;
    }
    const QStringList override = QProcess::splitCommand(qEnvironmentVariable("TERMINAL"));
    if (!override.isEmpty()) {
        if (QStandardPaths::findExecutable(override.constFirst()).isEmpty()) {
            *error = QStringLiteral("Terminal executable was not found: %1")
                         .arg(override.constFirst());
            return {};
        }
        filesailLog(LogLevel::Debug, "open",
                    QStringLiteral("terminal: TERMINAL override %1")
                        .arg(override.constFirst()));
        return withLegacyExecFlag(override);
    }
    const QStringList gsettingsTerminal = terminalFromGsettings();
    if (!gsettingsTerminal.isEmpty()) {
        filesailLog(LogLevel::Debug, "open",
                    QStringLiteral("terminal: gsettings default %1")
                        .arg(gsettingsTerminal.constFirst()));
        return gsettingsTerminal;
    }
    for (const QString &candidate : legacyTerminalCandidates()) {
        if (!QStandardPaths::findExecutable(candidate).isEmpty()) {
            filesailLog(LogLevel::Debug, "open",
                        QStringLiteral("terminal: legacy candidate %1").arg(candidate));
            return withLegacyExecFlag({candidate});
        }
    }
    *error = QStringLiteral(
        "The default application for this file needs a terminal, but no terminal emulator was found. "
        "Set the TERMINAL environment variable.");
    return {};
}

QStringList expandDesktopExec(const QString &execLine, const QString &localPath,
                              const QString &fileUri, const QString &desktopFilePath,
                              const QString &appName)
{
    if (execLine.trimmed().isEmpty())
        return {};
    // Placeholder for a literal % so field-code detection and expansion below
    // never mistake an escaped %%F for a file code.
    const QString percentPlaceholder = QString(QChar(0xE000)) + QStringLiteral("PERCENT")
        + QString(QChar(0xE001));
    QString protectedLine = execLine;
    protectedLine.replace(QStringLiteral("%%"), percentPlaceholder);
    // Split before expanding so paths containing spaces stay a single argument.
    const QStringList rawArgv = QProcess::splitCommand(protectedLine);
    if (rawArgv.isEmpty())
        return {};
    bool hasFileCode = false;
    QStringList argv;
    argv.reserve(rawArgv.size() + 1);
    for (QString arg : rawArgv) {
        if (arg.contains(QStringLiteral("%f")) || arg.contains(QStringLiteral("%F"))
            || arg.contains(QStringLiteral("%u")) || arg.contains(QStringLiteral("%U")))
            hasFileCode = true;
        arg.replace(QStringLiteral("%f"), localPath);
        arg.replace(QStringLiteral("%F"), localPath);
        arg.replace(QStringLiteral("%u"), fileUri);
        arg.replace(QStringLiteral("%U"), fileUri);
        arg.replace(QStringLiteral("%c"), appName);
        arg.replace(QStringLiteral("%k"), desktopFilePath);
        for (const QString &code :
             {QStringLiteral("%i"), QStringLiteral("%d"), QStringLiteral("%D"),
              QStringLiteral("%n"), QStringLiteral("%N"), QStringLiteral("%v"),
              QStringLiteral("%m")})
            arg.replace(code, QString());
        arg.replace(percentPlaceholder, QStringLiteral("%"));
        if (!arg.isEmpty())
            argv.append(arg);
    }
    if (argv.isEmpty())
        return {};
    if (!hasFileCode)
        argv.append(localPath);
    return argv;
}

QJsonObject runOpenerSync(const QString &program, const QStringList &arguments)
{
    QProcess opener;
    opener.setProgram(program);
    opener.setArguments(arguments);
    opener.setStandardInputFile(QProcess::nullDevice());
    opener.start();
    if (!opener.waitForStarted(5000))
        return failure(
            QStringLiteral("Could not start %1: %2").arg(program, opener.errorString()));
    if (!opener.waitForFinished(10000)) {
        // xdg-open intentionally stays alive while it runs a blocking handler.
        // The application has likely launched, so reap the wrapper and report
        // success instead of blocking the backend worker indefinitely.
        opener.terminate();
        opener.waitForFinished(2000);
        return success();
    }
    if (opener.exitStatus() != QProcess::NormalExit || opener.exitCode() != 0) {
        QString details = QString::fromLocal8Bit(opener.readAllStandardError()).trimmed();
        if (details.isEmpty())
            details = QString::fromLocal8Bit(opener.readAllStandardOutput()).trimmed();
        if (details.isEmpty())
            details = QStringLiteral("exit code %1").arg(opener.exitCode());
        else if (details.size() > 500)
            details = details.left(500) + QStringLiteral("…");
        return failure(QStringLiteral("%1 failed: %2").arg(program, details));
    }
    return success();
}

} // namespace

QJsonObject openPath(const QJsonObject &params)
{
    QString error;
    const QString path = requiredPath(params, "path", &error);
    if (!error.isEmpty())
        return failure(error);
    if (!QFileInfo::exists(path))
        return failure(QStringLiteral("Path does not exist: %1").arg(path));

    // xdg-open cannot attach Terminal=true handlers (micro, vim, ...) to a
    // terminal when launched from the backend, so it reports success while
    // nothing visible happens. Detect those handlers and run them inside the
    // user's terminal emulator instead.
    const QString desktopFileName = findDefaultDesktopFile(candidateMimeNames(path));
    filesailLog(LogLevel::Debug, "open",
                QStringLiteral("handler for %1: %2").arg(path, desktopFileName));
    if (!desktopFileName.isEmpty()) {
        const DesktopEntry entry = readDesktopEntry(desktopFileName);
        if (entry.valid && entry.terminal) {
            const QString desktopFilePath = QStandardPaths::locate(
                QStandardPaths::GenericDataLocation,
                QStringLiteral("applications/") + desktopFileName);
            const QString fileUri =
                QUrl::fromLocalFile(path).toString(QUrl::FullyEncoded);
            const QStringList applicationArgv = expandDesktopExec(
                entry.exec, path, fileUri, desktopFilePath, entry.name);
            if (applicationArgv.isEmpty())
                return failure(QStringLiteral("Could not parse the default application entry: %1")
                                   .arg(desktopFileName));
            QString terminalError;
            const QStringList prefix = resolveTerminalPrefix(&terminalError);
            if (!terminalError.isEmpty())
                return failure(terminalError);
            const QStringList wrapped = prefix + applicationArgv;
            QProcess terminal;
            terminal.setProgram(wrapped.constFirst());
            terminal.setArguments(wrapped.mid(1));
            terminal.setWorkingDirectory(entry.workingDirectory.isEmpty()
                                             ? QFileInfo(path).absolutePath()
                                             : entry.workingDirectory);
            terminal.setStandardInputFile(QProcess::nullDevice());
            terminal.setStandardOutputFile(QProcess::nullDevice());
            terminal.setStandardErrorFile(QProcess::nullDevice());
            if (!terminal.startDetached())
                return failure(QStringLiteral("Could not start terminal application: %1")
                                   .arg(terminal.errorString()));
            return success();
        }
    }

    if (!QStandardPaths::findExecutable(QStringLiteral("xdg-open")).isEmpty())
        return runOpenerSync(QStringLiteral("xdg-open"), {path});
    if (!QStandardPaths::findExecutable(QStringLiteral("gio")).isEmpty()) {
        // gio open waits for the application to exit, so it cannot run
        // synchronously without blocking the backend worker.
        QProcess opener;
        opener.setProgram(QStringLiteral("gio"));
        opener.setArguments({QStringLiteral("open"), path});
        opener.setStandardInputFile(QProcess::nullDevice());
        opener.setStandardOutputFile(QProcess::nullDevice());
        opener.setStandardErrorFile(QProcess::nullDevice());
        if (!opener.startDetached())
            return failure(
                QStringLiteral("Could not start gio: %1").arg(opener.errorString()));
        return success();
    }
    return failure(QStringLiteral(
        "No default application opener (xdg-open or gio) is available. Install xdg-utils."));
}

QJsonObject openTerminal(const QJsonObject &params)
{
    QString error;
    const QString path = requiredPath(params, "path", &error);
    if (!error.isEmpty())
        return failure(error);
    if (!QFileInfo(path).isDir())
        return failure(QStringLiteral("Directory does not exist: %1").arg(path));

    QStringList command = QProcess::splitCommand(qEnvironmentVariable("TERMINAL"));
    if (command.isEmpty()) {
        QStringList candidates = {QStringLiteral("xdg-terminal-exec")};
        candidates += legacyTerminalCandidates();
        for (const QString &candidate : candidates) {
            if (!QStandardPaths::findExecutable(candidate).isEmpty()) {
                command = {candidate};
                break;
            }
        }
    }
    if (command.isEmpty())
        return failure("No terminal emulator found. Set the TERMINAL environment variable.");

    const QString program = command.takeFirst();
    if (QStandardPaths::findExecutable(program).isEmpty())
        return failure(QStringLiteral("Terminal executable was not found: %1").arg(program));

    QProcess terminal;
    terminal.setProgram(program);
    terminal.setArguments(command);
    terminal.setWorkingDirectory(path);
    terminal.setStandardInputFile(QProcess::nullDevice());
    terminal.setStandardOutputFile(QProcess::nullDevice());
    terminal.setStandardErrorFile(QProcess::nullDevice());
    if (!terminal.startDetached())
        return failure("Could not start terminal emulator");
    return success();
}

} // namespace FileOperations
