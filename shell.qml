import QtQuick
import Quickshell
import Quickshell.Io
import "qml/components" as FileSail
import "qml/core" as FileSailCore
import "integrations/noctalia" as Noctalia

ShellRoot {
    id: root

    Noctalia.NoctaliaConfigThemeProvider {
        theme: FileSailCore.Theme
    }

    property FileSailCore.WindowRegistry windowRegistry: FileSailCore.WindowRegistry {
        owner: root
        windowComponent: standaloneWindow
    }

    Component { id: standaloneWindow; FileSail.StandaloneWindow {} }

    IpcHandler {
        // The version is part of the endpoint name as well as the call
        // envelope. This lets a launcher distinguish an incompatible owner;
        // qs ipc reports an unknown target instead of silently accepting it.
        target: "filesail.v1"

        function ping(version: string) {
            return windowRegistry.acceptsVersion(version) ? "filesail/1" : "version-mismatch";
        }

        function open(path: string, version: string) {
            return windowRegistry.open(path, version) ? "accepted" : "rejected";
        }

        function show(path: string, selectionJson: string, version: string) {
            return windowRegistry.show(path, selectionJson, version) ? "accepted" : "rejected";
        }
    }

    Component.onCompleted: {
        const initial = String(Quickshell.env("FILESAIL_PATH") ?? "");
        const selection = String(Quickshell.env("FILESAIL_SELECTION_JSON") ?? "[]");
        if (!windowRegistry.show(initial, selection, String(windowRegistry.protocolVersion)))
            Qt.quit();
    }

}
