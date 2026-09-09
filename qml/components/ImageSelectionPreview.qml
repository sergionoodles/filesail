import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import "../core"

Item {
    id: root
    required property var entries
    property int selectionRevision: 0
    readonly property int maximumImages: 16
    readonly property var visibleEntries: entries.slice(0, maximumImages)

    Loader {
        anchors.fill: parent
        active: root.visibleEntries.length === 1
        sourceComponent: FileVisual {
            anchors.centerIn: parent
            width: Math.max(1, Math.min(parent.width, parent.height) - Theme.spaceM * 2)
            height: width
            entry: root.visibleEntries[0]
            thumbnailSize: Math.max(1, Math.ceil(width * Screen.devicePixelRatio))
            flavor: thumbnailSize <= 128 ? "normal" : thumbnailSize <= 256 ? "large" : "x-large"
            priority: "foreground"
        }
    }

    GridView {
        id: previewGrid
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spaceM
        anchors.rightMargin: Theme.spaceM
        height: Math.max(1, Math.min(parent.height - Theme.spaceM * 2, contentGridHeight))
        clip: true
        visible: root.visibleEntries.length > 1
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        model: root.visibleEntries
        cellWidth: visibleEntries.length === 1
            ? Math.max(1, width) : Math.max(120 * Theme.scale, width / 2)
        cellHeight: cellWidth
        readonly property int columnCount: Math.max(1, Math.floor(width / cellWidth))
        readonly property real contentGridHeight: Math.ceil(root.visibleEntries.length / columnCount) * cellHeight

        delegate: Item {
            required property var modelData
            required property int index
            width: previewGrid.cellWidth
            height: previewGrid.cellHeight
            Accessible.name: modelData.name
            Accessible.role: Accessible.ListItem
            FileVisual {
                id: imageVisual
                anchors.fill: parent
                anchors.margins: Theme.spaceS
                entry: modelData
                flavor: previewGrid.cellWidth * Screen.devicePixelRatio <= 128 ? "normal"
                    : previewGrid.cellWidth * Screen.devicePixelRatio <= 256 ? "large" : "x-large"
                priority: "foreground"
            }
            GridView.onPooled: imageVisual.releaseConsumer()
            GridView.onReused: imageVisual.acquireConsumer()
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Theme.spaceM
        visible: root.entries.length > root.maximumImages
        color: Qt.alpha(Theme.surface, 0.9)
        border.color: Theme.outline
        border.width: 1
        Text {
            id: summaryText
            anchors.centerIn: parent
            text: qsTr("%1 of %2 images").arg(root.maximumImages).arg(root.entries.length)
            color: Theme.text
            font.pixelSize: Theme.fontSmall
            Accessible.name: text
        }
        implicitWidth: Math.max(96 * Theme.scale, summaryText.implicitWidth + Theme.spaceS * 2)
        implicitHeight: Theme.fontSmall + Theme.spaceS * 2
    }
}
