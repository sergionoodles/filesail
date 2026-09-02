pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import "../core"

ColumnLayout {
    id: root

    required property var session
    property var model: null

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
            Text { Layout.fillWidth: true; text: "NAME"; color: Theme.textMuted; font.pixelSize: Theme.fontSmall - 1; font.weight: Font.DemiBold }
            Text { Layout.preferredWidth: 116 * Theme.scale; text: "MODIFIED"; color: Theme.textMuted; font.pixelSize: Theme.fontSmall - 1; font.weight: Font.DemiBold }
            Text { Layout.preferredWidth: 72 * Theme.scale; horizontalAlignment: Text.AlignRight; text: "SIZE"; color: Theme.textMuted; font.pixelSize: Theme.fontSmall - 1; font.weight: Font.DemiBold }
        }
    }

    ListView {
        id: listView
        Layout.fillWidth: true
        Layout.fillHeight: true
        model: root.model
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
