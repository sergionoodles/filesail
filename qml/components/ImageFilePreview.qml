import QtQuick
import QtQuick.Window
import "../core"

Item {
    id: root

    required property var entry
    property bool active: true

    readonly property string entryFingerprint: JSON.stringify([
        String(entry.url), Number(entry.size), String(entry.modified)
    ])
    readonly property url sourceUrl: entry.url
    readonly property real metadataAspectRatio: entry.imageWidth > 0 && entry.imageHeight > 0
        ? entry.imageWidth / entry.imageHeight : 0
    readonly property real intrinsicAspectRatio: image.status === Image.Ready
        && image.implicitWidth > 0 && image.implicitHeight > 0
        ? image.implicitWidth / image.implicitHeight : 0
    property int thumbnailConsumerToken: -1
    readonly property int previewManagerRevision: PreviewManager.revision
    readonly property var thumbnailPreview: thumbnailConsumerToken >= 0
        && previewManagerRevision >= 0
        ? PreviewManager.thumbnail(entry, "normal", thumbnailConsumerToken, "foreground", 128)
        : ({ state: "unsupported", revision: 0, lease: false })
    readonly property real thumbnailAspectRatio: ratioImage.status === Image.Ready
        && ratioImage.implicitWidth > 0
        && ratioImage.implicitHeight > 0
        ? ratioImage.implicitWidth / ratioImage.implicitHeight : 0
    readonly property real aspectRatio: metadataAspectRatio > 0 ? metadataAspectRatio
        : thumbnailAspectRatio > 0 ? thumbnailAspectRatio
        : intrinsicAspectRatio > 0 ? intrinsicAspectRatio : 0
    readonly property bool ready: active && requestedFingerprint === entryFingerprint
        && image.status === Image.Ready
    readonly property bool loading: active && !ready && image.status !== Image.Error
    readonly property bool error: active && requestedFingerprint === entryFingerprint
        && image.status === Image.Error
    readonly property string previewReadiness: !active ? "unavailable"
        : ready ? "ready" : error ? "error" : "loading"
    readonly property string previewError: error
        ? qsTr("Preview unavailable: %1").arg(entry.name) : ""

    property int decodedPixelWidth: 1
    property int decodedPixelHeight: 1
    property string requestedFingerprint: ""
    property string requestedSource: ""
    property int loadGeneration: 0

    function syncRatioThumbnail() {
        if (!active || metadataAspectRatio > 0) {
            if (thumbnailConsumerToken >= 0)
                PreviewManager.releaseConsumer(thumbnailConsumerToken);
            return;
        }
        if (thumbnailConsumerToken < 0)
            thumbnailConsumerToken = PreviewManager.allocateConsumer();
        PreviewManager.acquire(entry, "normal", thumbnailConsumerToken, "foreground", 128);
    }

    function releaseImage() {
        ++loadGeneration;
        requestedFingerprint = "";
        requestedSource = "";
    }

    function decodeLongSide() {
        // Decode once with enough headroom for normal pane resizing. Keeping
        // this bounded avoids turning a 16-image selection into a native-size
        // allocation storm; resizing scales the retained frame instead.
        return Math.min(2048, Math.max(1024,
            Math.ceil(Math.max(width, height) * Screen.devicePixelRatio * 2)));
    }

    function loadEntry() {
        ++loadGeneration;
        const generation = loadGeneration;
        const fingerprint = entryFingerprint;
        requestedFingerprint = "";
        requestedSource = "";
        decodedPixelWidth = decodeLongSide();
        decodedPixelHeight = decodedPixelWidth;
        // A separate event-loop turn makes a same-URL fingerprint change a
        // real Image reload without adding a query string to a local URL.
        Qt.callLater(() => {
            if (root.active && generation === root.loadGeneration
                    && fingerprint === root.entryFingerprint) {
                requestedFingerprint = fingerprint;
                requestedSource = root.entry.url;
            }
        });
    }

    onActiveChanged: {
        syncRatioThumbnail();
        active ? loadEntry() : releaseImage();
    }
    onEntryChanged: syncRatioThumbnail()
    onMetadataAspectRatioChanged: syncRatioThumbnail()
    onEntryFingerprintChanged: if (requestedFingerprint !== entryFingerprint) loadEntry()

    Image {
        id: ratioImage
        source: root.thumbnailPreview.state === "ready" && root.thumbnailPreview.lease
            ? root.thumbnailPreview.url + "#filesail-ratio-" + root.thumbnailPreview.revision : ""
        sourceSize: Qt.size(128, 128)
        asynchronous: true
        cache: false
        visible: false
    }

    Image {
        id: image
        anchors.fill: parent
        source: root.active ? root.requestedSource : ""
        sourceSize: Qt.size(root.decodedPixelWidth, root.decodedPixelHeight)
        asynchronous: true
        autoTransform: true
        cache: false
        smooth: true
        fillMode: Image.PreserveAspectFit
        visible: root.ready
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha(Theme.surface, 0.18)
        radius: Theme.radiusS
        visible: root.loading && root.aspectRatio > 0

        Rectangle {
            id: skeleton
            x: (parent.width - width) / 2
            y: (parent.height - height) / 2
            width: root.aspectRatio > 0
                ? Math.min(parent.width, parent.height * root.aspectRatio) : 0
            height: root.aspectRatio > 0
                ? Math.min(parent.height, parent.width / root.aspectRatio) : 0
            color: Qt.alpha(Theme.primary, 0.16)
            border.width: 1
            border.color: Qt.alpha(Theme.primary, 0.28)
            radius: Theme.radiusS

            SequentialAnimation on opacity {
                running: root.loading
                loops: Animation.Infinite
                NumberAnimation { from: 0.45; to: 0.85; duration: 700; easing.type: Easing.InOutSine }
                NumberAnimation { from: 0.85; to: 0.45; duration: 700; easing.type: Easing.InOutSine }
            }
        }
    }

    Rectangle {
        anchors.fill: parent
        color: "transparent"
        radius: Theme.radiusS
        visible: root.error

        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spaceM * 2, 260 * Theme.scale)
            spacing: Theme.spaceS

            FileIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(64 * Theme.scale, parent.width * 0.34)
                height: width
                iconName: root.entry.iconName
            }
            Text {
                width: parent.width
                color: Theme.error
                text: qsTr("Preview unavailable\n%1").arg(root.entry.name)
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                elide: Text.ElideMiddle
                Accessible.name: text
            }
        }
    }

    Component.onCompleted: {
        syncRatioThumbnail();
        loadEntry();
    }
    Component.onDestruction: {
        if (thumbnailConsumerToken >= 0)
            PreviewManager.releaseConsumer(thumbnailConsumerToken);
        releaseImage();
    }
}
