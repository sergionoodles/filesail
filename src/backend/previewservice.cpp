#include "previewservice.h"
#include "logging.h"

#include <QCryptographicHash>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusInterface>
#include <QDBusMessage>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QMimeDatabase>
#include <QSet>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>
#include <archive.h>
#include <archive_entry.h>

namespace {
QJsonObject failure(const QString &message) { return {{"ok", false}, {"error", message}}; }

QString escaped(const QString &source)
{
    QString result = source.toHtmlEscaped();
    result.replace(QChar::Null, QChar(0xfffd));
    return result;
}

bool visualMime(const QString &mime)
{
    return mime.startsWith("image/") || mime.startsWith("video/") || mime == "application/pdf";
}
}

PreviewService::PreviewService(QObject *parent)
    : QObject(parent)
{
    auto bus = QDBusConnection::sessionBus();
    bus.connect("org.freedesktop.thumbnails.Thumbnailer1", "/org/freedesktop/thumbnails/Thumbnailer1",
                "org.freedesktop.thumbnails.Thumbnailer1", "Ready", this,
                SLOT(tumblerReady(uint,QStringList)));
    bus.connect("org.freedesktop.thumbnails.Thumbnailer1", "/org/freedesktop/thumbnails/Thumbnailer1",
                "org.freedesktop.thumbnails.Thumbnailer1", "Error", this,
                SLOT(tumblerError(uint,QStringList,int,QString)));
    bus.connect("org.freedesktop.thumbnails.Thumbnailer1", "/org/freedesktop/thumbnails/Thumbnailer1",
                "org.freedesktop.thumbnails.Thumbnailer1", "Finished", this,
                SLOT(tumblerFinished(uint)));
}

QString PreviewService::localRegularFile(const QJsonObject &params, QString *error)
{
    const QString raw = params.value("path").toString();
    if (raw.isEmpty() || raw.contains(QChar::Null)) { *error = "path must be an absolute local path"; return {}; }
    QString path = raw;
    if (raw.startsWith("file:")) {
        const QUrl url(raw, QUrl::StrictMode);
        if (!url.isValid() || !url.isLocalFile() || !url.query().isEmpty() || !url.fragment().isEmpty()) {
            *error = "path must be an absolute local path"; return {};
        }
        path = url.toLocalFile();
    }
    if (!QDir::isAbsolutePath(path)) { *error = "path must be an absolute local path"; return {}; }
    const QFileInfo info(QDir::cleanPath(path));
    if (!info.exists() || !info.isFile() || !info.isReadable()) {
        *error = "preview requires a readable regular file"; return {};
    }
    return info.absoluteFilePath();
}

QJsonObject PreviewService::capabilities() const
{
    const auto registered = QDBusConnection::sessionBus().interface()->isServiceRegistered(
        "org.freedesktop.thumbnails.Thumbnailer1");
    return {{"ok", true}, {"tumbler", registered.isValid() && registered.value()},
        {"flavors", QJsonArray{"normal", "large", "x-large", "xx-large"}},
        {"thumbnailMimeTypes", QJsonArray{}}, {"textHighlighting", false}, {"archiveListing", true}};
}

QString PreviewService::cachedThumbnail(const QString &path, const QString &flavor)
{
    static const QStringList flavors{"normal", "large", "x-large", "xx-large"};
    const int requestedIndex = flavors.indexOf(flavor);
    if (requestedIndex < 0) return {};
    const QByteArray uri = QUrl::fromLocalFile(path).toEncoded();
    const QString name = QString::fromLatin1(QCryptographicHash::hash(uri, QCryptographicHash::Md5).toHex()) + ".png";
    const QString root = QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation) + "/thumbnails/";
    for (int index = requestedIndex; index >= 0; --index) {
        const QFileInfo candidate(root + flavors.at(index) + "/" + name);
        if (candidate.isFile() && !candidate.isSymLink())
            return QUrl::fromLocalFile(candidate.absoluteFilePath()).toString();
    }
    return {};
}

void PreviewService::thumbnails(int requestId, const QJsonObject &params,
                                const CancellationToken &token,
                                std::function<void(QJsonObject)> completed)
{
    const QString flavor = params.value("flavor").toString("normal");
    const QSet<QString> flavors{"normal", "large", "x-large", "xx-large"};
    if (!flavors.contains(flavor)) { completed(failure("Unsupported thumbnail flavor")); return; }
    const QJsonArray requested = params.value("items").toArray();
    if (requested.size() > 64) { completed(failure("thumbnail batches are limited to 64 items")); return; }

    QJsonArray items;
    QStringList uris;
    QStringList mimeTypes;
    filesailLog(LogLevel::Debug, "preview",
                QStringLiteral("thumbnailBatch flavor=%1 count=%2").arg(flavor).arg(requested.size()));
    QMimeDatabase mimeDatabase;
    for (const QJsonValue &value : requested) {
        if (cancellationRequested(token)) { completed({}); return; }
        const QJsonObject input = value.toObject();
        QString error;
        const QString path = localRegularFile(input, &error);
        QJsonObject item{{"path", input.value("path").toString()}};
        if (path.isEmpty()) { item.insert("status", "unsupported"); items.append(item); continue; }
        const QFileInfo info(path);
        const QString suppliedMime = input.value("mimeType").toString();
        const QString mime = suppliedMime.isEmpty()
            ? mimeDatabase.mimeTypeForFile(info, QMimeDatabase::MatchExtension).name() : suppliedMime;
        item.insert("fingerprint", QString::number(info.size()) + ":" + QString::number(info.lastModified().toMSecsSinceEpoch()));
        const QString cached = cachedThumbnail(path, flavor);
        if (!cached.isEmpty()) {
            item.insert("status", "ready"); item.insert("url", cached);
        } else if (visualMime(mime)) {
            item.insert("status", "queued");
            uris.append(QUrl::fromLocalFile(path).toString());
            mimeTypes.append(mime);
        } else {
            item.insert("status", "unsupported");
        }
        items.append(item);
    }
    if (uris.isEmpty()) { completed({{"ok", true}, {"items", items}}); return; }
    if (cancellationRequested(token)) { completed({}); return; }

    QDBusInterface tumbler("org.freedesktop.thumbnails.Thumbnailer1", "/org/freedesktop/thumbnails/Thumbnailer1",
                           "org.freedesktop.thumbnails.Thumbnailer1", QDBusConnection::sessionBus());
    const QDBusMessage reply = tumbler.call("Queue", uris, mimeTypes, flavor,
                                            params.value("priority").toString() == "foreground" ? "foreground" : "background", 0U);
    if (reply.type() != QDBusMessage::ReplyMessage || reply.arguments().isEmpty()) {
        completed({{"ok", true}, {"items", items}});
        return;
    }
    const uint handle = reply.arguments().first().toUInt();
    m_thumbnailRequests.insert(requestId, ThumbnailRequest{
        requestId, handle, flavor, items, token, std::move(completed)});
    m_tumblerRequests.insert(handle, requestId);
    QTimer::singleShot(15000, this, [this, requestId] {
        if (m_thumbnailRequests.contains(requestId)) finishThumbnail(requestId);
    });
}

void PreviewService::cancelThumbnail(int requestId)
{
    const auto iterator = m_thumbnailRequests.find(requestId);
    if (iterator == m_thumbnailRequests.end()) return;
    if (iterator->tumblerHandle != 0) {
        QDBusInterface tumbler("org.freedesktop.thumbnails.Thumbnailer1", "/org/freedesktop/thumbnails/Thumbnailer1",
                               "org.freedesktop.thumbnails.Thumbnailer1", QDBusConnection::sessionBus());
        tumbler.call("Dequeue", iterator->tumblerHandle);
        m_tumblerRequests.remove(iterator->tumblerHandle);
    }
    finishThumbnail(requestId);
}

void PreviewService::finishThumbnail(int requestId)
{
    const auto iterator = m_thumbnailRequests.find(requestId);
    if (iterator == m_thumbnailRequests.end()) return;
    const ThumbnailRequest request = iterator.value();
    m_tumblerRequests.remove(request.tumblerHandle);
    m_thumbnailRequests.erase(iterator);
    if (cancellationRequested(request.token)) { request.completed({}); return; }
    QJsonArray items = request.items;
    for (int index = 0; index < items.size(); ++index) {
        if (cancellationRequested(request.token)) { request.completed({}); return; }
        QJsonObject item = items.at(index).toObject();
        if (item.value("status") != "queued") continue;
        const QUrl url(item.value("path").toString());
        const QString path = url.isLocalFile() ? url.toLocalFile() : item.value("path").toString();
        const QString output = cachedThumbnail(path, request.flavor);
        if (!output.isEmpty()) { item.insert("status", "ready"); item.insert("url", output); }
        else item.insert("status", "unsupported");
        items[index] = item;
    }
    request.completed({{"ok", true}, {"items", items}});
}

void PreviewService::tumblerReady(uint handle, const QStringList &uris)
{
    if (m_tumblerRequests.contains(handle))
        filesailLog(LogLevel::Debug, "preview", QStringLiteral("tumbler ready %1 (%2 uri(s))").arg(handle).arg(uris.size()));
}

void PreviewService::tumblerError(uint handle, const QStringList &uris, int, const QString &message)
{
    if (!m_tumblerRequests.contains(handle)) return;
    filesailLog(LogLevel::Debug, "preview",
                QStringLiteral("tumbler error %1 (%2 uri(s))").arg(message).arg(uris.size()));
}

void PreviewService::tumblerFinished(uint handle)
{
    const int requestId = m_tumblerRequests.value(handle, -1);
    if (requestId >= 0) finishThumbnail(requestId);
}

QJsonObject PreviewService::text(const QJsonObject &params, const CancellationToken &token) const
{
    QString error;
    const QString path = localRegularFile(params, &error);
    if (path.isEmpty()) return failure(error);
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly)) return failure("Could not open preview file");
    constexpr qsizetype maximumCharacters = 65536;
    QByteArray bytes = file.read(maximumCharacters * 4 + 1);
    const bool moreBytes = !file.atEnd();
    if (cancellationRequested(token)) return {};
    if (bytes.contains('\0')) return {{"ok", true}, {"kind", "unsupported"}, {"reason", "binary"}};
    const QString decoded = QString::fromUtf8(bytes);
    if (decoded.contains(QChar::ReplacementCharacter) && !bytes.isEmpty() && !moreBytes)
        return {{"ok", true}, {"kind", "unsupported"}, {"reason", "encoding"}};
    const bool characterTruncated = decoded.size() > maximumCharacters || moreBytes;
    QString source = decoded.left(maximumCharacters);
    QStringList lines = source.split('\n');
    if (source.endsWith('\n') && !lines.isEmpty()) lines.removeLast();
    const bool lineTruncated = lines.size() > 500;
    if (lineTruncated) lines = lines.sliced(0, 500);
    source = lines.join('\n');
    const QString mime = QMimeDatabase().mimeTypeForFile(path, QMimeDatabase::MatchExtension).name();
    return {{"ok", true}, {"kind", "text"}, {"mimeType", mime}, {"language", "Plain Text"}, {"encoding", "UTF-8"},
        {"truncated", characterTruncated || lineTruncated}, {"bytesRead", bytes.size()}, {"lineCount", lines.size()},
        {"html", "<pre>" + escaped(source) + "</pre>"}};
}

QJsonObject PreviewService::archive(const QJsonObject &params, const CancellationToken &token) const
{
    QString error;
    const QString path = localRegularFile(params, &error);
    if (path.isEmpty()) return failure(error);
    struct archive *reader = archive_read_new();
    archive_read_support_filter_all(reader);
    archive_read_support_format_all(reader);
    if (archive_read_open_filename(reader, QFile::encodeName(path).constData(), 64 * 1024) != ARCHIVE_OK) {
        archive_read_free(reader);
        return {{"ok", true}, {"kind", "unsupported"}, {"reason", "unreadable archive"}};
    }
    QJsonArray entries;
    struct archive_entry *entry = nullptr;
    bool truncated = false;
    qsizetype metadataBytes = 0;
    QElapsedTimer deadline;
    deadline.start();
    while (entries.size() < 250 && metadataBytes < 4 * 1024 * 1024 && deadline.elapsed() < 5000) {
        if (cancellationRequested(token)) { archive_read_free(reader); return {}; }
        if (archive_read_next_header(reader, &entry) != ARCHIVE_OK) break;
        const char *rawName = archive_entry_pathname_utf8(entry);
        const QString name = rawName ? QString::fromUtf8(rawName) : QStringLiteral("<invalid name>");
        const mode_t type = archive_entry_filetype(entry);
        const QString kind = type == AE_IFDIR ? "directory" : type == AE_IFLNK ? "symlink" : "file";
        metadataBytes += name.size() * static_cast<qsizetype>(sizeof(QChar));
        entries.append(QJsonObject{{"name", escaped(name.left(32 * 1024))}, {"type", kind},
            {"size", static_cast<double>(archive_entry_size(entry))}, {"encrypted", archive_entry_is_encrypted(entry) > 0}});
        archive_read_data_skip(reader);
    }
    if (entries.size() == 250 && metadataBytes < 4 * 1024 * 1024 && deadline.elapsed() < 5000) {
        if (cancellationRequested(token)) { archive_read_free(reader); return {}; }
        truncated = archive_read_next_header(reader, &entry) == ARCHIVE_OK;
    } else {
        truncated = metadataBytes >= 4 * 1024 * 1024 || deadline.elapsed() >= 5000;
    }
    const char *formatName = archive_format_name(reader);
    const QString format = QString::fromUtf8(formatName ? formatName : "archive");
    archive_read_free(reader);
    return {{"ok", true}, {"kind", "archive"}, {"format", format}, {"truncated", truncated},
        {"entryCountAtLeast", entries.size()}, {"entries", entries}};
}
