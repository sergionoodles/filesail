import QtQuick
import Quickshell

QtObject {
    id: root

    property string path: String(Quickshell.env("HOME") ?? "/")
    property string requestedPath: path
    property string canonicalPath: path
    property string parentPath: "/"
    property bool showHidden: false
    property string filter: ""
    property string sortBy: "name"
    property bool descending: false
    property bool loading: false
    property string error: ""
    property int activeRequest: -1
    property string activeLoadKind: "refresh"
    property string watchedPath: ""
    property string pendingWatchPath: ""
    property int pendingWatchRequest: -1
    property int revision: 0
    property string acceptedLargeDirectoryPath: ""
    property var folderContext: ({ version: 1, signals: [] })
    readonly property alias entries: entryModel
    readonly property int count: entryModel.count

    signal loaded(string path, bool navigation)
    signal loadFailed(string message)
    signal largeDirectoryWarning(string path, int entryCountAtLeast)
    signal unsafeEntriesSkipped(int count)

    function subscribe(path) {
        if (!path || watchedPath === path || pendingWatchPath === path)
            return;
        pendingWatchPath = path;
        let requestId = -1;
        requestId = BackendClient.watchDirectory(path, result => {
            if (requestId !== root.pendingWatchRequest)
                return;
            root.pendingWatchRequest = -1;
            root.pendingWatchPath = "";
            if (root.path === path)
                root.watchedPath = path;
            else
                BackendClient.unwatchDirectory(path);
        }, message => {
            if (requestId !== root.pendingWatchRequest)
                return;
            root.pendingWatchRequest = -1;
            root.pendingWatchPath = "";
        });
        pendingWatchRequest = requestId;
    }

    function unsubscribe() {
        const subscribed = watchedPath;
        const pending = pendingWatchPath;
        watchedPath = "";
        pendingWatchPath = "";
        if (pendingWatchRequest >= 0) {
            BackendClient.cancel(pendingWatchRequest);
            pendingWatchRequest = -1;
        }
        if (BackendClient.available && subscribed.length > 0)
            BackendClient.unwatchDirectory(subscribed);
        if (BackendClient.available && pending.length > 0 && pending !== subscribed)
            BackendClient.unwatchDirectory(pending);
    }

    function refresh(loadKind, allowLargeDirectory) {
        const kind = requestedPath !== path ? "navigation" : loadKind ?? "refresh";
        const allowLarge = allowLargeDirectory === true
            || requestedPath === acceptedLargeDirectoryPath;
        if (activeRequest >= 0)
            BackendClient.cancel(activeRequest);
        loading = true;
        error = "";
        activeLoadKind = kind;
        let requestId = -1;
        requestId = BackendClient.listDirectory({
            path: requestedPath,
            showHidden,
            filter,
            sortBy,
            descending,
            allowLargeDirectory: allowLarge,
            includeContext: true
        }, result => {
            if (requestId !== root.activeRequest)
                return;
            root.activeRequest = -1;
            root.loading = false;

            entryModel.clear();
            for (const entry of result.entries ?? [])
                entryModel.append(entry);

            root.path = result.path;
            root.requestedPath = result.path;
            root.canonicalPath = result.path;
            root.parentPath = result.parentPath;
            root.folderContext = result.context ?? ({ version: 1, signals: [] });
            root.revision++;
            const unsafeEntryCount = Number(result.unsafeEntryCount ?? 0);
            if (unsafeEntryCount > 0)
                root.unsafeEntriesSkipped(unsafeEntryCount);
            root.subscribe(root.path);
            root.loaded(root.path, root.activeLoadKind === "navigation");
        }, (message, result) => {
            if (requestId !== root.activeRequest)
                return;
            root.activeRequest = -1;
            root.loading = false;
            if (result?.requiresConfirmation) {
                root.requestedPath = root.path;
                root.largeDirectoryWarning(result.path ?? root.path,
                                           Number(result.entryCountAtLeast ?? 0));
                return;
            }
            root.error = message;
            root.requestedPath = root.path;
            root.unsubscribe();
            root.loadFailed(message);
        });
        activeRequest = requestId;
    }

    function loadLargeDirectory(path) {
        if (!path)
            return;
        acceptedLargeDirectoryPath = path;
        requestedPath = path;
        refresh("navigation", true);
    }

    function setPath(nextPath) {
        if (!nextPath || nextPath === path) {
            requestedPath = path;
            refresh("refresh");
            return;
        }
        watcherDelay.stop();
        unsubscribe();
        requestedPath = nextPath;
        refresh("navigation");
    }

    onShowHiddenChanged: refresh("refresh")
    onFilterChanged: filterDelay.restart()
    onSortByChanged: refresh("refresh")
    onDescendingChanged: refresh("refresh")

    Component.onCompleted: refresh("navigation")
    Component.onDestruction: {
        if (activeRequest >= 0)
            BackendClient.cancel(activeRequest);
        unsubscribe();
    }

    property ListModel modelStorage: ListModel { id: entryModel }

    property Timer filterTimer: Timer {
        id: filterDelay
        interval: 160
        onTriggered: root.refresh("refresh")
    }

    property Connections backendConnections: Connections {
        target: BackendClient

        function onBackendStopped(message) {
            watcherDelay.stop();
            root.watchedPath = "";
            root.pendingWatchPath = "";
            root.pendingWatchRequest = -1;
        }

        function onEventReceived(event, message) {
            if (event === "directoryWatchLost" && message.path === root.watchedPath) {
                root.watchedPath = "";
                return;
            }
            if (event === "directoryChanged" && message.path === root.path
                    && root.watchedPath === root.path)
                watcherDelay.restart();
        }
    }

    property Timer watcherTimer: Timer {
        id: watcherDelay
        interval: 180
        onTriggered: {
            root.requestedPath = root.path;
            root.refresh("refresh");
        }
    }
}
