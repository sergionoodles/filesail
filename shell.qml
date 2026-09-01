import QtQuick
import Quickshell
import "qml/components" as FileSail
import "qml/core" as FileSailCore

ShellRoot {
    FloatingWindow {
        id: window

        visible: true
        title: "FileSail"
        implicitWidth: 1120
        implicitHeight: 760
        minimumSize: Qt.size(720, 480)
        color: FileSailCore.Theme.surface
        onVisibleChanged: if (!visible) Qt.quit()

        FileSail.FileSailView {
            anchors.fill: parent
            initialPath: {
                const requested = String(Quickshell.env("FILESAIL_PATH") ?? "");
                return requested.length > 0 ? requested : String(Quickshell.env("HOME") ?? "/");
            }
        }
    }
}
