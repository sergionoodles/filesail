import QtQuick
import QtQuick.Controls
import "../core"

TextField {
    id: root

    property string leadingIconName: ""

    color: Theme.text
    placeholderTextColor: Theme.textMuted
    font.pixelSize: Theme.fontBody
    selectByMouse: true
    leftPadding: leadingIconName.length > 0 ? Theme.spaceM + 18 * Theme.scale + Theme.spaceS : Theme.spaceM
    rightPadding: Theme.spaceM
    background: Rectangle {
        implicitHeight: 38 * Theme.scale
        radius: Theme.radiusS
        color: Theme.surface
        border.width: 1
        border.color: root.activeFocus ? Theme.primary : Theme.divider
    }

    LucideIcon {
        anchors.left: parent.left
        anchors.leftMargin: Theme.spaceM
        anchors.verticalCenter: parent.verticalCenter
        name: root.leadingIconName
        iconSize: 17 * Theme.scale
        iconColor: Qt.alpha(Theme.primary, 0.65)
        visible: root.leadingIconName.length > 0 && root.text.length === 0
    }
}
