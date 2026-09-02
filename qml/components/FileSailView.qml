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
        for (const entry of session.directory.entries) {
            if (selected[entry.path] && entry.isDirectory)
                return true;
        }
        return false;
    }
    readonly property real previewRequiredWidth: (190 + 1 + 360 + 220) * Theme.scale
    readonly property bool previewEnabled: previewPaneEnabled && width >= previewRequiredWidth
    readonly property bool modalActive: dialogs.active

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

    BrowserSession {
        id: session
        initialPath: root.initialPath
        onNoticeRequested: (message, error) => root.showNotice(message, error)
        onLargeDirectoryWarningRequested: (path, entryCountAtLeast) =>
            dialogs.openLargeDirectory(path, entryCountAtLeast, toolbar)
    }

    Connections {
        target: session.directory
        function onRevisionChanged() { PreviewManager.advanceGeneration(); }
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
        onAboutRequested: dialogs.openAbout(toolbar)
    }

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
                backAction: actions.backAction
                forwardAction: actions.forwardAction
                upAction: actions.upAction
                openNewWindowAction: actions.openNewWindowAction
                createAction: actions.createAction
                renameAction: actions.renameAction
                copyAction: actions.copyAction
                moveAction: actions.moveAction
                pasteAction: actions.pasteAction
                trashAction: actions.trashAction
                listViewAction: actions.listViewAction
                gridViewAction: actions.gridViewAction
                hiddenFilesAction: actions.hiddenFilesAction
                previewAction: actions.previewAction
                aboutAction: actions.aboutAction
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
                PreviewPane {
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
            }
        }
    }

    NoticeBanner {
        id: noticeBanner
    }

    BrowserDialogs {
        id: dialogs
        session: session
    }
}
