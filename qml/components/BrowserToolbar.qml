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
    required property Action openNewWindowAction
    required property Action openTerminalAction
    required property Action createAction
    required property Action renameAction
    required property Action copyAction
    required property Action moveAction
    required property Action pasteAction
    required property Action trashAction
    required property Action infoAction
    required property Action listViewAction
    required property Action gridViewAction
    required property Action hiddenFilesAction
    required property Action previewAction
    required property Action aboutAction

    signal navigate(string path)

    function beginPathEditing() {
        navigationBar.beginPathEditing();
    }

    spacing: 0

    NavigationBar {
        id: navigationBar
        session: root.session
        compact: root.compact
        backAction: root.backAction
        forwardAction: root.forwardAction
        upAction: root.upAction
        openNewWindowAction: root.openNewWindowAction
        openTerminalAction: root.openTerminalAction
        listViewAction: root.listViewAction
        gridViewAction: root.gridViewAction
        hiddenFilesAction: root.hiddenFilesAction
        aboutAction: root.aboutAction
        onNavigate: path => root.navigate(path)
    }

    FileActionBar {
        session: root.session
        createAction: root.createAction
        renameAction: root.renameAction
        copyAction: root.copyAction
        moveAction: root.moveAction
        pasteAction: root.pasteAction
        trashAction: root.trashAction
        infoAction: root.infoAction
        previewAction: root.previewAction
    }

    Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.alpha(Theme.outline, 0.5) }
}
