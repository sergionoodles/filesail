import QtQuick
import "../core"

Item {
    id: root

    required property var session
    property string viewMode: "list"
    signal contextMenuRequested(var entry, bool background, real x, real y)

    function focusActiveView() {
        const activeLoader = root.viewMode === "list" ? listLoader : gridLoader;
        if (activeLoader.item && activeLoader.item.focusView)
            activeLoader.item.focusView();
    }

    onViewModeChanged: Qt.callLater(root.focusActiveView)

    Rectangle {
        anchors.fill: parent
        color: Theme.surface

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) {
                    root.session.clearSelection();
                    root.contextMenuRequested(null, true, mouse.x, mouse.y);
                } else {
                    root.session.clearSelection();
                }
            }
        }

        Loader {
            id: listLoader
            anchors.fill: parent
            active: root.viewMode === "list"
            sourceComponent: FileListView {
                session: root.session
                model: root.session.directory.entries
                onContextMenuRequested: (entry, x, y) => {
                    const point = listLoader.item.mapToItem(root, x, y);
                    root.contextMenuRequested(entry, !entry, point.x, point.y);
                }
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
                onContextMenuRequested: (entry, x, y) => {
                    const point = gridLoader.item.mapToItem(root, x, y);
                    root.contextMenuRequested(entry, !entry, point.x, point.y);
                }
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
