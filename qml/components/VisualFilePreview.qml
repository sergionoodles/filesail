import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import "../core"

Item {
    id: root
    required property var entry
    readonly property bool video: entry.mimeType.indexOf("video/") === 0
    ColumnLayout { anchors.fill: parent; anchors.margins: Theme.spaceM; spacing: Theme.spaceM
        Item {
            Layout.fillWidth: true
            Layout.fillHeight: true

            FileVisual {
                anchors.centerIn: parent
                width: Math.min(parent.width, parent.height)
                height: width
                entry: root.entry
                thumbnailSize: Math.max(1, Math.ceil(Math.min(parent.width, parent.height) * Screen.devicePixelRatio))
                flavor: thumbnailSize <= 128 ? "normal" : thumbnailSize <= 256 ? "large" : "x-large"
                priority: "foreground"
            }
        }
        Text { Layout.fillWidth: true; text: `${root.entry.name}\n${Format.size(root.entry.size, false)}`; color: Theme.textMuted; textFormat: Text.PlainText; elide: Text.ElideRight }
    }
}
