pragma Singleton

import QtQuick

QtObject {
    id: root

    // These limits apply to decoded-image ownership in FileSail. Tumbler's
    // disk cache is external and is intentionally not counted here.
    property int maximumEntries: 256
    property int maximumMetadataBytes: 2 * 1024 * 1024
    property int maximumDecodeBytes: 48 * 1024 * 1024
    property var results: ({})
    property var queued: ({})
    property var consumers: ({})
    property var consumerKeys: ({})
    property int nextConsumerToken: 1
    property int activeViews: 0
    property int generation: 0
    property int directoryGeneration: 0
    property int revision: 0
    property int activeDecodeBytes: 0
    property var requests: ({})

    function key(entry, flavor) {
        return `${entry.path}|${entry.size}|${entry.modified}|${flavor}`;
    }

    function allocateConsumer() { return nextConsumerToken++; }

    function acquire(entry, flavor, consumer, priority, thumbnailSize) {
        if (!entry || !consumer || entry.isDirectory || !eligibleVisual(entry.mimeType)) return;
        const requestKey = key(entry, flavor);
        for (const oldKey of Object.keys(results)) {
            const old = results[oldKey];
            if (old.entry.path === entry.path && oldKey !== requestKey && old.consumers === 0) {
                delete queued[oldKey];
                delete results[oldKey];
            }
        }
        const oldKey = consumerKeys[consumer];
        if (oldKey === requestKey) return;
        if (oldKey) releaseKey(oldKey, consumer);
        consumerKeys[consumer] = requestKey;
        consumers[requestKey] = (consumers[requestKey] ?? 0) + 1;
        let record = results[requestKey];
        if (!record) {
            record = { state: "queued", url: "", revision: 0, consumers: 0,
                lastUse: ++generation, generation: root.generation,
                directoryGeneration: root.directoryGeneration, entry, flavor,
                priority: priority === "foreground" ? "foreground" : "background",
                decodeBytes: Math.max(1, Math.ceil(thumbnailSize || 128) ** 2 * 4), lease: false };
            results[requestKey] = record;
            queued[requestKey] = true;
        }
        if (record.state === "queued") flushDelay.restart();
        record.consumers = consumers[requestKey];
        record.lastUse = ++generation;
        grantLeases();
        trim();
        revision++;
    }

    function releaseKey(requestKey, consumer) {
        if (consumerKeys[consumer] !== requestKey) return;
        delete consumerKeys[consumer];
        const count = Math.max(0, (consumers[requestKey] ?? 0) - 1);
        if (count === 0) delete consumers[requestKey]; else consumers[requestKey] = count;
        const record = results[requestKey];
        if (record) {
            record.consumers = count;
            record.lastUse = ++generation;
            if (record.state === "queued" && count === 0) delete queued[requestKey];
            if (record.lease && count === 0) { record.lease = false; activeDecodeBytes -= record.decodeBytes; }
        }
        cancelUnusedRequest(requestKey);
        grantLeases();
        trim();
        revision++;
    }

    function release(entry, flavor, consumer) {
        if (!entry || !consumer) return;
        releaseKey(key(entry, flavor), consumer);
    }

    function releaseConsumer(consumer) {
        const requestKey = consumerKeys[consumer];
        if (requestKey) releaseKey(requestKey, consumer);
    }

    function thumbnail(entry, flavor, consumer, priority, thumbnailSize) {
        if (!entry || entry.isDirectory || !eligibleVisual(entry.mimeType))
            return ({ state: "unsupported", revision: 0, lease: false });
        const requestKey = key(entry, flavor);
        const record = results[requestKey];
        if (!record) return ({ state: "queued", revision: revision, lease: false });
        // Return a value snapshot rather than the mutable cache record. QML
        // compares var values by identity, so returning the record itself
        // would hide state changes from bindings that already hold it.
        return { state: record.state, url: record.url, revision: record.revision, lease: record.lease };
    }

    function eligibleVisual(mime) {
        return mime.indexOf("image/") === 0 || mime.indexOf("video/") === 0 || mime === "application/pdf";
    }

    function trim() {
        const keys = Object.keys(results);
        let metadataBytes = 0;
        for (const requestKey of keys)
            metadataBytes += String(results[requestKey].entry.path).length * 2 + 160;
        if (keys.length <= maximumEntries && metadataBytes <= maximumMetadataBytes) return;
        keys.sort((left, right) => (results[left].lastUse ?? 0) - (results[right].lastUse ?? 0));
        for (const requestKey of keys) {
            if (Object.keys(results).length <= maximumEntries && metadataBytes <= maximumMetadataBytes) break;
            const record = results[requestKey];
            if (record.consumers > 0 || record.state === "loading") continue;
            delete queued[requestKey];
            delete results[requestKey];
            metadataBytes -= String(record.entry.path).length * 2 + 160;
        }
        for (const requestKey of Object.keys(results)) {
            const record = results[requestKey];
            if (record.consumers === 0 && record.directoryGeneration < directoryGeneration) {
                delete queued[requestKey];
                delete results[requestKey];
            }
        }
        revision++;
    }

    function cancelUnusedRequest(requestKey) {
        const requestId = requests[requestKey];
        if (!requestId || (consumers[requestKey] ?? 0) > 0) return;
        BackendClient.cancel(requestId);
        delete requests[requestKey];
        const record = results[requestKey];
        if (record && record.state === "loading") record.state = "queued";
    }

    function grantLeases() {
        const candidates = Object.keys(results).map(requestKey => results[requestKey])
            .filter(record => record.state === "ready" && !record.lease && record.consumers > 0)
            .sort((left, right) => left.lastUse - right.lastUse);
        for (const record of candidates) {
            if (activeDecodeBytes + record.decodeBytes > maximumDecodeBytes) continue;
            record.lease = true;
            activeDecodeBytes += record.decodeBytes;
        }
    }

    function flush() {
        const groups = ({ });
        for (const requestKey of Object.keys(queued)) {
            const record = results[requestKey];
            if (!record || record.consumers === 0) { delete queued[requestKey]; continue; }
            const groupKey = `${record.flavor}|${record.priority}`;
            if (!groups[groupKey]) groups[groupKey] = [];
            groups[groupKey].push({ key: requestKey, entry: record.entry });
            record.state = "loading";
        }
        queued = ({ });
        for (const groupKey of Object.keys(groups)) {
            const separator = groupKey.lastIndexOf("|");
            const flavor = groupKey.slice(0, separator);
            const priority = groupKey.slice(separator + 1);
            const group = groups[groupKey];
            for (let offset = 0; offset < group.length; offset += 64) {
                const batch = group.slice(offset, offset + 64);
                const requestId = BackendClient.requestThumbnails(
                    batch.map(item => ({ path: item.entry.path, mimeType: item.entry.mimeType })),
                    flavor, priority,
                    result => completeBatch(requestId, batch, flavor, result),
                    message => failBatch(requestId, batch, message));
                for (const item of batch) requests[item.key] = requestId;
            }
        }
        revision++;
    }

    function completeBatch(requestId, batch, flavor, result) {
        for (const item of batch) delete requests[item.key];
        const byPath = ({ });
        for (const item of batch) byPath[item.entry.path] = item;
        for (const item of result.items ?? []) {
            const match = byPath[item.path];
            if (!match || !results[match.key]) continue;
            const record = results[match.key];
            record.state = item.status ?? "unsupported";
            record.url = item.url ?? "";
            record.revision++;
            if (record.state === "ready" && record.consumers === 0) record.lease = false;
        }
        grantLeases();
        trim();
        revision++;
    }

    function failBatch(requestId, batch, message) {
        for (const item of batch) {
            delete requests[item.key];
            const record = results[item.key];
            if (record) { record.state = "error"; record.revision++; }
        }
        Logger.warn("preview", `thumbnailBatch failed: ${message}`);
        revision++;
    }

    function acquireView() { activeViews++; }
    function releaseView() {
        activeViews = Math.max(0, activeViews - 1);
        if (activeViews !== 0) return;
        flushDelay.stop();
        for (const requestKey of Object.keys(requests)) BackendClient.cancel(requests[requestKey]);
        results = ({ }); queued = ({ }); consumers = ({ }); consumerKeys = ({ }); requests = ({ });
        activeDecodeBytes = 0;
        revision++;
    }
    function advanceGeneration() { directoryGeneration++; generation++; trim(); }

    property Timer flushTimer: Timer { id: flushDelay; interval: 40; onTriggered: root.flush() }
}
