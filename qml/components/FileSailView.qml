import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "../core"

Rectangle {
    id: root

    property string initialPath: String(Quickshell.env("HOME") ?? "/")
    // Hosts may override density; otherwise the view adapts to its available width.
    property bool compact: width > 0 && width < 900 * Theme.scale
    property int cornerRadius: 0
    property Component previewComponent: null
    // A URL provider is preferred because Loader.setSource can supply required
    // properties before the preview component completes.
    property url previewSource: ""
    // Preview providers receive the selected path explicitly via Loader.item.
    // Providers should declare `property string selectedPath` (or use this context).
    property QtObject previewContext: QtObject { property string selectedPath: session.primarySelectionPath }
    property string noticeText: ""
    property bool noticeError: false
    property string viewMode: "list"
    property string renameTarget: ""
    property var trashTargets: []
    property string createParent: ""
    readonly property int selectedCount: session.selectedCount
    readonly property bool selectionIncludesDirectory: {
        // A preview provider is never available for folders. Inspect the current
        // directory entries rather than relying on the primary selection so a
        // mixed selection also collapses the otherwise empty preview pane.
        const selected = session.selectedPaths;
        for (let index = 0; index < session.directory.count; index++) {
            const entry = session.directory.entries.get(index);
            if (selected[entry.path] && entry.isDirectory)
                return true;
        }
        return false;
    }
    readonly property bool previewEnabled: (previewComponent !== null || previewSource !== "")
        && session.primarySelectionPath.length > 0
        && !selectionIncludesDirectory
    readonly property bool modalActive: createPrompt.visible || renamePrompt.visible || trashPrompt.visible || largeDirectoryPrompt.visible

    color: Theme.surface
    radius: cornerRadius
    clip: true

    function navigate(path) { session.navigate(path); }

    function showNotice(message, isError) {
        noticeText = message;
        noticeError = isError;
        noticeTimer.restart();
    }

    function openCreatePrompt() {
        createParent = session.directory.path;
        createPrompt.open("", { parent: createParent }, toolbar);
    }

    function openRenamePrompt() {
        if (session.selectedCount !== 1)
            return;
        renameTarget = session.primarySelectionPath;
        renamePrompt.open(renameTarget.split('/').pop(), { path: renameTarget }, toolbar);
    }

    function openTrashPrompt() {
        if (session.selectedCount === 0)
            return;
        trashTargets = Object.keys(session.selectedPaths);
        trashPrompt.open("", { paths: trashTargets.slice() }, toolbar);
    }

    BrowserSession {
        id: session
        initialPath: root.initialPath
        onNoticeRequested: (message, error) => root.showNotice(message, error)
        onLargeDirectoryWarningRequested: (path, entryCountAtLeast) =>
            largeDirectoryPrompt.open("", { path: path, entryCountAtLeast: entryCountAtLeast }, toolbar)
    }

    property Action editLocationAction: Action { shortcut: "Ctrl+L"; enabled: !root.modalActive; onTriggered: toolbar.beginPathEditing() }
    property Action backAction: Action { text: qsTr("Back"); shortcut: "Alt+Left"; enabled: !root.modalActive && session.navigation.canGoBack; onTriggered: session.navigation.back() }
    property Action forwardAction: Action { text: qsTr("Forward"); shortcut: "Alt+Right"; enabled: !root.modalActive && session.navigation.canGoForward; onTriggered: session.navigation.forward() }
    property Action upAction: Action { text: qsTr("Parent folder"); shortcut: "Alt+Up"; enabled: !root.modalActive && session.directory.path !== "/"; onTriggered: session.navigation.up() }
    property Action hiddenFilesAction: Action {
        text: qsTr("Show hidden files"); shortcut: "Ctrl+H"; enabled: !root.modalActive
        checked: session.directory.showHidden
        onTriggered: session.directory.showHidden = !session.directory.showHidden
    }
    property Action copyAction: Action { text: qsTr("Copy"); shortcut: "Ctrl+C"; enabled: !root.modalActive && session.selectedCount > 0; onTriggered: session.copySelection("copy") }
    property Action moveAction: Action { text: qsTr("Move"); shortcut: "Ctrl+X"; enabled: !root.modalActive && session.selectedCount > 0; onTriggered: session.copySelection("move") }
    property Action pasteAction: Action { text: qsTr("Paste"); shortcut: "Ctrl+V"; enabled: !root.modalActive && session.clipboardPaths.length > 0; onTriggered: session.paste() }
    property Action createAction: Action { text: qsTr("New folder"); shortcut: "Ctrl+Shift+N"; enabled: !root.modalActive; onTriggered: root.openCreatePrompt() }
    property Action renameAction: Action { text: qsTr("Rename"); shortcut: "F2"; enabled: !root.modalActive && session.selectedCount === 1; onTriggered: root.openRenamePrompt() }
    property Action refreshAction: Action { text: qsTr("Refresh"); shortcut: "F5"; enabled: !root.modalActive; onTriggered: session.directory.refresh("refresh") }
    property Action openTerminalAction: Action {
        text: qsTr("Open Terminal Here"); shortcut: "F4"; enabled: !root.modalActive
        onTriggered: session.runOperation("terminal", { path: session.directory.path }, false,
                                         qsTr("Terminal opened"), false, false)
    }
    property Action trashAction: Action { text: qsTr("Move to Trash"); shortcut: "Delete"; enabled: !root.modalActive && session.selectedCount > 0; onTriggered: root.openTrashPrompt() }
    property Action listViewAction: Action { text: qsTr("Details view"); checked: root.viewMode === "list"; enabled: !root.modalActive; onTriggered: root.viewMode = "list" }
    property Action gridViewAction: Action { text: qsTr("Grid view"); checked: root.viewMode === "grid"; enabled: !root.modalActive; onTriggered: root.viewMode = "grid" }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        Sidebar {
            Layout.preferredWidth: root.compact ? 174 * Theme.scale : 190 * Theme.scale
            Layout.fillHeight: true
            currentPath: session.directory.path
            projectsModel: SavedLocationsModel.projects
            bookmarksModel: SavedLocationsModel.bookmarks
            onNavigate: path => root.navigate(path)
            onAddCurrentDirectoryRequested: collection => SavedLocationsModel.addCurrentDirectory(collection, session.directory.path, () => root.showNotice(qsTr("Folder added"), false), message => root.showNotice(message, true))
            onRemoveLocationRequested: (collection, id) => SavedLocationsModel.remove(collection, id, () => root.showNotice(qsTr("Folder removed"), false), message => root.showNotice(message, true))
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
                compact: root.compact
                backAction: root.backAction
                forwardAction: root.forwardAction
                upAction: root.upAction
                openTerminalAction: root.openTerminalAction
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
                    sourceComponent: root.previewSource === "" ? root.previewComponent : null
                    SplitView.preferredWidth: visible ? 300 * Theme.scale : 0
                    SplitView.minimumWidth: visible ? 220 * Theme.scale : 0
                    property string selectedPath: session.primarySelectionPath
                    function loadPreview() {
                        if (root.previewSource !== "")
                            setSource(root.previewSource, { selectedPath: root.previewContext.selectedPath });
                    }
                    Component.onCompleted: loadPreview()
                    Connections {
                        target: root
                        function onPreviewSourceChanged() { previewLoader.loadPreview(); }
                    }
                    onLoaded: {
                        // The property lives on the preview object, not the Loader.
                        if (item)
                            item.selectedPath = Qt.binding(() => root.previewContext.selectedPath);
                    }
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
            text: Format.safeText(root.noticeText)
            textFormat: Text.PlainText
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
        title: qsTr("New folder")
        message: qsTr("Create a folder in %1").arg(root.createParent)
        placeholder: qsTr("Folder name")
        acceptLabel: qsTr("Create")
        onAccepted: value => session.runOperation("mkdir", { parent: payload.parent, name: value }, true, qsTr("Folder created"))
    }
    ModalPrompt {
        id: renamePrompt
        anchors.fill: parent
        title: qsTr("Rename")
        message: root.renameTarget
        placeholder: qsTr("New name")
        acceptLabel: qsTr("Rename")
        onAccepted: value => session.runOperation("rename", { path: payload.path, name: value }, true, qsTr("Item renamed"))
    }
    ModalPrompt {
        id: trashPrompt
        anchors.fill: parent
        title: root.trashTargets.length === 1 ? qsTr("Move item to Trash?") : qsTr("Move %1 items to Trash?").arg(root.trashTargets.length)
        message: qsTr("Items remain recoverable from the desktop Trash. Permanent deletion is intentionally unavailable here.")
        acceptLabel: qsTr("Move to Trash")
        destructive: true
        inputVisible: false
        onAccepted: session.runOperation("trash", { paths: payload.paths }, true, qsTr("Moved to Trash"))
    }
    ModalPrompt {
        id: largeDirectoryPrompt
        anchors.fill: parent
        title: qsTr("Large folder")
        message: qsTr("This folder contains at least %1 items. Loading it may temporarily make FileSail less responsive.")
            .arg(payload.entryCountAtLeast)
        acceptLabel: qsTr("Load folder")
        inputVisible: false
        onAccepted: session.loadLargeDirectory(payload.path)
    }
}
