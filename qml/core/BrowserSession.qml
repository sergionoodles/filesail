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
    property var clipboardPaths: []
    property string clipboardMode: "copy"
    property int clipboardRevision: 0
    property int pendingHistoryTarget: 0
    property var activeOperations: ({})
    property bool backendSessionAcquired: false
    property bool sessionAlive: true
    readonly property int selectedCount: Object.keys(selectedPaths).length
    readonly property alias directory: directoryModel
    readonly property alias navigation: navigationController

    signal noticeRequested(string message, bool error)
    signal largeDirectoryWarningRequested(string path, int entryCountAtLeast)

    function navigate(path) {
        navigationController.navigate(path);
    }

    function loadLargeDirectory(path) {
        directoryModel.loadLargeDirectory(path);
    }

    function clearSelection() {
        selectedPaths = ({});
        primarySelectionPath = "";
        selectionAnchorPath = "";
        updateSelectedEntries();
    }

    function resetFocus() {
        focusedPath = directoryModel.entries.length > 0 ? directoryModel.entries[0].path : "";
        clearSelection();
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

    function setSelection(paths, additive, anchorPath, basePaths) {
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

    function runOperation(method, params, refreshAfter, successMessage, clearClipboardOnSuccess,
                          clearSelectionOnSuccess) {
        const originPath = directoryModel.path;
        const selectionSnapshot = Object.keys(selectedPaths);
        const operationPaths = Array.isArray(params.paths)
            ? params.paths.slice() : params.path ? [params.path] : [];
        const clipboardRevisionAtStart = clipboardRevision;
        const usesClipboard = (method === "copy" || method === "move")
            && clipboardPaths.length === operationPaths.length
            && clipboardPaths.every((path, index) => path === operationPaths[index]);
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
            if ((clearClipboardOnSuccess ?? false)
                    && root.clipboardRevision === clipboardRevisionAtStart) {
                root.clipboardPaths = [];
                root.clipboardRevision++;
            }
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
            const completed = result?.completed?.length ?? 0;
            const partial = result?.partial?.length ?? 0;
            const changed = completed + partial;
            let suffix = completed > 0
                ? ` (${completed} item(s) completed before the error)` : "";
            if (partial > 0)
                suffix += ` (${partial} destination(s) committed, but source cleanup failed)`;
            if (changed > 0 && refreshAfter && directoryModel.path === originPath) {
                directoryModel.refresh("refresh");
                root.removeFromSelection(operationPaths.slice(0, changed));
            }
            if (changed > 0 && usesClipboard
                    && root.clipboardRevision === clipboardRevisionAtStart) {
                root.clipboardPaths = operationPaths.slice(changed);
                root.clipboardRevision++;
            }
            root.noticeRequested(message + suffix, true);
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
        clipboardPaths = Object.keys(selectedPaths);
        clipboardMode = mode;
        clipboardRevision++;
        noticeRequested(mode === "move" ? "Ready to move selection" : "Copied selection", false);
    }

    function paste() {
        if (clipboardPaths.length === 0)
            return;
        runOperation(clipboardMode, {
            paths: clipboardPaths,
            targetDirectory: directoryModel.path
        }, true, clipboardMode === "move" ? "Moved into this folder" : "Copied into this folder",
        clipboardMode === "move");
    }

    property NavigationController navigationObject: NavigationController {
        id: navigationController
        initialPath: root.initialPath
        onNavigationRequested: (path, historyTarget) => {
            root.pendingHistoryTarget = historyTarget;
            directoryModel.setPath(path);
        }
    }

    property DirectoryModel directoryObject: DirectoryModel {
        id: directoryModel
        path: root.initialPath
        onLoaded: (path, navigation) => {
            if (!root.initialSelectionApplied && root.initialSelectionPaths.length > 0) {
                root.setSelection(root.initialSelectionPaths, false, root.initialSelectionPaths[0]);
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

    Component.onCompleted: {
        BackendClient.acquireSession();
        backendSessionAcquired = true;
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
    }
}
