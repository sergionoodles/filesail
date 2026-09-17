#include "localpath.h"

#include <QDir>
#include <QFile>
#include <QUrl>

namespace LocalPath {

bool isRepresentable(const QString &path)
{
    return QFile::decodeName(QFile::encodeName(path)) == path;
}

QString parse(const QString &raw, Error *error)
{
    const auto fail = [error](Error reason) {
        *error = reason;
        return QString();
    };
    if (raw.trimmed().isEmpty())
        return fail(Error::Missing);

    QString path = raw;
    if (raw.startsWith(QLatin1String("file:"), Qt::CaseInsensitive)) {
        const QUrl url(raw, QUrl::StrictMode);
        if (!url.isValid() || !url.isLocalFile()
            || (!url.host().isEmpty() && url.host() != QLatin1String("localhost"))
            || !url.userInfo().isEmpty() || !url.query().isEmpty()
            || !url.fragment().isEmpty())
            return fail(Error::NotLocal);
        path = url.toLocalFile();
    }
    if (path.isEmpty() || path.contains(QChar::Null) || !QDir::isAbsolutePath(path))
        return fail(Error::NotLocal);
    path = QDir::cleanPath(path);
    if (!isRepresentable(path))
        return fail(Error::Unrepresentable);
    *error = Error::None;
    return path;
}

QString parse(const QJsonValue &value, Error *error)
{
    if (!value.isString()) {
        *error = Error::Missing;
        return {};
    }
    return parse(value.toString(), error);
}

}
