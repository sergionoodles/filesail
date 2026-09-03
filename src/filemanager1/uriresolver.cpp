#include "uriresolver.h"

#include <QDir>
#include <QUrl>

namespace FileManager1 {

QString localPath(const QString &raw)
{
    if (raw.isEmpty() || raw.contains(QChar::Null) || raw.size() > 4096)
        return {};

    if (raw.startsWith("file:", Qt::CaseInsensitive)) {
        const QUrl url(raw, QUrl::StrictMode);
        if (!url.isValid() || !url.isLocalFile() || !url.query().isEmpty()
            || !url.fragment().isEmpty())
            return {};
        const QString path = url.toLocalFile();
        return QDir::isAbsolutePath(path) ? QDir::cleanPath(path) : QString{};
    }

    if (!QDir::isAbsolutePath(raw) || raw.contains("://"))
        return {};
    return QDir::cleanPath(raw);
}

}
