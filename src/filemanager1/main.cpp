#include "filemanager1service.h"

#include <QCoreApplication>
#include <QDBusConnection>
#include <QDBusError>
#include <QDebug>

int main(int argc, char **argv)
{
    QCoreApplication application(argc, argv);
    application.setApplicationName(QStringLiteral("filesail-filemanager1"));

    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected()) {
        qCritical("FileSail FileManager1: cannot connect to the session bus: %s",
                  qPrintable(bus.lastError().message()));
        return 1;
    }
    if (!bus.registerService(QStringLiteral("org.freedesktop.FileManager1"))) {
        qCritical("FileSail FileManager1: cannot register service: %s",
                  qPrintable(bus.lastError().message()));
        return 1;
    }

    FileManager1Service service;
    if (!bus.registerObject(QStringLiteral("/org/freedesktop/FileManager1"), &service,
                            QDBusConnection::ExportAllSlots)) {
        qCritical("FileSail FileManager1: cannot register object: %s",
                  qPrintable(bus.lastError().message()));
        return 1;
    }
    return application.exec();
}
