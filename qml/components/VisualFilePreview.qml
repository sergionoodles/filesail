import QtQuick
import QtQuick.Layouts
import "../core"

Item {
    id: root
    required property var entry
    readonly property bool video: entry.mimeType.indexOf("video/") === 0
    ColumnLayout { anchors.fill: parent; anchors.margins: Theme.spaceM; spacing: Theme.spaceM
        FileVisual { Layout.fillWidth: true; Layout.fillHeight: true; entry: root.entry; thumbnailSize: 1024 * Theme.scale; flavor: "xx-large"; priority: "foreground" }
        Text { Layout.fillWidth: true; text: `${root.entry.name}\n${Format.size(root.entry.size, false)}`; color: Theme.textMuted; textFormat: Text.PlainText; elide: Text.ElideRight }
    }
}
