import QtQuick
import Quickshell
import Quickshell.Io

// Owns Noctalia's on-disk theme source. Keeping this separate from Theme lets
// the shared view run without Noctalia and lets a future host supply its own
// provider (or a per-view Theme instance).
QtObject {
    id: root

    property var theme: null
    property var colors: ({})
    property var metrics: ({})
    readonly property string configDir: {
        const configured = String(Quickshell.env("NOCTALIA_CONFIG_DIR") ?? "");
        return configured.length > 0
            ? configured.replace(/\/$/, "")
            : String(Quickshell.env("HOME") ?? "") + "/.config/noctalia";
    }

    function boundedNumber(value, fallback, minimum, maximum) {
        const number = Number(value);
        return Number.isFinite(number) ? Math.max(minimum, Math.min(maximum, number)) : fallback;
    }

    function validColor(value) {
        return typeof value === "string"
            && /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$/.test(value);
    }

    function loadColors() {
        try {
            const text = colorsFile.text();
            if (text.length > 256 * 1024)
                return;
            const data = JSON.parse(text);
            const next = {
                primary: data.mPrimary,
                primaryText: data.mOnPrimary,
                surface: data.mSurface,
                surfaceVariant: data.mSurfaceVariant,
                text: data.mOnSurface,
                textMuted: data.mOnSurfaceVariant,
                outline: data.mOutline,
                error: data.mError
            };
            if (Object.values(next).every(validColor))
                colors = next;
        } catch (error) {
            // A config write can be observed mid-write; retain the last valid theme.
        }
    }

    function loadMetrics() {
        try {
            const text = settingsFile.text();
            if (text.length > 256 * 1024)
                return;
            const general = JSON.parse(text).general ?? {};
            const disabled = Boolean(general.animationDisabled);
            const speed = boundedNumber(general.animationSpeed, 1, 0.1, 10);
            metrics = {
                scale: boundedNumber(general.scaleRatio, 1, 0.5, 3),
                radiusRatio: boundedNumber(general.radiusRatio, 1, 0.25, 4),
                animationFast: disabled ? 0 : Math.round(150 / speed)
            };
        } catch (error) {
            // Preserve the host-neutral defaults until a valid settings file exists.
        }
    }

    function scheduleReload() {
        reloadTimer.restart();
    }

    property Timer reloadTimer: Timer {
        interval: 200
        onTriggered: {
            root.colorsFile.reload();
            root.settingsFile.reload();
        }
    }

    property FileView colorsFile: FileView {
        path: root.configDir + "/colors.json"
        preload: true
        watchChanges: true
        printErrors: false
        onLoaded: root.loadColors()
        onFileChanged: root.scheduleReload()
    }

    property FileView settingsFile: FileView {
        path: root.configDir + "/settings.json"
        preload: true
        watchChanges: true
        printErrors: false
        onLoaded: root.loadMetrics()
        onFileChanged: root.scheduleReload()
    }

    property FileView directoryWatcher: FileView {
        path: root.configDir
        watchChanges: true
        printErrors: false
        onFileChanged: root.scheduleReload()
    }

    // QtObject has no default child property, so each Binding must be owned by
    // an explicit property rather than declared as an implicit child.
    property Binding primaryBinding: Binding { target: root.theme; property: "primary"; value: root.colors.primary; when: root.theme && root.colors.primary !== undefined }
    property Binding primaryTextBinding: Binding { target: root.theme; property: "primaryText"; value: root.colors.primaryText; when: root.theme && root.colors.primaryText !== undefined }
    property Binding surfaceBinding: Binding { target: root.theme; property: "surface"; value: root.colors.surface; when: root.theme && root.colors.surface !== undefined }
    property Binding surfaceVariantBinding: Binding { target: root.theme; property: "surfaceVariant"; value: root.colors.surfaceVariant; when: root.theme && root.colors.surfaceVariant !== undefined }
    property Binding textBinding: Binding { target: root.theme; property: "text"; value: root.colors.text; when: root.theme && root.colors.text !== undefined }
    property Binding textMutedBinding: Binding { target: root.theme; property: "textMuted"; value: root.colors.textMuted; when: root.theme && root.colors.textMuted !== undefined }
    property Binding outlineBinding: Binding { target: root.theme; property: "outline"; value: root.colors.outline; when: root.theme && root.colors.outline !== undefined }
    property Binding errorBinding: Binding { target: root.theme; property: "error"; value: root.colors.error; when: root.theme && root.colors.error !== undefined }
    property Binding scaleBinding: Binding { target: root.theme; property: "scale"; value: root.metrics.scale; when: root.theme && root.metrics.scale !== undefined }
    property Binding radiusRatioBinding: Binding { target: root.theme; property: "radiusRatio"; value: root.metrics.radiusRatio; when: root.theme && root.metrics.radiusRatio !== undefined }
    property Binding animationFastBinding: Binding { target: root.theme; property: "animationFast"; value: root.metrics.animationFast; when: root.theme && root.metrics.animationFast !== undefined }
}
