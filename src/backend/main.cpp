#include "backendserver.h"
#include "filesail_version.h"
#include "logging.h"

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
        filesailLog(LogLevel::Error, "backend",
                    QStringLiteral("Failed to connect backend protocol to stdin/stdout"));
        return 1;
    }
    filesailLog(LogLevel::Info, "backend",
                QStringLiteral("serving %1").arg(QStringLiteral(FILESAIL_VERSION)));
    return application.exec();
}
