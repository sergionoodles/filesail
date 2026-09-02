import QtQuick
import "../core"

Item {
    id: root

    required property var session
    property string viewMode: "list"

    function focusActiveView() {
        const activeLoader = root.viewMode === "list" ? listLoader : gridLoader;
        if (activeLoader.item && activeLoader.item.focusView)
            activeLoader.item.focusView();
    }

    onViewModeChanged: Qt.callLater(root.focusActiveView)

    Rectangle {
        anchors.fill: parent
        color: Theme.surface

        MouseArea { anchors.fill: parent; onClicked: root.session.clearSelection() }

        Loader {
            id: listLoader
            anchors.fill: parent
            active: root.viewMode === "list"
            sourceComponent: FileListView {
                session: root.session
                model: root.session.directory.entries
            }
        }

        Loader {
            id: gridLoader
            anchors.fill: parent
            anchors.margins: Theme.spaceL
            active: root.viewMode === "grid"
            sourceComponent: FileGridView {
                session: root.session
                model: root.session.directory.entries
            }
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
