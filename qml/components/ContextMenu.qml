import QtQuick
import QtQuick.Controls
import "../core"

Menu {
    id: root

    required property var session
    required property var actions
    property var entry: null
    property bool backgroundContext: true
    property string targetDirectory: ""

    width: 240 * Theme.scale
    delegate: ThemedMenuItem {}

    Connections {
        target: root.session.directory
        function onPathChanged() { root.close(); }
    }

    background: Rectangle {
        color: Theme.surfaceVariant
        border.width: 1
        border.color: Theme.divider
    }

    function openAt(x, y, contextEntry, isBackground) {
        entry = contextEntry;
        backgroundContext = isBackground;
        targetDirectory = isBackground ? session.directory.path : (contextEntry?.isDirectory ? contextEntry.path : session.directory.path);
        popup(x, y);
    }

    ThemedMenuItem {
        text: root.entry && !root.backgroundContext ? qsTr("Open") : qsTr("Open Folder")
        enabled: !root.backgroundContext && root.session.selectedCount === 1
        visible: !root.backgroundContext
        onTriggered: {
            if (root.entry)
                root.session.openEntry(root.entry.path, root.entry.isDirectory);
        }
    }
    ThemedMenuItem {
        text: qsTr("Open in New Window")
        enabled: !root.actions.modalActive && (root.backgroundContext || root.entry?.isDirectory)
        visible: root.backgroundContext || root.entry?.isDirectory
        onTriggered: root.actions.newWindowRequested(root.targetDirectory)
    }
    ThemedMenuItem {
        text: root.actions.openTerminalAction.text
        enabled: root.actions.openTerminalAction.enabled
        visible: root.backgroundContext || root.entry?.isDirectory
        onTriggered: root.session.runOperation("terminal", { path: root.targetDirectory }, false, qsTr("Terminal opened"), false)
    }

    MenuSeparator {
        padding: 0
        topPadding: Theme.spaceS
        bottomPadding: Theme.spaceS
        contentItem: Rectangle {
            implicitWidth: 200 * Theme.scale
            implicitHeight: 1
            color: Theme.divider
        }
    }

    ThemedMenuItem {
        text: root.actions.createAction.text
        visible: root.backgroundContext
        enabled: root.actions.createAction.enabled
        onTriggered: root.actions.createAction.trigger()
    }
    ThemedMenuItem {
        text: root.actions.copyAction.text
        visible: !root.backgroundContext
        enabled: root.actions.copyAction.enabled
        onTriggered: root.actions.copyAction.trigger()
    }
    ThemedMenuItem {
        text: root.actions.moveAction.text
        visible: !root.backgroundContext
        enabled: root.actions.moveAction.enabled
        onTriggered: root.actions.moveAction.trigger()
    }
    ThemedMenuItem {
        text: root.actions.pasteAction.text
        visible: root.backgroundContext
        enabled: root.actions.pasteAction.enabled
        onTriggered: root.session.paste(root.targetDirectory)
    }

    MenuSeparator {
        id: selectionDivider
        visible: !root.backgroundContext
        padding: 0
        topPadding: visible ? Theme.spaceS : 0
        bottomPadding: visible ? Theme.spaceS : 0
        contentItem: Rectangle {
            implicitWidth: 200 * Theme.scale
            implicitHeight: selectionDivider.visible ? 1 : 0
            color: Theme.divider
        }
    }

    ThemedMenuItem {
        text: root.actions.renameAction.text
        visible: !root.backgroundContext
        enabled: root.actions.renameAction.enabled
        onTriggered: root.actions.renameAction.trigger()
    }
    ThemedMenuItem {
        text: root.actions.trashAction.text
        visible: !root.backgroundContext
        enabled: root.actions.trashAction.enabled
        onTriggered: root.actions.trashAction.trigger()
    }
    ThemedMenuItem {
        text: root.actions.infoAction.text
        visible: !root.backgroundContext
        enabled: root.actions.infoAction.enabled
        onTriggered: root.actions.infoAction.trigger()
    }

    MenuSeparator {
        id: backgroundDivider
        visible: root.backgroundContext
        padding: 0
        topPadding: visible ? Theme.spaceS : 0
        bottomPadding: visible ? Theme.spaceS : 0
        contentItem: Rectangle {
            implicitWidth: 200 * Theme.scale
            implicitHeight: backgroundDivider.visible ? 1 : 0
            color: Theme.divider
        }
    }

    ThemedMenuItem {
        text: root.actions.selectAllAction.text
        visible: root.backgroundContext
        enabled: root.actions.selectAllAction.enabled
        onTriggered: root.actions.selectAllAction.trigger()
    }
    Menu {
        title: qsTr("View")
        visible: root.backgroundContext
        implicitHeight: visible ? 32 * Theme.scale : 0
        delegate: ThemedMenuItem {}
        ThemedMenuItem { text: root.actions.listViewAction.text; checkable: true; checked: root.actions.listViewAction.checked; onTriggered: root.actions.listViewAction.trigger() }
        ThemedMenuItem { text: root.actions.gridViewAction.text; checkable: true; checked: root.actions.gridViewAction.checked; onTriggered: root.actions.gridViewAction.trigger() }
        ThemedMenuItem { text: root.actions.previewAction.text; checkable: true; checked: root.actions.previewAction.checked; onTriggered: root.actions.previewAction.trigger() }
    }
    Menu {
        title: qsTr("Sort By")
        visible: root.backgroundContext
        implicitHeight: visible ? 32 * Theme.scale : 0
        delegate: ThemedMenuItem {}
        ThemedMenuItem { text: root.actions.sortByNameAction.text; checkable: true; checked: root.actions.sortByNameAction.checked; onTriggered: root.actions.sortByNameAction.trigger() }
        ThemedMenuItem { text: root.actions.sortBySizeAction.text; checkable: true; checked: root.actions.sortBySizeAction.checked; onTriggered: root.actions.sortBySizeAction.trigger() }
        ThemedMenuItem { text: root.actions.sortByModifiedAction.text; checkable: true; checked: root.actions.sortByModifiedAction.checked; onTriggered: root.actions.sortByModifiedAction.trigger() }
    }
    ThemedMenuItem {
        text: root.actions.refreshAction.text
        visible: root.backgroundContext
        enabled: root.actions.refreshAction.enabled
        onTriggered: root.actions.refreshAction.trigger()
    }
}
