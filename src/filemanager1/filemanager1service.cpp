#include "filemanager1service.h"

#include "uriresolver.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QMap>
#include <QProcess>
#include <QStandardPaths>

namespace {

QStringList resolve(const QStringList &uris)
{
    QStringList paths;
    for (const QString &uri : uris) {
        const QString path = FileManager1::localPath(uri);
        if (path.isEmpty())
            qWarning("FileSail FileManager1: ignoring non-local URI: %s", qPrintable(uri));
        else
            paths.append(path);
    }
    return paths;
}

}

FileManager1Service::FileManager1Service(QObject *parent)
    : QObject(parent)
{
}

void FileManager1Service::ShowFolders(const QStringList &uris, const QString &startupId)
{
    Q_UNUSED(startupId)
    showFolders(resolve(uris));
}

void FileManager1Service::ShowItems(const QStringList &uris, const QString &startupId)
{
    Q_UNUSED(startupId)
    showItems(resolve(uris));
}

void FileManager1Service::ShowItemProperties(const QStringList &uris, const QString &startupId)
{
    Q_UNUSED(startupId)
    qWarning("FileSail FileManager1: ShowItemProperties is not implemented");
    Q_UNUSED(uris)
}

void FileManager1Service::showFolders(const QStringList &paths)
{
    for (const QString &path : paths) {
        if (QFileInfo(path).exists() && !QFileInfo(path).isDir()) {
            qWarning("FileSail FileManager1: ignoring non-directory folder: %s", qPrintable(path));
            continue;
        }
        launch(path);
    }
}

void FileManager1Service::showItems(const QStringList &paths)
{
    QMap<QString, QStringList> grouped;
    for (const QString &path : paths) {
        const QFileInfo info(path);
        if (info.exists() && info.isDir()) {
            if (path == "/")
                grouped[path];
            else
                grouped[info.absolutePath()].append(path);
        } else {
            grouped[info.absolutePath()].append(path);
        }
    }
    for (auto it = grouped.cbegin(); it != grouped.cend(); ++it)
        launch(it.key(), it.value());
}

bool FileManager1Service::launch(const QString &directory, const QStringList &selection)
{
    QStringList arguments{"--path", directory};
    if (!selection.isEmpty()) {
        QJsonArray selected;
        for (const QString &path : selection)
            selected.append(path);
        arguments << "--select-json"
                  << QString::fromUtf8(QJsonDocument(selected).toJson(QJsonDocument::Compact));
    }
    const bool started = QProcess::startDetached(launcher(), arguments);
    if (!started)
        qWarning("FileSail FileManager1: could not start filesail");
    return started;
}

QString FileManager1Service::launcher() const
{
    const QString path = QStandardPaths::findExecutable(QStringLiteral("filesail"));
    return path.isEmpty() ? QStringLiteral("/usr/bin/filesail") : path;
}
