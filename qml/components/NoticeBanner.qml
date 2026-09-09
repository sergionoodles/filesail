import QtQuick
import "../core"

Rectangle {
    id: root

    property string noticeText: ""
    property bool noticeError: false
    readonly property bool showing: noticeTimer.running

    function show(message, isError) {
        noticeText = message;
        noticeError = isError;
        noticeTimer.restart();
    }

    anchors.top: parent.top
    anchors.horizontalCenter: parent.horizontalCenter
    anchors.topMargin: Theme.spaceM
    width: Math.min(parent.width - Theme.spaceXl * 2, noticeLabel.implicitWidth + Theme.spaceXl * 2)
    height: 34 * Theme.scale
    radius: Theme.radiusS
    color: noticeError ? Theme.error : Theme.primary
    visible: noticeTimer.running
    z: 900

    Text {
        id: noticeLabel
        anchors.centerIn: parent
        text: Format.safeText(root.noticeText)
        textFormat: Text.PlainText
        color: Theme.primaryText
        font.pixelSize: Theme.fontBody
        font.weight: Font.DemiBold
        elide: Text.ElideRight
    }

    Timer {
        id: noticeTimer
        interval: 2800
    }
}
