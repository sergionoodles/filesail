import QtQuick
import QtQuick.Controls
import "../core"

QtObject {
    id: root

    required property var session
    required property bool modalActive
    property string viewMode: Settings.viewMode
    property bool previewPaneEnabled: Settings.previewPaneEnabled

    signal editLocationRequested()
    signal newWindowRequested(string path)
    signal createRequested()
    signal renameRequested()
    signal trashRequested()
    signal aboutRequested()

    property Action editLocationAction: Action { shortcut: "Ctrl+L"; enabled: !root.modalActive; onTriggered: root.editLocationRequested() }
    property Action backAction: Action { text: qsTr("Back"); shortcut: "Alt+Left"; enabled: !root.modalActive && root.session.navigation.canGoBack; onTriggered: root.session.navigation.back() }
    property Action forwardAction: Action { text: qsTr("Forward"); shortcut: "Alt+Right"; enabled: !root.modalActive && root.session.navigation.canGoForward; onTriggered: root.session.navigation.forward() }
    property Action upAction: Action { text: qsTr("Parent folder"); shortcut: "Alt+Up"; enabled: !root.modalActive && root.session.directory.path !== "/"; onTriggered: root.session.navigation.up() }
    property Action hiddenFilesAction: Action {
        text: qsTr("Show hidden files"); shortcut: "Ctrl+H"; enabled: !root.modalActive
        checked: Settings.showHidden
        onTriggered: Settings.setShowHidden(!Settings.showHidden)
    }
    property Action copyAction: Action { text: qsTr("Copy"); shortcut: "Ctrl+C"; enabled: !root.modalActive && root.session.selectedCount > 0; onTriggered: root.session.copySelection("copy") }
    property Action moveAction: Action { text: qsTr("Move"); shortcut: "Ctrl+X"; enabled: !root.modalActive && root.session.selectedCount > 0; onTriggered: root.session.copySelection("move") }
    property Action pasteAction: Action { text: qsTr("Paste"); shortcut: "Ctrl+V"; enabled: !root.modalActive && root.session.clipboardPaths.length > 0; onTriggered: root.session.paste() }
    property Action selectAllAction: Action { text: qsTr("Select all"); shortcut: "Ctrl+A"; enabled: !root.modalActive; onTriggered: root.session.selectAllVisible() }
    property Action createAction: Action { text: qsTr("New folder"); shortcut: "Ctrl+Shift+N"; enabled: !root.modalActive; onTriggered: root.createRequested() }
    property Action renameAction: Action { text: qsTr("Rename"); shortcut: "Alt+R"; enabled: !root.modalActive && root.session.selectedCount === 1; onTriggered: root.renameRequested() }
    property Action refreshAction: Action { text: qsTr("Refresh"); shortcut: "Ctrl+R"; enabled: !root.modalActive; onTriggered: root.session.directory.refresh("refresh") }
    property Action openNewWindowAction: Action {
        text: qsTr("Open New Window Here"); shortcut: "Ctrl+N"; enabled: !root.modalActive
        onTriggered: root.newWindowRequested(root.session.directory.path)
    }
    property Action trashAction: Action { text: qsTr("Move to Trash"); shortcut: "Delete"; enabled: !root.modalActive && root.session.selectedCount > 0; onTriggered: root.trashRequested() }
    property Action listViewAction: Action { text: qsTr("Details view"); shortcut: "Ctrl+1"; checked: root.viewMode === "list"; enabled: !root.modalActive; onTriggered: Settings.setViewMode("list") }
    property Action gridViewAction: Action { text: qsTr("Grid view"); shortcut: "Ctrl+2"; checked: root.viewMode === "grid"; enabled: !root.modalActive; onTriggered: Settings.setViewMode("grid") }
    property Action previewAction: Action { text: qsTr("Preview pane"); shortcut: "Ctrl+P"; checked: root.previewPaneEnabled; enabled: !root.modalActive; onTriggered: Settings.setPreviewPaneEnabled(!Settings.previewPaneEnabled) }
    property Action aboutAction: Action { text: qsTr("About FileSail"); enabled: !root.modalActive; onTriggered: root.aboutRequested() }
}
