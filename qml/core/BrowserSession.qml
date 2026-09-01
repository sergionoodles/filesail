import QtQuick
import Quickshell

QtObject {
    id: root

    property string initialPath: String(Quickshell.env("HOME") ?? "/")
    property var selectedPaths: ({})
    property string primarySelectionPath: ""
    property var clipboardPaths: []
    property string clipboardMode: "copy"
    property int clipboardRevision: 0
    property int pendingHistoryTarget: 0
    property var activeOperations: ({})
    readonly property int selectedCount: Object.keys(selectedPaths).length
    readonly property alias directory: directoryModel
    readonly property alias navigation: navigationController

    signal noticeRequested(string message, bool error)

    function navigate(path) {
        navigationController.navigate(path);
    }

    function clearSelection() {
        selectedPaths = ({});
        primarySelectionPath = "";
    }

    function removeFromSelection(paths) {
        const next = Object.assign({}, selectedPaths);
        for (const path of paths)
            delete next[path];
        selectedPaths = next;
        primarySelectionPath = next[primarySelectionPath]
            ? primarySelectionPath : Object.keys(next)[0] ?? "";
    }

    function reconcileSelection() {
        const available = {};
        for (let index = 0; index < directoryModel.count; index++)
            available[directoryModel.entries.get(index).path] = true;
        const next = {};
        for (const path of Object.keys(selectedPaths)) {
            if (available[path])
                next[path] = true;
        }
        selectedPaths = next;
        primarySelectionPath = next[primarySelectionPath]
            ? primarySelectionPath : Object.keys(next)[0] ?? "";
    }

    function select(path, modifiers) {
        const additive = (modifiers & Qt.ControlModifier) !== 0;
        const next = additive ? Object.assign({}, selectedPaths) : {};
        if (additive && next[path])
            delete next[path];
        else
            next[path] = true;
        selectedPaths = next;
        primarySelectionPath = next[path] ? path : Object.keys(next)[0] ?? "";
    }

    function openEntry(path, isDirectory) {
        if (isDirectory)
            navigationController.navigate(path);
        else
            runOperation("open", { path }, false, "Opened with the default application");
    }

    function runOperation(method, params, refreshAfter, successMessage, clearClipboardOnSuccess) {
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
            if (operationId < 0)
                return;
            const operations = Object.assign({}, root.activeOperations);
            delete operations[operationId];
            root.activeOperations = operations;
        };
        const succeeded = result => {
            detach();
            if ((clearClipboardOnSuccess ?? false)
                    && root.clipboardRevision === clipboardRevisionAtStart) {
                root.clipboardPaths = [];
                root.clipboardRevision++;
            }
            if (refreshAfter && directoryModel.path === originPath)
                directoryModel.refresh("refresh");
            if (directoryModel.path === originPath)
                root.removeFromSelection(selectionSnapshot);
            root.noticeRequested(successMessage, false);
        };
        const failed = (message, result) => {
            detach();
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
        if (method === "open")
            operationId = BackendClient.openPath(params.path, succeeded, failed);
        else if (method === "mkdir")
            operationId = BackendClient.createDirectory(params.parent, params.name, succeeded, failed);
        else if (method === "rename")
            operationId = BackendClient.renamePath(params.path, params.name, succeeded, failed);
        else if (method === "copy")
            operationId = BackendClient.copyPaths(params.paths, params.targetDirectory, succeeded, failed);
        else if (method === "move")
            operationId = BackendClient.movePaths(params.paths, params.targetDirectory, succeeded, failed);
        else if (method === "trash")
            operationId = BackendClient.trashPaths(params.paths, succeeded, failed);
        else
            operationId = BackendClient.performOperation(method, params, succeeded, failed);
        if (operationId >= 0) {
            const operations = Object.assign({}, activeOperations);
            operations[operationId] = true;
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
            if (navigation) {
                navigationController.commit(path, root.pendingHistoryTarget);
                root.pendingHistoryTarget = -1;
                root.clearSelection();
            } else {
                root.reconcileSelection();
            }
        }
        onLoadFailed: message => root.pendingHistoryTarget = -1
    }

    Component.onDestruction: {
        for (const id of Object.keys(activeOperations))
            BackendClient.cancel(Number(id));
        activeOperations = ({});
    }
}
