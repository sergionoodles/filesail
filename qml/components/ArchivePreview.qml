import QtQuick
import QtQuick.Layouts
import "../core"

Item {
    id: root
    required property var entry
    property var entries: []
    property string statusText: qsTr("Loading archive…")
    property int requestId: -1
    Component.onCompleted: {
        Logger.debug("preview", `archive ${entry.path}`);
        requestId = BackendClient.requestArchivePreview(entry.path, result => {
            entries = result.entries ?? [];
            statusText = result.truncated ? qsTr("Archive listing truncated") : result.format ?? "Archive";
        }, message => {
            Logger.warn("preview", `archive failed: ${message}`);
            statusText = message;
        });
    }
    Component.onDestruction: { if (requestId >= 0) BackendClient.cancelPreview(requestId); }
    ColumnLayout { anchors.fill: parent; anchors.margins: Theme.spaceM; spacing: Theme.spaceS
        Text { Layout.fillWidth: true; text: root.statusText; color: Theme.textMuted }
        ListView { Layout.fillWidth: true; Layout.fillHeight: true; model: root.entries; clip: true
            delegate: RowLayout { required property var modelData; width: ListView.view.width
                Text { Layout.fillWidth: true; text: modelData.name; color: Theme.text; elide: Text.ElideRight }
                Text { text: Format.size(modelData.size, false); color: Theme.textMuted }
            }
        }
    }
}
