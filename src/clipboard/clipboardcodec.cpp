#include "clipboardcodec.h"

#include <QDir>
#include <QFile>
#include <QSet>
#include <QUrl>

namespace FileSail::Clipboard {
namespace {

bool validUtf8(const QByteArray &bytes)
{
    const QString text = QString::fromUtf8(bytes.constData(), bytes.size());
    return !text.contains(QChar::ReplacementCharacter)
        && text.toUtf8() == bytes;
}

bool validPath(const QString &path)
{
    if (path.isEmpty() || path.contains(QChar::Null) || !QDir::isAbsolutePath(path)
        || path.toUtf8().size() > MaxPathBytes)
        return false;
    // QFile's conversion check is the same representability rule used by the
    // file manager's existing URI resolver. Clipboard import must not replace
    // an unrepresentable name with a lossy path.
    return QFile::decodeName(QFile::encodeName(path)) == path;
}

QStringList uniquePaths(const QStringList &paths)
{
    QStringList result;
    QSet<QString> seen;
    for (const QString &path : paths) {
        if (!seen.contains(path)) {
            seen.insert(path);
            result.append(path);
        }
    }
    return result;
}

DecodeResult failure(const QString &reason)
{
    return {false, {}, reason};
}

DecodeResult decodeLines(const QByteArray &bytes, bool allowMode, Mode defaultMode,
                         Mode *declaredMode = nullptr)
{
    if (bytes.isEmpty() || bytes.size() > MaxMimeBytes)
        return failure("clipboard MIME data is empty or too large");
    if (!validUtf8(bytes))
        return failure("clipboard MIME data is not valid UTF-8");

    QList<QByteArray> rawLines = bytes.split('\n');
    if (!rawLines.isEmpty() && rawLines.last().isEmpty())
        rawLines.removeLast();
    QStringList paths;
    Mode mode = defaultMode;
    bool sawPath = false;
    for (int i = 0; i < rawLines.size(); ++i) {
        QByteArray line = rawLines.at(i);
        if (line.endsWith('\r'))
            line.chop(1);
        if (line.isEmpty())
            return failure("clipboard URI list contains an empty entry");
        if (allowMode && i == 0 && (line == "copy" || line == "cut")) {
            mode = line == "cut" ? Mode::Cut : Mode::Copy;
            if (declaredMode)
                *declaredMode = mode;
            continue;
        }
        QUrl url = QUrl::fromEncoded(line, QUrl::StrictMode);
        if (!url.isValid() || url.scheme().compare("file", Qt::CaseInsensitive) != 0
            || !url.userInfo().isEmpty() || !url.query().isEmpty() || !url.fragment().isEmpty()
            || (!url.host().isEmpty() && url.host().compare("localhost", Qt::CaseInsensitive) != 0))
            return failure("clipboard contains a non-local or malformed file URI");
        const QString path = url.toLocalFile();
        if (!validPath(path))
            return failure("clipboard contains an invalid local path");
        paths.append(path);
        sawPath = true;
        if (paths.size() > MaxItems)
            return failure("clipboard contains too many paths");
    }
    if (!sawPath)
        return failure(allowMode ? "clipboard metadata has no file URIs" : "clipboard URI list has no files");
    return {true, {mode, uniquePaths(paths)}, {}};
}

}

QString modeName(Mode mode)
{
    return mode == Mode::Cut ? QStringLiteral("cut") : QStringLiteral("copy");
}

bool parseMode(const QString &value, Mode *mode)
{
    if (value == "copy") {
        if (mode)
            *mode = Mode::Copy;
        return true;
    }
    if (value == "cut") {
        if (mode)
            *mode = Mode::Cut;
        return true;
    }
    return false;
}

QByteArray encodeUriList(const QStringList &paths)
{
    QByteArray result;
    for (const QString &path : paths) {
        if (!result.isEmpty())
            result.append('\n');
        result.append(QUrl::fromLocalFile(path).toEncoded(QUrl::FullyEncoded));
    }
    result.append('\n');
    return result;
}

QByteArray encodeGnome(const Payload &payload)
{
    QByteArray result = modeName(payload.mode).toUtf8();
    result.append('\n');
    result.append(encodeUriList(payload.paths));
    return result;
}

DecodeResult decodeUriList(const QByteArray &bytes)
{
    return decodeLines(bytes, false, Mode::Copy);
}

DecodeResult decodeGnome(const QByteArray &bytes)
{
    if (bytes.size() > MaxMimeBytes || bytes.isEmpty())
        return failure("clipboard GNOME metadata is empty or too large");
    const int newline = bytes.indexOf('\n');
    if (newline <= 0)
        return failure("clipboard GNOME metadata has no operation line");
    QByteArray operation = bytes.left(newline);
    if (operation.endsWith('\r'))
        operation.chop(1);
    Mode mode;
    if (!parseMode(QString::fromUtf8(operation), &mode))
        return failure("clipboard GNOME metadata has an unknown operation");
    Mode declared = mode;
    return decodeLines(bytes.mid(newline + 1), false, mode, &declared);
}

DecodeResult decodeOffers(const QByteArray *uriList, const QByteArray *gnome)
{
    if (!uriList && !gnome)
        return failure("clipboard has no supported file representation");

    DecodeResult uri;
    DecodeResult metadata;
    if (uriList)
        uri = decodeUriList(*uriList);
    if (gnome)
        metadata = decodeGnome(*gnome);
    if (gnome && !metadata.ok)
        return metadata;
    if (uriList && !uri.ok)
        return uri;
    if (gnome && uriList && metadata.payload.paths != uri.payload.paths)
        return failure("clipboard file representations disagree");
    return gnome ? metadata : uri;
}

}
