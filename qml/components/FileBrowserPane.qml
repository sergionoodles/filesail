import QtQuick
import "../core"

Item {
    id: root

    required property var session
    property string viewMode: "list"

    Rectangle {
        anchors.fill: parent
        color: Theme.surface

        MouseArea { anchors.fill: parent; onClicked: root.session.clearSelection() }

        FileListView {
            anchors.fill: parent
            session: root.session
            visible: root.viewMode === "list"
            model: root.viewMode === "list" ? root.session.directory.entries : null
        }

        FileGridView {
            anchors.fill: parent
            anchors.margins: Theme.spaceL
            session: root.session
            visible: root.viewMode === "grid"
            model: root.viewMode === "grid" ? root.session.directory.entries : null
        }

        BrowserPaneStateOverlay {
            anchors.fill: parent
            loading: root.session.directory.loading
            error: root.session.directory.error
            itemCount: root.session.directory.count
            filter: root.session.directory.filter
            onRetryRequested: root.session.directory.refresh("refresh")
        }
    }
}
