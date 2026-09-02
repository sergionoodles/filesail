import QtQuick

Item {
    id: root

    required property var session
    property string createParent: ""
    property string renameTarget: ""
    property var trashTargets: []
    readonly property bool active: createPrompt.visible || renamePrompt.visible || trashPrompt.visible || largeDirectoryPrompt.visible

    function openCreate(parentPath, focusTarget) {
        createParent = parentPath;
        createPrompt.open("", { parent: parentPath }, focusTarget);
    }

    function openRename(path, focusTarget) {
        renameTarget = path;
        renamePrompt.open(path.split("/").pop(), { path: path }, focusTarget);
    }

    function openTrash(paths, focusTarget) {
        trashTargets = paths;
        trashPrompt.open("", { paths: paths.slice() }, focusTarget);
    }

    function openLargeDirectory(path, entryCountAtLeast, focusTarget) {
        largeDirectoryPrompt.open("", { path: path, entryCountAtLeast: entryCountAtLeast }, focusTarget);
    }

    anchors.fill: parent
    z: 1000

    ModalPrompt {
        id: createPrompt
        anchors.fill: parent
        title: qsTr("New folder")
        message: qsTr("Create a folder in %1").arg(root.createParent)
        placeholder: qsTr("Folder name")
        acceptLabel: qsTr("Create")
        onAccepted: value => root.session.runOperation("mkdir", { parent: payload.parent, name: value }, true, qsTr("Folder created"))
    }
    ModalPrompt {
        id: renamePrompt
        anchors.fill: parent
        title: qsTr("Rename")
        message: root.renameTarget
        placeholder: qsTr("New name")
        acceptLabel: qsTr("Rename")
        onAccepted: value => root.session.runOperation("rename", { path: payload.path, name: value }, true, qsTr("Item renamed"))
    }
    ModalPrompt {
        id: trashPrompt
        anchors.fill: parent
        title: root.trashTargets.length === 1 ? qsTr("Move item to Trash?") : qsTr("Move %1 items to Trash?").arg(root.trashTargets.length)
        message: qsTr("Items remain recoverable from the desktop Trash. Permanent deletion is intentionally unavailable here.")
        acceptLabel: qsTr("Move to Trash")
        destructive: true
        inputVisible: false
        onAccepted: root.session.runOperation("trash", { paths: payload.paths }, true, qsTr("Moved to Trash"))
    }
    ModalPrompt {
        id: largeDirectoryPrompt
        anchors.fill: parent
        title: qsTr("Large folder")
        message: qsTr("This folder contains at least %1 items. Loading it may temporarily make FileSail less responsive.")
            .arg(payload.entryCountAtLeast)
        acceptLabel: qsTr("Load folder")
        inputVisible: false
        onAccepted: root.session.loadLargeDirectory(payload.path)
    }
}
