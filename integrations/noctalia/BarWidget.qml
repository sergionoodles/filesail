import QtQuick
import Quickshell
import qs.Commons
import qs.Services.UI

Item {
    id: root

    property var pluginApi: null
    property ShellScreen screen
    property string widgetId: ""
    property string section: ""

    readonly property string screenName: screen ? screen.name : ""
    readonly property real capsuleHeight: Style.getCapsuleHeightForScreen(screenName)
    readonly property real contentWidth: capsuleHeight
    readonly property real contentHeight: capsuleHeight

    anchors.centerIn: parent
    implicitWidth: contentWidth
    implicitHeight: contentHeight

    Rectangle {
        anchors.centerIn: parent
        width: root.contentWidth
        height: root.contentHeight
        radius: Style.radiusL
        color: mouseArea.containsMouse ? Color.mHover : Style.capsuleColor
        border.color: Style.capsuleBorderColor
        border.width: Style.capsuleBorderWidth

        Image {
            anchors.centerIn: parent
            width: root.capsuleHeight * 0.58
            height: width
            source: "../../logo.png"
            sourceSize: Qt.size(Math.ceil(root.contentWidth * 0.58), Math.ceil(root.contentHeight * 0.58))
            fillMode: Image.PreserveAspectFit
            mipmap: false
        }
    }

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: pluginApi?.togglePanel(root.screen, root)
        onEntered: TooltipService.show(root, "FileSail", BarService.getTooltipDirection(root.screenName))
        onExited: TooltipService.hide()
    }
}
