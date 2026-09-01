#pragma once

#include <QJsonObject>
#include <QString>

#include <vector>

// A deliberately small description of an entry already observed while listing
// a directory. The detector never follows a symlink or traverses arbitrary
// descendants.
struct FolderContextEntry {
    enum class Type { RegularFile, Directory, Other };

    QString name;
    Type type = Type::Other;
};

class FolderContextDetector
{
public:
    static QJsonObject detect(const QString &directoryPath,
                              const std::vector<FolderContextEntry> &entries);
};
