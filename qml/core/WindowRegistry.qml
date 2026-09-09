import QtQuick
import Quickshell

// Owns standalone windows without sharing any browser state between them.
// The registry itself is deliberately small; each created window owns the
// FileSailView (and therefore its BrowserSession) independently.
QtObject {
    id: root

    required property QtObject owner
    required property Component windowComponent
    property var windows: []
    property int nextWindowId: 1
    readonly property int windowCount: windows.length
    readonly property int protocolVersion: 1

    signal windowOpened(int windowId, string path)
    signal windowClosed(int windowId)

    property Connections backendLeaseConnections: Connections {
        target: BackendClient
        function onOperationLeasesChanged() { root.quitIfIdle(); }
    }

    function normalizedPath(requested) {
        // Do not trim non-empty paths: leading/trailing spaces can be valid
        // filename bytes. The backend remains the canonical path authority.
        const value = String(requested ?? "");
        const home = String(Quickshell.env("HOME") ?? "/");
        const path = value.length === 0 ? home : value;
        if (path.length > 4096 || path.indexOf("\u0000") >= 0 || path[0] !== "/")
            return "";
        return path;
    }

    function acceptsVersion(version) {
        return String(version ?? "") === String(root.protocolVersion);
    }

    function open(requestedPath, version) {
        return root.show(requestedPath, "[]", version);
    }

    function show(requestedPath, selectionJson, version) {
        if (!root.acceptsVersion(version)) {
            Logger.warn("windows", `activation protocol mismatch: ${version}`);
            return false;
        }
        const path = root.normalizedPath(requestedPath);
        if (path.length === 0) {
            Logger.warn("windows", "activation rejected invalid local path");
            return false;
        }
        let selectionPaths = [];
        try {
            const parsed = JSON.parse(String(selectionJson ?? "[]"));
            if (!Array.isArray(parsed) || !parsed.every(item => typeof item === "string" && item[0] === "/"))
                throw new Error("selection must be an array of absolute paths");
            selectionPaths = parsed;
        } catch (error) {
            Logger.warn("windows", `activation rejected invalid selection: ${error}`);
            return false;
        }
        const windowId = root.nextWindowId++;
        const window = root.windowComponent.createObject(root.owner, {
            windowId: windowId,
            initialPath: path,
            initialSelectionPaths: selectionPaths
        });
        if (!window) {
            Logger.error("windows", `could not create window ${windowId}`);
            return false;
        }
        window.closeRequested.connect(() => root.close(window));
        window.newWindowRequested.connect(path => root.open(path, root.protocolVersion));
        root.windows = root.windows.concat([window]);
        Logger.info("windows", `opened ${windowId} path=${path} live=${root.windowCount}`);
        root.windowOpened(windowId, path);
        return true;
    }

    function close(window) {
        const index = root.windows.indexOf(window);
        if (index < 0)
            return;
        const windowId = window.windowId;
        window.beingDestroyed = true;
        const next = root.windows.slice();
        next.splice(index, 1);
        root.windows = next;
        root.windowClosed(windowId);
        window.destroy();
        Logger.info("windows", `closed ${windowId} live=${root.windowCount}`);
        root.quitIfIdle();
    }

    function quitIfIdle() {
        if (root.windowCount === 0 && BackendClient.operationLeases === 0)
            Qt.quit();
    }

    function closeAll() {
        const current = root.windows.slice();
        for (const window of current)
            root.close(window);
    }
}
