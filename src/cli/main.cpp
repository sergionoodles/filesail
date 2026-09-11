#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QHash>
#include <QProcess>
#include <QSet>
#include <QStandardPaths>
#include <QTextStream>
#include <QThread>
#include <QUuid>

#include <optional>

namespace {
constexpr auto controlTarget = "filesail.control.v1";

struct ProcessResult {
    int exitCode = -1;
    QByteArray output;
    QByteArray error;
    bool timedOut = false;
};

struct Host {
    QString instanceId;
    QJsonObject description;
};

ProcessResult runProcess(const QString &program, const QStringList &arguments, int timeoutMs = 5000)
{
    QProcess process;
    process.setProgram(program);
    process.setArguments(arguments);
    process.start();
    if (!process.waitForStarted(timeoutMs))
        return {-1, {}, process.errorString().toUtf8(), false};
    if (!process.waitForFinished(timeoutMs)) {
        process.kill();
        process.waitForFinished();
        return {-1, process.readAllStandardOutput(), process.readAllStandardError(), true};
    }
    QByteArray output = process.readAllStandardOutput();
    QByteArray error = process.readAllStandardError();
    constexpr qsizetype maximumTransportOutput = 2 * 1024 * 1024;
    if (output.size() > maximumTransportOutput || error.size() > maximumTransportOutput)
        return {-1, {}, QByteArrayLiteral("Quickshell output exceeded the 2 MiB client limit"), false};
    return {process.exitCode(), std::move(output), std::move(error), false};
}

std::optional<QJsonObject> parseObject(const QByteArray &bytes)
{
    QJsonParseError error;
    const QJsonDocument document = QJsonDocument::fromJson(bytes.trimmed(), &error);
    if (error.error != QJsonParseError::NoError || !document.isObject())
        return std::nullopt;
    return document.object();
}

QString instanceId(const QJsonObject &object)
{
    for (const auto *key : {"id", "instanceId", "instance", "instance_id"}) {
        const QString value = object.value(QLatin1String(key)).toString();
        if (!value.isEmpty())
            return value;
    }
    return {};
}

QJsonArray instanceArray(const QJsonDocument &document)
{
    if (document.isArray())
        return document.array();
    const QJsonObject root = document.object();
    for (const auto *key : {"instances", "data", "rows"}) {
        if (root.value(QLatin1String(key)).isArray())
            return root.value(QLatin1String(key)).toArray();
    }
    return {};
}

class Transport {
public:
    Transport()
    {
        m_qs = qEnvironmentVariable("FILESAIL_QS");
        if (m_qs.isEmpty())
            m_qs = QStandardPaths::findExecutable(QStringLiteral("qs"));
        if (m_qs.isEmpty())
            m_qs = QStandardPaths::findExecutable(QStringLiteral("quickshell"));
    }

    bool available() const { return !m_qs.isEmpty(); }

    std::optional<QJsonObject> call(const QString &id, const QString &function,
                                    const QStringList &arguments, int timeoutMs,
                                    QString *diagnostic = nullptr) const
    {
        QStringList command{QStringLiteral("ipc"), QStringLiteral("--id"), id,
                            QStringLiteral("call"),
                            QString::fromLatin1(controlTarget), function};
        command.append(arguments);
        const ProcessResult result = runProcess(m_qs, command, timeoutMs);
        if (result.exitCode != 0 || result.timedOut) {
            if (diagnostic)
                *diagnostic = result.timedOut ? QStringLiteral("Quickshell IPC timed out")
                    : QString::fromUtf8(result.error).trimmed();
            return std::nullopt;
        }
        const auto object = parseObject(result.output);
        if (!object && diagnostic)
            *diagnostic = QStringLiteral("Quickshell IPC returned malformed JSON");
        return object;
    }

    QList<Host> discover(QString *diagnostic = nullptr) const
    {
        QList<Host> hosts;
        if (!available()) {
            if (diagnostic) *diagnostic = QStringLiteral("Quickshell executable was not found");
            return hosts;
        }
        const ProcessResult listed = runProcess(m_qs,
            {QStringLiteral("list"), QStringLiteral("--all"), QStringLiteral("--json")}, 3000);
        QJsonParseError parseError;
        const QJsonDocument document = QJsonDocument::fromJson(listed.output, &parseError);
        if (parseError.error != QJsonParseError::NoError) {
            // Quickshell 0.3 prints a human message when no instances exist.
            if (listed.exitCode != 0 && diagnostic)
                *diagnostic = QString::fromUtf8(listed.error).trimmed();
            return hosts;
        }
        for (const QJsonValue &value : instanceArray(document)) {
            const QJsonObject candidate = value.toObject();
            const QString id = instanceId(candidate);
            if (id.isEmpty())
                continue;
            const auto description = call(id, QStringLiteral("describe"), {}, 1500);
            if (description && description->value(QStringLiteral("ok")).toBool()
                    && description->value(QStringLiteral("protocol")).toString()
                        == QLatin1String(controlTarget))
                hosts.push_back({id, *description});
        }
        return hosts;
    }

private:
    QString m_qs;
};

int printJson(const QJsonObject &object, bool forceFailure = false)
{
    QTextStream(stdout) << QJsonDocument(object).toJson(QJsonDocument::Compact) << Qt::endl;
    return forceFailure || !object.value(QStringLiteral("ok")).toBool() ? 1 : 0;
}

int usage(const QString &message = {})
{
    if (!message.isEmpty())
        QTextStream(stderr) << "filesail-cli: " << message << '\n';
    QTextStream(stderr)
        << "Usage: filesail-cli [--window ID] [--host ID] [--timeout MS] [--no-wait] COMMAND\n"
        << "Commands:\n"
        << "  windows list|ensure|create [--location LOCATION]\n"
        << "  state | capabilities | entries [--limit N] [--cursor CURSOR]\n"
        << "  navigate --location LOCATION | back | forward | up | refresh\n"
        << "  select --path PATH [--mode replace|add|remove] [--primary PATH]\n"
        << "  clear-selection | preview show|hide | events [--since N] [--limit N]\n"
        << "  filter --value TEXT | hidden show|hide | view-mode list|grid\n"
        << "  sort --field name|size|modified [--descending] [--folders-first BOOL]\n"
        << "  result REQUEST_ID\n";
    return 2;
}

QString takeOption(QStringList &arguments, const QString &name, bool *found = nullptr)
{
    for (qsizetype i = 0; i < arguments.size(); ++i) {
        if (arguments[i] == name) {
            if (i + 1 >= arguments.size())
                return {};
            const QString value = arguments.takeAt(i + 1);
            arguments.removeAt(i);
            if (found) *found = true;
            return value;
        }
        if (arguments[i].startsWith(name + QLatin1Char('='))) {
            const QString value = arguments.takeAt(i).mid(name.size() + 1);
            if (found) *found = true;
            return value;
        }
    }
    if (found) *found = false;
    return {};
}

bool takeFlag(QStringList &arguments, const QString &name)
{
    const qsizetype index = arguments.indexOf(name);
    if (index < 0)
        return false;
    arguments.removeAt(index);
    return true;
}

QJsonObject failure(const QString &code, const QString &message, const QJsonObject &extra = {})
{
    QJsonObject result{{QStringLiteral("version"), 1}, {QStringLiteral("ok"), false},
                       {QStringLiteral("code"), code}, {QStringLiteral("message"), message}};
    for (auto it = extra.begin(); it != extra.end(); ++it)
        result.insert(it.key(), it.value());
    return result;
}

QString localLocation(const QString &location)
{
    if (location.startsWith(QLatin1Char('/')))
        return location;
    const QString key = location.toLower();
    const QHash<QString, QStandardPaths::StandardLocation> locations{
        {QStringLiteral("home"), QStandardPaths::HomeLocation},
        {QStringLiteral("desktop"), QStandardPaths::DesktopLocation},
        {QStringLiteral("documents"), QStandardPaths::DocumentsLocation},
        {QStringLiteral("downloads"), QStandardPaths::DownloadLocation},
        {QStringLiteral("music"), QStandardPaths::MusicLocation},
        {QStringLiteral("pictures"), QStandardPaths::PicturesLocation},
        {QStringLiteral("videos"), QStandardPaths::MoviesLocation},
        {QStringLiteral("templates"), QStandardPaths::TemplatesLocation},
        {QStringLiteral("publicshare"), QStandardPaths::PublicShareLocation},
    };
    if (key == QLatin1String("trash"))
        return QDir(QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation))
            .filePath(QStringLiteral("Trash/files"));
    return locations.contains(key) ? QStandardPaths::writableLocation(locations.value(key)) : QString{};
}

QList<Host> filterHosts(const QList<Host> &hosts, const QString &selector)
{
    if (selector.isEmpty())
        return hosts;
    QList<Host> filtered;
    for (const Host &host : hosts) {
        const QString generation = host.description.value(QStringLiteral("hostGeneration")).toString();
        const QString kind = host.description.value(QStringLiteral("hostKind")).toString();
        if (host.instanceId == selector || generation == selector || kind == selector
                || host.instanceId.startsWith(selector) || generation.startsWith(selector))
            filtered.push_back(host);
    }
    return filtered;
}

struct Target {
    Host host;
    QJsonObject window;
};

QList<Target> targets(const QList<Host> &hosts, const QString &windowId)
{
    QList<Target> result;
    for (const Host &host : hosts) {
        for (const QJsonValue &value : host.description.value(QStringLiteral("windows")).toArray()) {
            const QJsonObject window = value.toObject();
            if (windowId.isEmpty() || window.value(QStringLiteral("window")).toString() == windowId)
                result.push_back({host, window});
        }
    }
    return result;
}

QJsonObject targetChoices(const QList<Target> &matches)
{
    QJsonArray choices;
    for (const Target &target : matches) {
        QJsonObject choice = target.window;
        choice.insert(QStringLiteral("hostGeneration"),
                      target.host.description.value(QStringLiteral("hostGeneration")));
        choice.insert(QStringLiteral("instanceId"), target.host.instanceId);
        choices.push_back(choice);
    }
    return failure(QStringLiteral("ambiguous_target"),
                   QStringLiteral("More than one eligible FileSail window is available"),
                   {{QStringLiteral("choices"), choices}});
}

QString newRequestId()
{
    return QStringLiteral("cli-%1").arg(QUuid::createUuid().toString(QUuid::WithoutBraces));
}

QJsonObject submit(const Transport &transport, const Target &target, const QString &method,
                   const QJsonObject &params, const QString &requestId, int expectedRevision,
                   bool wait, int timeoutMs)
{
    QJsonObject envelope{{QStringLiteral("version"), 1},
                         {QStringLiteral("requestId"), requestId},
                         {QStringLiteral("window"), target.window.value(QStringLiteral("window"))},
                         {QStringLiteral("method"), method}, {QStringLiteral("params"), params}};
    if (expectedRevision >= 0)
        envelope.insert(QStringLiteral("expectedRevision"), expectedRevision);
    QString diagnostic;
    auto response = transport.call(target.host.instanceId, QStringLiteral("submit"),
        {QString::fromUtf8(QJsonDocument(envelope).toJson(QJsonDocument::Compact))}, 5000, &diagnostic);
    if (!response)
        return failure(QStringLiteral("host_disconnected"), diagnostic,
                       {{QStringLiteral("requestId"), requestId}});
    if (!wait || response->value(QStringLiteral("status")).toString() != QLatin1String("pending"))
        return *response;

    const qint64 deadline = QDateTime::currentMSecsSinceEpoch() + timeoutMs;
    while (QDateTime::currentMSecsSinceEpoch() < deadline) {
        QThread::msleep(50);
        response = transport.call(target.host.instanceId, QStringLiteral("result"), {requestId}, 3000, &diagnostic);
        if (!response)
            return failure(QStringLiteral("host_disconnected"), diagnostic,
                           {{QStringLiteral("requestId"), requestId}});
        if (response->value(QStringLiteral("status")).toString() != QLatin1String("pending"))
            return *response;
    }
    return failure(QStringLiteral("timeout"),
                   QStringLiteral("The command may still be pending; query its request ID"),
                   {{QStringLiteral("requestId"), requestId},
                    {QStringLiteral("status"), QStringLiteral("pending")}});
}

QJsonObject submitCreate(const Transport &transport, const Host &host, const QString &location,
                         const QString &requestId, bool wait, int timeoutMs)
{
    QJsonObject envelope{{QStringLiteral("version"), 1},
                         {QStringLiteral("requestId"), requestId},
                         {QStringLiteral("method"), QStringLiteral("windows.create")},
                         {QStringLiteral("params"), QJsonObject{{QStringLiteral("location"), location}}}};
    QString diagnostic;
    auto response = transport.call(host.instanceId, QStringLiteral("submit"),
        {QString::fromUtf8(QJsonDocument(envelope).toJson(QJsonDocument::Compact))}, 5000, &diagnostic);
    if (!response)
        return failure(QStringLiteral("host_disconnected"), diagnostic,
                       {{QStringLiteral("requestId"), requestId}});
    if (!wait || response->value(QStringLiteral("status")).toString() != QLatin1String("pending"))
        return *response;
    const qint64 deadline = QDateTime::currentMSecsSinceEpoch() + timeoutMs;
    while (QDateTime::currentMSecsSinceEpoch() < deadline) {
        QThread::msleep(50);
        response = transport.call(host.instanceId, QStringLiteral("result"), {requestId}, 3000, &diagnostic);
        if (!response)
            return failure(QStringLiteral("host_disconnected"), diagnostic,
                           {{QStringLiteral("requestId"), requestId}});
        if (response->value(QStringLiteral("status")).toString() != QLatin1String("pending"))
            return *response;
    }
    return failure(QStringLiteral("timeout"), QStringLiteral("Window creation may still be pending"),
                   {{QStringLiteral("requestId"), requestId},
                    {QStringLiteral("status"), QStringLiteral("pending")}});
}

std::optional<QJsonObject> launchWindow(const Transport &transport, const QString &location,
                                        int timeoutMs, const QSet<QString> &oldIds, bool ensure)
{
    const QString path = localLocation(location);
    if (path.isEmpty() || !QFileInfo(path).isDir())
        return failure(QStringLiteral("invalid_path"), QStringLiteral("Unknown or unavailable location: %1").arg(location));
    QString launcher = qEnvironmentVariable("FILESAIL_LAUNCHER");
    if (launcher.isEmpty()) {
        const QString sibling = QDir(QCoreApplication::applicationDirPath()).filePath(QStringLiteral("filesail"));
        launcher = QFileInfo(sibling).isExecutable() ? sibling : QStandardPaths::findExecutable(QStringLiteral("filesail"));
    }
    if (launcher.isEmpty())
        return failure(QStringLiteral("launch_failed"), QStringLiteral("The filesail launcher was not found"));
    QStringList launcherArguments{QStringLiteral("--path"), path};
    if (ensure)
        launcherArguments.prepend(QStringLiteral("--ensure-window"));
    if (!QProcess::startDetached(launcher, launcherArguments))
        return failure(QStringLiteral("launch_failed"), QStringLiteral("Could not start FileSail"));

    const qint64 deadline = QDateTime::currentMSecsSinceEpoch() + timeoutMs;
    while (QDateTime::currentMSecsSinceEpoch() < deadline) {
        QThread::msleep(75);
        for (const Host &host : transport.discover()) {
            for (const QJsonValue &value : host.description.value(QStringLiteral("windows")).toArray()) {
                const QJsonObject window = value.toObject();
                const QString id = window.value(QStringLiteral("window")).toString();
                if (!oldIds.contains(id) && window.value(QStringLiteral("ready")).toBool())
                    return QJsonObject{{QStringLiteral("version"), 1}, {QStringLiteral("ok"), true},
                        {QStringLiteral("status"), QStringLiteral("succeeded")},
                        {QStringLiteral("window"), id}, {QStringLiteral("data"), QJsonObject{{QStringLiteral("state"), window}}}};
            }
        }
    }
    return failure(QStringLiteral("timeout"), QStringLiteral("FileSail did not publish a ready window before the deadline"));
}
}

int main(int argc, char **argv)
{
    QCoreApplication application(argc, argv);
    application.setApplicationName(QStringLiteral("filesail-cli"));
    QStringList arguments = application.arguments().mid(1);
    if (arguments.isEmpty())
        return usage();
    if (arguments.contains(QStringLiteral("--help")) || arguments.contains(QStringLiteral("-h"))) {
        usage();
        return 0;
    }

    const QString windowSelector = takeOption(arguments, QStringLiteral("--window"));
    const QString hostSelector = takeOption(arguments, QStringLiteral("--host"));
    const QString requestedId = takeOption(arguments, QStringLiteral("--request-id"));
    const QString timeoutText = takeOption(arguments, QStringLiteral("--timeout"));
    const QString expectedText = takeOption(arguments, QStringLiteral("--expected-revision"));
    const bool noWait = takeFlag(arguments, QStringLiteral("--no-wait"));
    bool timeoutOk = true;
    const int timeoutMs = timeoutText.isEmpty() ? 15000 : timeoutText.toInt(&timeoutOk);
    if (!timeoutOk || timeoutMs < 1 || timeoutMs > 300000)
        return usage(QStringLiteral("--timeout must be between 1 and 300000 milliseconds"));
    const int expectedRevision = expectedText.isEmpty() ? -1 : expectedText.toInt();
    const QString requestId = requestedId.isEmpty() ? newRequestId() : requestedId;

    const Transport transport;
    if (!transport.available())
        return printJson(failure(QStringLiteral("transport_unavailable"), QStringLiteral("Quickshell executable was not found")));
    QList<Host> hosts = filterHosts(transport.discover(), hostSelector);
    if (!hostSelector.isEmpty() && hosts.isEmpty())
        return printJson(failure(QStringLiteral("host_not_found"), QStringLiteral("No matching FileSail host is available")));

    const QString command = arguments.takeFirst();
    if (command == QLatin1String("windows")) {
        if (arguments.isEmpty()) return usage(QStringLiteral("windows requires list, ensure, or create"));
        const QString action = arguments.takeFirst();
        const QString location = takeOption(arguments, QStringLiteral("--location"));
        if (!arguments.isEmpty())
            return usage(QStringLiteral("unexpected windows argument: %1").arg(arguments.first()));
        const QList<Target> allTargets = targets(hosts, {});
        if (action == QLatin1String("list")) {
            QJsonArray hostArray;
            QJsonArray windowArray;
            for (const Host &host : hosts) {
                QJsonObject description = host.description;
                description.insert(QStringLiteral("instanceId"), host.instanceId);
                hostArray.push_back(description);
            }
            for (const Target &target : allTargets) {
                QJsonObject window = target.window;
                window.insert(QStringLiteral("hostGeneration"), target.host.description.value(QStringLiteral("hostGeneration")));
                window.insert(QStringLiteral("instanceId"), target.host.instanceId);
                windowArray.push_back(window);
            }
            return printJson({{QStringLiteral("version"), 1}, {QStringLiteral("ok"), true},
                              {QStringLiteral("hosts"), hostArray}, {QStringLiteral("windows"), windowArray}});
        }
        if (action != QLatin1String("ensure") && action != QLatin1String("create"))
            return usage(QStringLiteral("unknown windows command"));
        if (action == QLatin1String("ensure") && allTargets.size() == 1)
            return printJson({{QStringLiteral("version"), 1}, {QStringLiteral("ok"), true},
                {QStringLiteral("status"), QStringLiteral("succeeded")},
                {QStringLiteral("window"), allTargets.first().window.value(QStringLiteral("window"))},
                {QStringLiteral("data"), QJsonObject{{QStringLiteral("state"), allTargets.first().window}}}});
        if (action == QLatin1String("ensure") && allTargets.size() > 1)
            return printJson(targetChoices(allTargets));
        const QString requestedLocation = location.isEmpty() ? QStringLiteral("home") : location;
        QList<Host> creators;
        for (const Host &host : hosts)
            if (host.description.value(QStringLiteral("canCreateWindow")).toBool()) creators.push_back(host);
        if (creators.size() > 1)
            return printJson(failure(QStringLiteral("ambiguous_target"), QStringLiteral("More than one standalone host can create the window")));
        if (creators.size() == 1)
            return printJson(submitCreate(transport, creators.first(), requestedLocation, requestId, !noWait, timeoutMs));
        QSet<QString> oldIds;
        for (const Target &target : allTargets) oldIds.insert(target.window.value(QStringLiteral("window")).toString());
        return printJson(*launchWindow(transport, requestedLocation, timeoutMs, oldIds,
                                       action == QLatin1String("ensure")));
    }

    if (command == QLatin1String("result")) {
        if (arguments.isEmpty()) return usage(QStringLiteral("result requires a request ID"));
        const QString id = arguments.takeFirst();
        if (!arguments.isEmpty()) return usage(QStringLiteral("result accepts one request ID"));
        QJsonArray unknown;
        for (const Host &host : hosts) {
            const auto result = transport.call(host.instanceId, QStringLiteral("result"), {id}, 3000);
            if (result && result->value(QStringLiteral("code")).toString() != QLatin1String("result_unknown"))
                return printJson(*result);
            if (result) unknown.push_back(*result);
        }
        return printJson(failure(QStringLiteral("result_unknown"), QStringLiteral("Request result is unknown or expired"),
                                 {{QStringLiteral("requestId"), id}}));
    }

    if (command == QLatin1String("events")) {
        const QString since = takeOption(arguments, QStringLiteral("--since"));
        const QString limit = takeOption(arguments, QStringLiteral("--limit"));
        if (!arguments.isEmpty()) return usage(QStringLiteral("unexpected events argument: %1").arg(arguments.first()));
        if (!windowSelector.isEmpty()) {
            const QList<Target> eventTargets = targets(hosts, windowSelector);
            if (eventTargets.isEmpty())
                return printJson(failure(QStringLiteral("window_not_found"),
                                         QStringLiteral("The requested window is not available")));
            if (eventTargets.size() > 1)
                return printJson(targetChoices(eventTargets));
            hosts = {eventTargets.first().host};
        }
        if (hosts.size() != 1)
            return printJson(failure(hosts.isEmpty() ? QStringLiteral("no_host") : QStringLiteral("ambiguous_target"),
                                     QStringLiteral("Select exactly one host for events")));
        const auto response = transport.call(hosts.first().instanceId, QStringLiteral("eventsSince"),
            {since.isEmpty() ? QStringLiteral("0") : since, limit.isEmpty() ? QStringLiteral("100") : limit}, 3000);
        return printJson(response.value_or(failure(QStringLiteral("host_disconnected"), QStringLiteral("Could not query host events"))));
    }

    QList<Target> matches = targets(hosts, windowSelector);
    if (!windowSelector.isEmpty() && matches.isEmpty())
        return printJson(failure(QStringLiteral("window_not_found"), QStringLiteral("The requested window is not available"),
                                 {{QStringLiteral("window"), windowSelector}}));
    if (matches.size() > 1)
        return printJson(targetChoices(matches));
    if (matches.isEmpty()) {
        if (command != QLatin1String("navigate"))
            return printJson(failure(QStringLiteral("no_window"), QStringLiteral("No FileSail window is available")));
        const QString location = takeOption(arguments, QStringLiteral("--location"));
        if (location.isEmpty()) return usage(QStringLiteral("navigate requires --location"));
        QList<Host> creators;
        for (const Host &host : hosts)
            if (host.description.value(QStringLiteral("canCreateWindow")).toBool()) creators.push_back(host);
        if (creators.size() == 1)
            return printJson(submitCreate(transport, creators.first(), location, requestId, !noWait, timeoutMs));
        if (creators.size() > 1)
            return printJson(failure(QStringLiteral("ambiguous_target"), QStringLiteral("More than one standalone host can create a window")));
        return printJson(*launchWindow(transport, location, timeoutMs, {}, true));
    }

    QString method = command;
    QJsonObject params;
    if (command == QLatin1String("navigate")) {
        const QString location = takeOption(arguments, QStringLiteral("--location"));
        if (location.isEmpty()) return usage(QStringLiteral("navigate requires --location"));
        params.insert(QStringLiteral("location"), location);
    } else if (command == QLatin1String("entries")) {
        const QString limit = takeOption(arguments, QStringLiteral("--limit"));
        const QString cursor = takeOption(arguments, QStringLiteral("--cursor"));
        if (!limit.isEmpty()) params.insert(QStringLiteral("limit"), limit.toInt());
        if (!cursor.isEmpty()) params.insert(QStringLiteral("cursor"), cursor);
    } else if (command == QLatin1String("select")) {
        QJsonArray paths;
        while (true) {
            bool found = false;
            const QString path = takeOption(arguments, QStringLiteral("--path"), &found);
            if (!found) break;
            paths.push_back(path);
        }
        if (paths.isEmpty()) return usage(QStringLiteral("select requires --path"));
        params.insert(QStringLiteral("paths"), paths);
        const QString mode = takeOption(arguments, QStringLiteral("--mode"));
        const QString primary = takeOption(arguments, QStringLiteral("--primary"));
        if (!mode.isEmpty()) params.insert(QStringLiteral("mode"), mode);
        if (!primary.isEmpty()) params.insert(QStringLiteral("primary"), primary);
    } else if (command == QLatin1String("clear-selection")) {
        method = QStringLiteral("selection.clear");
    } else if (command == QLatin1String("preview")) {
        if (arguments.isEmpty() || (arguments.first() != QLatin1String("show") && arguments.first() != QLatin1String("hide")))
            return usage(QStringLiteral("preview requires show or hide"));
        method = QStringLiteral("preview.%1").arg(arguments.takeFirst());
    } else if (command == QLatin1String("filter")) {
        params.insert(QStringLiteral("value"), takeOption(arguments, QStringLiteral("--value")));
    } else if (command == QLatin1String("hidden")) {
        if (arguments.isEmpty() || (arguments.first() != QLatin1String("show")
                && arguments.first() != QLatin1String("hide")))
            return usage(QStringLiteral("hidden requires show or hide"));
        params.insert(QStringLiteral("show"), arguments.takeFirst() == QLatin1String("show"));
    } else if (command == QLatin1String("view-mode")) {
        if (arguments.isEmpty() || (arguments.first() != QLatin1String("list")
                && arguments.first() != QLatin1String("grid")))
            return usage(QStringLiteral("view-mode requires list or grid"));
        method = QStringLiteral("viewMode");
        params.insert(QStringLiteral("mode"), arguments.takeFirst());
    } else if (command == QLatin1String("sort")) {
        const QString field = takeOption(arguments, QStringLiteral("--field"));
        if (!QStringList{QStringLiteral("name"), QStringLiteral("size"), QStringLiteral("modified")}.contains(field))
            return usage(QStringLiteral("sort requires --field name, size, or modified"));
        params.insert(QStringLiteral("field"), field);
        params.insert(QStringLiteral("descending"), takeFlag(arguments, QStringLiteral("--descending")));
        const QString foldersFirst = takeOption(arguments, QStringLiteral("--folders-first"));
        if (!foldersFirst.isEmpty()) {
            if (foldersFirst != QLatin1String("true") && foldersFirst != QLatin1String("false"))
                return usage(QStringLiteral("--folders-first must be true or false"));
            params.insert(QStringLiteral("foldersFirst"), foldersFirst == QLatin1String("true"));
        }
    } else if (QStringList{QStringLiteral("state"), QStringLiteral("capabilities"), QStringLiteral("back"),
                           QStringLiteral("forward"), QStringLiteral("up"), QStringLiteral("refresh")}.contains(command)) {
        // No additional arguments.
    } else {
        return usage(QStringLiteral("unknown command: %1").arg(command));
    }
    if (!arguments.isEmpty())
        return usage(QStringLiteral("unexpected argument: %1").arg(arguments.first()));
    return printJson(submit(transport, matches.first(), method, params, requestId,
                            expectedRevision, !noWait, timeoutMs));
}
