pragma Singleton

import QtQuick
import Quickshell.Io

// Transport-independent command router. Browser state and mutations stay in
// BrowserSession; this singleton only validates, targets, tracks, and retains.
QtObject {
    id: root

    readonly property int protocolVersion: 1
    property string hostGeneration: ""
    property var windows: []
    property var requests: ({})
    property var requestOrder: []
    property var pendingByWindow: ({})
    property var eventHistory: []
    property int nextEventSequence: 1
    property int maximumRequestBytes: 64 * 1024
    property int maximumResults: 128
    property int maximumEvents: 256
    property int maximumOutstanding: 64
    property int maximumResultBytes: 512 * 1024
    property var createWindowCallback: null

    readonly property var capabilitySnapshot: ({
        version: protocolVersion,
        methods: ["state", "entries", "navigate", "back", "forward", "up", "refresh",
                  "select", "selection.clear", "preview.show", "preview.hide", "filter",
                  "hidden", "sort", "viewMode", "capabilities", "windows.create"],
        limits: {
            requestBytes: maximumRequestBytes,
            outstandingCommands: maximumOutstanding,
            retainedResults: maximumResults,
            retainedEvents: maximumEvents,
            entriesPage: 500,
            selectionStatePaths: 64,
            resultBytes: maximumResultBytes
        },
        preferences: {
            filter: "window",
            sort: "host-shared",
            hidden: "host-shared",
            preview: "host-shared",
            viewMode: "host-shared"
        },
        preview: { builtInReadiness: true, customProviderReadiness: "provider-dependent" },
        filesystemMutations: false,
        externalApplicationLaunching: false
    })

    function clone(value) { return JSON.parse(JSON.stringify(value)); }
    function json(value) { return JSON.stringify(value); }
    function utf8Bytes(value) {
        const text = String(value);
        let bytes = 0;
        for (let index = 0; index < text.length; ++index) {
            const code = text.charCodeAt(index);
            if (code < 0x80) bytes += 1;
            else if (code < 0x800) bytes += 2;
            else if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length
                     && text.charCodeAt(index + 1) >= 0xdc00 && text.charCodeAt(index + 1) <= 0xdfff) {
                bytes += 4;
                index++;
            } else bytes += 3;
        }
        return bytes;
    }
    function error(code, message, extra) {
        return Object.assign({ version: protocolVersion, ok: false, code, message }, extra ?? {});
    }

    function describeObject() {
        return {
            version: protocolVersion,
            protocol: "filesail.control.v1",
            hostGeneration,
            ready: hostGeneration.length > 0,
            hostKind: createWindowCallback ? "standalone"
                : (windows.length > 0 ? windows[0].hostKind : "embedded"),
            canCreateWindow: Boolean(createWindowCallback),
            capabilities: capabilitySnapshot,
            windows: windows.filter(adapter => adapter.windowId.length > 0)
                .map(adapter => adapter.stateSnapshot())
        };
    }

    function describe() {
        const description = describeObject();
        description.ok = true;
        return json(description);
    }

    function findWindow(windowId) {
        for (const adapter of windows) {
            if (adapter.windowId === windowId)
                return adapter;
        }
        return null;
    }

    function registerWindow(adapter) {
        if (windows.indexOf(adapter) < 0)
            windows = windows.concat([adapter]);
        adapter.requestFinished.connect(root.onAdapterRequestFinished);
        adapter.stateChanged.connect(kind => root.onAdapterStateChanged(adapter, kind));
        allocateWindowId(adapter);
    }

    function allocateWindowId(adapter) {
        BackendClient.allocateControlIdentity(result => {
            if (!adapter || windows.indexOf(adapter) < 0)
                return;
            const candidate = String(result.value ?? "");
            if (!candidate || findWindow(candidate)) {
                allocateWindowId(adapter);
                return;
            }
            adapter.windowId = candidate;
            adapter.registered = true;
            emitEvent("window.opened", adapter, "", { state: adapter.stateSnapshot() });
            maybeCompleteCreate(adapter);
        }, message => Logger.warn("control", `could not allocate window ID: ${message}`));
    }

    function unregisterWindow(adapter) {
        const index = windows.indexOf(adapter);
        if (index < 0)
            return;
        const id = adapter.windowId;
        if (id && pendingByWindow[id])
            finishRequest(pendingByWindow[id], false, "window_not_found", "Window closed before the request completed", {});
        const next = windows.slice();
        next.splice(index, 1);
        windows = next;
        if (id)
            emitEvent("window.closed", adapter, "", {});
    }

    function onAdapterStateChanged(adapter, kind) {
        const eventType = kind === "directory" ? "directory.committed"
            : kind === "selection" ? "selection.changed"
            : kind === "preview" ? "preview.changed" : "state.changed";
        emitEvent(eventType, adapter, "", { kind, revision: adapter.revision });
        maybeCompleteCreate(adapter);
    }

    function onAdapterRequestFinished(requestId, ok, code, message, data) {
        finishRequest(requestId, ok, code, message, data);
    }

    function emitEvent(type, adapter, requestId, data) {
        if (!hostGeneration)
            return;
        const event = {
            version: protocolVersion,
            hostGeneration,
            sequence: nextEventSequence++,
            type,
            window: adapter ? adapter.windowId : "",
            requestId: requestId ?? "",
            data: data ?? {}
        };
        eventHistory.push(event);
        if (eventHistory.length > maximumEvents)
            eventHistory = eventHistory.slice(eventHistory.length - maximumEvents);
        eventHistory = eventHistory.slice();
        ipc.event(json(event));
    }

    function remember(requestId, envelope, targetId) {
        const fingerprint = json(envelope);
        requests[requestId] = {
            requestId,
            fingerprint,
            window: targetId ?? "",
            method: String(envelope.method),
            status: "pending",
            submittedAt: Date.now(),
            result: null,
            createAdapter: null
        };
        requestOrder.push(requestId);
        trimResults();
    }

    function trimResults() {
        while (requestOrder.length > maximumResults) {
            const index = requestOrder.findIndex(id => requests[id]?.status !== "pending");
            if (index < 0)
                break;
            const oldest = requestOrder[index];
            requestOrder.splice(index, 1);
            delete requests[oldest];
        }
        requestOrder = requestOrder.slice();
    }

    function finishRequest(requestId, ok, code, message, data) {
        const record = requests[requestId];
        if (!record || record.status !== "pending")
            return;
        const adapter = record.window ? findWindow(record.window) : record.createAdapter;
        record.status = ok ? "succeeded" : "failed";
        record.result = {
            version: protocolVersion,
            requestId,
            window: adapter ? adapter.windowId : record.window,
            hostGeneration,
            ok,
            status: record.status,
            code: ok ? "" : String(code || "failed"),
            message: String(message ?? ""),
            resultingRevision: adapter ? adapter.revision : 0,
            data: data ?? {}
        };
        if (record.window && pendingByWindow[record.window] === requestId)
            delete pendingByWindow[record.window];
        emitEvent("request.finished", adapter, requestId, {
            ok: record.result.ok,
            status: record.result.status,
            code: record.result.code,
            resultingRevision: record.result.resultingRevision
        });
        trimResults();
    }

    function result(requestId) {
        const id = String(requestId ?? "");
        const record = requests[id];
        if (!record)
            return json(error("result_unknown", "Request result is unknown or expired", { requestId: id }));
        if (record.status === "pending")
            return json({ version: protocolVersion, ok: true, requestId: id, status: "pending",
                          window: record.window, hostGeneration });
        return json(record.result);
    }

    function eventsSince(sequence, limit) {
        const after = Math.max(0, Number(sequence ?? 0));
        const bounded = Math.max(1, Math.min(256, Number(limit ?? 100)));
        const oldest = eventHistory.length > 0 ? eventHistory[0].sequence : nextEventSequence;
        if (after > 0 && after < oldest - 1)
            return json(error("event_gap", "Requested events have expired", {
                hostGeneration, oldestSequence: oldest, nextSequence: nextEventSequence
            }));
        const events = eventHistory.filter(event => event.sequence > after).slice(0, bounded);
        return json({ version: protocolVersion, ok: true, hostGeneration, events,
                      nextSequence: events.length > 0 ? events[events.length - 1].sequence : after });
    }

    function countOutstanding() {
        let count = 0;
        for (const id of Object.keys(requests))
            if (requests[id].status === "pending") count++;
        return count;
    }

    function submit(raw) {
        const text = String(raw ?? "");
        if (text.length === 0 || utf8Bytes(text) > maximumRequestBytes)
            return json(error("invalid_request", "Request is empty or exceeds the size limit"));
        let envelope;
        try { envelope = JSON.parse(text); }
        catch (exception) { return json(error("invalid_request", "Request is not valid JSON")); }
        if (!envelope || Number(envelope.version) !== protocolVersion
                || typeof envelope.requestId !== "string" || !envelope.requestId
                || typeof envelope.method !== "string")
            return json(error("invalid_request", "version, requestId, and method are required"));
        if (envelope.requestId.length > 128)
            return json(error("invalid_request", "requestId exceeds 128 characters"));

        const existing = requests[envelope.requestId];
        if (existing) {
            if (existing.fingerprint !== json(envelope))
                return json(error("request_id_conflict", "requestId was already used with different arguments",
                                  { requestId: envelope.requestId }));
            return existing.status === "pending" ? result(envelope.requestId) : json(existing.result);
        }
        if (countOutstanding() >= maximumOutstanding)
            return json(error("busy", "The host command queue is full", { requestId: envelope.requestId }));

        const method = envelope.method;
        const params = envelope.params && typeof envelope.params === "object" ? envelope.params : {};
        if (method === "windows.create")
            return submitCreate(envelope, params);

        const adapter = findWindow(String(envelope.window ?? ""));
        if (!adapter)
            return json(error("window_not_found", "The requested window is not available",
                              { requestId: envelope.requestId, window: String(envelope.window ?? "") }));
        if (envelope.expectedRevision !== undefined
                && Number(envelope.expectedRevision) !== adapter.revision)
            return json(error("stale_state", "Window state changed since it was inspected", {
                requestId: envelope.requestId, window: adapter.windowId, revision: adapter.revision
            }));

        remember(envelope.requestId, envelope, adapter.windowId);
        if (method === "state") {
            finishRequest(envelope.requestId, true, "", "", { state: adapter.stateSnapshot() });
        } else if (method === "entries") {
            const page = adapter.entriesPage(params);
            finishRequest(envelope.requestId, page.ok, page.code, page.message, page);
        } else if (method === "capabilities") {
            finishRequest(envelope.requestId, true, "", "", { capabilities: capabilitySnapshot });
        } else {
            if (pendingByWindow[adapter.windowId]) {
                finishRequest(envelope.requestId, false, "busy", "Another control command is pending for this window", {});
                return result(envelope.requestId);
            }
            pendingByWindow[adapter.windowId] = envelope.requestId;
            if (["navigate", "back", "forward", "up", "refresh"].indexOf(method) >= 0)
                submitNavigation(adapter, envelope.requestId, method, params);
            else if (method === "select")
                adapter.applySelection(envelope.requestId, params);
            else if (method === "selection.clear")
                adapter.clearSelection(envelope.requestId);
            else if (method === "preview.show" || method === "preview.hide")
                adapter.setPreview(envelope.requestId, method === "preview.show");
            else if (["filter", "hidden", "sort", "viewMode"].indexOf(method) >= 0)
                adapter.setPreference(envelope.requestId, method, params);
            else
                finishRequest(envelope.requestId, false, "unknown_method", `Unknown method: ${method}`, {});
        }
        return result(envelope.requestId);
    }

    function submitNavigation(adapter, requestId, method, params) {
        if (method !== "navigate") {
            adapter.beginNavigation(requestId, method, "");
            return;
        }
        const location = params.location ?? params.path;
        if (typeof location !== "string" || location.length === 0) {
            finishRequest(requestId, false, "invalid_path", "navigate requires a location", {});
            return;
        }
        const revisionAtResolve = adapter.revision;
        BackendClient.resolveControlLocation(location, result => {
            if (!requests[requestId] || requests[requestId].status !== "pending")
                return;
            if (!findWindow(adapter.windowId)) {
                finishRequest(requestId, false, "window_not_found", "Window closed before navigation", {});
                return;
            }
            if (adapter.revision !== revisionAtResolve) {
                finishRequest(requestId, false, "superseded", "Window changed while resolving the location", {});
                return;
            }
            adapter.beginNavigation(requestId, method, String(result.path));
        }, message => finishRequest(requestId, false, "invalid_path", message, {}));
    }

    function submitCreate(envelope, params) {
        if (!createWindowCallback)
            return json(error("unsupported", "This host cannot create standalone windows",
                              { requestId: envelope.requestId }));
        remember(envelope.requestId, envelope, "");
        const location = params.location ?? params.path ?? "home";
        BackendClient.resolveControlLocation(location, result => {
            if (!requests[envelope.requestId] || requests[envelope.requestId].status !== "pending")
                return;
            const created = createWindowCallback(String(result.path));
            if (!created || !created.controlAdapter) {
                finishRequest(envelope.requestId, false, "create_failed", "Could not create a window", {});
                return;
            }
            requests[envelope.requestId].createAdapter = created.controlAdapter;
            maybeCompleteCreate(created.controlAdapter);
        }, message => finishRequest(envelope.requestId, false, "invalid_path", message, {}));
        return result(envelope.requestId);
    }

    function maybeCompleteCreate(adapter) {
        if (!adapter || !adapter.windowId)
            return;
        for (const requestId of Object.keys(requests)) {
            const record = requests[requestId];
            if (record.status !== "pending" || record.createAdapter !== adapter)
                continue;
            if (adapter.session.directory.error.length > 0)
                finishRequest(requestId, false, "invalid_path", adapter.session.directory.error,
                              { state: adapter.stateSnapshot() });
            else if (adapter.ready)
                finishRequest(requestId, true, "", "", { state: adapter.stateSnapshot() });
        }
    }

    property IpcHandler ipcObject: IpcHandler {
        id: ipc
        target: "filesail.control.v1"

        signal event(string payload)

        function describe(): string { return root.describe(); }
        function submit(request: string): string { return root.submit(request); }
        function result(requestId: string): string { return root.result(requestId); }
        function eventsSince(sequence: string, limit: string): string {
            return root.eventsSince(sequence, limit);
        }
    }

    Component.onCompleted: BackendClient.allocateControlIdentity(result => {
        hostGeneration = String(result.value ?? "");
        emitEvent("host.ready", null, "", {});
    }, message => Logger.warn("control", `could not allocate host generation: ${message}`))
}
