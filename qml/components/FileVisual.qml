import QtQuick
import QtQuick.Window
import "../core"

Item {
    id: root
    required property var entry
    property bool selected: false
    property int thumbnailSize: Math.max(1, Math.ceil(Math.max(width, height) * Screen.devicePixelRatio))
    property string flavor: "normal"
    property string priority: "background"
    property int consumerToken: -1
    property bool consumerActive: true
    readonly property int previewManagerRevision: PreviewManager.revision
    readonly property var preview: {
        // The revision is a real QML dependency, so existing delegates
        // re-evaluate after an asynchronous result mutates the cache record.
        return consumerActive && consumerToken >= 0 && previewManagerRevision >= 0
            ? PreviewManager.thumbnail(entry, flavor, consumerToken, priority, thumbnailSize)
            : ({ state: "unsupported", revision: 0, lease: false });
    }

    function acquireConsumer() {
        if (consumerToken < 0) consumerToken = PreviewManager.allocateConsumer();
        consumerActive = true;
        PreviewManager.acquire(entry, flavor, consumerToken, priority, thumbnailSize);
    }
    function releaseConsumer() {
        if (consumerToken >= 0) { PreviewManager.releaseConsumer(consumerToken); consumerActive = false; }
    }

    Component.onCompleted: acquireConsumer()
    onEntryChanged: if (consumerActive) acquireConsumer()
    onFlavorChanged: if (consumerActive) acquireConsumer()

    Loader {
        anchors.fill: parent
        active: previewImage.status !== Image.Ready
        sourceComponent: FileIcon { iconName: root.entry.iconName; selected: root.selected }
    }
    Image {
        id: previewImage
        anchors.fill: parent
        source: root.preview.state === "ready" && root.preview.lease ? root.preview.url : ""
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
    Component.onDestruction: releaseConsumer()
}
