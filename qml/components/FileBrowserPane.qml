pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "../core"

Item {
    id: root

    required property var session
    property string viewMode: "list"

    Rectangle {
        anchors.fill: parent
        color: Theme.surface

        MouseArea { anchors.fill: parent; onClicked: root.session.clearSelection() }

        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            visible: root.viewMode === "list"

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 30 * Theme.scale
                color: Qt.alpha(Theme.surfaceVariant, 0.25)

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spaceL + 34 * Theme.scale
                    anchors.rightMargin: Theme.spaceL
                    spacing: Theme.spaceM
                    Text { Layout.fillWidth: true; text: "NAME"; color: Theme.textMuted; font.pixelSize: Theme.fontSmall - 1; font.weight: Font.DemiBold }
                    Text { Layout.preferredWidth: 116 * Theme.scale; text: "MODIFIED"; color: Theme.textMuted; font.pixelSize: Theme.fontSmall - 1; font.weight: Font.DemiBold }
                    Text { Layout.preferredWidth: 72 * Theme.scale; horizontalAlignment: Text.AlignRight; text: "SIZE"; color: Theme.textMuted; font.pixelSize: Theme.fontSmall - 1; font.weight: Font.DemiBold }
                }
            }

            ListView {
                id: listView
                Layout.fillWidth: true
                Layout.fillHeight: true
                model: root.viewMode === "list" ? root.session.directory.entries : null
                clip: true
                cacheBuffer: 168 * Theme.scale
                boundsBehavior: Flickable.StopAtBounds

                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    gesturePolicy: TapHandler.DragThreshold
                    onTapped: eventPoint => {
                        const index = listView.indexAt(
                            eventPoint.position.x + listView.contentX,
                            eventPoint.position.y + listView.contentY);
                        if (index === -1)
                            root.session.clearSelection();
                    }
                }

                delegate: Rectangle {
                    id: listDelegate
                    required property int index
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
                            Layout.preferredWidth: 24 * Theme.scale; Layout.preferredHeight: 24 * Theme.scale
                            entry: ({ name: listDelegate.name, path: listDelegate.path, isDirectory: listDelegate.isDirectory, size: listDelegate.size, modified: listDelegate.modified, iconName: listDelegate.iconName, mimeType: listDelegate.mimeType })
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
                        onClicked: mouse => root.session.select(listDelegate.path, mouse.modifiers)
                        onDoubleClicked: root.session.openEntry(listDelegate.path, listDelegate.isDirectory)
                        activeFocusOnTab: true
                        Keys.onReturnPressed: root.session.openEntry(listDelegate.path, listDelegate.isDirectory)
                        Keys.onEnterPressed: root.session.openEntry(listDelegate.path, listDelegate.isDirectory)
                        Keys.onSpacePressed: root.session.select(listDelegate.path, Qt.NoModifier)
                    }
                }
            }
        }

        GridView {
            id: gridView
            anchors.fill: parent
            anchors.margins: Theme.spaceL
            visible: root.viewMode === "grid"
            model: root.viewMode === "grid" ? root.session.directory.entries : null
            clip: true
            cacheBuffer: gridView.cellHeight * 2
            cellWidth: 118 * Theme.scale
            cellHeight: 112 * Theme.scale
            boundsBehavior: Flickable.StopAtBounds

            TapHandler {
                acceptedButtons: Qt.LeftButton
                gesturePolicy: TapHandler.DragThreshold
                onTapped: eventPoint => {
                    const index = gridView.indexAt(
                        eventPoint.position.x + gridView.contentX,
                        eventPoint.position.y + gridView.contentY);
                    if (index === -1)
                        root.session.clearSelection();
                }
            }
            delegate: Rectangle {
                id: gridDelegate
                required property int index
                required property string name
                required property string path
                required property bool isDirectory
                required property double size
                required property string modified
                required property string iconName
                required property string mimeType
                width: gridView.cellWidth - Theme.spaceS
                height: gridView.cellHeight - Theme.spaceS
                radius: Theme.radiusM
                Accessible.name: gridDelegate.name
                Accessible.role: Accessible.ListItem
                color: root.session.selectedPaths[path] ? Qt.alpha(Theme.primary, 0.16)
                     : gridMouse.containsMouse ? Qt.alpha(Theme.text, 0.06) : "transparent"
                border.width: root.session.selectedPaths[path] ? 1 : 0
                border.color: Qt.alpha(Theme.primary, 0.5)
                Column {
                    anchors.centerIn: parent
                    width: parent.width - Theme.spaceM * 2
                    spacing: Theme.spaceS
                    FileVisual { width: 46 * Theme.scale; height: 46 * Theme.scale; anchors.horizontalCenter: parent.horizontalCenter
                        entry: ({ name: gridDelegate.name, path: gridDelegate.path, isDirectory: gridDelegate.isDirectory, iconName: gridDelegate.iconName, mimeType: gridDelegate.mimeType, size: gridDelegate.size, modified: gridDelegate.modified })
                        selected: root.session.selectedPaths[gridDelegate.path] ?? false }
                    Text { width: parent.width; text: Format.safeText(gridDelegate.name); textFormat: Text.PlainText; color: Theme.text; font.pixelSize: Theme.fontBody; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.Wrap }
                }
                MouseArea {
                    id: gridMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: mouse => root.session.select(gridDelegate.path, mouse.modifiers)
                    onDoubleClicked: root.session.openEntry(gridDelegate.path, gridDelegate.isDirectory)
                    activeFocusOnTab: true
                    Keys.onReturnPressed: root.session.openEntry(gridDelegate.path, gridDelegate.isDirectory)
                    Keys.onEnterPressed: root.session.openEntry(gridDelegate.path, gridDelegate.isDirectory)
                    Keys.onSpacePressed: root.session.select(gridDelegate.path, Qt.NoModifier)
                }
            }
        }

        Column {
            anchors.centerIn: parent
            spacing: Theme.spaceM
            visible: !root.session.directory.loading && root.session.directory.error.length === 0 && root.session.directory.count === 0
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.session.directory.filter.length > 0 ? "⌕" : "◇"; color: Theme.textMuted; font.pixelSize: 34 * Theme.scale }
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: root.session.directory.filter.length > 0 ? "No matching files" : "This folder is empty"; color: Theme.textMuted; font.pixelSize: Theme.fontBody }
        }
        Column {
            anchors.centerIn: parent
            spacing: Theme.spaceM
            visible: root.session.directory.error.length > 0
            Text { anchors.horizontalCenter: parent.horizontalCenter; text: "!"; color: Theme.error; font.pixelSize: 30 * Theme.scale; font.bold: true }
            Text { width: Math.min(root.width - 60, 480); text: Format.safeText(root.session.directory.error); textFormat: Text.PlainText; color: Theme.textMuted; font.pixelSize: Theme.fontBody; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap }
            IconButton { anchors.horizontalCenter: parent.horizontalCenter; label: "Retry"; onClicked: root.session.directory.refresh("refresh") }
        }
        Rectangle {
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: 2
            color: Theme.primary
            visible: root.session.directory.loading
            opacity: 0.8
            SequentialAnimation on opacity {
                running: root.session.directory.loading
                loops: Animation.Infinite
                NumberAnimation { to: 0.25; duration: 500 }
                NumberAnimation { to: 0.9; duration: 500 }
            }
        }
    }
}
