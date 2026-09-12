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
    signal infoRequested()
    signal aboutRequested()
    signal keybindingsRequested()

    property Action editLocationAction: Action { shortcut: "Ctrl+L"; enabled: !root.modalActive; onTriggered: root.editLocationRequested() }
    property Action backAction: Action { text: qsTr("Back"); shortcut: "Alt+Left"; enabled: !root.modalActive && root.session.navigation.canGoBack; onTriggered: root.session.goBack("user") }
    property Action forwardAction: Action { text: qsTr("Forward"); shortcut: "Alt+Right"; enabled: !root.modalActive && root.session.navigation.canGoForward; onTriggered: root.session.goForward("user") }
    property Action upAction: Action { text: qsTr("Parent folder"); shortcut: "Alt+Up"; enabled: !root.modalActive && root.session.directory.path !== "/"; onTriggered: root.session.goUp("user") }
    property Action hiddenFilesAction: Action {
        text: qsTr("Show hidden files"); shortcut: "Ctrl+H"; enabled: !root.modalActive
        checked: Settings.showHidden
        onTriggered: Settings.setShowHidden(!Settings.showHidden)
    }
    property Action sortByNameAction: Action {
        text: qsTr("Name")
        checkable: true
        checked: root.session.directory.sortBy === "name"
        enabled: !root.modalActive
        onTriggered: root.session.setSort("name", root.session.directory.descending)
    }
    property Action sortBySizeAction: Action {
        text: qsTr("Size")
        checkable: true
        checked: root.session.directory.sortBy === "size"
        enabled: !root.modalActive
        onTriggered: root.session.setSort("size", root.session.directory.descending)
    }
    property Action sortByModifiedAction: Action {
        text: qsTr("Modification date")
        checkable: true
        checked: root.session.directory.sortBy === "modified"
        enabled: !root.modalActive
        onTriggered: root.session.setSort("modified", root.session.directory.descending)
    }
    property Action sortAscendingAction: Action {
        text: qsTr("Ascending")
        checkable: true
        checked: !root.session.directory.descending
        enabled: !root.modalActive
        onTriggered: root.session.setSort(root.session.directory.sortBy, false)
    }
    property Action sortDescendingAction: Action {
        text: qsTr("Descending")
        checkable: true
        checked: root.session.directory.descending
        enabled: !root.modalActive
        onTriggered: root.session.setSort(root.session.directory.sortBy, true)
    }
    property Action foldersFirstAction: Action {
        text: qsTr("Always show folders first")
        checkable: true
        checked: root.session.directory.foldersFirst
        enabled: !root.modalActive
        onTriggered: root.session.setFoldersFirst(!root.session.directory.foldersFirst)
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
    property Action openTerminalAction: Action {
        text: qsTr("Open Terminal Here"); enabled: !root.modalActive
        onTriggered: root.session.runOperation("terminal", { path: root.session.directory.path }, false,
                                         qsTr("Terminal opened"), false, false)
    }
    property Action trashAction: Action { text: qsTr("Move to Trash"); shortcut: "Delete"; enabled: !root.modalActive && root.session.selectedCount > 0; onTriggered: root.trashRequested() }
    property Action infoAction: Action { text: qsTr("File info"); shortcut: "Ctrl+I"; enabled: !root.modalActive && root.session.selectedCount === 1; onTriggered: root.infoRequested() }
    property Action listViewAction: Action { text: qsTr("Details view"); shortcut: "Ctrl+1"; checked: root.viewMode === "list"; enabled: !root.modalActive; onTriggered: Settings.setViewMode("list") }
    property Action gridViewAction: Action { text: qsTr("Grid view"); shortcut: "Ctrl+2"; checked: root.viewMode === "grid"; enabled: !root.modalActive; onTriggered: Settings.setViewMode("grid") }
    property Action previewAction: Action { text: qsTr("Preview pane"); shortcut: "Ctrl+P"; checked: root.previewPaneEnabled; enabled: !root.modalActive; onTriggered: Settings.setPreviewPaneEnabled(!Settings.previewPaneEnabled) }
    property Action aboutAction: Action { text: qsTr("About FileSail"); enabled: !root.modalActive; onTriggered: root.aboutRequested() }
    property Action keybindingsAction: Action {
        text: qsTr("Show keyboard shortcuts"); shortcut: "?"; enabled: !root.modalActive
        onTriggered: root.keybindingsRequested()
    }

    function actionEntry(action) {
        return { label: action.text, shortcut: String(action.shortcut ?? "") };
    }

    // Keep the recap tied to the registered Actions. The remaining entries are
    // handled directly by the file views and therefore have no Action object.
    function keybindingGroups() {
        return [
            {
                title: qsTr("Navigation"),
                entries: [
                    actionEntry(backAction),
                    actionEntry(forwardAction),
                    actionEntry(upAction),
                    actionEntry(editLocationAction),
                    actionEntry(refreshAction),
                    { label: qsTr("Open focused item"), shortcut: qsTr("Enter") },
                    { label: qsTr("Move focus"), shortcut: qsTr("Arrow keys") },
                    { label: qsTr("Jump to start / end"), shortcut: qsTr("Home / End") },
                    { label: qsTr("Page through list"), shortcut: qsTr("Page Up / Page Down") },
                    { label: qsTr("Go to parent folder"), shortcut: qsTr("Backspace") },
                    { label: qsTr("Toggle focused selection"), shortcut: qsTr("Space") },
                    { label: qsTr("Clear selection"), shortcut: qsTr("Escape") }
                ]
            },
            {
                title: qsTr("Files"),
                entries: [
                    actionEntry(copyAction),
                    actionEntry(moveAction),
                    actionEntry(pasteAction),
                    actionEntry(selectAllAction),
                    actionEntry(createAction),
                    actionEntry(renameAction),
                    actionEntry(openNewWindowAction),
                    actionEntry(trashAction),
                    actionEntry(infoAction)
                ]
            },
            {
                title: qsTr("View"),
                entries: [
                    actionEntry(hiddenFilesAction),
                    actionEntry(listViewAction),
                    actionEntry(gridViewAction),
                    actionEntry(previewAction),
                    { label: qsTr("Open context menu"), shortcut: qsTr("Menu / Shift+F10") }
                ]
            },
            {
                title: qsTr("Help"),
                entries: [actionEntry(keybindingsAction)]
            }
        ];
    }
}
