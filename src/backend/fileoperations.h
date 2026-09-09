#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QString>

#include "cancellation.h"

#include <functional>

namespace FileOperations {

using ProgressCallback = std::function<void(const QJsonObject &)>;

QJsonObject listDirectory(const QJsonObject &params, const CancellationToken &token = {});
QJsonObject completeDirectories(const QJsonObject &params, const CancellationToken &token = {});
QJsonObject createDirectory(const QJsonObject &params);
QJsonObject renamePath(const QJsonObject &params);
QJsonObject trashPaths(const QJsonObject &params);
QJsonObject copyPaths(const QJsonObject &params, const CancellationToken &token = {},
                      const ProgressCallback &progress = {});
QJsonObject movePaths(const QJsonObject &params, const CancellationToken &token = {},
                      const ProgressCallback &progress = {});
QJsonObject setExecutable(const QJsonObject &params);
QJsonObject openPath(const QJsonObject &params);
QJsonObject openTerminal(const QJsonObject &params);

} // namespace FileOperations
