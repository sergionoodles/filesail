#include "uriresolver.h"

#include <QDir>
#include <QFile>
#include <QUrl>

namespace FileManager1 {

QString localPath(const QString &raw)
{
    if (raw.isEmpty() || raw.contains(QChar::Null) || raw.size() > 4096)
        return {};

    if (raw.startsWith("file:", Qt::CaseInsensitive)) {
        const QUrl url(raw, QUrl::StrictMode);
        if (!url.isValid() || !url.isLocalFile()
            || (!url.host().isEmpty() && url.host() != "localhost")
            || !url.userInfo().isEmpty() || !url.query().isEmpty() || !url.fragment().isEmpty())
            return {};
        const QString path = url.toLocalFile();
        if (path.isEmpty() || path.contains(QChar::Null) || !QDir::isAbsolutePath(path)
            || QFile::decodeName(QFile::encodeName(path)) != path)
            return {};
        return QDir::cleanPath(path);
    }

    if (!QDir::isAbsolutePath(raw) || raw.contains("://")
        || QFile::decodeName(QFile::encodeName(raw)) != raw)
        return {};
    return QDir::cleanPath(raw);
}

}
