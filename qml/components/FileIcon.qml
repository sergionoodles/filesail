import QtQuick
import Quickshell
import Quickshell.Widgets
import "../core"

Item {
    id: root

    property string iconName: "text-x-generic"
    property bool selected: false

    IconImage {
        anchors.fill: parent
        source: Quickshell.iconPath(root.iconName, "text-x-generic")
        asynchronous: true
        smooth: true
        opacity: root.selected ? 1.0 : 0.88
    }
}
