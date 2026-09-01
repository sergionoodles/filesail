import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

ColumnLayout {
    id: root

    required property var session
    property bool panelMode: false
    required property Action backAction
    required property Action forwardAction
    required property Action upAction
    required property Action createAction
    required property Action renameAction
    required property Action copyAction
    required property Action moveAction
    required property Action pasteAction
    required property Action trashAction
    required property Action listViewAction
    required property Action gridViewAction
    required property Action hiddenFilesAction

    signal navigate(string path)

    function beginPathEditing() {
        breadcrumbs.editing = true;
    }

    spacing: 0

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 56 * Theme.scale
        color: Qt.alpha(Theme.surfaceVariant, 0.34)

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spaceL
            anchors.rightMargin: Theme.spaceL
            spacing: Theme.spaceS

            IconButton { icon: "‹"; enabled: root.backAction.enabled; tooltip: root.backAction.text; onClicked: root.backAction.trigger() }
            IconButton { icon: "›"; enabled: root.forwardAction.enabled; tooltip: root.forwardAction.text; onClicked: root.forwardAction.trigger() }
            IconButton { icon: "↑"; enabled: root.upAction.enabled; tooltip: root.upAction.text; onClicked: root.upAction.trigger() }

            BreadcrumbBar {
                id: breadcrumbs
                Layout.fillWidth: true
                path: root.session.directory.path
                onNavigate: path => root.navigate(path)
            }

            TextField {
                id: searchInput
                Layout.preferredWidth: root.panelMode ? 140 * Theme.scale : 190 * Theme.scale
                implicitHeight: 36 * Theme.scale
                placeholderText: "Filter this folder"
                text: root.session.directory.filter
                color: Theme.text
                placeholderTextColor: Theme.textMuted
                font.pixelSize: Theme.fontBody
                leftPadding: Theme.spaceM
                rightPadding: Theme.spaceM
                onTextChanged: root.session.directory.filter = text
                background: Rectangle {
                    radius: Theme.radiusS
                    color: Qt.alpha(Theme.surfaceVariant, 0.72)
                    border.width: 1
                    border.color: searchInput.activeFocus ? Theme.primary : Qt.alpha(Theme.outline, 0.72)
                }
            }
        }
    }

    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.alpha(Theme.outline, 0.5) }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 48 * Theme.scale
        color: Theme.surface

        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: Theme.spaceL
            anchors.rightMargin: Theme.spaceL
            spacing: Theme.spaceXs

            IconButton { icon: "+"; label: root.panelMode ? "" : root.createAction.text; enabled: root.createAction.enabled; onClicked: root.createAction.trigger() }
            IconButton { icon: "✎"; enabled: root.renameAction.enabled; tooltip: root.renameAction.text; onClicked: root.renameAction.trigger() }
            IconButton { icon: "⧉"; enabled: root.copyAction.enabled; tooltip: root.copyAction.text; onClicked: root.copyAction.trigger() }
            IconButton { icon: "✂"; enabled: root.moveAction.enabled; tooltip: root.moveAction.text; onClicked: root.moveAction.trigger() }
            IconButton { icon: "⇥"; enabled: root.pasteAction.enabled; tooltip: root.pasteAction.text; onClicked: root.pasteAction.trigger() }
            IconButton { icon: "♲"; enabled: root.trashAction.enabled; tooltip: root.trashAction.text; onClicked: root.trashAction.trigger() }

            Item { Layout.fillWidth: true }

            IconButton { icon: "·☰"; checked: root.listViewAction.checked; tooltip: root.listViewAction.text; onClicked: root.listViewAction.trigger() }
            IconButton { icon: "▦"; checked: root.gridViewAction.checked; tooltip: root.gridViewAction.text; onClicked: root.gridViewAction.trigger() }
            IconButton { icon: "◌"; checked: root.hiddenFilesAction.checked; tooltip: root.hiddenFilesAction.text; onClicked: root.hiddenFilesAction.trigger() }
        }
    }
}
