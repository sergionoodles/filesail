import QtQuick
import Quickshell
import Quickshell.Io

// Maps Noctalia's published palette into FileSail's host-neutral Theme.
//
// Noctalia 5 no longer writes colors.json. The standalone host registers a
// user template so Noctalia renders ~/.config/filesail/theme.json on every
// palette change, then FileView-watches that file. Metrics come from the
// v5 TOML config. Noctalia 4's colors.json / settings.json remain a fallback.
QtObject {
    id: root

    property var theme: null
    property var colors: ({
        primary: "#7aa2f7", primaryText: "#16161e", surface: "#1a1b26",
        surfaceVariant: "#24283b", text: "#c0caf5", textMuted: "#9aa5ce",
        outline: "#353d57", error: "#f7768e", errorText: "#16161e"
    })
    property var metrics: ({ appearance: "dark", scale: 1, radiusRatio: 1, animationFast: 150 })

    property bool liveThemeLoaded: false
    property bool liveThemeChecked: false
    property bool bundledTemplateChecked: false
    property bool v5ConfigSeen: false
    property bool templateEntryPresent: false
    property bool templateEntryChecked: false
    property bool templateDirReady: false
    property bool templateInstallStarted: false

    readonly property string homeDir: String(Quickshell.env("HOME") ?? "")
    readonly property string filesailConfigDir: {
        const xdgConfig = String(Quickshell.env("XDG_CONFIG_HOME") ?? "");
        return (xdgConfig.length > 0 ? xdgConfig : root.homeDir + "/.config") + "/filesail";
    }
    readonly property string configDir: {
        const legacy = String(Quickshell.env("NOCTALIA_CONFIG_DIR") ?? "");
        if (legacy.length > 0)
            return legacy.replace(/\/$/, "");
        return root.noctaliaHome("NOCTALIA_CONFIG_HOME", "XDG_CONFIG_HOME", root.homeDir + "/.config");
    }
    readonly property string stateDir: {
        return root.noctaliaHome("NOCTALIA_STATE_HOME", "XDG_STATE_HOME", root.homeDir + "/.local/state");
    }
    readonly property string liveThemePath: root.filesailConfigDir + "/theme.json"
    readonly property string templateSourcePath: root.configDir + "/templates/filesail.json"
    readonly property string templateEntryPath: root.configDir + "/filesail.toml"
    readonly property string templateEntrySource: [
        "# Written by FileSail so the standalone window follows the Noctalia palette.",
        "# Set enabled = false to stop generating ~/.config/filesail/theme.json.",
        "[theme.templates.user.filesail]",
        "input_path  = \"templates/filesail.json\"",
        "output_path = \"$XDG_CONFIG_HOME/filesail/theme.json\"",
        ""
    ].join("\n")

    function noctaliaHome(overrideName, xdgName, fallbackHome) {
        const override = String(Quickshell.env(overrideName) ?? "");
        if (override.length > 0)
            return override.replace(/\/$/, "") + "/noctalia";
        const xdg = String(Quickshell.env(xdgName) ?? "");
        if (xdg.length > 0)
            return xdg.replace(/\/$/, "") + "/noctalia";
        return fallbackHome + "/noctalia";
    }

    function fileUrlPath(url) {
        const text = String(url ?? "");
        if (text.startsWith("file://"))
            return decodeURIComponent(text.slice(7));
        return text;
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
        if (quote === "\"" || quote === "'") {
            const end = trimmed.indexOf(quote, 1);
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
        if (typeof text !== "string" || text.length === 0)
            return undefined;
        const tableRe = new RegExp("(?:^|\\n)\\s*\\[" + escapeRegExp(table) + "\\]\\s*(?:\\n|$)");
        const start = text.search(tableRe);
        if (start < 0)
            return undefined;
        const fromTable = text.slice(start);
        const next = fromTable.search(/\n\s*\[[^\]]+\]/);
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

    function noteV5Config() {
        if (root.v5ConfigSeen)
            return;
        root.v5ConfigSeen = true;
        if (!root.templateDirProcess.running)
            root.templateDirProcess.running = true;
        root.maybeInstallTemplate();
    }

    function maybeInstallTemplate() {
        if (root.templateInstallStarted
            || !root.v5ConfigSeen
            || !root.templateEntryChecked
            || !root.liveThemeChecked
            || !root.bundledTemplateChecked
            || !root.templateDirReady)
            return;
        root.templateInstallStarted = true;
        root.writeTemplateFiles();
    }

    function writeTemplateFiles() {
        const source = root.fileText(root.bundledTemplateFile);
        if (source.length === 0)
            return;
        if (root.fileText(root.templateSourceFile) !== source)
            root.templateSourceFile.setText(source);

        if (!root.templateEntryPresent) {
            root.templateEntryFile.setText(root.templateEntrySource);
            root.applyTemplatesProcess.running = true;
            return;
        }

        const entryText = root.fileText(root.templateEntryFile);
        if (/enabled\s*=\s*false/.test(entryText))
            return;
        if (!root.liveThemeLoaded)
            root.applyTemplatesProcess.running = true;
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
            if (!next)
                return;
            root.colors = next;
            root.liveThemeLoaded = true;
            if (data.appearance === "dark" || data.appearance === "light") {
                const metrics = Object.assign({}, root.metrics);
                metrics.appearance = data.appearance;
                root.metrics = metrics;
            }
        } catch (error) {
            // A template write can be observed mid-write; retain the last valid theme.
        }
    }

    function loadLegacyColors() {
        if (root.liveThemeLoaded)
            return;
        try {
            const text = root.legacyColorsFile.text();
            if (text.length > 256 * 1024)
                return;
            const data = JSON.parse(text);
            const next = root.colorMapFromObject(data, {
                primary: "mPrimary", primaryText: "mOnPrimary",
                surface: "mSurface", surfaceVariant: "mSurfaceVariant",
                text: "mOnSurface", textMuted: "mOnSurfaceVariant",
                outline: "mOutline", error: "mError", errorText: "mOnError"
            });
            if (next)
                root.colors = next;
        } catch (error) {
            // A config write can be observed mid-write; retain the last valid theme.
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

    function loadV5Metrics() {
        const next = Object.assign(
            {},
            root.metricsFromToml(root.fileText(root.configTomlFile)),
            root.metricsFromToml(root.fileText(root.settingsTomlFile))
        );
        if (Object.keys(next).length === 0)
            return;
        const merged = Object.assign({}, root.metrics, next);
        if (root.liveThemeLoaded)
            merged.appearance = root.metrics.appearance;
        root.metrics = merged;
    }

    function loadLegacyMetrics() {
        if (root.v5ConfigSeen)
            return;
        try {
            const text = root.legacySettingsFile.text();
            if (text.length > 256 * 1024)
                return;
            const data = JSON.parse(text);
            const general = data.general ?? {};
            const disabled = Boolean(general.animationDisabled);
            const speed = root.boundedNumber(general.animationSpeed, 1, 0.1, 10);
            root.metrics = {
                appearance: data.colorSchemes?.darkMode === false ? "light" : "dark",
                scale: root.boundedNumber(general.scaleRatio, 1, 0.5, 3),
                radiusRatio: root.boundedNumber(general.radiusRatio, 1, 0.25, 4),
                animationFast: disabled ? 0 : Math.round(150 / speed)
            };
        } catch (error) {
            // Preserve the host-neutral defaults until a valid settings file exists.
        }
    }

    function scheduleReload() { root.reloadTimer.restart(); }

    function reloadWatchedFiles() {
        root.liveThemeFile.reload();
        root.settingsTomlFile.reload();
        root.configTomlFile.reload();
        root.legacyColorsFile.reload();
        root.legacySettingsFile.reload();
    }

    property Timer reloadTimer: Timer {
        interval: 200
        onTriggered: root.reloadWatchedFiles()
    }

    property Process templateDirProcess: Process {
        command: ["mkdir", "-p", root.configDir + "/templates", root.filesailConfigDir]
        running: false
        onExited: exitCode => {
            root.templateDirReady = exitCode === 0;
            root.maybeInstallTemplate();
        }
    }

    property Process applyTemplatesProcess: Process {
        command: ["noctalia", "msg", "templates-apply"]
        running: false
        onExited: exitCode => root.liveThemeFile.reload()
    }

    property FileView bundledTemplateFile: FileView {
        path: root.fileUrlPath(Qt.resolvedUrl("theme-template.json"))
        preload: true
        printErrors: false
        onLoaded: {
            root.bundledTemplateChecked = true;
            root.maybeInstallTemplate();
        }
        onLoadFailed: {
            root.bundledTemplateChecked = true;
            root.maybeInstallTemplate();
        }
    }

    property FileView templateSourceFile: FileView {
        path: root.templateSourcePath
        preload: false
        printErrors: false
        atomicWrites: true
    }

    property FileView templateEntryFile: FileView {
        path: root.templateEntryPath
        preload: true
        printErrors: false
        atomicWrites: true
        onLoaded: {
            root.templateEntryPresent = true;
            root.templateEntryChecked = true;
            root.maybeInstallTemplate();
        }
        onLoadFailed: {
            root.templateEntryPresent = false;
            root.templateEntryChecked = true;
            root.maybeInstallTemplate();
        }
    }

    property FileView liveThemeFile: FileView {
        path: root.liveThemePath
        preload: true
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.loadLiveTheme();
            root.liveThemeChecked = true;
            root.maybeInstallTemplate();
        }
        onFileChanged: root.scheduleReload()
        onLoadFailed: {
            root.liveThemeChecked = true;
            root.maybeInstallTemplate();
        }
    }

    property FileView settingsTomlFile: FileView {
        path: root.stateDir + "/settings.toml"
        preload: true
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.noteV5Config();
            root.loadV5Metrics();
        }
        onFileChanged: root.scheduleReload()
    }

    property FileView configTomlFile: FileView {
        path: root.configDir + "/config.toml"
        preload: true
        watchChanges: true
        printErrors: false
        onLoaded: {
            root.noteV5Config();
            root.loadV5Metrics();
        }
        onFileChanged: root.scheduleReload()
    }

    property FileView legacyColorsFile: FileView {
        path: root.configDir + "/colors.json"
        preload: true
        watchChanges: true
        printErrors: false
        onLoaded: root.loadLegacyColors()
        onFileChanged: root.scheduleReload()
    }

    property FileView legacySettingsFile: FileView {
        path: root.configDir + "/settings.json"
        preload: true
        watchChanges: true
        printErrors: false
        onLoaded: root.loadLegacyMetrics()
        onFileChanged: root.scheduleReload()
    }

    // Atomic replacements change the directory entry. Watch the parent so a
    // FileView on the old inode still sees the new file.
    property FileView filesailDirectoryWatcher: FileView {
        path: root.filesailConfigDir
        watchChanges: true
        printErrors: false
        onFileChanged: root.scheduleReload()
    }

    property FileView stateDirectoryWatcher: FileView {
        path: root.stateDir
        watchChanges: true
        printErrors: false
        onFileChanged: root.scheduleReload()
    }

    property Binding primaryBinding: Binding { target: root.theme; property: "primary"; value: root.colors.primary; when: root.theme && root.colors.primary !== undefined }
    property Binding primaryTextBinding: Binding { target: root.theme; property: "primaryText"; value: root.colors.primaryText; when: root.theme && root.colors.primaryText !== undefined }
    property Binding surfaceBinding: Binding { target: root.theme; property: "surface"; value: root.colors.surface; when: root.theme && root.colors.surface !== undefined }
    property Binding surfaceVariantBinding: Binding { target: root.theme; property: "surfaceVariant"; value: root.colors.surfaceVariant; when: root.theme && root.colors.surfaceVariant !== undefined }
    property Binding textBinding: Binding { target: root.theme; property: "text"; value: root.colors.text; when: root.theme && root.colors.text !== undefined }
    property Binding textMutedBinding: Binding { target: root.theme; property: "textMuted"; value: root.colors.textMuted; when: root.theme && root.colors.textMuted !== undefined }
    property Binding outlineBinding: Binding { target: root.theme; property: "outline"; value: root.colors.outline; when: root.theme && root.colors.outline !== undefined }
    property Binding errorBinding: Binding { target: root.theme; property: "error"; value: root.colors.error; when: root.theme && root.colors.error !== undefined }
    property Binding errorTextBinding: Binding { target: root.theme; property: "errorText"; value: root.colors.errorText; when: root.theme && root.colors.errorText !== undefined }
    property Binding appearanceBinding: Binding { target: root.theme; property: "appearance"; value: root.metrics.appearance; when: root.theme && root.metrics.appearance !== undefined }
    property Binding scaleBinding: Binding { target: root.theme; property: "scale"; value: root.metrics.scale; when: root.theme && root.metrics.scale !== undefined }
    property Binding radiusRatioBinding: Binding { target: root.theme; property: "radiusRatio"; value: root.metrics.radiusRatio; when: root.theme && root.metrics.radiusRatio !== undefined }
    property Binding animationFastBinding: Binding { target: root.theme; property: "animationFast"; value: root.metrics.animationFast; when: root.theme && root.metrics.animationFast !== undefined }
}
