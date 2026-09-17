#include "previewservice.h"
#include "localpath.h"
#include "logging.h"

#include <QCryptographicHash>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusInterface>
#include <QDBusMessage>
#include <QDBusPendingCallWatcher>
#include <QDBusPendingReply>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QFutureWatcher>
#include <QJsonArray>
#include <QMimeDatabase>
#include <QImageReader>
#include <QSet>
#include <QStandardPaths>
#include <QStringDecoder>
#include <QTimer>
#include <QThreadPool>
#include <QUrl>
#include <QtConcurrentRun>
#include <archive.h>
#include <archive_entry.h>

namespace {
constexpr qsizetype maximumThumbnailPixels = 16 * 1024 * 1024;
constexpr qsizetype maximumThumbnailBytes = 64 * 1024 * 1024;

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

QString fingerprint(const QFileInfo &info)
{
    return QString::number(info.size()) + ":" + QString::number(info.lastModified().toMSecsSinceEpoch());
}

bool validInteger(const QString &value, qint64 *result)
{
    bool ok = false;
    const qint64 parsed = value.toLongLong(&ok);
    if (!ok || parsed < 0) return false;
    if (result) *result = parsed;
    return true;
}

bool validMtimeSeconds(const QString &value, qint64 *result)
{
    const qsizetype decimal = value.indexOf('.');
    if (decimal < 0) return validInteger(value, result);
    if (decimal == 0 || decimal == value.size() - 1 || value.indexOf('.', decimal + 1) >= 0)
        return false;
    for (qsizetype index = decimal + 1; index < value.size(); ++index)
        if (!value.at(index).isDigit()) return false;
    return validInteger(value.left(decimal), result);
}

QString validCachedThumbnail(const QString &path, const QString &uri, const QFileInfo &source,
                            const QString &flavor)
{
    static const QStringList flavors{"normal", "large", "x-large", "xx-large"};
    const int requestedIndex = flavors.indexOf(flavor);
    if (requestedIndex < 0) return {};
    const QByteArray hashInput = QUrl::fromLocalFile(path).toEncoded();
    const QString name = QString::fromLatin1(QCryptographicHash::hash(hashInput, QCryptographicHash::Md5).toHex()) + ".png";
    const QString root = QStandardPaths::writableLocation(QStandardPaths::GenericCacheLocation) + "/thumbnails/";
    const qint64 sourceMtime = source.lastModified().toSecsSinceEpoch();
    for (int index = requestedIndex; index >= 0; --index) {
        const QFileInfo candidate(root + flavors.at(index) + "/" + name);
        if (!candidate.isFile() || candidate.isSymLink()
            || candidate.size() <= 0 || candidate.size() > maximumThumbnailBytes) continue;

        QImageReader reader(candidate.absoluteFilePath(), QByteArrayLiteral("png"));
        reader.setAutoDetectImageFormat(false);
        QImageReader::setAllocationLimit(maximumThumbnailBytes / (1024 * 1024));
        QImage image = reader.read();
        const QSize size = image.size();
        if (image.isNull() || !size.isValid() || size.width() <= 0 || size.height() <= 0
            || static_cast<qsizetype>(size.width()) * size.height() > maximumThumbnailPixels)
            continue;

        qint64 storedMtime = 0;
        const QString storedUri = image.text("Thumb::URI");
        const QString storedSize = image.text("Thumb::Size");
        if (storedUri.isEmpty() || !validMtimeSeconds(image.text("Thumb::MTime"), &storedMtime)
            || storedUri != uri || storedMtime != sourceMtime)
            continue;
        if (!storedSize.isEmpty()) {
            qint64 sizeValue = 0;
            if (!validInteger(storedSize, &sizeValue) || sizeValue != source.size()) continue;
        }
        return QUrl::fromLocalFile(candidate.absoluteFilePath()).toString();
    }
    return {};
}

QString validatedThumbnail(const QString &path, const QString &uri, const QString &expectedFingerprint,
                           const QString &flavor)
{
    const QFileInfo source(path);
    if (!source.exists() || !source.isFile() || !source.isReadable()
        || fingerprint(source) != expectedFingerprint) return {};
    const QString cached = validCachedThumbnail(path, uri, source, flavor);
    const QFileInfo after(path);
    return !cached.isEmpty() && after.exists() && fingerprint(after) == expectedFingerprint ? cached : QString();
}

// True when any read filter (gzip, xz, zstd, ...) wraps the archive stream.
// Filter index `archive_filter_count - 1` is the raw file; it reports
// ARCHIVE_FILTER_NONE and is included in the check harmlessly.
bool streamCompressed(struct archive *reader)
{
    const int count = archive_filter_count(reader);
    for (int index = 0; index < count; ++index) {
        if (archive_filter_code(reader, index) != ARCHIVE_FILTER_NONE)
            return true;
    }
    return false;
}

QDBusInterface tumbler()
{
    return QDBusInterface("org.freedesktop.thumbnails.Thumbnailer1", "/org/freedesktop/thumbnails/Thumbnailer1",
                          "org.freedesktop.thumbnails.Thumbnailer1", QDBusConnection::sessionBus());
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
    LocalPath::Error pathError;
    const QString path = LocalPath::parse(params.value("path"), &pathError);
    if (pathError != LocalPath::Error::None) { *error = "path must be an absolute local path"; return {}; }
    const QFileInfo info(path);
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

void PreviewService::thumbnails(int requestId, const QJsonObject &params, QThreadPool &readPool,
                                const CancellationToken &token,
                                std::function<void(QJsonObject)> completed)
{
    const QString flavor = params.value("flavor").toString("normal");
    const QSet<QString> flavors{"normal", "large", "x-large", "xx-large"};
    if (!flavors.contains(flavor)) { completed(failure("Unsupported thumbnail flavor")); return; }
    const QJsonArray requested = params.value("items").toArray();
    if (requested.size() > 64) { completed(failure("thumbnail batches are limited to 64 items")); return; }

    QJsonArray items;
    QList<ThumbnailSource> sources;
    filesailLog(LogLevel::Debug, "preview",
                QStringLiteral("thumbnailBatch flavor=%1 count=%2").arg(flavor).arg(requested.size()));
    QMimeDatabase mimeDatabase;
    for (const QJsonValue &value : requested) {
        if (cancellationRequested(token)) { completed({}); return; }
        const QJsonObject input = value.toObject();
        QString error;
        const QString path = localRegularFile(input, &error);
        QJsonObject item{{"path", input.value("path").toString()}};
        if (path.isEmpty()) {
            item.insert("status", "unsupported"); items.append(item); sources.append(ThumbnailSource{}); continue;
        }
        const QFileInfo info(path);
        const QString suppliedMime = input.value("mimeType").toString();
        const QString mime = suppliedMime.isEmpty()
            ? mimeDatabase.mimeTypeForFile(info, QMimeDatabase::MatchExtension).name() : suppliedMime;
        item.insert("fingerprint", fingerprint(info));
        item.insert("status", visualMime(mime) ? "queued" : "unsupported");
        items.append(item);
        sources.append(ThumbnailSource{path, QString::fromUtf8(QUrl::fromLocalFile(path).toEncoded()), mime});
    }
    m_readPool = &readPool;
    const quint64 generation = m_nextThumbnailGeneration++;
    m_thumbnailRequests.insert(requestId, ThumbnailRequest{
        requestId, generation, 0, flavor,
        params.value("priority").toString() == "foreground" ? "foreground" : "background",
        items, sources, token, std::move(completed), params.value("incremental").toBool(),
        false, false, 0, {}, {}});
    const QFuture<QJsonArray> future = QtConcurrent::run(&readPool, [items, sources, flavor, token] {
        QJsonArray inspected;
        for (qsizetype index = 0; index < items.size(); ++index) {
            if (cancellationRequested(token)) return QJsonArray{};
            QJsonObject item = items.at(index).toObject();
            if (item.value("status").toString() == "queued") {
                const QString cached = validatedThumbnail(sources.at(index).path, sources.at(index).uri,
                                                          item.value("fingerprint").toString(), flavor);
                if (!cached.isEmpty()) { item.insert("status", "ready"); item.insert("url", cached); }
            }
            inspected.append(item);
        }
        return inspected;
    });
    auto *watcher = new QFutureWatcher<QJsonArray>(this);
    connect(watcher, &QFutureWatcher<QJsonArray>::finished, this, [this, watcher, requestId, generation] {
        const QJsonArray inspected = watcher->result();
        watcher->deleteLater();
        auto iterator = m_thumbnailRequests.find(requestId);
        if (iterator == m_thumbnailRequests.end() || iterator->generation != generation) return;
        if (cancellationRequested(iterator->token)
            || (inspected.isEmpty() && !iterator->items.isEmpty())) {
            finishThumbnail(requestId);
            return;
        }
        iterator->items = inspected;
        QJsonArray initial;
        QStringList uris;
        QStringList mimeTypes;
        for (qsizetype index = 0; index < inspected.size(); ++index) {
            const QJsonObject item = inspected.at(index).toObject();
            if (item.value("status") == "ready") initial.append(item);
            else if (item.value("status") == "queued") {
                uris.append(iterator->sources.at(index).uri);
                mimeTypes.append(iterator->sources.at(index).mimeType);
            }
        }
        if (iterator->incremental && !initial.isEmpty() && !uris.isEmpty())
            emit eventReady({{"event", "thumbnailReady"}, {"requestId", requestId}, {"items", initial}});
        if (uris.isEmpty()) { finishThumbnail(requestId); return; }

        auto *queueWatcher = new QDBusPendingCallWatcher(tumbler().asyncCall(
            "Queue", uris, mimeTypes, iterator->flavor, iterator->priority, 0U), this);
        connect(queueWatcher, &QDBusPendingCallWatcher::finished, this, [this, queueWatcher, requestId, generation] {
            const QDBusPendingReply<uint> reply = *queueWatcher;
            queueWatcher->deleteLater();
            auto current = m_thumbnailRequests.find(requestId);
            if (current == m_thumbnailRequests.end() || current->generation != generation) return;
            if (!reply.isValid() || reply.value() == 0) {
                finishThumbnail(requestId);
                return;
            }
            current->tumblerHandle = reply.value();
            m_tumblerRequests.insert(current->tumblerHandle, requestId);
            if (cancellationRequested(current->token)) {
                tumbler().call("Dequeue", current->tumblerHandle);
                finishThumbnail(requestId);
                return;
            }
            const QStringList earlyUris = m_earlyTumblerReady.take(current->tumblerHandle);
            if (!earlyUris.isEmpty()) tumblerReady(current->tumblerHandle, earlyUris);
            if (m_earlyTumblerFinished.remove(current->tumblerHandle) > 0) {
                finishThumbnail(requestId);
                return;
            }
            QTimer::singleShot(15000, this, [this, requestId, generation] {
                const auto current = m_thumbnailRequests.find(requestId);
                if (current != m_thumbnailRequests.end() && current->generation == generation) {
                    if (current->tumblerHandle != 0) tumbler().call("Dequeue", current->tumblerHandle);
                    finishThumbnail(requestId);
                }
            });
        });
    });
    watcher->setFuture(future);
}

void PreviewService::cancelThumbnail(int requestId)
{
    const auto iterator = m_thumbnailRequests.find(requestId);
    if (iterator == m_thumbnailRequests.end()) return;
    if (iterator->tumblerHandle != 0) {
        tumbler().call("Dequeue", iterator->tumblerHandle);
        m_tumblerRequests.remove(iterator->tumblerHandle);
    }
    finishThumbnail(requestId);
}

void PreviewService::finishThumbnail(int requestId)
{
    const auto iterator = m_thumbnailRequests.find(requestId);
    if (iterator == m_thumbnailRequests.end()) return;
    if (iterator->tumblerHandle != 0) {
        m_tumblerRequests.remove(iterator->tumblerHandle);
        iterator->tumblerHandle = 0;
    }
    iterator->finished = true;
    if (iterator->pendingValidation > 0) return;
    if (!cancellationRequested(iterator->token) && !iterator->finalValidationStarted) {
        iterator->finalValidationStarted = true;
        QList<int> unresolved;
        for (int index = 0; index < iterator->items.size(); ++index)
            if (iterator->items.at(index).toObject().value("status") == "queued") unresolved.append(index);
        if (!unresolved.isEmpty()) {
            startThumbnailValidation(requestId, unresolved, false);
            return;
        }
    }
    const ThumbnailRequest request = iterator.value();
    m_thumbnailRequests.erase(iterator);
    if (cancellationRequested(request.token)) { request.completed({}); return; }
    QJsonArray items;
    for (const QJsonValue &value : request.items) {
        QJsonObject item = value.toObject();
        if (item.value("status") == "queued") item.insert("status", "unsupported");
        items.append(item);
    }
    request.completed({{"ok", true}, {"items", items}});
}

void PreviewService::tumblerReady(uint handle, const QStringList &uris)
{
    const int requestId = m_tumblerRequests.value(handle, -1);
    if (requestId < 0) {
        if (m_earlyTumblerReady.size() < 64) m_earlyTumblerReady.insert(handle, uris);
        return;
    }
    auto iterator = m_thumbnailRequests.find(requestId);
    if (iterator == m_thumbnailRequests.end()) return;
    QList<int> indices;
    for (int index = 0; index < iterator->items.size(); ++index) {
        const QJsonObject item = iterator->items.at(index).toObject();
        if (item.value("status") == "queued" && !iterator->published.contains(index)
            && !iterator->validating.contains(index)
            && uris.contains(iterator->sources.at(index).uri))
            indices.append(index);
    }
    if (!indices.isEmpty()) startThumbnailValidation(requestId, indices, true);
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
    if (requestId < 0) {
        if (m_earlyTumblerFinished.size() < 64) m_earlyTumblerFinished.insert(handle);
        return;
    }
    finishThumbnail(requestId);
}

void PreviewService::startThumbnailValidation(int requestId, const QList<int> &indices, bool publish)
{
    auto iterator = m_thumbnailRequests.find(requestId);
    if (iterator == m_thumbnailRequests.end()) return;
    for (const int index : indices) {
        if (iterator->validating.contains(index)) continue;
        iterator->validating.insert(index);
        ++iterator->pendingValidation;
        const ThumbnailSource source = iterator->sources.at(index);
        const QString expected = iterator->items.at(index).toObject().value("fingerprint").toString();
        const quint64 generation = iterator->generation;
        const QFuture<QString> future = QtConcurrent::run(m_readPool,
            [source, expected, flavor = iterator->flavor, token = iterator->token] {
            return cancellationRequested(token) ? QString()
                : validatedThumbnail(source.path, source.uri, expected, flavor);
        });
        auto *watcher = new QFutureWatcher<QString>(this);
        connect(watcher, &QFutureWatcher<QString>::finished, this,
                [this, watcher, requestId, generation, index, publish] {
            const QString url = watcher->result();
            watcher->deleteLater();
            auto current = m_thumbnailRequests.find(requestId);
            if (current == m_thumbnailRequests.end() || current->generation != generation) return;
            current->validating.remove(index);
            current->pendingValidation = std::max(0, current->pendingValidation - 1);
            if (!url.isEmpty() && !cancellationRequested(current->token)
                && current->items.at(index).toObject().value("status") == "queued") {
                QJsonObject item = current->items.at(index).toObject();
                item.insert("status", "ready");
                item.insert("url", url);
                current->items[index] = item;
                if (publish && current->incremental && !current->published.contains(index)) {
                    current->published.insert(index);
                    emit eventReady({{"event", "thumbnailReady"}, {"requestId", requestId},
                                     {"items", QJsonArray{item}}});
                }
            }
            if (current->finished) finishThumbnail(requestId);
        });
        watcher->setFuture(future);
    }
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
    // A literal U+FFFD is valid content. Track decoding errors separately, and
    // allow an incomplete trailing sequence only when the read was bounded.
    QStringDecoder decoder(QStringDecoder::Utf8,
                           moreBytes ? QStringDecoder::Flag::Default : QStringDecoder::Flag::Stateless);
    const QString decoded = decoder(bytes);
    if (decoder.hasError())
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
    bool skipTimedOut = false;
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
        QString displayName = name.left(32 * 1024);
        displayName.replace(QChar::Null, QChar(0xfffd));
        entries.append(QJsonObject{{"name", displayName}, {"type", kind},
            {"size", static_cast<double>(archive_entry_size(entry))}, {"encrypted", archive_entry_is_encrypted(entry) > 0}});
        if (!streamCompressed(reader)) {
            // The container seeks past entry data, so skipping is cheap.
            archive_read_data_skip(reader);
            continue;
        }
        // A compressed stream cannot seek: skipping an entry means
        // decompressing it. Read in blocks so cancellation and the listing
        // deadline are honored inside large entries.
        const void *block = nullptr;
        size_t blockSize = 0;
        la_int64_t blockOffset = 0;
        int status = ARCHIVE_OK;
        while ((status = archive_read_data_block(reader, &block, &blockSize, &blockOffset)) == ARCHIVE_OK
               || status == ARCHIVE_WARN) {
            if (cancellationRequested(token)) { archive_read_free(reader); return {}; }
            if (deadline.elapsed() >= 5000) { skipTimedOut = true; break; }
        }
        if (skipTimedOut || status < ARCHIVE_WARN) break;
    }
    if (skipTimedOut) {
        truncated = true;
    } else if (entries.size() == 250 && metadataBytes < 4 * 1024 * 1024 && deadline.elapsed() < 5000) {
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
