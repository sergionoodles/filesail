import QtQuick
import Quickshell

QtObject {
    id: root

    property string initialPath: String(Quickshell.env("HOME") ?? "/")
    property var initialSelectionPaths: []
    property bool initialSelectionApplied: false
    property var selectedPaths: ({})
    property string primarySelectionPath: ""
    property string focusedPath: ""
    property string selectionAnchorPath: ""
    property var selectedEntries: []
    property int selectionRevision: 0
    readonly property var clipboardPaths: FileClipboard.paths
    readonly property string clipboardMode: FileClipboard.mode
    readonly property int clipboardRevision: FileClipboard.generation
    property int pendingHistoryTarget: 0
    property var activeOperations: ({})
    property bool backendSessionAcquired: false
    property bool sessionAlive: true
    property bool clipboardSessionAcquired: false
    property var preparedMountPoints: []
    readonly property int selectedCount: Object.keys(selectedPaths).length
    readonly property alias directory: directoryModel
    readonly property alias navigation: navigationController

    signal noticeRequested(string message, bool error)
    signal largeDirectoryWarningRequested(string path, int entryCountAtLeast)
    signal interaction(string kind, string origin)

    function navigate(path, origin) {
        navigationController.navigate(path, origin);
    }

    function goBack(origin) { navigationController.back(origin); }
    function goForward(origin) { navigationController.forward(origin); }
    function goUp(origin) { navigationController.up(origin); }

    function loadLargeDirectory(path) {
        directoryModel.loadLargeDirectory(path);
    }

    function clearSelection(origin) {
        selectedPaths = ({});
        primarySelectionPath = "";
        selectionAnchorPath = "";
        updateSelectedEntries();
        interaction("selection", String(origin ?? "user"));
    }

    function resetFocus() {
        focusedPath = directoryModel.entries.length > 0 ? directoryModel.entries[0].path : "";
        clearSelection("internal");
    }

    function removeFromSelection(paths) {
        const next = Object.assign({}, selectedPaths);
        for (const path of paths)
            delete next[path];
        selectedPaths = next;
        primarySelectionPath = next[primarySelectionPath]
            ? primarySelectionPath : Object.keys(next)[0] ?? "";
        if (!next[selectionAnchorPath])
            selectionAnchorPath = primarySelectionPath;
        updateSelectedEntries();
    }

    function reconcileSelection() {
        const available = {};
        for (const entry of directoryModel.sourceEntries)
            available[entry.path] = true;
        const next = {};
        for (const path of Object.keys(selectedPaths)) {
            if (available[path])
                next[path] = true;
        }
        selectedPaths = next;
        primarySelectionPath = next[primarySelectionPath]
            ? primarySelectionPath : Object.keys(next)[0] ?? "";
        if (!next[selectionAnchorPath])
            selectionAnchorPath = primarySelectionPath;
        updateSelectedEntries();
    }

    function select(path, modifiers) {
        selectEntry(path, modifiers);
    }

    function visibleIndex(path) {
        for (let index = 0; index < directoryModel.entries.length; ++index) {
            if (directoryModel.entries[index].path === path)
                return index;
        }
        return -1;
    }

    function setSelection(paths, additive, anchorPath, basePaths, origin) {
        const next = additive
            ? Object.assign({}, basePaths ? basePaths.reduce((result, path) => {
                result[path] = true;
                return result;
            }, {}) : selectedPaths)
            : {};
        for (const path of paths ?? [])
            next[path] = true;
        selectedPaths = next;
        const visibleAnchor = anchorPath && visibleIndex(anchorPath) >= 0 ? anchorPath : "";
        primarySelectionPath = visibleAnchor && next[visibleAnchor]
            ? visibleAnchor : Object.keys(next)[0] ?? "";
        if (visibleAnchor) {
            focusedPath = visibleAnchor;
            selectionAnchorPath = visibleAnchor;
        }
        updateSelectedEntries();
        interaction("selection", String(origin ?? "user"));
    }

    function selectRange(anchorPath, targetPath, additive) {
        const targetIndex = visibleIndex(targetPath);
        const anchorIndex = visibleIndex(anchorPath);
        if (targetIndex < 0)
            return;
        if (anchorIndex < 0) {
            setSelection([targetPath], additive, targetPath);
            return;
        }
        const first = Math.min(anchorIndex, targetIndex);
        const last = Math.max(anchorIndex, targetIndex);
        const paths = [];
        for (let index = first; index <= last; ++index)
            paths.push(directoryModel.entries[index].path);
        setSelection(paths, additive, targetPath);
    }

    function selectEntry(path, modifiers) {
        if (visibleIndex(path) < 0)
            return;
        const shift = (modifiers & Qt.ShiftModifier) !== 0;
        const additive = (modifiers & Qt.ControlModifier) !== 0;
        focusedPath = path;
        if (shift) {
            selectRange(selectionAnchorPath || path, path, additive);
            return;
        }
        if (additive) {
            const next = Object.assign({}, selectedPaths);
            if (next[path])
                delete next[path];
            else
                next[path] = true;
            selectedPaths = next;
            primarySelectionPath = next[path] ? path : Object.keys(next)[0] ?? "";
            selectionAnchorPath = path;
            updateSelectedEntries();
            interaction("selection", "user");
            return;
        }
        setSelection([path], false, path);
    }

    function moveFocus(path, modifiers) {
        if (visibleIndex(path) < 0)
            return;
        focusedPath = path;
        const shift = (modifiers & Qt.ShiftModifier) !== 0;
        const additive = (modifiers & Qt.ControlModifier) !== 0;
        if (shift)
            selectRange(selectionAnchorPath || path, path, additive);
        else if (!additive)
            setSelection([path], false, path);
    }

    function toggleFocusedEntry() {
        if (focusedPath)
            selectEntry(focusedPath, Qt.ControlModifier);
    }

    function selectAllVisible() {
        const paths = directoryModel.entries.map(entry => entry.path);
        setSelection(paths, false, focusedPath || paths[0] || "");
    }

    function setSort(field, isDescending) {
        const normalized = ["name", "size", "modified"].indexOf(field) >= 0 ? field : "name";
        directoryModel.sortBy = normalized;
        directoryModel.descending = isDescending === true;
        Settings.setSortBy(normalized);
        Settings.setDescending(isDescending === true);
    }

    function toggleSort(field) {
        setSort(field, directoryModel.sortBy === field ? !directoryModel.descending : false);
    }

    function setFoldersFirst(value) {
        directoryModel.foldersFirst = value === true;
        Settings.setFoldersFirst(value === true);
    }

    // Directory order is the only stable order shared by list and grid views.
    // Entries are retained by reference from the current immutable snapshot.
    function updateSelectedEntries() {
        const ordered = directoryModel.entries.filter(entry => selectedPaths[entry.path]);
        const visiblePaths = {};
        for (const entry of ordered)
            visiblePaths[entry.path] = true;
        for (const entry of directoryModel.sourceEntries) {
            if (selectedPaths[entry.path] && !visiblePaths[entry.path])
                ordered.push(entry);
        }
        selectedEntries = ordered;
        selectionRevision++;
    }

    function openEntry(path, isDirectory) {
        if (isDirectory)
            navigationController.navigate(path);
        else
            runOperation("open", { path }, false, "Opened with the default application");
    }

    function runOperation(method, params, refreshAfter, successMessage, clearSelectionOnSuccess) {
        const originPath = directoryModel.path;
        const selectionSnapshot = Object.keys(selectedPaths);
        const operationPaths = Array.isArray(params.paths)
            ? params.paths.slice() : params.path ? [params.path] : [];
        let operationId = -1;
        const detach = () => {
            if (!root.sessionAlive || operationId < 0)
                return;
            const operations = Object.assign({}, root.activeOperations);
            delete operations[operationId];
            root.activeOperations = operations;
        };
        const succeeded = result => {
            detach();
            if (!root.sessionAlive)
                return;
            if (refreshAfter && directoryModel.path === originPath)
                directoryModel.refresh("refresh");
            if ((clearSelectionOnSuccess ?? true) && directoryModel.path === originPath)
                root.removeFromSelection(selectionSnapshot);
            root.noticeRequested(successMessage, false);
        };
        const failed = (message, result) => {
            detach();
            if (!root.sessionAlive)
                return;
            const completed = result && result.completed ? result.completed.length : 0;
            const partial = result && result.partial ? result.partial.length : 0;
            const recovery = result && result.recovery ? result.recovery.length : 0;
            const cancelled = result && result.errorCode === "cancelled";
            const changed = completed;
            let suffix = completed > 0
                ? ` (${completed} item(s) completed before the error)` : "";
            if (partial > 0)
                suffix += ` (${partial} destination(s) committed, but source cleanup failed)`;
            if (recovery > 0)
                suffix += ` (${recovery} item(s) need recovery; see backend details)`;
            if ((changed > 0 || cancelled || recovery > 0) && refreshAfter
                    && directoryModel.path === originPath) {
                directoryModel.refresh("refresh");
            }
            if (changed > 0 && directoryModel.path === originPath) {
                root.removeFromSelection(operationPaths.slice(0, changed));
            }
            if (cancelled) {
                const label = method === "copy" ? qsTr("Copy")
                    : method === "move" ? qsTr("Cut")
                    : method === "trash" ? qsTr("Remove") : qsTr("Operation");
                root.noticeRequested(qsTr("%1 cancelled; %2 item(s) completed")
                    .arg(label).arg(completed) + suffix, false);
            } else {
                root.noticeRequested(message + suffix, true);
            }
        };
        const summary = operationPaths.length > 0
            ? `${operationPaths.length} path(s)` : JSON.stringify(params);
        Logger.info("operation", `${method} ${summary}`);
        const succeededLogged = result => {
            Logger.info("operation", `${method} succeeded`);
            succeeded(result);
        };
        const failedLogged = (message, result) => {
            Logger.warn("operation", `${method} failed: ${message}`);
            failed(message, result);
        };
        if (method === "open")
            operationId = BackendClient.openPath(params.path, succeededLogged, failedLogged);
        else if (method === "terminal")
            operationId = BackendClient.openTerminal(params.path, succeededLogged, failedLogged);
        else if (method === "mkdir")
            operationId = BackendClient.createDirectory(params.parent, params.name, succeededLogged, failedLogged);
        else if (method === "rename")
            operationId = BackendClient.renamePath(params.path, params.name, succeededLogged, failedLogged);
        else if (method === "copy")
            operationId = BackendClient.copyPaths(params.paths, params.targetDirectory, succeededLogged, failedLogged);
        else if (method === "move")
            operationId = BackendClient.movePaths(params.paths, params.targetDirectory, succeededLogged, failedLogged);
        else if (method === "trash")
            operationId = BackendClient.trashPaths(params.paths, succeededLogged, failedLogged);
        else if (method === "setExecutable")
            operationId = BackendClient.setExecutable(params.path, params.executable, succeededLogged, failedLogged);
        else
            operationId = BackendClient.performOperation(method, params, succeededLogged, failedLogged);
        if (operationId >= 0) {
            const operations = Object.assign({}, activeOperations);
            operations[operationId] = method;
            activeOperations = operations;
        }
        return operationId;
    }

    function copySelection(mode) {
        if (selectedCount === 0)
            return;
        const paths = Object.keys(selectedPaths);
        FileClipboard.publish(paths, mode === "move" ? "cut" : "copy", () => {
            root.noticeRequested(mode === "move" ? "Ready to cut selection" : "Copied selection", false);
        }, message => root.noticeRequested(message, true));
    }

    function paste(destination) {
        const target = String(destination ?? directoryModel.path);
        FileClipboard.beginPaste(target, (operationId, record) => {
            const next = Object.assign({}, root.activeOperations);
            next[operationId] = record.mode === "cut" ? "move" : "copy";
            root.activeOperations = next;
        }, (result, success, record) => {
            if (!root.sessionAlive)
                return;
            const next = Object.assign({}, root.activeOperations);
            delete next[record.operationId];
            root.activeOperations = next;
            const completed = result && result.ok ? record.paths.length
                : Array.isArray(result?.completed) ? result.completed.length : 0;
            if (directoryModel.path === record.destination) {
                directoryModel.refresh("refresh");
                if (completed > 0)
                    root.removeFromSelection(record.paths.slice(0, completed));
            }
            if (success)
                root.noticeRequested(record.mode === "cut" ? "Moved into this folder" : "Copied into this folder", false);
            else if (result.errorCode === "cancelled")
                root.noticeRequested(`${record.mode === "cut" ? "Cut" : "Copy"} cancelled; ${completed} item(s) completed`, false);
            else
                root.noticeRequested(result.error ?? "Paste failed", true);
        }, message => root.noticeRequested(message, true));
    }

    function pathInMounts(path, mountPoints) {
        return (mountPoints ?? []).some(mount => VolumeModel.isWithin(path, mount));
    }

    function prepareMountRemoval(mountPoints) {
        if (!pathInMounts(directoryModel.path, mountPoints)
                && !pathInMounts(directoryModel.requestedPath, mountPoints))
            return;
        preparedMountPoints = mountPoints.slice();
        directoryModel.pauseForRemoval();
        clearSelection("internal");
        PreviewManager.advanceGeneration();
    }

    function finishMountRemoval(mountPoints, success, unexpected) {
        const affected = pathInMounts(directoryModel.path, mountPoints)
                      || pathInMounts(directoryModel.requestedPath, mountPoints);
        if (success) {
            navigationController.pruneMountPoints(mountPoints);
            preparedMountPoints = [];
            if (affected) {
                directoryModel.removalPaused = false;
                pendingHistoryTarget = -1;
                directoryModel.setPath(navigationController.homePath);
                if (unexpected)
                    noticeRequested(qsTr("A drive was disconnected. FileSail moved this window to Home."), true);
            } else {
                directoryModel.resumeAfterRemoval();
            }
        } else {
            preparedMountPoints = [];
            directoryModel.resumeAfterRemoval();
        }
    }

    property NavigationController navigationObject: NavigationController {
        id: navigationController
        initialPath: root.initialPath
        onNavigationRequested: (path, historyTarget, origin) => {
            root.interaction("navigation", origin);
            root.pendingHistoryTarget = historyTarget;
            directoryModel.setPath(path);
        }
    }

    property DirectoryModel directoryObject: DirectoryModel {
        id: directoryModel
        path: root.initialPath
        onLoaded: (path, navigation) => {
            if (!root.initialSelectionApplied && root.initialSelectionPaths.length > 0) {
                root.setSelection(root.initialSelectionPaths, false, root.initialSelectionPaths[0], undefined, "internal");
                root.initialSelectionApplied = true;
            }
            if (navigation) {
                navigationController.commit(path, root.pendingHistoryTarget);
                root.pendingHistoryTarget = -1;
                root.resetFocus();
            } else {
                root.reconcileSelection();
                if (!root.focusedPath || root.visibleIndex(root.focusedPath) < 0)
                    root.focusedPath = root.directory.entries.length > 0
                        ? root.directory.entries[0].path : "";
            }
        }
        onLoadFailed: message => root.pendingHistoryTarget = -1
        onLargeDirectoryWarning: (path, entryCountAtLeast) => {
            root.pendingHistoryTarget = -1;
            root.largeDirectoryWarningRequested(path, entryCountAtLeast);
        }
        onUnsafeEntriesSkipped: count => root.noticeRequested(
            `${count} item(s) were hidden because their names are unsafe in the current locale`, true)
    }

    property Connections volumeConnections: Connections {
        target: VolumeModel
        function onRemovalPreparing(mountPoints) { root.prepareMountRemoval(mountPoints); }
        function onRemovalFinished(mountPoints, success) { root.finishMountRemoval(mountPoints, success, false); }
        function onMountPointsLost(mountPoints, expected, disconnected) {
            if (!expected && root.pathInMounts(root.directory.path, mountPoints)) {
                root.prepareMountRemoval(mountPoints);
                root.finishMountRemoval(mountPoints, true, disconnected);
            }
        }
    }

    Component.onCompleted: {
        BackendClient.acquireSession();
        backendSessionAcquired = true;
        FileClipboard.acquireSession();
        clipboardSessionAcquired = true;
    }

    Component.onDestruction: {
        sessionAlive = false;
        for (const id of Object.keys(activeOperations)) {
            // A committed mutation owns an independent backend lease and must
            // finish after its initiating browser is closed. Read/preview
            // requests are safe to cancel with the session.
            if (!BackendClient.isMutation(activeOperations[id]))
                BackendClient.cancel(Number(id));
        }
        activeOperations = ({});
        if (backendSessionAcquired) {
            BackendClient.releaseSession();
            backendSessionAcquired = false;
        }
        if (clipboardSessionAcquired) {
            FileClipboard.releaseSession();
            clipboardSessionAcquired = false;
        }
    }
}
