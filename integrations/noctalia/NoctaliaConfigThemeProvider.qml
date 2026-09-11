import QtQuick
import Quickshell
import Quickshell.Io

// Noctalia owns palette resolution (including wallpaper, scheduled mode and
// custom schemes). Consume its public app template output, never its caches.
QtObject {
    id: root

    property var theme: null
    property var colors: ({})
    property var metrics: ({})
    property bool liveThemeLoaded: false
    property bool configSeen: false
    property bool bundledTemplateChecked: false
    property bool templateEntryChecked: false
    property bool templateEntryPresent: false
    property bool templateReady: false
    property bool setupStarted: false
    property bool refreshPending: true
    property int refreshAttempts: 0
    property string effectiveConfig: ""
    property string lastWarning: ""
    readonly property bool templateEnabled: root.tomlValue(root.effectiveConfig, "theme.templates.user.filesail", "input_path") !== undefined
                                          && root.tomlValue(root.effectiveConfig, "theme.templates.user.filesail", "enabled") !== false

    readonly property string homeDir: String(Quickshell.env("HOME") ?? "")
    readonly property string filesailConfigDir: (String(Quickshell.env("XDG_CONFIG_HOME") || root.homeDir + "/.config")) + "/filesail"
    readonly property string configDir: root.noctaliaHome("NOCTALIA_CONFIG_HOME", "XDG_CONFIG_HOME", root.homeDir + "/.config")
    readonly property string stateDir: root.noctaliaHome("NOCTALIA_STATE_HOME", "XDG_STATE_HOME", root.homeDir + "/.local/state")
    readonly property string liveThemePath: root.filesailConfigDir + "/theme.json"
    readonly property string templateEntrySource: [
        "# FileSail's Noctalia app-theme bridge. Set enabled = false to opt out.",
        "[theme.templates.user.filesail]",
        'input_path = "templates/filesail.json"',
        'output_path = "$XDG_CONFIG_HOME/filesail/theme.json"',
        ""
    ].join("\n")

    function noctaliaHome(overrideName, xdgName, fallbackHome) {
        return String(Quickshell.env(overrideName) || Quickshell.env(xdgName) || fallbackHome).replace(/\/$/, "") + "/noctalia";
    }

    function warn(message) {
        if (message !== root.lastWarning) {
            root.lastWarning = message;
            console.warn("FileSail theme: " + message);
        }
    }

    function boundedNumber(value, fallback, minimum, maximum) {
        const number = Number(value);
        return Number.isFinite(number) ? Math.max(minimum, Math.min(maximum, number)) : fallback;
    }

    function validColor(value) {
        return typeof value === "string"
            && /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(value);
    }

    function escapeRegExp(value) {
        return String(value).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    }

    function parseTomlScalar(raw) {
        const trimmed = String(raw ?? "").trim();
        if (trimmed.length === 0 || trimmed.startsWith("#"))
            return undefined;
        const quote = trimmed[0];
        if (quote === "\"") {
            const quoted = trimmed.match(/^"(?:\\.|[^"\\])*"/);
            return quoted ? JSON.parse(quoted[0]) : undefined;
        }
        if (quote === "'") {
            const end = trimmed.indexOf("'", 1);
            if (end > 0)
                return trimmed.slice(1, end);
        }
        const unquoted = trimmed.split("#")[0].trim();
        if (unquoted === "true")
            return true;
        if (unquoted === "false")
            return false;
        const number = Number(unquoted);
        return Number.isFinite(number) ? number : unquoted;
    }

    function tomlValue(text, table, key) {
        // Only read scalar fields from `noctalia config export full`, whose
        // formatting is canonical. Noctalia handles TOML syntax and merging.
        if (typeof text !== "string" || text.length === 0)
            return undefined;
        const tableRe = new RegExp("(?:^|\\n)\\s*\\[" + escapeRegExp(table) + "\\]\\s*(?:\\n|$)");
        const header = tableRe.exec(text);
        if (!header)
            return undefined;
        const fromTable = text.slice(header.index + header[0].length);
        const next = fromTable.search(/(?:^|\n)\s*\[[^\]]+\]/);
        const body = next >= 0 ? fromTable.slice(0, next) : fromTable;
        const keyRe = new RegExp("(?:^|\\n)\\s*" + escapeRegExp(key) + "\\s*=\\s*([^\\n]+)");
        const match = body.match(keyRe);
        return match ? parseTomlScalar(match[1]) : undefined;
    }

    function fileText(fileView) {
        try {
            return fileView.text();
        } catch (error) {
            return "";
        }
    }

    function maybeInstallTemplate() {
        if (root.setupStarted || !root.configSeen || !root.bundledTemplateChecked || !root.templateEntryChecked)
            return;
        root.setupStarted = true;
        // A declarative registration may point directly at the packaged
        // template. It needs no writes to Noctalia's config directory.
        if (!root.templateEntryPresent && root.tomlValue(root.effectiveConfig, "theme.templates.user.filesail", "input_path") !== undefined) {
            root.templateReady = true;
            root.maybeRefresh();
            return;
        }
        root.templateDirProcess.running = true;
    }

    function setupFailed() {
        root.setupStarted = false;
        root.warn("Cannot install the Noctalia template. Check write access to " + root.configDir);
    }

    function writeTemplateSource() {
        const source = root.fileText(root.bundledTemplateFile);
        if (!source) {
            root.warn("The bundled Noctalia theme template is missing.");
            return;
        }
        if (root.fileText(root.templateSourceFile) === source)
            root.writeTemplateEntry();
        else
            root.templateSourceFile.setText(source);
    }

    function writeTemplateEntry() {
        // Existing entries belong to the user, including explicit opt-outs.
        if (root.templateEntryPresent || root.tomlValue(root.effectiveConfig, "theme.templates.user.filesail", "input_path") !== undefined)
            root.finishSetup();
        else
            root.templateEntryFile.setText(root.templateEntrySource);
    }

    function finishSetup() {
        root.templateReady = true;
        root.exportConfigProcess.running = true;
    }

    function acceptConfig(text) {
        if (!text.trim())
            return;
        root.configSeen = true;
        const wasEnabled = root.templateEnabled;
        root.effectiveConfig = text;
        if (!wasEnabled && root.templateEnabled) {
            root.refreshPending = true;
            root.refreshAttempts = 0;
        }
        // Rebuild from the effective snapshot: removing an override must reset
        // it, and includes / GUI overrides must have Noctalia's precedence.
        const next = root.metricsFromToml(text);
        if (root.liveThemeLoaded)
            next.appearance = root.metrics.appearance;
        root.metrics = next;
        root.maybeInstallTemplate();
        root.maybeRefresh();
    }

    function maybeRefresh() {
        if (!root.templateReady || !root.refreshPending || root.reloadConfigProcess.running || root.applyTemplatesProcess.running)
            return;
        if (!root.templateEnabled) {
            root.warn("The filesail template is disabled or excluded from Noctalia's effective config. Check [include] and [theme.templates.user.filesail].");
            return;
        }
        root.refreshAttempts += 1;
        root.reloadConfigProcess.running = true;
    }

    function colorMapFromObject(data, keys) {
        if (!data || typeof data !== "object")
            return null;
        const next = {
            primary: data[keys.primary], primaryText: data[keys.primaryText],
            surface: data[keys.surface], surfaceVariant: data[keys.surfaceVariant],
            text: data[keys.text], textMuted: data[keys.textMuted],
            outline: data[keys.outline], error: data[keys.error], errorText: data[keys.errorText]
        };
        return Object.values(next).every(root.validColor) ? next : null;
    }

    function loadLiveTheme() {
        try {
            const text = root.liveThemeFile.text();
            if (text.length > 256 * 1024)
                return;
            const data = JSON.parse(text);
            const next = root.colorMapFromObject(data, {
                primary: "primary", primaryText: "primaryText",
                surface: "surface", surfaceVariant: "surfaceVariant",
                text: "text", textMuted: "textMuted",
                outline: "outline", error: "error", errorText: "errorText"
            });
            if (!next || (data.appearance !== "dark" && data.appearance !== "light"))
                return;
            root.colors = next;
            root.liveThemeLoaded = true;
            Qt.callLater(() => { if (root.theme) root.theme.animatePalette = true; });
            if (data.appearance === "dark" || data.appearance === "light") {
                const metrics = Object.assign({}, root.metrics);
                metrics.appearance = data.appearance;
                root.metrics = metrics;
            }
        } catch (error) {
            // A template write can be observed mid-write; retain the last valid theme.
        }
    }

    function metricsFromToml(text) {
        if (typeof text !== "string" || text.length === 0)
            return ({});
        const next = {};
        const mode = root.tomlValue(text, "theme", "mode");
        if (mode === "dark" || mode === "light")
            next.appearance = mode;
        const scale = root.tomlValue(text, "accessibility", "ui_scale");
        if (scale !== undefined)
            next.scale = root.boundedNumber(scale, 1, 0.5, 3);
        const radius = root.tomlValue(text, "shell", "corner_radius_scale");
        if (radius !== undefined)
            next.radiusRatio = root.boundedNumber(radius, 1, 0.25, 4);
        const animationEnabled = root.tomlValue(text, "shell.animation", "enabled");
        const animationSpeed = root.tomlValue(text, "shell.animation", "speed");
        if (animationEnabled === false)
            next.animationFast = 0;
        else if (animationSpeed !== undefined || animationEnabled === true)
            next.animationFast = Math.round(150 / root.boundedNumber(animationSpeed, 1, 0.1, 10));
        return next;
    }

    function reloadWatchedFiles() {
        root.liveThemeFile.reload();
        if (!root.exportConfigProcess.running)
            root.exportConfigProcess.running = true;
    }

    property Timer reloadTimer: Timer {
        interval: 100
        onTriggered: root.reloadWatchedFiles()
    }

    // Also repairs a missed watch (missing parent, atomic replacement) and
    // discovers changes in included TOML files without reimplementing TOML.
    // Back off when Noctalia is absent or its initial palette is not ready.
    property Timer recoveryTimer: Timer {
        interval: !root.configSeen || root.refreshAttempts >= 3 ? 30000 : 5000
        running: true
        repeat: true
        onTriggered: root.reloadWatchedFiles()
    }

    property Process exportConfigProcess: Process {
        command: ["noctalia", "config", "export", "full"]
        running: true
        property string output: ""
        stdout: StdioCollector { onStreamFinished: root.exportConfigProcess.output = text }
        stderr: StdioCollector {}
        onExited: exitCode => {
            if (exitCode === 0)
                root.acceptConfig(output);
            output = "";
        }
    }

    property Process templateDirProcess: Process {
        command: ["mkdir", "-p", root.configDir + "/templates", root.filesailConfigDir]
        onExited: exitCode => {
            if (exitCode === 0)
                root.writeTemplateSource();
            else
                root.setupFailed();
        }
    }

    property Process reloadConfigProcess: Process {
        command: ["noctalia", "msg", "config-reload"]
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: exitCode => {
            if (exitCode === 0)
                root.applyTemplatesProcess.running = true;
            else
                root.warn("Waiting for Noctalia to reload the FileSail template registration.");
        }
    }

    property Process applyTemplatesProcess: Process {
        command: ["noctalia", "msg", "templates-apply"]
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        onExited: exitCode => {
            if (exitCode !== 0) {
                root.warn("Waiting for Noctalia's resolved palette; theme sync will retry.");
            } else {
                root.refreshPending = false;
                root.refreshAttempts = 0;
            }
            root.liveThemeFile.reload();
        }
    }

    property FileView bundledTemplateFile: FileView {
        path: decodeURIComponent(String(Qt.resolvedUrl("theme-template.json")).replace(/^file:\/\//, ""))
        preload: true
        printErrors: false
        onLoaded: { root.bundledTemplateChecked = true; root.maybeInstallTemplate(); }
        onLoadFailed: root.warn("Cannot read the bundled Noctalia template.")
    }

    property FileView templateSourceFile: FileView {
        path: root.configDir + "/templates/filesail.json"
        printErrors: false
        atomicWrites: true
        onSaved: root.writeTemplateEntry()
        onSaveFailed: root.setupFailed()
    }

    property FileView templateEntryFile: FileView {
        path: root.configDir + "/filesail.toml"
        preload: true
        printErrors: false
        atomicWrites: true
        onLoaded: { root.templateEntryPresent = true; root.templateEntryChecked = true; root.maybeInstallTemplate(); }
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) {
                root.templateEntryChecked = true;
                root.maybeInstallTemplate();
            } else {
                root.warn("Cannot read " + path + "; leaving it unchanged.");
            }
        }
        onSaved: { root.templateEntryPresent = true; root.finishSetup(); }
        onSaveFailed: root.setupFailed()
    }

    property FileView liveThemeFile: FileView {
        path: root.liveThemePath
        preload: true
        watchChanges: true
        printErrors: false
        onLoaded: root.loadLiveTheme()
        onFileChanged: root.reloadTimer.restart()
        onLoadFailed: root.refreshPending = true
    }

    property FileView filesailDirectoryWatcher: FileView {
        path: root.filesailConfigDir
        watchChanges: true
        printErrors: false
        onFileChanged: root.reloadTimer.restart()
    }

    property FileView configDirectoryWatcher: FileView {
        path: root.configDir
        watchChanges: true
        printErrors: false
        onFileChanged: root.reloadTimer.restart()
    }

    property FileView stateDirectoryWatcher: FileView {
        path: root.stateDir
        watchChanges: true
        printErrors: false
        onFileChanged: root.reloadTimer.restart()
    }

    property Binding primaryBinding: Binding { target: root.theme; property: "primary"; value: root.colors.primary ?? "transparent"; when: root.theme && root.colors.primary !== undefined }
    property Binding primaryTextBinding: Binding { target: root.theme; property: "primaryText"; value: root.colors.primaryText ?? "transparent"; when: root.theme && root.colors.primaryText !== undefined }
    property Binding surfaceBinding: Binding { target: root.theme; property: "surface"; value: root.colors.surface ?? "transparent"; when: root.theme && root.colors.surface !== undefined }
    property Binding surfaceVariantBinding: Binding { target: root.theme; property: "surfaceVariant"; value: root.colors.surfaceVariant ?? "transparent"; when: root.theme && root.colors.surfaceVariant !== undefined }
    property Binding textBinding: Binding { target: root.theme; property: "text"; value: root.colors.text ?? "transparent"; when: root.theme && root.colors.text !== undefined }
    property Binding textMutedBinding: Binding { target: root.theme; property: "textMuted"; value: root.colors.textMuted ?? "transparent"; when: root.theme && root.colors.textMuted !== undefined }
    property Binding outlineBinding: Binding { target: root.theme; property: "outline"; value: root.colors.outline ?? "transparent"; when: root.theme && root.colors.outline !== undefined }
    property Binding errorBinding: Binding { target: root.theme; property: "error"; value: root.colors.error ?? "transparent"; when: root.theme && root.colors.error !== undefined }
    property Binding errorTextBinding: Binding { target: root.theme; property: "errorText"; value: root.colors.errorText ?? "transparent"; when: root.theme && root.colors.errorText !== undefined }
    property Binding appearanceBinding: Binding { target: root.theme; property: "appearance"; value: root.metrics.appearance; when: root.theme && root.metrics.appearance !== undefined }
    property Binding scaleBinding: Binding { target: root.theme; property: "scale"; value: root.metrics.scale; when: root.theme && root.metrics.scale !== undefined }
    property Binding radiusRatioBinding: Binding { target: root.theme; property: "radiusRatio"; value: root.metrics.radiusRatio; when: root.theme && root.metrics.radiusRatio !== undefined }
    property Binding animationFastBinding: Binding { target: root.theme; property: "animationFast"; value: root.metrics.animationFast; when: root.theme && root.metrics.animationFast !== undefined }
}
