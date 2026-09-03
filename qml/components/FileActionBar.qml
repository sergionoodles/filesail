import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Rectangle {
    id: root

    required property var session
    required property Action createAction
    required property Action renameAction
    required property Action copyAction
    required property Action moveAction
    required property Action pasteAction
    required property Action trashAction
    required property Action infoAction
    required property Action previewAction
    readonly property int actionIconSize: Math.round(18 * Theme.scale)

    Layout.fillWidth: true
    implicitHeight: 48 * Theme.scale
    color: Theme.surface

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.spaceL
        anchors.rightMargin: Theme.spaceL
        spacing: Theme.spaceXs

        IconButton { iconName: "folder-plus"; iconSize: root.actionIconSize; tooltip: root.createAction.text; enabled: root.createAction.enabled; onClicked: root.createAction.trigger() }
        IconButton { iconName: "square-pen"; iconSize: root.actionIconSize; enabled: root.renameAction.enabled; tooltip: root.renameAction.text; onClicked: root.renameAction.trigger() }
        IconButton { iconName: "copy"; iconSize: root.actionIconSize; enabled: root.copyAction.enabled; tooltip: root.copyAction.text; onClicked: root.copyAction.trigger() }
        IconButton { iconName: "scissors"; iconSize: root.actionIconSize; enabled: root.moveAction.enabled; tooltip: qsTr("Cut"); onClicked: root.moveAction.trigger() }
        IconButton { iconName: "clipboard-paste"; iconSize: root.actionIconSize; enabled: root.pasteAction.enabled; tooltip: root.pasteAction.text; onClicked: root.pasteAction.trigger() }
        IconButton { iconName: "trash-2"; iconSize: root.actionIconSize; enabled: root.trashAction.enabled; tooltip: root.trashAction.text; onClicked: root.trashAction.trigger() }
        IconButton { iconName: "info"; iconSize: root.actionIconSize; enabled: root.infoAction.enabled; tooltip: root.infoAction.text; onClicked: root.infoAction.trigger() }

        IconButton { iconName: "image"; iconSize: root.actionIconSize; checked: root.previewAction.checked; tooltip: root.previewAction.text; onClicked: root.previewAction.trigger() }

        FolderContextBar {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.leftMargin: Theme.spaceM
            folderContext: root.session.directory.folderContext
        }
    }
}
