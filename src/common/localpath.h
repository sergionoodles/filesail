#pragma once

#include <QJsonValue>
#include <QString>

// Shared validation for absolute local paths received over FileSail's
// protocols. Accepts a plain absolute path or a local `file:` URL without
// userinfo, query, fragment, or a non-localhost authority.
namespace LocalPath {

enum class Error {
    None,
    Missing,        // Not a string, or empty/blank.
    NotLocal,       // Relative path, NUL byte, or rejected URL.
    Unrepresentable // Cannot round-trip through the local 8-bit encoding.
};

// Returns the cleaned absolute path, or an empty string with `error` set.
QString parse(const QString &raw, Error *error);
QString parse(const QJsonValue &value, Error *error);

bool isRepresentable(const QString &path);

}
