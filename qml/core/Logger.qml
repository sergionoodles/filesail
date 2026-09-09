pragma Singleton

import QtQuick
import Quickshell

QtObject {
    id: root

    readonly property int errorLevel: 0
    readonly property int warnLevel: 1
    readonly property int infoLevel: 2
    readonly property int debugLevel: 3
    readonly property int level: root.levelFromEnv(Quickshell.env("FILESAIL_LOG"))

    function levelFromEnv(value) {
        const raw = String(value ?? "info").toLowerCase();
        if (raw === "debug")
            return debugLevel;
        if (raw === "warn" || raw === "warning")
            return warnLevel;
        if (raw === "error" || raw === "off" || raw === "silent")
            return errorLevel;
        return infoLevel;
    }

    function line(module, message) {
        return `[filesail:${module}] ${message}`;
    }

    function debug(module, message) {
        if (level >= debugLevel)
            console.log(line(module, message));
    }

    function info(module, message) {
        if (level >= infoLevel)
            console.info(line(module, message));
    }

    function warn(module, message) {
        if (level >= warnLevel)
            console.warn(line(module, message));
    }

    function error(module, message) {
        console.error(line(module, message));
    }
}
