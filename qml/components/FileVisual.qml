import QtQuick
import "../core"

Item {
    id: root
    required property var entry
    property bool selected: false
    property int thumbnailSize: 128 * Theme.scale
    property string flavor: "normal"
    property string priority: "background"
    readonly property var preview: PreviewManager.thumbnail(entry, flavor, root, priority)

    FileIcon { anchors.fill: parent; iconName: root.entry.iconName; selected: root.selected; visible: previewImage.status !== Image.Ready }
    Image {
        id: previewImage
        anchors.fill: parent
        source: root.preview.state === "ready" ? root.preview.url : ""
        sourceSize.width: root.thumbnailSize
        sourceSize.height: root.thumbnailSize
        asynchronous: true; cache: false; fillMode: Image.PreserveAspectFit
        visible: status === Image.Ready
    }
    Rectangle {
        visible: root.entry.mimeType.indexOf("video/") === 0 && previewImage.status === Image.Ready
        anchors.right: parent.right; anchors.bottom: parent.bottom
        width: 16 * Theme.scale; height: width; color: Theme.primary; radius: Theme.radiusS
        Text { anchors.centerIn: parent; text: "▶"; color: Theme.primaryText; font.pixelSize: 9 * Theme.scale }
    }
    Component.onDestruction: PreviewManager.release(entry, flavor, root)
}
