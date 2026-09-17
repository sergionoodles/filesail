import QtQuick
import "../core"

Item {
    id: root

    required property var session
    property string viewMode: "list"
    property bool inputBlocked: false
    signal contextMenuRequested(var entry, bool background, real x, real y)
    signal filterRequested(string text)

    function offerFiltering(event) {
        if (root.inputBlocked)
            return false;
        const activeLoader = root.viewMode === "list" ? listLoader : gridLoader;
        const activeView = activeLoader.item;
        if (!activeView || !activeView.activeFocus || event.modifiers !== Qt.NoModifier)
            return false;
        const text = String(event.text ?? "");
        if (text.length === 0)
            return false;
        for (let index = 0; index < text.length; ++index) {
            const code = text.charCodeAt(index);
            if (code === 0x2f || code < 0x20 || (code >= 0x7f && code <= 0x9f)
                    || code === 0x2028 || code === 0x2029)
                return false;
        }
        root.filterRequested(text);
        return true;
    }

    function focusActiveView() {
        const activeLoader = root.viewMode === "list" ? listLoader : gridLoader;
        if (activeLoader.item && activeLoader.item.focusView)
            activeLoader.item.focusView();
    }

    onViewModeChanged: Qt.callLater(root.focusActiveView)
    Component.onCompleted: Qt.callLater(root.focusActiveView)

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
                    root.focusActiveView();
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
                filterEventHandler: event => root.offerFiltering(event)
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
                filterEventHandler: event => root.offerFiltering(event)
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
