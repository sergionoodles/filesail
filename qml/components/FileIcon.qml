import QtQuick
import Quickshell
import "../core"

Item {
    id: root

    property string iconName: "text-x-generic"
    property bool selected: false

    Image {
        anchors.fill: parent
        source: Quickshell.iconPath(root.iconName, "text-x-generic")
        sourceSize: Qt.size(Math.max(1, Math.ceil(root.width)), Math.max(1, Math.ceil(root.height)))
        asynchronous: true
        smooth: true
        opacity: root.selected ? 1.0 : 0.88
    }
}
