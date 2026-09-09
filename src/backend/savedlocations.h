#pragma once

#include <QJsonObject>

namespace SavedLocations {

QJsonObject list();
QJsonObject add(const QJsonObject &params);
QJsonObject remove(const QJsonObject &params);
QString configDirectoryPath();

} // namespace SavedLocations
