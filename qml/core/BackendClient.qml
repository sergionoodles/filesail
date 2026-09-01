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
    property int requestTimeout: 30000
    property bool available: backend.running
    property bool rejectingRequests: false
    property string lastError: ""

    signal response(int id, var result)
    signal eventReceived(string event, var message)
    signal backendStopped(string message)

    function request(method, params, onSuccess, onFailure, timeout) {
        if (rejectingRequests)
            return -1;
        const id = nextRequestId++;
        const line = JSON.stringify({ id, method, params: params ?? {} }) + "\n";
        const timeoutMs = timeout === undefined ? requestTimeout : timeout;
        const requests = Object.assign({}, pendingRequests);
        requests[id] = {
            onSuccess: onSuccess,
            onFailure: onFailure,
            deadline: timeoutMs > 0 ? Date.now() + timeoutMs : 0
        };
        pendingRequests = requests;
        if (backend.running)
            backend.write(line);
        else {
            pendingLines.push({ id, line });
            pendingLines = pendingLines.slice();
            backend.running = true;
        }
        return id;
    }

    function cancel(id) {
        if (!pendingRequests[id])
            return;
        const requests = Object.assign({}, pendingRequests);
        delete requests[id];
        pendingRequests = requests;
    }

    function complete(message) {
        const id = message.id ?? -1;
        const pending = pendingRequests[id];
        if (!pending) {
            response(id, message);
            return;
        }
        cancel(id);
        if (message.ok) {
            if (pending.onSuccess)
                pending.onSuccess(message);
        } else if (pending.onFailure) {
            pending.onFailure(message.error ?? "Unknown backend error", message);
        }
        response(id, message);
    }

    function rejectAll(message) {
        rejectingRequests = true;
        const requests = pendingRequests;
        pendingRequests = ({});
        pendingLines = [];
        for (const id in requests) {
            const pending = requests[id];
            if (pending.onFailure) {
                try {
                    pending.onFailure(message, { id: Number(id), ok: false, error: message });
                } catch (error) {
                    lastError = `${message}; request cleanup failed`;
                }
            }
        }
        rejectingRequests = false;
    }

    function listDirectory(params, onSuccess, onFailure) {
        return request("list", params, onSuccess, onFailure);
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
        running: true

        stdout: SplitParser {
            onRead: line => {
                let message;
                try {
                    message = JSON.parse(line);
                } catch (error) {
                    root.lastError = "Backend returned invalid JSON";
                    root.rejectAll(root.lastError);
                    return;
                }
                if (message.event)
                    root.eventReceived(message.event, message);
                else
                    root.complete(message);
            }
        }

        stderr: SplitParser {
            onRead: line => root.lastError = String(line).trim()
        }

        onStarted: {
            root.lastError = "";
            root.flush();
        }

        onExited: exitCode => {
            const message = root.lastError || `FileSail backend exited (${exitCode})`;
            root.rejectAll(message);
            root.backendStopped(message);
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
}
