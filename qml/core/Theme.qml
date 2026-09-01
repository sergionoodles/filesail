pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    // Portable defaults intentionally mirror Noctalia's Material-style token names.
    property color primary: "#7aa2f7"
    property color primaryText: "#16161e"
    property color secondary: "#bb9af7"
    property color surface: "#1a1b26"
    property color surfaceVariant: "#24283b"
    property color text: "#c0caf5"
    property color textMuted: "#9aa5ce"
    property color outline: "#353d57"
    property color hover: "#9ece6a"
    property color error: "#f7768e"

    property real scale: 1.0
    property real radiusRatio: 1.0
    readonly property int spaceXs: Math.round(4 * scale)
    readonly property int spaceS: Math.round(6 * scale)
    readonly property int spaceM: Math.round(9 * scale)
    readonly property int spaceL: Math.round(13 * scale)
    readonly property int spaceXl: Math.round(18 * scale)
    readonly property int radiusS: Math.round(8 * radiusRatio)
    readonly property int radiusM: Math.round(12 * radiusRatio)
    readonly property int radiusL: Math.round(16 * radiusRatio)
    readonly property int fontSmall: Math.round(10 * scale)
    readonly property int fontBody: Math.round(11 * scale)
    readonly property int fontTitle: Math.round(16 * scale)
    property int animationFast: 150
    property int animationNormal: 300
    readonly property string noctaliaConfigDir: {
        const configured = String(Quickshell.env("NOCTALIA_CONFIG_DIR") ?? "");
        return configured.length > 0
            ? configured.replace(/\/$/, "")
            : String(Quickshell.env("HOME") ?? "") + "/.config/noctalia";
    }

    function apply(tokens) {
        if (!tokens)
            return;
        for (const key of Object.keys(tokens)) {
            if (root[key] !== undefined)
                root[key] = tokens[key];
        }
    }

    function loadColorFile() {
        try {
            const data = JSON.parse(noctaliaColors.text());
            apply({
                primary: data.mPrimary,
                primaryText: data.mOnPrimary,
                secondary: data.mSecondary,
                surface: data.mSurface,
                surfaceVariant: data.mSurfaceVariant,
                text: data.mOnSurface,
                textMuted: data.mOnSurfaceVariant,
                outline: data.mOutline,
                hover: data.mHover,
                error: data.mError
            });
        } catch (error) {
            // Defaults remain active when Noctalia is not installed or the file is mid-write.
        }
    }

    function loadSettingsFile() {
        try {
            const data = JSON.parse(noctaliaSettings.text());
            const general = data.general ?? {};
            scale = general.scaleRatio ?? scale;
            radiusRatio = general.radiusRatio ?? radiusRatio;
            if (general.animationDisabled) {
                animationFast = 0;
                animationNormal = 0;
            } else {
                const speed = Math.max(0.1, Number(general.animationSpeed ?? 1));
                animationFast = Math.round(150 / speed);
                animationNormal = Math.round(300 / speed);
            }
        } catch (error) {
        }
    }

    function scheduleReload() {
        reloadTimer.restart();
    }

    property Timer reloadTimer: Timer {
        interval: 200
        onTriggered: {
            root.noctaliaColors.reload();
            root.noctaliaSettings.reload();
        }
    }

    property FileView noctaliaColors: FileView {
        path: root.noctaliaConfigDir + "/colors.json"
        preload: true
        watchChanges: true
        printErrors: false
        onLoaded: root.loadColorFile()
        onFileChanged: root.scheduleReload()
    }

    property FileView noctaliaSettings: FileView {
        path: root.noctaliaConfigDir + "/settings.json"
        preload: true
        watchChanges: true
        printErrors: false
        onLoaded: root.loadSettingsFile()
        onFileChanged: root.scheduleReload()
    }

    property FileView noctaliaDirectoryWatcher: FileView {
        path: root.noctaliaConfigDir
        watchChanges: true
        printErrors: false
        onFileChanged: root.scheduleReload()
    }
}
