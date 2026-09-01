import QtQuick
import "../core"

Item {
    id: root
    required property var entries
    property int selectionRevision: 0
    Flickable {
        id: previews
        anchors.fill: parent
        anchors.margins: Theme.spaceM
        clip: true
        contentWidth: Math.max(width, previewGrid.width)
        contentHeight: Math.max(height, previewGrid.height)
        boundsBehavior: Flickable.StopAtBounds

        Grid {
            id: previewGrid
            readonly property real cellSize: root.entries.length === 1
                ? Math.min(previews.width, previews.height)
                : Math.max(120 * Theme.scale, previews.width / 2)
            readonly property int columnCount: Math.max(1, Math.min(root.entries.length, Math.floor(previews.width / cellSize)))
            x: Math.max(0, (previews.width - width) / 2)
            y: Math.max(0, (previews.height - height) / 2)
            columns: columnCount
            width: columnCount * cellSize
            height: Math.ceil(root.entries.length / columnCount) * cellSize

            Repeater {
                model: root.entries
                delegate: Item {
                    required property var modelData
                    width: previewGrid.cellSize
                    height: previewGrid.cellSize
                    Accessible.name: modelData.name
                    Accessible.role: Accessible.ListItem
                    FileVisual {
                        anchors.fill: parent
                        anchors.margins: Theme.spaceS
                        entry: modelData
                        thumbnailSize: 512 * Theme.scale
                        flavor: "x-large"
                        priority: "foreground"
                    }
                }
            }
        }
    }
}
