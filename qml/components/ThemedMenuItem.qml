import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

MenuItem {
    id: control

    hoverEnabled: true
    padding: Theme.spaceS
    leftPadding: Theme.spaceL
    rightPadding: Theme.spaceL
    spacing: Theme.spaceM
    implicitHeight: 32 * Theme.scale
    font.pixelSize: Theme.fontBody

    contentItem: RowLayout {
        spacing: control.spacing

        Text {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            text: Format.safeText(control.text)
            textFormat: Text.PlainText
            color: control.enabled ? Theme.text : Theme.textMuted
            font.pixelSize: Theme.fontBody
            elide: Text.ElideRight
            verticalAlignment: Text.AlignVCenter
        }

        Rectangle {
            visible: control.checkable
            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
            Layout.preferredWidth: 14 * Theme.scale
            Layout.preferredHeight: 14 * Theme.scale
            radius: Theme.radiusS
            color: control.checked ? Theme.primary : "transparent"
            border.width: 1
            border.color: control.checked ? Theme.primary : Theme.outline

            LucideIcon {
                anchors.centerIn: parent
                visible: control.checked
                name: "check"
                iconSize: 11 * Theme.scale
                iconColor: Theme.primaryText
            }
        }
    }

    indicator: Item {
        implicitWidth: 0
        implicitHeight: 0
    }

    background: Rectangle {
        implicitWidth: 200
        implicitHeight: 32 * Theme.scale
        radius: Theme.radiusS
        color: control.highlighted || control.down ? Theme.selectionFill
             : control.hovered ? Theme.controlHover : "transparent"
    }
}
