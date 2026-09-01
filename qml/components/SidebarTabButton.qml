import QtQuick
import QtQuick.Controls
import "../core"

AbstractButton {
    id: root

    required property string iconName
    required property string tooltip
    implicitWidth: 40 * Theme.scale
    implicitHeight: implicitWidth
    hoverEnabled: true
    checkable: true
    focusPolicy: Qt.StrongFocus
    Accessible.name: tooltip
    Accessible.role: Accessible.PageTab

    background: Rectangle {
        radius: Theme.radiusS
        color: root.checked ? Theme.selectionFill : root.hovered ? Theme.controlHover : "transparent"
        border.width: root.visualFocus ? 1 : 0
        border.color: Theme.primary
    }
    contentItem: LucideIcon {
        name: root.iconName
        iconColor: root.checked ? Theme.primary : Theme.textMuted
        iconSize: Theme.iconSize
    }
    ToolTip.visible: hovered
    ToolTip.text: tooltip
    ToolTip.delay: 450
}
