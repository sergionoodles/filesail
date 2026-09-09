import QtQuick
import Quickshell
import "../core" as FileSailCore

FloatingWindow {
    id: root

    required property int windowId
    required property string initialPath
    property var initialSelectionPaths: []
    property bool beingDestroyed: false

    signal closeRequested()
    signal newWindowRequested(string path)

    visible: true
    title: "FileSail"
    implicitWidth: 1120
    implicitHeight: 760
    minimumSize: Qt.size(720, 480)
    color: FileSailCore.Theme.surface

    FileSailView {
        anchors.fill: parent
        initialPath: root.initialPath
        initialSelectionPaths: root.initialSelectionPaths
        onNewWindowRequested: path => root.newWindowRequested(path)
    }

    onVisibleChanged: {
        if (!visible && !beingDestroyed)
            closeRequested();
    }
}
