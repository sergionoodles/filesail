pragma ComponentBehavior: Bound

import QtQuick
import "../core"

GridView {
    id: gridView

    required property var session

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
                gridView.session.clearSelection();
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
        color: gridView.session.selectedPaths[path] ? Qt.alpha(Theme.primary, 0.16)
             : gridMouse.containsMouse ? Qt.alpha(Theme.text, 0.06) : "transparent"
        border.width: gridView.session.selectedPaths[path] ? 1 : 0
        border.color: Qt.alpha(Theme.primary, 0.5)
        Column {
            anchors.centerIn: parent
            width: parent.width - Theme.spaceM * 2
            spacing: Theme.spaceS
            FileVisual { width: 46 * Theme.scale; height: 46 * Theme.scale; anchors.horizontalCenter: parent.horizontalCenter
                entry: ({ name: gridDelegate.name, path: gridDelegate.path, isDirectory: gridDelegate.isDirectory, iconName: gridDelegate.iconName, mimeType: gridDelegate.mimeType, size: gridDelegate.size, modified: gridDelegate.modified })
                selected: gridView.session.selectedPaths[gridDelegate.path] ?? false }
            Text { width: parent.width; text: Format.safeText(gridDelegate.name); textFormat: Text.PlainText; color: Theme.text; font.pixelSize: Theme.fontBody; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.Wrap }
        }
        MouseArea {
            id: gridMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: mouse => gridView.session.select(gridDelegate.path, mouse.modifiers)
            onDoubleClicked: gridView.session.openEntry(gridDelegate.path, gridDelegate.isDirectory)
            activeFocusOnTab: true
            Keys.onReturnPressed: gridView.session.openEntry(gridDelegate.path, gridDelegate.isDirectory)
            Keys.onEnterPressed: gridView.session.openEntry(gridDelegate.path, gridDelegate.isDirectory)
            Keys.onSpacePressed: gridView.session.select(gridDelegate.path, Qt.NoModifier)
        }
    }
}
