#pragma once

#include <QJsonArray>
#include <QJsonObject>
#include <QString>

#include "cancellation.h"

namespace FileOperations {

QJsonObject listDirectory(const QJsonObject &params, const CancellationToken &token = {});
QJsonObject completeDirectories(const QJsonObject &params, const CancellationToken &token = {});
QJsonObject createDirectory(const QJsonObject &params);
QJsonObject renamePath(const QJsonObject &params);
QJsonObject trashPaths(const QJsonObject &params);
QJsonObject copyPaths(const QJsonObject &params);
QJsonObject movePaths(const QJsonObject &params);
QJsonObject setExecutable(const QJsonObject &params);
QJsonObject openPath(const QJsonObject &params);
QJsonObject openTerminal(const QJsonObject &params);

} // namespace FileOperations
