import QtQuick
import Quickshell
import Quickshell.Io
import "qml/core" as Core
import "integrations/noctalia" as Noctalia

ShellRoot {
    id: root
    property int primaryChanges: 0
    Connections {
        target: Core.Theme
        function onPrimaryChanged() { root.primaryChanges += 1; }
    }
    Noctalia.NoctaliaConfigThemeProvider { id: provider; theme: Core.Theme }
    IpcHandler {
        target: "themeTest"
        function snapshot(): string {
            return JSON.stringify({
                primary: String(Core.Theme.primary), surface: String(Core.Theme.surface),
                text: String(Core.Theme.text), appearance: Core.Theme.appearance,
                scale: Core.Theme.scale, animationFast: Core.Theme.animationFast,
                primaryChanges: root.primaryChanges,
                loaded: provider.liveThemeLoaded, ready: provider.templateReady,
                enabled: provider.templateEnabled, pending: provider.refreshPending
            });
        }
        function refresh(): void { provider.reloadWatchedFiles(); }
    }
}
