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

    property ListModel previewEntriesModel: ListModel {
        dynamicRoles: true
    }

    function sameEntry(left, right) {
        return left && right
            && left.path === right.path
            && left.name === right.name
            && left.size === right.size
            && left.modified === right.modified
            && left.mimeType === right.mimeType
            && left.iconName === right.iconName;
    }

    function syncPreviewEntries() {
        const wanted = root.visibleEntries;
        const wantedPaths = new Set(wanted.map(entry => entry.path));

        for (let index = previewEntriesModel.count - 1; index >= 0; --index) {
            if (!wantedPaths.has(previewEntriesModel.get(index).entry.path))
                previewEntriesModel.remove(index);
        }

        for (let targetIndex = 0; targetIndex < wanted.length; ++targetIndex) {
            const wantedEntry = wanted[targetIndex];
            let currentIndex = -1;
            for (let index = targetIndex; index < previewEntriesModel.count; ++index) {
                if (previewEntriesModel.get(index).entry.path === wantedEntry.path) {
                    currentIndex = index;
                    break;
                }
            }
            if (currentIndex < 0) {
                previewEntriesModel.insert(targetIndex, { entry: wantedEntry });
            } else {
                if (currentIndex !== targetIndex)
                    previewEntriesModel.move(currentIndex, targetIndex, 1);
                if (!sameEntry(previewEntriesModel.get(targetIndex).entry, wantedEntry))
                    previewEntriesModel.setProperty(targetIndex, "entry", wantedEntry);
            }
        }
    }

    Component.onCompleted: syncPreviewEntries()
    onEntriesChanged: syncPreviewEntries()
    onSelectionRevisionChanged: syncPreviewEntries()

    GridView {
        id: previewGrid
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: Theme.spaceM
        anchors.rightMargin: Theme.spaceM
        height: Math.max(1, Math.min(parent.height - Theme.spaceM * 2, contentGridHeight))
        clip: true
        visible: root.previewEntriesModel.count > 0
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        model: root.previewEntriesModel
        cellWidth: previewEntriesModel.count === 1
            ? Math.max(1, Math.min(width, root.height - Theme.spaceM * 2))
            : Math.max(120 * Theme.scale, width / 2)
        cellHeight: cellWidth
        readonly property int columnCount: Math.max(1, Math.floor(width / cellWidth))
        readonly property real contentGridHeight: Math.ceil(root.previewEntriesModel.count / columnCount) * cellHeight

        delegate: Item {
            required property var entry
            required property int index
            width: previewGrid.cellWidth
            height: previewGrid.cellHeight
            Accessible.name: entry.name
            Accessible.role: Accessible.ListItem
            FileVisual {
                id: imageVisual
                anchors.fill: parent
                anchors.margins: Theme.spaceS
                entry: parent.entry
                thumbnailSize: 512
                flavor: "x-large"
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
