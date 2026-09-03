#pragma once

#include <QObject>
#include <QStringList>

class FileManager1Service final : public QObject {
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.FileManager1")

public:
    explicit FileManager1Service(QObject *parent = nullptr);

public slots:
    void ShowFolders(const QStringList &uris, const QString &startupId);
    void ShowItems(const QStringList &uris, const QString &startupId);
    void ShowItemProperties(const QStringList &uris, const QString &startupId);

private:
    void showFolders(const QStringList &paths);
    void showItems(const QStringList &paths);
    bool launch(const QString &directory, const QStringList &selection = {});
    QString launcher() const;
};
