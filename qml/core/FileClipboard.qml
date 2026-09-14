pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
    id: root

    property string clipboardCommand: {
        const configured = String(Quickshell.env("FILESAIL_CLIPBOARD") ?? "");
        return configured.length > 0 ? configured : "filesail-clipboard";
    }
    property int sessionLeases: 0
    property int operationLeases: 0
    property int nextRequestId: 1
    property var pendingRequests: ({})
    property var pendingLines: []
    property int pendingRevision: 0
    property string state: "unavailable"
    property bool available: false
    property bool ready: state === "ready" && available && paths.length > 0
    property bool owned: false
    property var paths: []
    property string mode: "copy"
    property string offerToken: ""
    property int generation: 0
    property string reason: "Clipboard helper is starting"
    property int restartCount: 0
    property bool restartBackoff: false
    property int requestTimeout: 10000
    property var inFlight: ({})
    readonly property int pendingCount: pendingRevision >= 0 ? Object.keys(pendingRequests).length : 0
    readonly property bool shouldRun: sessionLeases > 0 || operationLeases > 0 || pendingCount > 0
    readonly property string statusText: {
        if (state === "ready")
            return `${mode === "cut" ? "Cut" : "Copy"} buffer: ${paths.length}`;
        if (state === "reading")
            return qsTr("Reading clipboard…");
        if (state === "empty")
            return qsTr("Clipboard is empty");
        if (state === "unsupported")
            return reason || qsTr("Clipboard content is not a local file selection");
        return reason || qsTr("File clipboard unavailable");
    }

    signal pasteStarted(int operationId)
    signal pasteFinished(int operationId, var result, bool success)
    signal clipboardError(string message)

    function setSnapshot(snapshot) {
        const nextPaths = Array.isArray(snapshot.paths) ? snapshot.paths.slice() : [];
        state = String(snapshot.state ?? "unavailable");
        available = snapshot.available === undefined
            ? available && state !== "unavailable" : snapshot.available === true;
        owned = snapshot.owned === true;
        paths = nextPaths;
        mode = snapshot.mode === "cut" ? "cut" : "copy";
        offerToken = String(snapshot.offerToken ?? "");
        generation = Number(snapshot.generation ?? generation);
        reason = String(snapshot.reason ?? "");
    }

    function setCapabilities(capabilities) {
        available = capabilities.available === true;
        if (!available && sessionLeases > 0) {
            state = "unavailable";
            owned = false;
            paths = [];
            reason = String(capabilities.reason ?? "Clipboard transport unavailable");
        }
    }

    function acquireSession() {
        sessionLeases++;
        restartBackoff = false;
        restartTimer.stop();
    }

    function releaseSession() {
        sessionLeases = Math.max(0, sessionLeases - 1);
        scheduleRestartOrStop();
    }

    function pruneMountPoints(mountPoints) {
        if (!owned || !offerToken)
            return;
        const remaining = paths.filter(path => !(mountPoints ?? []).some(
            mount => VolumeModel.isWithin(path, mount)));
        if (remaining.length === paths.length)
            return;
        request("replaceIfCurrent", {
            expectedOfferToken: offerToken,
            paths: remaining,
            mode,
            clear: remaining.length === 0
        }, setSnapshot, message => Logger.warn("clipboard", message));
    }

    function scheduleRestartOrStop() {
        if (!shouldRun || helper.running)
            return;
        if (restartCount >= 5) {
            restartBackoff = true;
            reason = qsTr("Clipboard helper stopped after repeated failures");
            return;
        }
        restartBackoff = false;
        restartTimer.restart();
    }

    function failPending(message) {
        const pending = pendingRequests;
        pendingRequests = ({});
        pendingLines = [];
        pendingRevision++;
        for (const id in pending) {
            if (pending[id].onFailure)
                pending[id].onFailure(message, { id: Number(id), ok: false, error: message });
        }
    }

    function request(method, params, onSuccess, onFailure, timeout) {
        if (restartBackoff)
            return -1;
        const id = nextRequestId++;
        const request = {
            method, onSuccess, onFailure,
            deadline: timeout === 0 ? 0 : Date.now() + (timeout ?? requestTimeout)
        };
        const next = Object.assign({}, pendingRequests);
        next[id] = request;
        pendingRequests = next;
        pendingRevision++;
        const line = JSON.stringify({ protocol: "filesail.clipboard.v1", version: 1,
            id, method, params: params ?? {} }) + "\n";
        if (helper.running)
            helper.write(line);
        else {
            pendingLines = pendingLines.concat([{ id, line }]);
        }
        return id;
    }

    function flush() {
        for (const queued of pendingLines) {
            if (pendingRequests[queued.id])
                helper.write(queued.line);
        }
        pendingLines = [];
    }

    function complete(message) {
        const id = Number(message.id ?? -1);
        const pending = pendingRequests[id];
        if (!pending)
            return;
        const next = Object.assign({}, pendingRequests);
        delete next[id];
        pendingRequests = next;
        pendingRevision++;
        if (message.ok) {
            if (pending.onSuccess)
                pending.onSuccess(message);
        } else if (pending.onFailure) {
            pending.onFailure(String(message.error ?? "Clipboard helper request failed"), message);
        }
    }

    function handleLine(line) {
        let message;
        try {
            message = JSON.parse(line);
        } catch (error) {
            reason = qsTr("Clipboard helper returned invalid JSON");
            clipboardError(reason);
            return;
        }
        if (message.event === "capabilities") {
            setCapabilities(message);
            return;
        }
        if (message.event === "changed") {
            setSnapshot(message);
            return;
        }
        if (message.event === "error") {
            reason = String(message.reason ?? "Clipboard helper error");
            clipboardError(reason);
            return;
        }
        complete(message);
    }

    function publish(selectionPaths, selectionMode, onSuccess, onFailure) {
        if (!available) {
            if (onFailure) onFailure(reason || qsTr("Clipboard transport unavailable"));
            return -1;
        }
        const cleanPaths = selectionPaths.slice();
        return request("writeFiles", { paths: cleanPaths, mode: selectionMode === "cut" ? "cut" : "copy" },
            result => {
                setSnapshot(result);
                if (onSuccess) onSuccess();
            }, onFailure);
    }

    function beginPaste(destination, onStarted, onFinished, onFailure) {
        if (!ready) {
            if (onFailure) onFailure(reason || qsTr("Clipboard is not ready"));
            return -1;
        }
        const requestedToken = offerToken;
        const requestedPaths = paths.slice();
        const requestedMode = mode;
        return request("snapshot", {}, result => {
            if (String(result.offerToken ?? "") !== requestedToken
                    || result.state !== "ready"
                    || !Array.isArray(result.paths)
                    || result.paths.length === 0) {
                if (onFailure) onFailure(qsTr("Clipboard changed before Paste could start"));
                return;
            }
            if (requestedMode === "cut") {
                for (const id in inFlight) {
                    if (inFlight[id].mode === "cut" && inFlight[id].offerToken === requestedToken) {
                        if (onFailure) onFailure(qsTr("This Cut selection is already being pasted"));
                        return;
                    }
                }
            }
            const operationId = requestedMode === "cut"
                ? BackendClient.movePaths(requestedPaths, destination, null, null)
                : BackendClient.copyPaths(requestedPaths, destination, null, null);
            if (operationId < 0) {
                if (onFailure) onFailure(qsTr("The file operation could not be started"));
                return;
            }
            const record = {
                operationId, mode: requestedMode, paths: requestedPaths,
                destination, offerToken: requestedToken, onFinished
            };
            const next = Object.assign({}, inFlight);
            next[operationId] = record;
            inFlight = next;
            operationLeases++;
            if (onStarted) onStarted(operationId, record);
            pasteStarted(operationId);
        }, onFailure);
    }

    function finishPaste(result, method) {
        const id = Number(result.id ?? -1);
        const record = inFlight[id];
        if (!record || (method !== "copy" && method !== "move"))
            return;
        const next = Object.assign({}, inFlight);
        delete next[id];
        inFlight = next;
        operationLeases = Math.max(0, operationLeases - 1);
        const finalize = () => {
            if (record.onFinished)
                record.onFinished(result, !!result.ok, record);
            pasteFinished(id, result, !!result.ok);
        };
        if (record.mode !== "cut" || !owned || offerToken !== record.offerToken) {
            finalize();
            return;
        }
        if (result.ok) {
            request("replaceIfCurrent", { expectedOfferToken: record.offerToken, clear: true },
                    () => finalize(), () => finalize());
            return;
        }
        const completed = Array.isArray(result.completed) ? result.completed.length : 0;
        // `completed` contains destination paths in source order. A partial
        // entry committed its destination but did not complete source cleanup,
        // so it and every later source remain in the Cut offer.
        if (completed > 0) {
            const remaining = record.paths.slice(completed);
            request("replaceIfCurrent", {
                expectedOfferToken: record.offerToken,
                paths: remaining,
                mode: "cut",
                clear: remaining.length === 0
            }, () => finalize(), () => finalize());
        } else {
            finalize();
        }
    }

    property Connections backendConnections: Connections {
        target: BackendClient
        function onMutationTerminated(result, method) { root.finishPaste(result, method); }
    }

    property Connections volumeConnections: Connections {
        target: VolumeModel
        function onRemovalFinished(mountPoints, success) {
            if (success) root.pruneMountPoints(mountPoints);
        }
        function onMountPointsLost(mountPoints, expected, disconnected) {
            if (!expected) root.pruneMountPoints(mountPoints);
        }
    }

    property Timer requestTimer: Timer {
        interval: 500
        repeat: true
        running: root.pendingCount > 0
        onTriggered: {
            const now = Date.now();
            for (const id in root.pendingRequests) {
                const pending = root.pendingRequests[id];
                if (pending.deadline > 0 && pending.deadline <= now) {
                    const next = Object.assign({}, root.pendingRequests);
                    delete next[id];
                    root.pendingRequests = next;
                    root.pendingRevision++;
                    if (pending.onFailure)
                        pending.onFailure(qsTr("Clipboard helper request timed out"), {});
                }
            }
        }
    }

    property Timer restartTimer: Timer {
        interval: Math.min(5000, 250 * Math.max(1, root.restartCount))
        onTriggered: {
            root.restartCount++;
            root.restartBackoff = false;
        }
    }

    property Process helper: Process {
        command: [root.clipboardCommand, "--serve"]
        stdinEnabled: true
        running: root.shouldRun && !root.restartBackoff && !root.restartTimer.running
        stdout: SplitParser { onRead: line => root.handleLine(line) }
        stderr: SplitParser { onRead: line => Logger.warn("clipboard", String(line)) }
        onStarted: {
            root.restartCount = 0;
            root.restartBackoff = false;
            root.reason = qsTr("Reading desktop clipboard");
            root.flush();
            root.request("capabilities", {}, root.setCapabilities, message => root.reason = message);
            root.request("snapshot", {}, root.setSnapshot, message => root.reason = message);
        }
        onExited: {
            root.available = false;
            root.owned = false;
            root.state = "unavailable";
            root.paths = [];
            root.failPending(qsTr("Clipboard helper stopped"));
            root.scheduleRestartOrStop();
        }
    }

    Component.onDestruction: {
        if (helper.running)
            helper.running = false;
    }
}
