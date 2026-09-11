import QtQuick
import Quickshell
import "../core" as FileSailCore

FloatingWindow {
    id: root

    required property int windowId
    required property string initialPath
    property var initialSelectionPaths: []
    property bool beingDestroyed: false
    readonly property alias controlAdapter: controlAdapterObject

    signal closeRequested()
    signal newWindowRequested(string path)

    visible: true
    title: "FileSail"
    implicitWidth: 1120
    implicitHeight: 760
    minimumSize: Qt.size(720, 480)
    color: FileSailCore.Theme.surface

    FileSailView {
        id: browserView
        anchors.fill: parent
        initialPath: root.initialPath
        initialSelectionPaths: root.initialSelectionPaths
        onNewWindowRequested: path => root.newWindowRequested(path)
    }

    property FileSailCore.ControlWindowAdapter controlAdapterProperty: FileSailCore.ControlWindowAdapter {
        id: controlAdapterObject
        view: browserView
        hostKind: "standalone"
        hostVisible: root.visible
        label: root.title
    }

    onVisibleChanged: {
        if (!visible && !beingDestroyed)
            closeRequested();
    }
}
