import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "../core"
import "." as FileSailComponents

Rectangle {
    id: root

    property string initialPath: String(Quickshell.env("HOME") ?? "/")
    property var initialSelectionPaths: []
    // Hosts may override density; otherwise the view adapts to its available width.
    property bool compact: width > 0 && width < 900 * Theme.scale
    property int cornerRadius: 0
    // A host may replace the built-in provider. Null selects FileSail's own
    // panel, whose bindings are established before component completion.
    property Component previewComponent: null
    // A URL provider is preferred because Loader.setSource can supply required
    // properties before the preview component completes.
    property url previewSource: ""
    // Preview providers receive the selected path explicitly via Loader.item.
    // Providers should declare `property string selectedPath` (or use this context).
    property QtObject previewContext: QtObject {
        property string selectedPath: session.primarySelectionPath
        property string primarySelectionPath: session.primarySelectionPath
        property var selectedPaths: Object.keys(session.selectedPaths)
        property var selectedEntries: session.selectedEntries
        property int selectionRevision: session.selectionRevision
    }
    property alias previewPaneEnabled: actions.previewPaneEnabled
    property alias viewMode: actions.viewMode
    readonly property int selectedCount: session.selectedCount
    readonly property bool selectionIncludesDirectory: {
        // A preview provider is never available for folders. Inspect the current
        // directory entries rather than relying on the primary selection so a
        // mixed selection also collapses the otherwise empty preview pane.
        const selected = session.selectedPaths;
        for (const entry of session.directory.sourceEntries) {
            if (selected[entry.path] && entry.isDirectory)
                return true;
        }
        return false;
    }
    readonly property real sidebarWidth: (root.compact ? 220 : 240) * Theme.scale
    readonly property real previewRequiredWidth: (240 + 1 + 360 + 220) * Theme.scale
    readonly property bool previewEnabled: previewPaneEnabled && width >= previewRequiredWidth
    readonly property bool modalActive: dialogs.active
    readonly property alias browserSession: session
    readonly property bool controlPreviewActualVisible: root.previewEnabled
    readonly property string controlPreviewReadiness: previewPane.providerReadiness
    readonly property string controlPreviewError: previewPane.providerError
    readonly property string controlPreviewUnavailableReason: {
        if (!root.previewPaneEnabled)
            return "not_requested";
        if (root.width < root.previewRequiredWidth)
            return "insufficient_width";
        if (session.selectedCount === 0)
            return "no_selection";
        if (root.selectionIncludesDirectory)
            return "unsupported_selection";
        return "";
    }

    signal newWindowRequested(string path)

    color: Theme.surface
    radius: cornerRadius
    clip: true

    Component.onCompleted: { Logger.info("view", `ready path=${initialPath}`); PreviewManager.acquireView(); }
    Component.onDestruction: PreviewManager.releaseView()

    function navigate(path) { session.navigate(path); }

    function showNotice(message, isError) {
        noticeBanner.show(message, isError);
    }

    function requestSafeRemove(drive) {
        dialogs.confirmSafeRemove(drive, () => VolumeModel.safeRemove(drive,
            (error, retry) => dialogs.openVolumeError(error, retry, toolbar),
            message => root.showNotice(message, false)), toolbar);
    }

    BrowserSession {
        id: session
        initialPath: root.initialPath
        initialSelectionPaths: root.initialSelectionPaths
        onNoticeRequested: (message, error) => root.showNotice(message, error)
        onLargeDirectoryWarningRequested: (path, entryCountAtLeast) =>
            dialogs.openLargeDirectory(path, entryCountAtLeast, toolbar)
    }

    Connections {
        target: session.directory
        function onRevisionChanged() { PreviewManager.advanceGeneration(); }
    }

    Connections {
        target: BackendClient
        function onMutationTerminated(result, method) {
            if (session.activeOperations[result.id])
                return;
            const completed = Array.isArray(result.completed) ? result.completed.length : 0;
            if (result.errorCode === "cancelled") {
                const label = method === "copy" ? qsTr("Copy") : method === "move" ? qsTr("Move")
                    : method === "trash" ? qsTr("Remove") : qsTr("Operation");
                root.showNotice(qsTr("%1 cancelled; %2 item(s) completed").arg(label).arg(completed), false);
            } else if (Array.isArray(result.recovery) && result.recovery.length > 0) {
                root.showNotice(qsTr("An operation needs filesystem recovery; details are in Activity"), true);
            }
        }
    }

    BrowserActions {
        id: actions
        session: session
        modalActive: root.modalActive
        onNewWindowRequested: path => root.newWindowRequested(path)
        onEditLocationRequested: toolbar.beginPathEditing()
        onCreateRequested: dialogs.openCreate(session.directory.path, toolbar)
        onRenameRequested: {
            if (session.selectedCount !== 1)
                return;
            dialogs.openRename(session.primarySelectionPath, toolbar);
        }
        onTrashRequested: {
            if (session.selectedCount === 0)
                return;
            dialogs.openTrash(Object.keys(session.selectedPaths), toolbar);
        }
        onInfoRequested: {
            if (session.selectedCount !== 1)
                return;
            dialogs.openInfo(session.selectedEntries[0], toolbar);
        }
        onAboutRequested: dialogs.openAbout(toolbar)
        onKeybindingsRequested: dialogs.openKeybindings(actions.keybindingGroups(), toolbar)
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        Sidebar {
            Layout.preferredWidth: root.sidebarWidth
            Layout.fillHeight: true
            topSectionHeight: toolbar.navigationSectionHeight
            currentPath: session.directory.path
            projectsModel: SavedLocationsModel.projects
            bookmarksModel: SavedLocationsModel.bookmarks
            onNavigate: path => root.navigate(path)
            onActivateVolume: volume => VolumeModel.activate(volume, path => root.navigate(path),
                (nextVolume, navigateCallback, errorCallback, noticeCallback) =>
                    dialogs.openUnlock(nextVolume, navigateCallback, errorCallback, noticeCallback, toolbar),
                (error, retry) => dialogs.openVolumeError(error, retry, toolbar),
                message => root.showNotice(message, false))
            onUnmountVolume: volume => VolumeModel.unmount(volume,
                (error, retry) => dialogs.openVolumeError(error, retry, toolbar),
                message => root.showNotice(message, false))
            onSafeRemoveDrive: drive => root.requestSafeRemove(drive)
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
                backAction: actions.backAction
                forwardAction: actions.forwardAction
                upAction: actions.upAction
                openNewWindowAction: actions.openNewWindowAction
                openTerminalAction: actions.openTerminalAction
                createAction: actions.createAction
                renameAction: actions.renameAction
                copyAction: actions.copyAction
                moveAction: actions.moveAction
                pasteAction: actions.pasteAction
                trashAction: actions.trashAction
                infoAction: actions.infoAction
                listViewAction: actions.listViewAction
                gridViewAction: actions.gridViewAction
                hiddenFilesAction: actions.hiddenFilesAction
                sortByNameAction: actions.sortByNameAction
                sortBySizeAction: actions.sortBySizeAction
                sortByModifiedAction: actions.sortByModifiedAction
                sortAscendingAction: actions.sortAscendingAction
                sortDescendingAction: actions.sortDescendingAction
                foldersFirstAction: actions.foldersFirstAction
                previewAction: actions.previewAction
                aboutAction: actions.aboutAction
                onNavigate: path => root.navigate(path)
            }

            SplitView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                orientation: Qt.Horizontal

                FileBrowserPane {
                    id: browserPane
                    SplitView.fillWidth: true
                    SplitView.minimumWidth: 360 * Theme.scale
                    session: session
                    viewMode: root.viewMode
                    onContextMenuRequested: (entry, background, x, y) => {
                        if (entry && !session.selectedPaths[entry.path])
                            session.selectEntry(entry.path, 0);
                        const point = browserPane.mapToItem(root, x, y);
                        contextMenu.openAt(point.x, point.y, entry, background);
                    }
                }
                PreviewPane {
                    id: previewPane
                    previewEnabled: root.previewEnabled
                    previewSource: root.previewSource
                    previewComponent: root.previewComponent
                    previewContext: root.previewContext
                }
            }

            BrowserStatusBar {
                Layout.fillWidth: true
                itemCount: session.directory.count
                selectedCount: session.selectedCount
                clipboardCount: session.clipboardPaths.length
                clipboardMode: session.clipboardMode
                clipboardState: FileClipboard.state
            }
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        y: Math.round(toolbar.navigationSectionHeight)
        height: 1
        color: Theme.divider
        z: 1
    }

    NoticeBanner {
        id: noticeBanner
    }

    BrowserDialogs {
        id: dialogs
        session: session
    }

    FileSailComponents.ContextMenu {
        id: contextMenu
        session: session
        actions: actions
        onClosed: browserPane.forceActiveFocus()
    }
}
