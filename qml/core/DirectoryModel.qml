import QtQuick
import Quickshell

QtObject {
    id: root

    property string path: String(Quickshell.env("HOME") ?? "/")
    property string requestedPath: path
    property string canonicalPath: path
    property string parentPath: "/"
    property bool showHidden: Settings.showHidden
    property string filter: ""
    property string sortBy: Settings.sortBy
    property bool descending: Settings.descending
    property bool foldersFirst: Settings.foldersFirst
    property bool loading: false
    property string error: ""
    property int activeRequest: -1
    property string activeLoadKind: "refresh"
    property bool refreshDirty: false
    property string dirtyLoadKind: "refresh"
    property string watchedPath: ""
    property string pendingWatchPath: ""
    property int pendingWatchRequest: -1
    property bool watchLeaseActive: false
    property int revision: 0
    property string acceptedLargeDirectoryPath: ""
    property var folderContext: ({ version: 1, signals: [] })
    // The backend response is already a parsed, immutable generation. The
    // visible array only contains references to those entry objects; no
    // ListModel proxy or per-entry dictionary is created.
    property var sourceEntries: []
    property var entries: []
    property var pathIndexes: ({})
    readonly property int count: entries.length

    signal loaded(string path, bool navigation)
    signal loadFailed(string message)
    signal largeDirectoryWarning(string path, int entryCountAtLeast)
    signal unsafeEntriesSkipped(int count)

    function applyView() {
        const query = filter.trim();
        const visible = query.length === 0 ? sourceEntries.slice() : sourceEntries.filter(entry =>
            entry.name.toLowerCase().indexOf(query.toLowerCase()) >= 0);
        visible.sort((left, right) => {
            if (foldersFirst && left.isDirectory !== right.isDirectory)
                return left.isDirectory ? -1 : 1;
            let comparison = 0;
            if (sortBy === "size")
                comparison = left.size - right.size;
            else if (sortBy === "modified")
                comparison = String(left.modified).localeCompare(String(right.modified));
            else if (sortBy === "type")
                comparison = (left.isDirectory ? "" : String(left.name).split(".").pop())
                    .localeCompare(right.isDirectory ? "" : String(right.name).split(".").pop());
            else
                comparison = String(left.name).localeCompare(String(right.name));
            if (comparison === 0 && sortBy !== "name")
                comparison = String(left.name).localeCompare(String(right.name));
            return descending ? -comparison : comparison;
        });
        entries = visible;
        revision++;
    }

    function subscribe(nextPath) {
        if (!nextPath || watchedPath === nextPath || pendingWatchPath === nextPath) return;
        pendingWatchPath = nextPath;
        let requestId = -1;
        requestId = BackendClient.watchDirectory(nextPath, result => {
            if (requestId !== root.pendingWatchRequest) return;
            root.pendingWatchRequest = -1;
            root.pendingWatchPath = "";
            if (root.path === nextPath) {
                root.watchedPath = nextPath;
                root.watchLeaseActive = true;
                Logger.debug("directory", `watch acquire ${nextPath}`);
            }
            else BackendClient.unwatchDirectory(nextPath);
        }, message => {
            if (requestId !== root.pendingWatchRequest) return;
            root.pendingWatchRequest = -1;
            root.pendingWatchPath = "";
        });
        pendingWatchRequest = requestId;
    }

    function unsubscribe() {
        const subscribed = watchedPath;
        const pending = pendingWatchPath;
        watchedPath = "";
        if (watchLeaseActive && subscribed.length > 0)
            Logger.debug("directory", `watch release ${subscribed}`);
        watchLeaseActive = false;
        pendingWatchPath = "";
        if (pendingWatchRequest >= 0) { BackendClient.cancel(pendingWatchRequest); pendingWatchRequest = -1; }
        if (BackendClient.available && subscribed.length > 0) BackendClient.unwatchDirectory(subscribed);
        if (BackendClient.available && pending.length > 0 && pending !== subscribed) BackendClient.unwatchDirectory(pending);
    }

    function refresh(loadKind, allowLargeDirectory) {
        const kind = requestedPath !== path ? "navigation" : loadKind ?? "refresh";
        // Coalesce watcher, UI, and mutation refreshes. A second listing is
        // started only after the active one has published or been canceled.
        if (activeRequest >= 0) {
            refreshDirty = true;
            dirtyLoadKind = kind === "navigation" ? "navigation" : dirtyLoadKind;
            return;
        }
        watcherDelay.stop();
        const allowLarge = allowLargeDirectory === true || requestedPath === acceptedLargeDirectoryPath;
        loading = true;
        error = "";
        activeLoadKind = kind;
        let requestId = -1;
        requestId = BackendClient.listDirectory({
            path: requestedPath, showHidden, allowLargeDirectory: allowLarge,
            // Filtering and sorting are local operations on the current
            // snapshot; the backend scans only when the directory changes.
            filter: "", sortBy: "name", descending: false, includeContext: true
        }, result => {
            if (requestId !== root.activeRequest) return;
            root.activeRequest = -1;
            root.loading = false;
            const stale = result.path !== root.requestedPath;
            if (stale || root.refreshDirty) {
                root.refreshDirty = false;
                root.refresh(root.dirtyLoadKind);
                return;
            }
            root.sourceEntries = result.entries ?? [];
            root.pathIndexes = ({});
            for (let index = 0; index < root.sourceEntries.length; ++index)
                root.pathIndexes[root.sourceEntries[index].path] = index;
            root.path = result.path;
            root.requestedPath = result.path;
            root.canonicalPath = result.path;
            root.parentPath = result.parentPath;
            root.folderContext = result.context ?? ({ version: 1, signals: [] });
            root.applyView();
            const unsafeEntryCount = Number(result.unsafeEntryCount ?? 0);
            if (unsafeEntryCount > 0) root.unsafeEntriesSkipped(unsafeEntryCount);
            root.subscribe(root.path);
            Logger.info("directory", `${root.activeLoadKind} ${root.path} (${root.count} entries)`);
            root.loaded(root.path, root.activeLoadKind === "navigation");
        }, (message, result) => {
            if (requestId !== root.activeRequest) return;
            root.activeRequest = -1;
            root.loading = false;
            if (result?.requiresConfirmation) {
                root.requestedPath = root.path;
                root.largeDirectoryWarning(result.path ?? root.path, Number(result.entryCountAtLeast ?? 0));
                return;
            }
            root.error = message;
            root.requestedPath = root.path;
            root.unsubscribe();
            root.loadFailed(message);
        });
        activeRequest = requestId;
    }

    function loadLargeDirectory(nextPath) {
        if (!nextPath) return;
        acceptedLargeDirectoryPath = nextPath;
        requestedPath = nextPath;
        refresh("navigation", true);
    }

    function setPath(nextPath) {
        if (!nextPath || nextPath === path) {
            requestedPath = path;
            refresh("refresh");
            return;
        }
        unsubscribe();
        requestedPath = nextPath;
        refresh("navigation");
    }

    onShowHiddenChanged: refresh("refresh")
    onFilterChanged: filterDelay.restart()
    onSortByChanged: applyView()
    onDescendingChanged: applyView()
    onFoldersFirstChanged: applyView()

    Component.onCompleted: refresh("navigation")
    Component.onDestruction: {
        if (activeRequest >= 0) BackendClient.cancel(activeRequest);
        unsubscribe();
    }

    property Timer filterTimer: Timer { id: filterDelay; interval: 160; onTriggered: root.applyView() }
    property Timer watcherTimer: Timer {
        id: watcherDelay
        interval: 180
        onTriggered: { root.requestedPath = root.path; root.refresh("refresh"); }
    }
    property Connections backendConnections: Connections {
        target: BackendClient
        function onBackendStopped(message) {
            watcherDelay.stop(); root.watchedPath = ""; root.watchLeaseActive = false;
            root.pendingWatchPath = ""; root.pendingWatchRequest = -1;
        }
        function onEventReceived(event, message) {
            if (event === "directoryWatchLost" && message.path === root.watchedPath) { root.watchedPath = ""; return; }
            if (event === "directoryChanged" && message.path === root.path && root.watchedPath === root.path)
                watcherDelay.restart();
        }
    }
}
