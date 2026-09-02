pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    readonly property string configDirectory: {
        const home = String(Quickshell.env("HOME") ?? "/");
        const configured = String(Quickshell.env("XDG_CONFIG_HOME") ?? "");
        return (configured.length > 0 ? configured : home + "/.config") + "/filesail";
    }
    readonly property string filePath: configDirectory + "/config.json"

    property bool previewPaneEnabled: false
    property bool showHidden: false
    property string viewMode: "list"
    property bool loaded: false
    property bool saveQueued: false
    property var changedBeforeLoad: ({})

    function setPreviewPaneEnabled(enabled) {
        if (previewPaneEnabled === enabled)
            return;
        previewPaneEnabled = enabled;
        markChangedBeforeLoad("previewPaneEnabled");
        queueSave();
    }

    function setShowHidden(enabled) {
        if (showHidden === enabled)
            return;
        showHidden = enabled;
        markChangedBeforeLoad("showHidden");
        queueSave();
    }

    function setViewMode(mode) {
        const normalized = mode === "grid" ? "grid" : "list";
        if (viewMode === normalized)
            return;
        viewMode = normalized;
        markChangedBeforeLoad("viewMode");
        queueSave();
    }

    function markChangedBeforeLoad(key) {
        if (loaded)
            return;
        const next = Object.assign({}, changedBeforeLoad);
        next[key] = true;
        changedBeforeLoad = next;
    }

    function applyLoadedValues() {
        if (!changedBeforeLoad.previewPaneEnabled)
            previewPaneEnabled = preferencesAdapter.previewPaneEnabled === true;
        if (!changedBeforeLoad.showHidden)
            showHidden = preferencesAdapter.showHidden === true;
        if (!changedBeforeLoad.viewMode)
            viewMode = preferencesAdapter.viewMode === "grid" ? "grid" : "list";
        loaded = true;
        if (saveQueued)
            save();
    }

    function queueSave() {
        saveQueued = true;
        if (loaded)
            save();
    }

    function save() {
        if (!loaded || directoryProcess.running || !saveQueued)
            return;
        saveQueued = false;
        preferencesAdapter.previewPaneEnabled = previewPaneEnabled;
        preferencesAdapter.showHidden = showHidden;
        preferencesAdapter.viewMode = viewMode;
        preferencesFile.writeAdapter();
    }

    property Process directoryProcess: Process {
        command: ["mkdir", "-p", root.configDirectory]
        running: true
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0)
                Logger.warn("preferences", `could not create ${root.configDirectory}`);
            if (root.saveQueued)
                root.save();
        }
    }

    property FileView preferencesFile: FileView {
        id: preferencesFile
        path: root.filePath
        preload: true
        watchChanges: false
        printErrors: false
        atomicWrites: true

        adapter: JsonAdapter {
            id: preferencesAdapter
            property int version: 1
            property bool previewPaneEnabled: false
            property bool showHidden: false
            property string viewMode: "list"
        }

        onLoaded: root.applyLoadedValues()
        onLoadFailed: {
            // Missing or malformed preferences leave the safe defaults in
            // place. They are written only after the user changes a value.
            root.loaded = true;
            if (root.saveQueued)
                root.save();
            Logger.debug("preferences", `using defaults for ${root.filePath}`);
        }
        onSaveFailed: error => Logger.warn("preferences", `could not save ${root.filePath}: ${error}`)
    }
}
