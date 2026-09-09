import QtQuick
import QtQuick.Layouts
import "../core"

Item {
    required property var entries
    ColumnLayout { anchors.fill: parent; anchors.margins: Theme.spaceXl; spacing: Theme.spaceM
        FileIcon { Layout.preferredWidth: 48 * Theme.scale; Layout.preferredHeight: width; iconName: entries.length === 1 ? entries[0].iconName : "text-x-generic" }
        Text { Layout.fillWidth: true; text: entries.length === 1 ? Format.safeText(entries[0].name) : qsTr("%1 items selected").arg(entries.length); color: Theme.text; font.pixelSize: Theme.fontTitle; wrapMode: Text.Wrap }
        Text { Layout.fillWidth: true; text: entries.length === 1 ? `${entries[0].mimeType}\n${Format.size(entries[0].size, entries[0].isDirectory)}` : qsTr("Select images only to see a combined preview."); color: Theme.textMuted; font.pixelSize: Theme.fontBody; wrapMode: Text.Wrap }
        Item { Layout.fillHeight: true }
    }
}
