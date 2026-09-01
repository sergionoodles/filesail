#include "backendserver.h"
#include "filesail_version.h"

#include <QCoreApplication>
#include <QTextStream>

int main(int argc, char *argv[])
{
    QCoreApplication application(argc, argv);
    application.setApplicationName("filesail-backend");
    application.setApplicationVersion(QStringLiteral(FILESAIL_VERSION));

    if (!application.arguments().contains("--serve")) {
        QTextStream(stderr) << "Usage: filesail-backend --serve\n";
        return 2;
    }

    BackendServer server;
    if (!server.start()) {
        QTextStream(stderr) << "Failed to connect backend protocol to stdin/stdout\n";
        return 1;
    }
    return application.exec();
}
