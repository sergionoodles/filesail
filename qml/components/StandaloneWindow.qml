import QtQuick
import Quickshell
import "../core" as FileSailCore

FloatingWindow {
    id: root

    required property int windowId
    required property string initialPath
    property bool beingDestroyed: false

    signal closeRequested()

    visible: true
    title: "FileSail"
    implicitWidth: 1120
    implicitHeight: 760
    minimumSize: Qt.size(720, 480)
    color: FileSailCore.Theme.surface

    FileSailView {
        anchors.fill: parent
        initialPath: root.initialPath
    }

    onVisibleChanged: {
        if (!visible && !beingDestroyed)
            closeRequested();
    }
}
