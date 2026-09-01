pragma Singleton

import QtQuick

QtObject {
    id: root

    // Keys include the directory-provided fingerprint fields, so a replaced
    // file can never reuse a result intended for an earlier incarnation.
    property var results: ({})
    property var queued: ({})
    property var consumers: ({})

    function key(entry, flavor) {
        return `${entry.path}|${entry.size}|${entry.modified}|${flavor}`;
    }

    function thumbnail(entry, flavor, consumer, priority) {
        if (!entry || entry.isDirectory || !eligibleVisual(entry.mimeType))
            return ({ state: "unsupported", revision: 0 });
        const requestKey = key(entry, flavor);
        if (consumer)
            consumers[`${requestKey}|${consumer}`] = true;
        if (results[requestKey])
            return results[requestKey];
        queued[requestKey] = { entry, flavor, priority: priority === "foreground" ? "foreground" : "background" };
        flushDelay.restart();
        return ({ state: "queued", revision: 0 });
    }

    function release(entry, flavor, consumer) {
        if (!entry || !consumer)
            return;
        delete consumers[`${key(entry, flavor)}|${consumer}`];
    }

    function eligibleVisual(mime) {
        return mime.indexOf("image/") === 0 || mime.indexOf("video/") === 0
            || mime === "application/pdf";
    }

    function flush() {
        const work = queued;
        const groups = ({});
        for (const requestKey in work) {
            const item = work[requestKey];
            // A recycled delegate may have released its interest before debounce.
            let interested = false;
            for (const consumerKey in consumers) {
                if (consumerKey.indexOf(`${requestKey}|`) === 0) { interested = true; break; }
            }
            if (!interested) continue;
            const groupKey = `${item.flavor}|${item.priority}`;
            if (!groups[groupKey])
                groups[groupKey] = [];
            groups[groupKey].push(item.entry);
            results[requestKey] = { state: "loading", revision: results[requestKey]?.revision ?? 0 };
        }
        // Publish loading before clearing queued. Otherwise clearing queued
        // invalidates FileVisual bindings while no result exists yet, causing
        // every delegate to enqueue the same work a second time.
        results = Object.assign({}, results);
        queued = ({});
        for (const groupKey in groups) {
            const separator = groupKey.lastIndexOf("|");
            const flavor = groupKey.slice(0, separator);
            const priority = groupKey.slice(separator + 1);
            const entries = groups[groupKey];
            Logger.debug("preview", `thumbnailBatch ${flavor} ${priority} x${entries.length}`);
            BackendClient.requestThumbnails(entries.map(entry => ({ path: entry.path, mimeType: entry.mimeType })), flavor,
                priority, result => {
                    for (const item of result.items ?? []) {
                        const entry = entries.find(candidate => candidate.path === item.path);
                        if (!entry) continue;
                        const requestKey = key(entry, flavor);
                        results[requestKey] = { state: item.status ?? "unsupported", url: item.url ?? "",
                            revision: (results[requestKey]?.revision ?? 0) + 1 };
                    }
                    results = Object.assign({}, results);
                }, message => {
                    Logger.warn("preview", `thumbnailBatch ${flavor} failed: ${message}`);
                    for (const entry of entries)
                        results[key(entry, flavor)] = { state: "error", revision: 0 };
                    results = Object.assign({}, results);
                });
        }
    }

    property Timer flushTimer: Timer { id: flushDelay; interval: 40; onTriggered: root.flush() }
}
