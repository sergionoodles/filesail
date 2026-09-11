import QtQuick

// Thin host adapter around the shared FileSailView control surface. It owns the
// opaque external ID for exactly the lifetime of the browser view.
QtObject {
    id: root

    required property var view
    property string hostKind: "unknown"
    property string label: ""
    property bool hostVisible: true
    property bool focusKnown: false
    property bool focused: false
    property string windowId: ""
    property int revision: 1
    property string activeRequestId: ""
    property string activeMethod: ""
    property string navigationTarget: ""
    property string preferenceValue: ""
    property bool applyingPreference: false
    property bool applyingPreview: false
    property bool registered: false

    readonly property var session: view ? view.browserSession : null
    readonly property bool ready: session !== null && !session.directory.loading
                                 && session.directory.error.length === 0

    signal stateChanged(string kind)
    signal requestFinished(string requestId, bool ok, string code, string message, var data)

    function bump(kind) {
        revision++;
        stateChanged(kind);
    }

    function stateSnapshot() {
        const selectedAll = session ? Object.keys(session.selectedPaths) : [];
        const selected = selectedAll.slice(0, 64);
        const unavailable = view ? view.controlPreviewUnavailableReason : "window_unavailable";
        return {
            window: windowId,
            hostKind,
            label,
            ready,
            visible: hostVisible,
            focus: focusKnown ? (focused ? "focused" : "unfocused") : "unknown",
            revision,
            path: session ? session.directory.path : "",
            pendingPath: session && session.directory.loading ? session.directory.requestedPath : "",
            loading: session ? session.directory.loading : false,
            error: session ? session.directory.error : "",
            selection: {
                paths: selected,
                primary: session ? session.primarySelectionPath : "",
                count: selectedAll.length,
                truncated: selectedAll.length > selected.length
            },
            navigation: {
                canGoBack: session ? session.navigation.canGoBack : false,
                canGoForward: session ? session.navigation.canGoForward : false
            },
            view: {
                filter: session ? session.directory.filter : "",
                showHidden: Settings.showHidden,
                sortBy: session ? session.directory.sortBy : Settings.sortBy,
                descending: session ? session.directory.descending : Settings.descending,
                foldersFirst: session ? session.directory.foldersFirst : Settings.foldersFirst,
                mode: Settings.viewMode,
                preferenceScope: "host-shared"
            },
            modal: { active: view ? view.modalActive : false },
            preview: {
                requestedVisible: Settings.previewPaneEnabled,
                actualVisible: view ? view.controlPreviewActualVisible : false,
                providerReadiness: unavailable.length === 0
                    ? view.controlPreviewReadiness : "unavailable",
                unavailableReason: unavailable.length > 0 ? unavailable : view.controlPreviewError,
                readinessReporting: view && (view.previewSource.toString().length > 0 || view.previewComponent)
                    ? "provider-dependent" : "built-in"
            }
        };
    }

    function entriesPage(params) {
        const limit = Math.max(1, Math.min(500, Number(params.limit ?? 100)));
        const snapshotRevision = session.directory.revision;
        let offset = Math.max(0, Number(params.offset ?? 0));
        if (params.cursor) {
            const parts = String(params.cursor).split(":");
            if (parts.length !== 2 || Number(parts[0]) !== snapshotRevision)
                return { ok: false, code: "stale_cursor", message: "Entry cursor belongs to an older snapshot" };
            offset = Math.max(0, Number(parts[1]));
        }
        const entries = [];
        let approximateBytes = 256;
        const maximumBytes = ControlRouter.maximumResultBytes;
        while (offset + entries.length < session.directory.entries.length
                && entries.length < limit) {
            const entry = session.directory.entries[offset + entries.length];
            const entryBytes = ControlRouter.utf8Bytes(JSON.stringify(entry)) + 1;
            if (entries.length > 0 && approximateBytes + entryBytes > maximumBytes)
                break;
            entries.push(entry);
            approximateBytes += entryBytes;
        }
        const nextOffset = offset + entries.length;
        return {
            ok: true,
            revision,
            snapshotRevision,
            path: session.directory.path,
            offset,
            entries,
            nextCursor: nextOffset < session.directory.entries.length
                ? `${snapshotRevision}:${nextOffset}` : ""
        };
    }

    function finish(ok, code, message, data) {
        if (!activeRequestId)
            return;
        const requestId = activeRequestId;
        activeRequestId = "";
        activeMethod = "";
        navigationTarget = "";
        preferenceValue = "";
        requestFinished(requestId, ok, code, message, data ?? {});
    }

    function beginNavigation(requestId, method, path) {
        if (view.modalActive) {
            requestFinished(requestId, false, "requires_user_input", "A modal dialog is active", {});
            return;
        }
        activeRequestId = requestId;
        activeMethod = method;
        navigationTarget = path;
        if (method === "navigate") {
            if (path === session.directory.path && !session.directory.loading) {
                Qt.callLater(() => root.finish(true, "", "", { path: session.directory.path, noOp: true }));
                return;
            }
            session.navigate(path, "control");
        } else if (method === "back") {
            if (!session.navigation.canGoBack) {
                Qt.callLater(() => root.finish(true, "", "", { path: session.directory.path, noOp: true }));
                return;
            }
            session.goBack("control");
        } else if (method === "forward") {
            if (!session.navigation.canGoForward) {
                Qt.callLater(() => root.finish(true, "", "", { path: session.directory.path, noOp: true }));
                return;
            }
            session.goForward("control");
        } else if (method === "up") {
            if (session.directory.path === "/") {
                Qt.callLater(() => root.finish(true, "", "", { path: "/", noOp: true }));
                return;
            }
            session.goUp("control");
        } else {
            session.directory.refresh("refresh");
        }
    }

    function applySelection(requestId, params) {
        if (view.modalActive) {
            requestFinished(requestId, false, "requires_user_input", "A modal dialog is active", {});
            return;
        }
        const paths = Array.isArray(params.paths) ? params.paths
            : (typeof params.path === "string" ? [params.path] : []);
        if (paths.length === 0 || !paths.every(path => typeof path === "string" && path[0] === "/")) {
            requestFinished(requestId, false, "invalid_path", "Selection requires absolute paths", {});
            return;
        }
        for (const path of paths) {
            if (session.visibleIndex(path) < 0) {
                requestFinished(requestId, false, "item_not_visible", `Item is not visible: ${path}`, {});
                return;
            }
        }
        const mode = String(params.mode ?? "replace");
        if (["replace", "add", "remove"].indexOf(mode) < 0) {
            requestFinished(requestId, false, "invalid_request", "Selection mode must be replace, add, or remove", {});
            return;
        }
        if (mode === "remove") {
            const next = Object.keys(session.selectedPaths).filter(path => paths.indexOf(path) < 0);
            session.setSelection(next, false, String(params.primary ?? next[0] ?? ""), undefined, "control");
        } else {
            const primary = String(params.primary ?? paths[0]);
            if (paths.indexOf(primary) < 0 && !(mode === "add" && session.selectedPaths[primary])) {
                requestFinished(requestId, false, "invalid_request", "Primary path must be selected", {});
                return;
            }
            session.setSelection(paths, mode === "add", primary, undefined, "control");
        }
        requestFinished(requestId, true, "", "", { selection: stateSnapshot().selection });
    }

    function clearSelection(requestId) {
        if (view.modalActive) {
            requestFinished(requestId, false, "requires_user_input", "A modal dialog is active", {});
            return;
        }
        session.clearSelection("control");
        requestFinished(requestId, true, "", "", { selection: stateSnapshot().selection });
    }

    function setPreview(requestId, show) {
        if (view.modalActive) {
            requestFinished(requestId, false, "requires_user_input", "A modal dialog is active", {});
            return;
        }
        applyingPreview = true;
        Settings.setPreviewPaneEnabled(show);
        applyingPreview = false;
        const preview = stateSnapshot().preview;
        if (!show) {
            requestFinished(requestId, true, "", "", { preview, preferenceScope: "host-shared" });
            return;
        }
        if (!preview.actualVisible || ["unavailable", "unsupported", "error"].indexOf(preview.providerReadiness) >= 0) {
            requestFinished(requestId, false, "preview_unavailable",
                            `Preview is unavailable: ${preview.unavailableReason}`, { preview });
            return;
        }
        if (preview.providerReadiness === "loading") {
            activeRequestId = requestId;
            activeMethod = "preview.show";
            return;
        }
        requestFinished(requestId, true, "", "", { preview, preferenceScope: "host-shared" });
    }

    function setPreference(requestId, method, params) {
        if (view.modalActive) {
            requestFinished(requestId, false, "requires_user_input", "A modal dialog is active", {});
            return;
        }
        if (method === "filter") {
            const value = String(params.value ?? "");
            if (session.directory.filter === value) {
                requestFinished(requestId, true, "", "", { view: stateSnapshot().view, preferenceScope: "window" });
                return;
            }
            activeRequestId = requestId;
            activeMethod = method;
            preferenceValue = value;
            session.directory.filter = value;
            return;
        } else if (method === "hidden") {
            const value = params.show === true;
            if (Settings.showHidden === value) {
                requestFinished(requestId, true, "", "", { view: stateSnapshot().view, preferenceScope: "host-shared" });
                return;
            }
            activeRequestId = requestId;
            activeMethod = method;
            preferenceValue = value ? "true" : "false";
            applyingPreference = true;
            Settings.setShowHidden(value);
            applyingPreference = false;
            return;
        } else if (method === "viewMode") {
            applyingPreference = true;
            Settings.setViewMode(String(params.mode ?? "list"));
            applyingPreference = false;
        }
        else if (method === "sort") {
            applyingPreference = true;
            session.setSort(String(params.field ?? "name"), params.descending === true);
            if (params.foldersFirst !== undefined)
                session.setFoldersFirst(params.foldersFirst === true);
            applyingPreference = false;
        }
        requestFinished(requestId, true, "", "", {
            view: stateSnapshot().view,
            preferenceScope: method === "filter" ? "window" : "host-shared"
        });
    }

    property Connections sessionConnections: Connections {
        target: root.session
        function onInteraction(kind, origin) {
            if (origin === "user" && root.activeRequestId
                    && (kind === "navigation" || kind === "selection"))
                root.finish(false, "superseded", "User interaction superseded the control request", {});
        }
        function onSelectionRevisionChanged() { root.bump("selection"); }
    }

    property Connections directoryConnections: Connections {
        target: root.session ? root.session.directory : null
        function onLoaded(path, navigation) {
            root.bump("directory");
            if (root.activeRequestId && root.activeMethod === "hidden") {
                root.finish(true, "", "", { view: root.stateSnapshot().view, preferenceScope: "host-shared" });
                return;
            }
            if (root.activeRequestId && (root.activeMethod === "refresh"
                    || root.navigationTarget.length === 0 || path === root.navigationTarget))
                root.finish(true, "", "", { path });
        }
        function onLoadFailed(message) {
            root.bump("directory");
            if (root.activeRequestId)
                root.finish(false, "invalid_path", message, { path: root.session.directory.path });
        }
        function onLargeDirectoryWarning(path, entryCountAtLeast) {
            root.bump("modal");
            if (root.activeRequestId)
                root.finish(false, "requires_user_input", "Large directory confirmation is required",
                            { path, entryCountAtLeast });
        }
        function onRevisionChanged() {
            root.bump("entries");
            if (root.activeRequestId && root.activeMethod === "filter"
                    && root.session.directory.filter === root.preferenceValue)
                root.finish(true, "", "", { view: root.stateSnapshot().view, preferenceScope: "window" });
        }
        function onFilterChanged() {
            if (root.activeRequestId && root.activeMethod === "filter"
                    && root.session.directory.filter !== root.preferenceValue)
                root.finish(false, "superseded", "User filtering superseded the control request", {});
        }
        function onLoadingChanged() { root.bump("loading"); }
        function onErrorChanged() { root.bump("error"); }
    }

    property Connections settingsConnections: Connections {
        target: Settings
        function onPreviewPaneEnabledChanged() {
            root.bump("preview");
            if (!root.applyingPreview && root.activeRequestId && root.activeMethod === "preview.show"
                    && !Settings.previewPaneEnabled)
                root.finish(false, "superseded", "A user preference change superseded the preview request", {});
        }
        function onShowHiddenChanged() {
            root.bump("preference");
            if (!root.applyingPreference && root.activeRequestId && root.activeMethod === "hidden"
                    && String(Settings.showHidden) !== root.preferenceValue)
                root.finish(false, "superseded", "A preference change superseded the control request", {});
        }
        function onViewModeChanged() { root.bump("preference"); }
        function onSortByChanged() { root.bump("preference"); }
        function onDescendingChanged() { root.bump("preference"); }
        function onFoldersFirstChanged() { root.bump("preference"); }
    }

    property Connections previewConnections: Connections {
        target: root.view
        function onControlPreviewReadinessChanged() {
            if (!root.activeRequestId || root.activeMethod !== "preview.show")
                return;
            const preview = root.stateSnapshot().preview;
            if (preview.providerReadiness === "loading")
                return;
            if (["ready", "unknown"].indexOf(preview.providerReadiness) >= 0)
                root.finish(true, "", "", { preview, preferenceScope: "host-shared" });
            else
                root.finish(false, "preview_unavailable", `Preview is unavailable: ${preview.unavailableReason}`, { preview });
        }
        function onControlPreviewUnavailableReasonChanged() {
            if (!root.activeRequestId || root.activeMethod !== "preview.show")
                return;
            const preview = root.stateSnapshot().preview;
            if (preview.unavailableReason.length > 0)
                root.finish(false, "preview_unavailable", `Preview is unavailable: ${preview.unavailableReason}`, { preview });
        }
        function onModalActiveChanged() {
            root.bump("modal");
        }
    }

    onHostVisibleChanged: bump("visibility")
    onLabelChanged: bump("label")

    Component.onCompleted: ControlRouter.registerWindow(root)
    Component.onDestruction: ControlRouter.unregisterWindow(root)
}
