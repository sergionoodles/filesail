#include "uriresolver.h"

#include "localpath.h"

namespace FileManager1 {

QString localPath(const QString &raw)
{
    if (raw.size() > 4096)
        return {};
    // Plain paths that look like another scheme's URI are never local files.
    if (!raw.startsWith(QLatin1String("file:"), Qt::CaseInsensitive) && raw.contains(QLatin1String("://")))
        return {};
    LocalPath::Error error;
    return LocalPath::parse(raw, &error);
}

}
