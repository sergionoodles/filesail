import QtQuick
import QtQuick.Layouts
import "../core"

Rectangle {
    id: root

    property int itemCount: 0
    property int selectedCount: 0
    property int clipboardCount: 0
    property string clipboardMode: "copy"

    implicitHeight: 30 * Theme.scale
    color: Theme.surface

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.spaceL
        anchors.rightMargin: Theme.spaceL
        Text {
            Layout.fillWidth: true
            text: root.selectedCount > 0 ? `${root.selectedCount} selected` : `${root.itemCount} items`
            color: Theme.textMuted
            font.pixelSize: Theme.fontSmall
        }
        Text {
            text: root.clipboardCount > 0 ? `${root.clipboardMode === "move" ? "Move" : "Copy"} buffer: ${root.clipboardCount}` : ""
            color: Theme.primary
            font.pixelSize: Theme.fontSmall
        }
    }
}
