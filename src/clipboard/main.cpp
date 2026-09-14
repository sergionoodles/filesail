#include "clipboardbridge.h"

#include <QCoreApplication>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QSocketNotifier>

#include <cerrno>
#include <fcntl.h>
#include <unistd.h>

using namespace FileSail::Clipboard;

namespace {

class ClipboardProtocol final : public QObject {
public:
    explicit ClipboardProtocol(QObject *parent = nullptr)
        : QObject(parent), m_inNotifier(new QSocketNotifier(STDIN_FILENO, QSocketNotifier::Read, this)),
          m_outNotifier(new QSocketNotifier(STDOUT_FILENO, QSocketNotifier::Write, this)),
          m_bridge(new ClipboardBridge(this))
    {
        const int flags = ::fcntl(STDOUT_FILENO, F_GETFL, 0);
        if (flags >= 0)
            ::fcntl(STDOUT_FILENO, F_SETFL, flags | O_NONBLOCK);
        const int inputFlags = ::fcntl(STDIN_FILENO, F_GETFL, 0);
        if (inputFlags >= 0)
            ::fcntl(STDIN_FILENO, F_SETFL, inputFlags | O_NONBLOCK);
        m_outNotifier->setEnabled(false);
        connect(m_inNotifier, &QSocketNotifier::activated, this, [this] { readInput(); });
        connect(m_outNotifier, &QSocketNotifier::activated, this, [this] { flushOutput(); });
        connect(m_bridge, &ClipboardBridge::capabilitiesChanged, this,
                [this](const QJsonObject &value) { emitEvent("capabilities", value); });
        connect(m_bridge, &ClipboardBridge::snapshotChanged, this,
                [this](const QJsonObject &value) { emitEvent("changed", value); });
        connect(m_bridge, &ClipboardBridge::protocolError, this,
                [this](const QString &reason) { emitEvent("error", QJsonObject{{"reason", reason}}); });
        m_bridge->start();
    }

private:
    void emitEvent(const char *event, QJsonObject value)
    {
        value.insert("protocol", "filesail.clipboard.v1");
        value.insert("version", 1);
        value.insert("event", event);
        write(QJsonDocument(value).toJson(QJsonDocument::Compact) + '\n');
    }

    void writeResponse(int id, bool ok, QJsonObject value = {})
    {
        value.insert("protocol", "filesail.clipboard.v1");
        value.insert("version", 1);
        value.insert("id", id);
        value.insert("ok", ok);
        write(QJsonDocument(value).toJson(QJsonDocument::Compact) + '\n');
    }

    void write(const QByteArray &line)
    {
        if (line.size() > FileSail::Clipboard::MaxFrameBytes) {
            QCoreApplication::quit();
            return;
        }
        m_output.append(line);
        flushOutput();
    }

    void flushOutput()
    {
        while (!m_output.isEmpty()) {
            const ssize_t written = ::write(STDOUT_FILENO, m_output.constData(),
                                            static_cast<size_t>(m_output.size()));
            if (written > 0) {
                m_output.remove(0, static_cast<qsizetype>(written));
                continue;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                m_outNotifier->setEnabled(true);
                return;
            }
            QCoreApplication::quit();
            return;
        }
        m_outNotifier->setEnabled(false);
    }

    void readInput()
    {
        char buffer[8192];
        while (true) {
            const ssize_t count = ::read(STDIN_FILENO, buffer, sizeof(buffer));
            if (count > 0) {
                m_input.append(buffer, static_cast<qsizetype>(count));
                if (m_input.size() > FileSail::Clipboard::MaxFrameBytes * 2) {
                    writeResponse(-1, false, {{"error", "clipboard protocol input is too large"}});
                    QCoreApplication::quit();
                    return;
                }
                consumeLines();
                continue;
            }
            if (count == 0) {
                m_inNotifier->setEnabled(false);
                QCoreApplication::quit();
                return;
            }
            if (errno == EAGAIN || errno == EWOULDBLOCK)
                return;
            QCoreApplication::quit();
            return;
        }
    }

    void consumeLines()
    {
        while (true) {
            const qsizetype end = m_input.indexOf('\n');
            if (end < 0)
                return;
            const QByteArray line = m_input.left(end);
            m_input.remove(0, end + 1);
            if (line.size() > FileSail::Clipboard::MaxFrameBytes) {
                writeResponse(-1, false, {{"error", "clipboard protocol frame is too large"}});
                continue;
            }
            QJsonParseError parseError;
            const QJsonDocument document = QJsonDocument::fromJson(line, &parseError);
            if (parseError.error != QJsonParseError::NoError || !document.isObject()) {
                writeResponse(-1, false, {{"error", "invalid clipboard protocol JSON"}});
                continue;
            }
            handle(document.object());
        }
    }

    void handle(const QJsonObject &request)
    {
        const int id = request.value("id").toInt(-1);
        const QString method = request.value("method").toString();
        const QJsonObject params = request.value("params").toObject();
        if (id < 0 || method.isEmpty()) {
            writeResponse(id, false, {{"error", "request id and method are required"}});
            return;
        }
        if (request.contains("protocol")
                && (request.value("protocol").toString() != "filesail.clipboard.v1"
                    || request.value("version").toInt() != 1)) {
            writeResponse(id, false, {{"error", "unsupported clipboard protocol"}});
            return;
        }
        if (method == "capabilities") {
            writeResponse(id, true, m_bridge->capabilities());
            return;
        }
        if (method == "snapshot") {
            writeResponse(id, true, m_bridge->snapshot());
            return;
        }
        if (method == "writeFiles") {
            const QJsonArray input = params.value("paths").toArray();
            QStringList paths;
            for (const QJsonValue &value : input)
                paths.append(value.toString());
            Mode mode;
            if (!parseMode(params.value("mode").toString(), &mode)) {
                writeResponse(id, false, {{"error", "clipboard mode must be copy or cut"}});
                return;
            }
            QString reason;
            if (!m_bridge->writeFiles(paths, mode, &reason))
                writeResponse(id, false, {{"error", reason}});
            else
                writeResponse(id, true, m_bridge->snapshot());
            return;
        }
        if (method == "replaceIfCurrent") {
            const bool clear = params.value("clear").toBool(false);
            const QJsonArray input = params.value("paths").toArray();
            QStringList paths;
            for (const QJsonValue &value : input)
                paths.append(value.toString());
            Mode mode;
            if (!parseMode(params.value("mode").toString("copy"), &mode)) {
                writeResponse(id, false, {{"error", "clipboard mode must be copy or cut"}});
                return;
            }
            QString reason;
            if (!m_bridge->replaceIfCurrent(params.value("expectedOfferToken").toString(),
                                            paths, mode, clear, &reason))
                writeResponse(id, false, {{"error", reason}});
            else
                writeResponse(id, true, m_bridge->snapshot());
            return;
        }
        if (method == "quit") {
            writeResponse(id, true);
            QCoreApplication::quit();
            return;
        }
        writeResponse(id, false, {{"error", "unknown clipboard method"}});
    }

    QSocketNotifier *m_inNotifier;
    QSocketNotifier *m_outNotifier;
    ClipboardBridge *m_bridge;
    QByteArray m_input;
    QByteArray m_output;
};

}

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    if (argc != 2 || QString::fromLocal8Bit(argv[1]) != "--serve")
        return 2;
    ClipboardProtocol protocol;
    return app.exec();
}
