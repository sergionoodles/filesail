#pragma once

#include <QString>

enum class LogLevel {
    Error = 0,
    Warn = 1,
    Info = 2,
    Debug = 3,
};

void filesailLog(LogLevel level, const char *module, const QString &message);
