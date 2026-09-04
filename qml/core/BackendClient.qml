pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    property string backendCommand: {
        const configured = String(Quickshell.env("FILESAIL_BACKEND") ?? "");
        return configured.length > 0 ? configured : "filesail-backend";
    }
    property int nextRequestId: 1
    property var pendingLines: []
    property var pendingRequests: ({})
    property int pendingRevision: 0
    property int requestTimeout: 30000
    property bool available: backend.running
    property bool rejectingRequests: false
    property string lastError: ""
    property int sessionLeases: 0
    property int operationLeases: 0
    property bool idleHold: false
    property int idleGracePeriod: 1500
    property bool restartRequested: false
    property var operations: []
    property string operationsBackendInstance: ""
    property int operationEventSequence: 0
    property int operationsRequestId: -1
    readonly property int pendingCount: pendingRevision >= 0 ? Object.keys(pendingRequests).length : 0
    readonly property bool shouldRun: (sessionLeases > 0 || operationLeases > 0
        || pendingCount > 0 || idleHold || restartRequested)

    signal response(int id, var result)
    signal eventReceived(string event, var message)
    signal backendStopped(string message)

    function isMutation(method) {
        return method === "mkdir" || method === "rename" || method === "trash"
            || method === "copy" || method === "move" || method === "setExecutable"
            || method === "locations.add" || method === "locations.remove";
    }

    function setOperations(nextOperations) {
        operations = nextOperations.slice();
    }

    function replaceOperation(operation) {
        const nextOperations = operations.slice();
        const index = nextOperations.findIndex(item => Number(item.id) === Number(operation.id));
        if (index >= 0)
            nextOperations[index] = operation;
        else
            nextOperations.push(operation);
        nextOperations.sort((left, right) => Number(left.queueSequence) - Number(right.queueSequence));
        setOperations(nextOperations);
    }

    function removeOperation(id) {
        const nextOperations = operations.filter(operation => Number(operation.id) !== Number(id));
        if (nextOperations.length !== operations.length)
            setOperations(nextOperations);
    }

    function applyOperationEvent(message) {
        const backendInstance = String(message.backendInstance ?? "");
        const eventSequence = Number(message.eventSequence ?? 0);
        if (backendInstance && operationsBackendInstance && backendInstance !== operationsBackendInstance) {
            setOperations([]);
            operationEventSequence = 0;
        }
        if (backendInstance)
            operationsBackendInstance = backendInstance;
        if (eventSequence > 0 && eventSequence <= operationEventSequence)
            return;
        const operation = message.operation;
        if (!operation || operation.id === undefined)
            return;
        operationEventSequence = Math.max(operationEventSequence, eventSequence);
        replaceOperation(operation);
    }

    function refreshOperations() {
        if (operationsRequestId >= 0 && pendingRequests[operationsRequestId])
            return operationsRequestId;
        operationsRequestId = request("operations.list", {}, result => {
            operationsRequestId = -1;
            const backendInstance = String(result.backendInstance ?? "");
            const eventSequence = Number(result.eventSequence ?? 0);
            if (backendInstance && operationsBackendInstance && backendInstance !== operationsBackendInstance) {
                operationEventSequence = 0;
            }
            if (backendInstance)
                operationsBackendInstance = backendInstance;
            if (backendInstance === operationsBackendInstance && eventSequence < operationEventSequence)
                return;
            operationEventSequence = eventSequence;
            setOperations(Array.isArray(result.operations) ? result.operations : []);
        }, () => operationsRequestId = -1, 5000);
        return operationsRequestId;
    }

    function acquireSession() {
        sessionLeases++;
        idleHold = false;
        idleShutdownTimer.stop();
        Logger.debug("backend", `session acquire count=${sessionLeases}`);
    }

    function releaseSession() {
        sessionLeases = Math.max(0, sessionLeases - 1);
        Logger.debug("backend", `session release count=${sessionLeases}`);
        scheduleIdleShutdown();
    }

    function scheduleIdleShutdown() {
        if (sessionLeases > 0 || operationLeases > 0 || pendingCount > 0) {
            idleHold = false;
            idleShutdownTimer.stop();
            return;
        }
        if (backend.running) {
            idleHold = true;
            idleShutdownTimer.restart();
        }
    }

    function request(method, params, onSuccess, onFailure, timeout) {
        if (rejectingRequests)
            return -1;
        const id = nextRequestId++;
        const line = JSON.stringify({ id, method, params: params ?? {} }) + "\n";
        const timeoutMs = timeout === undefined ? requestTimeout : timeout;
        pendingRequests[id] = {
            method: method,
            onSuccess: onSuccess,
            onFailure: onFailure,
            deadline: timeoutMs > 0 ? Date.now() + timeoutMs : 0
        };
        if (root.isMutation(method))
            operationLeases++;
        pendingRevision++;
        Logger.debug("backend", `→ ${id} ${method}`);
        if (backend.running)
            backend.write(line);
        else {
            pendingLines.push({ id, line });
            pendingLines = pendingLines.slice();
            // `running` is bound to lease/request state. The pending request
            // above is enough to start the process and flush the line later.
        }
        return id;
    }

    function cancel(id) {
        const pending = pendingRequests[id];
        if (!pending)
            return;
        if (root.isMutation(pending.method))
            return;
        delete pendingRequests[id];
        pendingRevision++;
        if (pending.method === "thumbnailBatch" || pending.method === "textPreview"
                || pending.method === "archivePreview")
            cancelPreview(id);
        else if (pending.method === "list")
            request("cancel", { requestId: id }, null, null, 0);
        scheduleIdleShutdown();
    }

    function forget(id) {
        const pending = pendingRequests[id];
        if (!pending)
            return;
        delete pendingRequests[id];
        if (root.isMutation(pending.method))
            operationLeases = Math.max(0, operationLeases - 1);
        pendingRevision++;
        scheduleIdleShutdown();
    }

    function cancelPreview(id) {
        // Cancellation is deliberately a separate protocol operation: it can
        // never be mistaken for a filesystem mutation cancellation.
        return request("cancelPreview", { requestId: id }, null, null, 0);
    }

    function requestThumbnails(items, flavor, priority, onSuccess, onFailure) {
        return request("thumbnailBatch", { items, flavor, priority }, onSuccess, onFailure);
    }

    function requestTextPreview(path, appearance, onSuccess, onFailure) {
        return request("textPreview", { path, appearance }, onSuccess, onFailure);
    }

    function requestArchivePreview(path, onSuccess, onFailure) {
        return request("archivePreview", { path }, onSuccess, onFailure);
    }

    function requestPreviewCapabilities(onSuccess, onFailure) {
        return request("previewCapabilities", {}, onSuccess, onFailure);
    }

    function complete(message) {
        const id = message.id ?? -1;
        const pending = pendingRequests[id];
        if (!pending) {
            response(id, message);
            return;
        }
        forget(id);
        if (root.isMutation(pending.method))
            root.removeOperation(id);
        Logger.debug("backend", `← ${id} ${pending.method} ok=${!!message.ok}`);
        if (message.ok) {
            if (pending.onSuccess)
                pending.onSuccess(message);
        } else if (pending.onFailure) {
            pending.onFailure(message.error ?? "Unknown backend error", message);
        }
        response(id, message);
    }

    function ingestStderr(line) {
        const text = String(line).trim();
        if (!text)
            return;
        const match = /^\[filesail:[^\]]+\]\[(error|warn|info|debug)\]/.exec(text);
        const severity = match ? match[1] : "warn";
        if (severity === "error")
            console.error(text);
        else if (severity === "debug")
            console.log(text);
        else if (severity === "info")
            console.info(text);
        else
            console.warn(text);
        if (severity === "error" || severity === "warn")
            root.lastError = text;
    }

    function rejectAll(message) {
        rejectingRequests = true;
        const requests = pendingRequests;
        pendingRequests = ({});
        pendingLines = [];
        for (const id in requests) {
            const pending = requests[id];
            if (root.isMutation(pending.method))
                operationLeases = Math.max(0, operationLeases - 1);
            if (pending.onFailure) {
                try {
                    pending.onFailure(message, { id: Number(id), ok: false, error: message });
                } catch (error) {
                    lastError = `${message}; request cleanup failed`;
                }
            }
        }
        pendingRevision++;
        operationsRequestId = -1;
        setOperations([]);
        operationsBackendInstance = "";
        operationEventSequence = 0;
        rejectingRequests = false;
        scheduleIdleShutdown();
    }

    function listDirectory(params, onSuccess, onFailure) {
        return request("list", params, onSuccess, onFailure);
    }

    function completeDirectories(parent, prefix, onSuccess, onFailure) {
        return request("completeDirectories", { parent, prefix }, onSuccess, onFailure);
    }

    function listLocations(onSuccess, onFailure) {
        return request("locations.list", {}, onSuccess, onFailure);
    }

    function addLocation(collection, path, onSuccess, onFailure) {
        return request("locations.add", { collection, path }, onSuccess, onFailure);
    }

    function removeLocation(collection, id, onSuccess, onFailure) {
        return request("locations.remove", { collection, id }, onSuccess, onFailure);
    }

    function watchDirectory(path, onSuccess, onFailure) {
        return request("watch", { path }, onSuccess, onFailure);
    }

    function unwatchDirectory(path, onSuccess, onFailure) {
        return request("unwatch", { path }, onSuccess, onFailure);
    }

    function performOperation(method, params, onSuccess, onFailure) {
        return request(method, params, onSuccess, onFailure);
    }

    function openPath(path, onSuccess, onFailure) {
        return request("open", { path }, onSuccess, onFailure);
    }

    function openTerminal(path, onSuccess, onFailure) {
        return request("terminal", { path }, onSuccess, onFailure);
    }

    function createDirectory(parent, name, onSuccess, onFailure) {
        return request("mkdir", { parent, name }, onSuccess, onFailure, 0);
    }

    function renamePath(path, name, onSuccess, onFailure) {
        return request("rename", { path, name }, onSuccess, onFailure, 0);
    }

    function copyPaths(paths, targetDirectory, onSuccess, onFailure) {
        return request("copy", { paths, targetDirectory }, onSuccess, onFailure, 0);
    }

    function movePaths(paths, targetDirectory, onSuccess, onFailure) {
        return request("move", { paths, targetDirectory }, onSuccess, onFailure, 0);
    }

    function trashPaths(paths, onSuccess, onFailure) {
        return request("trash", { paths }, onSuccess, onFailure, 0);
    }

    function setExecutable(path, executable, onSuccess, onFailure) {
        return request("setExecutable", { path, executable }, onSuccess, onFailure, 0);
    }

    function flush() {
        for (const queued of pendingLines) {
            if (pendingRequests[queued.id])
                backend.write(queued.line);
        }
        pendingLines = [];
    }

    property Process backend: Process {
        command: [root.backendCommand, "--serve"]
        stdinEnabled: true
        running: root.shouldRun

        stdout: SplitParser {
            onRead: line => {
                let message;
                try {
                    message = JSON.parse(line);
                } catch (error) {
                    root.lastError = "Backend returned invalid JSON";
                    Logger.error("backend", root.lastError);
                    root.rejectAll(root.lastError);
                    return;
                }
                if (message.event) {
                    if (message.event === "operationChanged")
                        root.applyOperationEvent(message);
                    root.eventReceived(message.event, message);
                } else
                    root.complete(message);
            }
        }

        stderr: SplitParser {
            onRead: line => root.ingestStderr(line)
        }

        onStarted: {
            root.restartRequested = false;
            root.lastError = "";
            Logger.info("backend", `started ${root.backendCommand}`);
            root.flush();
            root.refreshOperations();
        }

        onExited: exitCode => {
            const message = root.lastError || `FileSail backend exited (${exitCode})`;
            if (exitCode === 0)
                Logger.info("backend", "exited");
            else
                Logger.error("backend", message);
            root.rejectAll(message);
            root.backendStopped(message);
            root.scheduleIdleShutdown();
            // Re-evaluate the running binding after an unexpected exit. The
            // lease state remains authoritative, so later reads can restart
            // the backend without replaying rejected requests or mutations.
            if (root.sessionLeases > 0)
                root.restartRequested = true;
        }
    }


    property Timer timeoutTimer: Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            const now = Date.now();
            const requests = Object.assign({}, root.pendingRequests);
            const expired = [];
            for (const id in requests) {
                const pending = requests[id];
                if (pending.deadline === 0 || pending.deadline > now)
                    continue;
                delete requests[id];
                expired.push({ id: Number(id), pending });
            }
            if (expired.length > 0)
                root.pendingRequests = requests;
            for (const request of expired) {
                if (request.pending.method === "thumbnailBatch" || request.pending.method === "textPreview"
                        || request.pending.method === "archivePreview")
                    root.cancelPreview(request.id);
                Logger.warn("backend", `request ${request.id} ${request.pending.method} timed out`);
                if (request.pending.onFailure) {
                    try {
                        request.pending.onFailure("Backend request timed out", {
                            id: request.id, ok: false, error: "Backend request timed out"
                        });
                    } catch (error) {
                        root.lastError = "Backend request timeout cleanup failed";
                    }
                }
            }
        }
    }

    property Timer idleShutdownTimer: Timer {
        interval: root.idleGracePeriod
        repeat: false
        onTriggered: {
            if (root.sessionLeases === 0 && root.operationLeases === 0 && root.pendingCount === 0) {
                root.idleHold = false;
                Logger.info("backend", "idle grace period elapsed");
            }
        }
    }

    Component.onDestruction: {
        idleShutdownTimer.stop();
        root.rejectAll("FileSail host is shutting down");
        root.idleHold = false;
    }
}
