#include "logging.h"

#include <QByteArray>
#include <QtGlobal>
#include <cstdio>

namespace {
LogLevel levelFromEnv()
{
    const QByteArray raw = qgetenv("FILESAIL_LOG").toLower();
    if (raw == "debug")
        return LogLevel::Debug;
    if (raw == "warn" || raw == "warning")
        return LogLevel::Warn;
    if (raw == "error" || raw == "off" || raw == "silent")
        return LogLevel::Error;
    return LogLevel::Info;
}

const char *levelName(LogLevel level)
{
    switch (level) {
    case LogLevel::Debug:
        return "debug";
    case LogLevel::Info:
        return "info";
    case LogLevel::Warn:
        return "warn";
    case LogLevel::Error:
        return "error";
    }
    return "info";
}
}

void filesailLog(LogLevel level, const char *module, const QString &message)
{
    static const LogLevel configured = levelFromEnv();
    if (level > configured)
        return;

    const QByteArray line = (QStringLiteral("[filesail:") + QString::fromLatin1(module)
                             + QStringLiteral("][") + QString::fromLatin1(levelName(level))
                             + QStringLiteral("] ") + message + QChar('\n'))
                                .toUtf8();
    fwrite(line.constData(), 1, static_cast<size_t>(line.size()), stderr);
    fflush(stderr);
}
