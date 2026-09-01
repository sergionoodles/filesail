import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "../core"

Rectangle {
    id: root

    property string initialPath: String(Quickshell.env("HOME") ?? "/")
    property bool panelMode: false
    property Component previewComponent: null
    property string noticeText: ""
    property bool noticeError: false
    property string viewMode: "list"
    property string renameTarget: ""
    property var trashTargets: []
    property string createParent: ""
    readonly property int selectedCount: session.selectedCount
    readonly property bool previewEnabled: previewComponent !== null
        && session.primarySelectionPath.length > 0

    color: Theme.surface
    radius: panelMode ? Theme.radiusL : 0
    clip: true

    function navigate(path) { session.navigate(path); }

    function showNotice(message, isError) {
        noticeText = message;
        noticeError = isError;
        noticeTimer.restart();
    }

    function openCreatePrompt() {
        createParent = session.directory.path;
        createPrompt.open("");
    }

    function openRenamePrompt() {
        if (session.selectedCount !== 1)
            return;
        renameTarget = session.primarySelectionPath;
        renamePrompt.open(renameTarget.split('/').pop());
    }

    function openTrashPrompt() {
        if (session.selectedCount === 0)
            return;
        trashTargets = Object.keys(session.selectedPaths);
        trashPrompt.open();
    }

    BrowserSession {
        id: session
        initialPath: root.initialPath
        onNoticeRequested: (message, error) => root.showNotice(message, error)
    }

    property Action editLocationAction: Action { shortcut: "Ctrl+L"; onTriggered: toolbar.beginPathEditing() }
    property Action backAction: Action { text: "Back"; shortcut: "Alt+Left"; enabled: session.navigation.canGoBack; onTriggered: session.navigation.back() }
    property Action forwardAction: Action { text: "Forward"; shortcut: "Alt+Right"; enabled: session.navigation.canGoForward; onTriggered: session.navigation.forward() }
    property Action upAction: Action { text: "Parent folder"; shortcut: "Alt+Up"; enabled: session.directory.path !== "/"; onTriggered: session.navigation.up() }
    property Action hiddenFilesAction: Action {
        text: "Show hidden files"; shortcut: "Ctrl+H"
        checked: session.directory.showHidden
        onTriggered: session.directory.showHidden = !session.directory.showHidden
    }
    property Action copyAction: Action { text: "Copy"; shortcut: "Ctrl+C"; enabled: session.selectedCount > 0; onTriggered: session.copySelection("copy") }
    property Action moveAction: Action { text: "Move"; shortcut: "Ctrl+X"; enabled: session.selectedCount > 0; onTriggered: session.copySelection("move") }
    property Action pasteAction: Action { text: "Paste"; shortcut: "Ctrl+V"; enabled: session.clipboardPaths.length > 0; onTriggered: session.paste() }
    property Action createAction: Action { text: "New folder"; shortcut: "Ctrl+Shift+N"; onTriggered: root.openCreatePrompt() }
    property Action renameAction: Action { text: "Rename"; shortcut: "F2"; enabled: session.selectedCount === 1; onTriggered: root.openRenamePrompt() }
    property Action refreshAction: Action { text: "Refresh"; shortcut: "F5"; onTriggered: session.directory.refresh("refresh") }
    property Action trashAction: Action { text: "Move to Trash"; shortcut: "Delete"; enabled: session.selectedCount > 0; onTriggered: root.openTrashPrompt() }
    property Action listViewAction: Action { text: "Details view"; checked: root.viewMode === "list"; onTriggered: root.viewMode = "list" }
    property Action gridViewAction: Action { text: "Grid view"; checked: root.viewMode === "grid"; onTriggered: root.viewMode = "grid" }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        Sidebar {
            Layout.preferredWidth: root.panelMode ? 174 * Theme.scale : 190 * Theme.scale
            Layout.fillHeight: true
            currentPath: session.directory.path
            onNavigate: path => root.navigate(path)
        }
        Rectangle { Layout.preferredWidth: 1; Layout.fillHeight: true; color: Qt.alpha(Theme.outline, 0.55) }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            BrowserToolbar {
                id: toolbar
                Layout.fillWidth: true
                session: session
                panelMode: root.panelMode
                backAction: root.backAction
                forwardAction: root.forwardAction
                upAction: root.upAction
                createAction: root.createAction
                renameAction: root.renameAction
                copyAction: root.copyAction
                moveAction: root.moveAction
                pasteAction: root.pasteAction
                trashAction: root.trashAction
                listViewAction: root.listViewAction
                gridViewAction: root.gridViewAction
                hiddenFilesAction: root.hiddenFilesAction
                onNavigate: path => root.navigate(path)
            }

            SplitView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                orientation: Qt.Horizontal

                FileBrowserPane {
                    SplitView.fillWidth: true
                    SplitView.minimumWidth: 360 * Theme.scale
                    session: session
                    viewMode: root.viewMode
                }
                Loader {
                    id: previewLoader
                    visible: root.previewEnabled
                    active: visible
                    sourceComponent: root.previewComponent
                    SplitView.preferredWidth: visible ? 300 * Theme.scale : 0
                    SplitView.minimumWidth: visible ? 220 * Theme.scale : 0
                    property string selectedPath: session.primarySelectionPath
                }
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 30 * Theme.scale
                color: Qt.alpha(Theme.surfaceVariant, 0.42)
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spaceL
                    anchors.rightMargin: Theme.spaceL
                    Text {
                        Layout.fillWidth: true
                        text: session.selectedCount > 0 ? `${session.selectedCount} selected` : `${session.directory.count} items`
                        color: Theme.textMuted
                        font.pixelSize: Theme.fontSmall
                    }
                    Text {
                        text: session.clipboardPaths.length > 0 ? `${session.clipboardMode === "move" ? "Move" : "Copy"} buffer: ${session.clipboardPaths.length}` : ""
                        color: Theme.primary
                        font.pixelSize: Theme.fontSmall
                    }
                }
            }
        }
    }

    Rectangle {
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.topMargin: Theme.spaceM
        width: Math.min(parent.width - Theme.spaceXl * 2, noticeLabel.implicitWidth + Theme.spaceXl * 2)
        height: 34 * Theme.scale
        radius: Theme.radiusS
        color: root.noticeError ? Theme.error : Theme.primary
        visible: noticeTimer.running
        z: 900
        Text {
            id: noticeLabel
            anchors.centerIn: parent
            text: root.noticeText
            color: Theme.primaryText
            font.pixelSize: Theme.fontBody
            font.weight: Font.DemiBold
            elide: Text.ElideRight
        }
    }
    Timer { id: noticeTimer; interval: 2800 }

    ModalPrompt {
        id: createPrompt
        anchors.fill: parent
        title: "New folder"
        message: `Create a folder in ${root.createParent}`
        placeholder: "Folder name"
        acceptLabel: "Create"
        onAccepted: value => session.runOperation("mkdir", { parent: root.createParent, name: value }, true, "Folder created")
    }
    ModalPrompt {
        id: renamePrompt
        anchors.fill: parent
        title: "Rename"
        message: root.renameTarget
        placeholder: "New name"
        acceptLabel: "Rename"
        onAccepted: value => session.runOperation("rename", { path: root.renameTarget, name: value }, true, "Item renamed")
    }
    ModalPrompt {
        id: trashPrompt
        anchors.fill: parent
        title: root.trashTargets.length === 1 ? "Move item to Trash?" : `Move ${root.trashTargets.length} items to Trash?`
        message: "Items remain recoverable from the desktop Trash. Permanent deletion is intentionally unavailable here."
        acceptLabel: "Move to Trash"
        destructive: true
        inputVisible: false
        onAccepted: session.runOperation("trash", { paths: root.trashTargets }, true, "Moved to Trash")
    }
}
