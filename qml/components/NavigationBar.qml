import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Rectangle {
    id: root

    required property var session
    property bool compact: false
    required property Action backAction
    required property Action forwardAction
    required property Action upAction
    required property Action openNewWindowAction
    required property Action openTerminalAction
    required property Action listViewAction
    required property Action gridViewAction
    required property Action hiddenFilesAction
    required property Action sortByNameAction
    required property Action sortBySizeAction
    required property Action sortByModifiedAction
    required property Action sortAscendingAction
    required property Action sortDescendingAction
    required property Action foldersFirstAction
    required property Action aboutAction
    readonly property int actionIconSize: Math.round(18 * Theme.scale)

    signal navigate(string path)

    function beginPathEditing() {
        breadcrumbs.editing = true;
    }

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
                iconName: "square-arrow-out-up-right"
                enabled: root.openNewWindowAction.enabled
                tooltip: root.openNewWindowAction.text
                onClicked: root.openNewWindowAction.trigger()
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

    Menu {
        id: overflowMenu
        width: 220 * Theme.scale
        delegate: ThemedMenuItem {}

        background: Rectangle {
            color: Theme.surfaceVariant
            border.width: 1
            border.color: Theme.divider
        }

        ThemedMenuItem {
            text: root.hiddenFilesAction.text
            checkable: true
            checked: root.hiddenFilesAction.checked
            enabled: root.hiddenFilesAction.enabled
            onTriggered: root.hiddenFilesAction.trigger()
        }
        Menu {
            title: qsTr("Sort by")
            enabled: root.sortByNameAction.enabled
            delegate: ThemedMenuItem {}

            ThemedMenuItem {
                text: root.sortByNameAction.text
                checkable: true
                checked: root.sortByNameAction.checked
                enabled: root.sortByNameAction.enabled
                onTriggered: root.sortByNameAction.trigger()
            }
            ThemedMenuItem {
                text: root.sortBySizeAction.text
                checkable: true
                checked: root.sortBySizeAction.checked
                enabled: root.sortBySizeAction.enabled
                onTriggered: root.sortBySizeAction.trigger()
            }
            ThemedMenuItem {
                text: root.sortByModifiedAction.text
                checkable: true
                checked: root.sortByModifiedAction.checked
                enabled: root.sortByModifiedAction.enabled
                onTriggered: root.sortByModifiedAction.trigger()
            }
            MenuSeparator {
                padding: Theme.spaceS
                contentItem: Rectangle { implicitHeight: 1; color: Theme.divider }
            }
            ThemedMenuItem {
                text: root.sortAscendingAction.text
                checkable: true
                checked: root.sortAscendingAction.checked
                enabled: root.sortAscendingAction.enabled
                onTriggered: root.sortAscendingAction.trigger()
            }
            ThemedMenuItem {
                text: root.sortDescendingAction.text
                checkable: true
                checked: root.sortDescendingAction.checked
                enabled: root.sortDescendingAction.enabled
                onTriggered: root.sortDescendingAction.trigger()
            }
            MenuSeparator {
                padding: Theme.spaceS
                contentItem: Rectangle { implicitHeight: 1; color: Theme.divider }
            }
            ThemedMenuItem {
                text: root.foldersFirstAction.text
                checkable: true
                checked: root.foldersFirstAction.checked
                enabled: root.foldersFirstAction.enabled
                onTriggered: root.foldersFirstAction.trigger()
            }
        }
        MenuSeparator {
            padding: Theme.spaceS
            contentItem: Rectangle {
                implicitHeight: 1
                color: Theme.divider
            }
        }
        ThemedMenuItem {
            text: root.aboutAction.text
            enabled: root.aboutAction.enabled
            onTriggered: root.aboutAction.trigger()
        }
    }
}
