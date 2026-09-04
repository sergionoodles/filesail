pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "../core"

ColumnLayout {
    id: root

    required property var session
    property var model: null
    property var marqueeBaseSelection: []
    property bool marqueeAdditive: false

    function focusView() {
        listView.forceActiveFocus();
    }

    spacing: 0

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 30 * Theme.scale
        color: Qt.alpha(Theme.surfaceVariant, 0.25)

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spaceL + 34 * Theme.scale
            anchors.rightMargin: Theme.spaceL
            spacing: Theme.spaceM

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
                implicitHeight: 30 * Theme.scale

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spaceXs

                    Text {
                        text: qsTr("NAME")
                        color: nameHeaderMouse.containsMouse ? Theme.text : Theme.textMuted
                        font.pixelSize: Theme.fontSmall - 1
                        font.weight: Font.DemiBold
                    }
                    LucideIcon {
                        visible: root.session.directory.sortBy === "name"
                        name: root.session.directory.descending ? "chevron-down" : "chevron-up"
                        iconSize: Theme.fontSmall
                        iconColor: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    id: nameHeaderMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    Accessible.name: qsTr("Sort by name")
                    Accessible.role: Accessible.Button
                    onClicked: root.session.toggleSort("name")
                }
            }

            Item {
                Layout.preferredWidth: 116 * Theme.scale
                Layout.fillHeight: true
                implicitHeight: 30 * Theme.scale

                Row {
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spaceXs

                    Text {
                        text: qsTr("MODIFIED")
                        color: modifiedHeaderMouse.containsMouse ? Theme.text : Theme.textMuted
                        font.pixelSize: Theme.fontSmall - 1
                        font.weight: Font.DemiBold
                    }
                    LucideIcon {
                        visible: root.session.directory.sortBy === "modified"
                        name: root.session.directory.descending ? "chevron-down" : "chevron-up"
                        iconSize: Theme.fontSmall
                        iconColor: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                MouseArea {
                    id: modifiedHeaderMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    Accessible.name: qsTr("Sort by modification date")
                    Accessible.role: Accessible.Button
                    onClicked: root.session.toggleSort("modified")
                }
            }

            Item {
                Layout.preferredWidth: 72 * Theme.scale
                Layout.fillHeight: true
                implicitHeight: 30 * Theme.scale

                Row {
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spaceXs

                    LucideIcon {
                        visible: root.session.directory.sortBy === "size"
                        name: root.session.directory.descending ? "chevron-down" : "chevron-up"
                        iconSize: Theme.fontSmall
                        iconColor: Theme.primary
                        anchors.verticalCenter: parent.verticalCenter
                    }
                    Text {
                        text: qsTr("SIZE")
                        color: sizeHeaderMouse.containsMouse ? Theme.text : Theme.textMuted
                        font.pixelSize: Theme.fontSmall - 1
                        font.weight: Font.DemiBold
                    }
                }

                MouseArea {
                    id: sizeHeaderMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    Accessible.name: qsTr("Sort by size")
                    Accessible.role: Accessible.Button
                    onClicked: root.session.toggleSort("size")
                }
            }
        }
    }

    ListView {
        id: listView
        Layout.fillWidth: true
        Layout.fillHeight: true
        model: root.model
        clip: true
        reuseItems: true
        cacheBuffer: 168 * Theme.scale
        boundsBehavior: Flickable.StopAtBounds
        focus: true
        activeFocusOnTab: true
        keyNavigationEnabled: false

        function entryAt(index) {
            return root.model && index >= 0 && index < root.model.length ? root.model[index] : null;
        }

        function syncFocusedIndex() {
            let index = -1;
            for (let candidate = 0; candidate < listView.count; ++candidate) {
                const entry = listView.entryAt(candidate);
                if (entry && entry.path === root.session.focusedPath) {
                    index = candidate;
                    break;
                }
            }
            if (index < 0 && listView.count > 0)
                index = 0;
            listView.currentIndex = index;
        }

        function moveFocusTo(index, modifiers) {
            if (listView.count === 0)
                return;
            const nextIndex = Math.max(0, Math.min(listView.count - 1, index));
            const entry = listView.entryAt(nextIndex);
            if (!entry)
                return;
            listView.currentIndex = nextIndex;
            listView.positionViewAtIndex(nextIndex, ListView.Contain);
            root.session.moveFocus(entry.path, modifiers);
        }

        function marqueePaths(x, y, width, height) {
            const rowHeight = 42 * Theme.scale;
            const top = y + listView.contentY;
            const bottom = y + height + listView.contentY;
            const first = Math.max(0, Math.floor(top / rowHeight));
            const last = Math.min(listView.count - 1, Math.floor(Math.max(top, bottom - 0.001) / rowHeight));
            const paths = [];
            if (last < first || x + width <= 0 || x >= listView.width)
                return paths;
            for (let index = first; index <= last; ++index) {
                const entry = listView.entryAt(index);
                if (entry)
                    paths.push(entry.path);
            }
            return paths;
        }

        function updateMarquee(x, y, width, height) {
            root.session.setSelection(
                listView.marqueePaths(x, y, width, height),
                root.marqueeAdditive,
                "",
                root.marqueeBaseSelection);
        }

        Component.onCompleted: syncFocusedIndex()
        onActiveFocusChanged: if (activeFocus) syncFocusedIndex()
        onModelChanged: syncFocusedIndex()
        onCountChanged: syncFocusedIndex()

        Connections {
            target: root.session
            function onFocusedPathChanged() { listView.syncFocusedIndex(); }
        }

        SelectionMarquee {
            id: listMarquee
            anchors.fill: parent
            selectionView: listView
            session: root.session
            pointInItem: (x, y) => {
                const rowHeight = 42 * Theme.scale;
                const contentY = y + listView.contentY;
                const index = Math.floor(contentY / rowHeight);
                return index >= 0 && index < listView.count && x >= 0 && x < listView.width;
            }
            onDragStarted: modifiers => {
                listView.forceActiveFocus();
                root.marqueeBaseSelection = Object.keys(root.session.selectedPaths);
                root.marqueeAdditive = (modifiers & Qt.ControlModifier) !== 0;
            }
            onDragChanged: (x, y, width, height) => listView.updateMarquee(x, y, width, height)
            onDragFinished: (x, y, width, height) => {
                const paths = listView.marqueePaths(x, y, width, height);
                root.session.setSelection(paths, root.marqueeAdditive, paths[paths.length - 1] ?? "", root.marqueeBaseSelection);
                root.marqueeBaseSelection = [];
            }
        }

        Keys.onPressed: event => {
            const modifiers = event.modifiers;
            const control = (modifiers & Qt.ControlModifier) !== 0;
            let target = listView.currentIndex < 0 ? 0 : listView.currentIndex;
            let handled = true;
            if (event.key === Qt.Key_Up)
                target -= 1;
            else if (event.key === Qt.Key_Down)
                target += 1;
            else if (event.key === Qt.Key_Home)
                target = 0;
            else if (event.key === Qt.Key_End)
                target = listView.count - 1;
            else if (event.key === Qt.Key_PageUp)
                target -= Math.max(1, Math.floor(listView.height / (42 * Theme.scale)));
            else if (event.key === Qt.Key_PageDown)
                target += Math.max(1, Math.floor(listView.height / (42 * Theme.scale)));
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                const entry = listView.entryAt(target);
                if (entry)
                    root.session.openEntry(entry.path, entry.isDirectory);
            } else if (event.key === Qt.Key_Space) {
                root.session.toggleFocusedEntry();
            } else if (event.key === Qt.Key_Backspace) {
                root.session.navigation.up();
            } else if (event.key === Qt.Key_Escape) {
                root.session.clearSelection();
            } else if (event.key === Qt.Key_A && control) {
                root.session.selectAllVisible();
            } else {
                handled = false;
            }
            if (handled) {
                if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter
                        && event.key !== Qt.Key_Space && event.key !== Qt.Key_Backspace
                        && event.key !== Qt.Key_Escape && !(event.key === Qt.Key_A && control))
                    listView.moveFocusTo(target, modifiers);
                event.accepted = true;
            }
        }

        delegate: Rectangle {
            id: listDelegate
            required property int index
            required property var modelData
            required property string name
            required property string path
            required property bool isDirectory
            required property double size
            required property string modified
            required property string iconName
            required property string mimeType
            width: listView.width
            height: 42 * Theme.scale
            Accessible.name: listDelegate.name
            Accessible.role: Accessible.ListItem
            color: root.session.selectedPaths[path] ? Qt.alpha(Theme.primary, 0.16)
                 : rowMouse.containsMouse ? Qt.alpha(Theme.text, 0.055) : "transparent"
            border.width: root.session.focusedPath === listDelegate.path && listView.activeFocus ? 1 : 0
            border.color: Theme.primary

            Rectangle {
                anchors.left: parent.left
                width: 2 * Theme.scale
                height: parent.height - Theme.spaceM
                anchors.verticalCenter: parent.verticalCenter
                radius: 1
                color: Theme.primary
                visible: root.session.selectedPaths[listDelegate.path] ?? false
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.spaceL
                anchors.rightMargin: Theme.spaceL
                spacing: Theme.spaceM
                FileVisual {
                    id: listVisual
                    Layout.preferredWidth: 24 * Theme.scale; Layout.preferredHeight: 24 * Theme.scale
                    entry: listDelegate.modelData
                    selected: root.session.selectedPaths[listDelegate.path] ?? false
                    thumbnailSize: 24 * Theme.scale
                }
                Text { Layout.fillWidth: true; text: Format.safeText(listDelegate.name); textFormat: Text.PlainText; color: Theme.text; font.pixelSize: Theme.fontBody; elide: Text.ElideRight }
                Text { Layout.preferredWidth: 116 * Theme.scale; text: Format.date(listDelegate.modified); textFormat: Text.PlainText; color: Theme.textMuted; font.pixelSize: Theme.fontSmall; elide: Text.ElideRight }
                Text { Layout.preferredWidth: 72 * Theme.scale; horizontalAlignment: Text.AlignRight; text: Format.size(listDelegate.size, listDelegate.isDirectory); textFormat: Text.PlainText; color: Theme.textMuted; font.pixelSize: Theme.fontSmall }
            }
            MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onClicked: mouse => {
                    listView.forceActiveFocus();
                    root.session.selectEntry(listDelegate.path, mouse.modifiers);
                }
                onDoubleClicked: root.session.openEntry(listDelegate.path, listDelegate.isDirectory)
            }
            ListView.onPooled: listVisual.releaseConsumer()
            ListView.onReused: listVisual.acquireConsumer()
        }
    }
}
