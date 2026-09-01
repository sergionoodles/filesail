import QtQuick
import QtQuick.Controls
import "../core"

TextField {
    id: root

    color: Theme.text
    placeholderTextColor: Theme.textMuted
    font.pixelSize: Theme.fontBody
    selectByMouse: true
    leftPadding: Theme.spaceM
    rightPadding: Theme.spaceM
    background: Rectangle {
        implicitHeight: 38 * Theme.scale
        radius: Theme.radiusS
        color: Theme.surface
        border.width: 1
        border.color: root.activeFocus ? Theme.primary : Theme.divider
    }
}
