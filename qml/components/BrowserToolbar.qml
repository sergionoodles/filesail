import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

ColumnLayout {
    id: root

    required property var session
    property bool compact: false
    required property Action backAction
    required property Action forwardAction
    required property Action upAction
    required property Action openTerminalAction
    required property Action createAction
    required property Action renameAction
    required property Action copyAction
    required property Action moveAction
    required property Action pasteAction
    required property Action trashAction
    required property Action listViewAction
    required property Action gridViewAction
    required property Action hiddenFilesAction
    required property Action previewAction
    readonly property int actionIconSize: Math.round(18 * Theme.scale)

    signal navigate(string path)

    function beginPathEditing() {
        breadcrumbs.editing = true;
    }

    spacing: 0

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 56 * Theme.scale
        color: Theme.surface

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spaceL
            anchors.rightMargin: Theme.spaceL
            spacing: Theme.spaceS

            IconButton { iconName: "arrow-left"; enabled: root.backAction.enabled; tooltip: root.backAction.text; onClicked: root.backAction.trigger() }
            IconButton { iconName: "arrow-right"; enabled: root.forwardAction.enabled; tooltip: root.forwardAction.text; onClicked: root.forwardAction.trigger() }
            IconButton { iconName: "arrow-up"; enabled: root.upAction.enabled; tooltip: root.upAction.text; onClicked: root.upAction.trigger() }

            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spaceM

                BreadcrumbBar {
                    id: breadcrumbs
                    Layout.fillWidth: true
                    path: root.session.directory.path
                    onNavigate: path => root.navigate(path)
                }

                ThemedTextField {
                    id: searchInput
                    Layout.preferredWidth: root.compact ? 140 * Theme.scale : 190 * Theme.scale
                    implicitHeight: 36 * Theme.scale
                    leadingIconName: "search"
                    placeholderText: "Filter this folder"
                    text: root.session.directory.filter
                    onTextChanged: root.session.directory.filter = text
                }
            }

            Rectangle {
                Layout.preferredWidth: 1
                Layout.fillHeight: true
                Layout.topMargin: Theme.spaceS
                Layout.bottomMargin: Theme.spaceS
                color: Theme.divider
            }

            RowLayout {
                spacing: Theme.spaceXs

                IconButton {
                    iconName: root.listViewAction.checked ? "layout-grid" : "layout-list"
                    iconSize: root.actionIconSize
                    tooltip: root.listViewAction.checked ? root.gridViewAction.text : root.listViewAction.text
                    checkable: false
                    onClicked: root.listViewAction.checked ? root.gridViewAction.trigger() : root.listViewAction.trigger()
                }
                IconButton {
                    iconName: "square-terminal"
                    enabled: root.openTerminalAction.enabled
                    tooltip: root.openTerminalAction.text
                    onClicked: root.openTerminalAction.trigger()
                }
                IconButton {
                    id: overflowButton
                    iconName: "ellipsis-vertical"
                    iconSize: root.actionIconSize
                    tooltip: qsTr("More options")
                    checkable: false
                    onClicked: overflowMenu.popup(overflowButton, 0, overflowButton.height)
                }
            }
        }
    }

    Rectangle {
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

            IconButton { iconName: "image"; iconSize: root.actionIconSize; checked: root.previewAction.checked; tooltip: root.previewAction.text; onClicked: root.previewAction.trigger() }
        }
    }

    Menu {
        id: overflowMenu
        width: 220 * Theme.scale

        background: Rectangle {
            color: Theme.surfaceVariant
            border.width: 1
            border.color: Theme.divider
        }

        MenuItem {
            text: root.hiddenFilesAction.text
            checkable: true
            checked: root.hiddenFilesAction.checked
            enabled: root.hiddenFilesAction.enabled
            onTriggered: root.hiddenFilesAction.trigger()
        }
    }

    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.alpha(Theme.outline, 0.5) }

    FolderContextBar { Layout.fillWidth: true; folderContext: root.session.directory.folderContext }

    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.alpha(Theme.outline, 0.5) }
}
