import QtQuick
import "../core"

Item {
    id: root
    required property var entries
    property int selectionRevision: 0
    GridView {
        anchors.fill: parent; anchors.margins: Theme.spaceM; clip: true
        model: root.entries; cellWidth: Math.max(120 * Theme.scale, width / 2); cellHeight: cellWidth
        delegate: Item { required property var modelData; width: GridView.view.cellWidth; height: GridView.view.cellHeight
            Accessible.name: modelData.name; Accessible.role: Accessible.ListItem
            FileVisual { anchors.fill: parent; anchors.margins: Theme.spaceS; entry: modelData; thumbnailSize: 512 * Theme.scale; flavor: "x-large"; priority: "foreground" }
        }
    }
}
