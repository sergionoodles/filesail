import QtQuick
import "../core"

Rectangle {
    id: root

    property string icon: ""
    property string label: ""
    property bool checked: false
    property string tooltip: label
    signal clicked

    implicitWidth: label.length > 0 ? contentRow.implicitWidth + Theme.spaceM * 2 : 34 * Theme.scale
    implicitHeight: 34 * Theme.scale
    radius: Theme.radiusS
    color: checked ? Qt.alpha(Theme.primary, 0.18)
                   : mouseArea.containsMouse && enabled ? Qt.alpha(Theme.text, 0.08) : "transparent"
    border.width: checked ? 1 : 0
    border.color: Qt.alpha(Theme.primary, 0.42)
    opacity: enabled ? 1 : 0.35

    Behavior on color { ColorAnimation { duration: Theme.animationFast } }

    Row {
        id: contentRow
        anchors.centerIn: parent
        spacing: Theme.spaceS

        Text {
            text: root.icon
            color: root.checked ? Theme.primary : Theme.textMuted
            font.pixelSize: 16 * Theme.scale
            anchors.verticalCenter: parent.verticalCenter
        }

        Text {
            visible: root.label.length > 0
            text: root.label
            color: Theme.text
            font.pixelSize: Theme.fontBody
            font.weight: Font.Medium
            anchors.verticalCenter: parent.verticalCenter
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: root.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
        onClicked: if (root.enabled) root.clicked()
    }
}
