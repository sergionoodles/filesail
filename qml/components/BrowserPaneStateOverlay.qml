import QtQuick
import "../core"

Item {
    id: root

    property bool loading: false
    property string error: ""
    property int itemCount: 0
    property string filter: ""
    signal retryRequested()

    Column {
        anchors.centerIn: parent
        spacing: Theme.spaceM
        visible: !root.loading && root.error.length === 0 && root.itemCount === 0
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.filter.length > 0 ? "⌕" : "◇"; color: Theme.textMuted; font.pixelSize: Math.round(34 * Theme.scale) }
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.filter.length > 0 ? "No matching files" : "This folder is empty"; color: Theme.textMuted; font.pixelSize: Theme.fontBody }
    }
    Column {
        anchors.centerIn: parent
        spacing: Theme.spaceM
        visible: root.error.length > 0
        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "!"; color: Theme.error; font.pixelSize: Math.round(30 * Theme.scale); font.bold: true }
        Text { width: Math.min(root.width - 60, 480); text: Format.safeText(root.error); textFormat: Text.PlainText; color: Theme.textMuted; font.pixelSize: Theme.fontBody; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
        IconButton { anchors.horizontalCenter: parent.horizontalCenter; label: "Retry"; onClicked: root.retryRequested() }
    }
    Rectangle {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 2
        color: Theme.primary
        visible: root.loading
        opacity: 0.8
        SequentialAnimation on opacity {
            running: root.loading
            loops: Animation.Infinite
            NumberAnimation { to: 0.25; duration: 500 }
            NumberAnimation { to: 0.9; duration: 500 }
        }
    }
}
