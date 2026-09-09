import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Item {
    id: root
    required property var entry
    property string html: ""
    property string statusText: qsTr("Loading preview…")
    property int requestId: -1
    function load() {
        Logger.debug("preview", `text ${entry.path}`);
        requestId = BackendClient.requestTextPreview(entry.path, Theme.appearance, result => {
            if (requestId < 0) return;
            html = result.html ?? "";
            statusText = result.kind === "unsupported" ? qsTr("This file cannot be shown as text.")
                : (result.truncated ? qsTr("Preview truncated") : result.language ?? "Plain Text");
        }, message => {
            Logger.warn("preview", `text failed: ${message}`);
            statusText = message;
        });
    }
    Component.onCompleted: load()
    Component.onDestruction: { if (requestId >= 0) BackendClient.cancelPreview(requestId); }
    ColumnLayout { anchors.fill: parent; anchors.margins: Theme.spaceM; spacing: Theme.spaceS
        Text { Layout.fillWidth: true; text: root.statusText; color: Theme.textMuted; font.pixelSize: Theme.fontSmall }
        ScrollView { Layout.fillWidth: true; Layout.fillHeight: true
            TextEdit { width: parent.width; readOnly: true; selectByMouse: true; textFormat: TextEdit.RichText; text: root.html; color: Theme.text; font.family: "monospace"; wrapMode: TextEdit.NoWrap }
        }
    }
}
