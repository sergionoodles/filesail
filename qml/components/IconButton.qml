import QtQuick
import QtQuick.Controls
import "../core"

AbstractButton {
    id: root

    property string iconName: ""
    property string label: ""
    property string tooltip: label
    implicitWidth: label.length > 0 ? contentRow.implicitWidth + Theme.buttonPaddingHorizontal * 2 : implicitHeight
    implicitHeight: label.length > 0 ? Math.max(contentRow.implicitHeight + Theme.buttonPaddingVertical * 2, Theme.buttonHeight) : 40 * Theme.scale
    hoverEnabled: true
    checkable: true
    focusPolicy: Qt.StrongFocus
    Accessible.name: label.length > 0 ? label : tooltip
    Accessible.role: Accessible.Button
    opacity: enabled ? 1 : 0.35

    background: Rectangle {
        radius: Theme.radiusS
        color: root.checked ? Theme.selectionFill
             : root.down ? Qt.alpha(Theme.primary, 0.26)
             : root.hovered ? Theme.controlHover : "transparent"
        border.width: root.checked || root.visualFocus ? 1 : 0
        border.color: root.checked ? Qt.alpha(Theme.primary, 0.42) : Theme.primary
        Behavior on color { ColorAnimation { duration: Theme.animationFast } }
    }

    Row {
        id: contentRow
        anchors.centerIn: parent
        spacing: Theme.spaceS

        LucideIcon {
            name: root.iconName
            iconColor: root.checked ? Theme.primary : Theme.textMuted
            iconSize: Theme.iconSize
            anchors.verticalCenter: parent.verticalCenter
        }

        Text {
            visible: root.label.length > 0
            text: Format.safeText(root.label)
            textFormat: Text.PlainText
            color: Theme.text
            font.pixelSize: Theme.fontBody
            font.weight: Font.Medium
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    ToolTip.visible: hovered && tooltip.length > 0
    ToolTip.text: tooltip
    ToolTip.delay: 450
}
