import QtQuick

Item {
    id: root
    required property var session
    property string mode: ""
    property string dialogTitle: ""
    property string dialogMessage: ""
    property string dialogPlaceholder: ""
    property string dialogAcceptLabel: "Continue"
    property bool dialogDestructive: false
    property bool dialogInputVisible: true
    property string createParent: ""
    property string renameTarget: ""
    property var trashTargets: []
    readonly property bool active: (promptLoader.item ? promptLoader.item.visible : false)
        || (aboutLoader.item ? aboutLoader.item.visible : false)
    anchors.fill: parent
    z: 1000

    function openPrompt(nextMode, title, message, acceptLabel, inputVisible, destructive,
                        initialValue, payload, focusTarget, placeholder) {
        mode = nextMode;
        dialogTitle = title;
        dialogMessage = message;
        dialogAcceptLabel = acceptLabel;
        dialogInputVisible = inputVisible;
        dialogDestructive = destructive;
        dialogPlaceholder = placeholder ?? "";
        promptLoader.active = true;
        promptLoader.item.open(initialValue ?? "", payload ?? {}, focusTarget);
    }
    function openCreate(parentPath, focusTarget) {
        createParent = parentPath;
        openPrompt("create", qsTr("New folder"), qsTr("Create a folder in %1").arg(parentPath),
                   qsTr("Create"), true, false, "", { parent: parentPath }, focusTarget, qsTr("Folder name"));
    }
    function openRename(path, focusTarget) {
        renameTarget = path;
        openPrompt("rename", qsTr("Rename"), path, qsTr("Rename"), true, false,
                   path.split("/").pop(), { path }, focusTarget, qsTr("New name"));
    }
    function openTrash(paths, focusTarget) {
        trashTargets = paths;
        openPrompt("trash", paths.length === 1 ? qsTr("Move item to Trash?") : qsTr("Move %1 items to Trash?").arg(paths.length),
                   qsTr("Items remain recoverable from the desktop Trash. Permanent deletion is intentionally unavailable here."),
                   qsTr("Move to Trash"), false, true, "", { paths: paths.slice() }, focusTarget);
    }
    function openLargeDirectory(path, entryCountAtLeast, focusTarget) {
        openPrompt("largeDirectory", qsTr("Large folder"),
                   qsTr("This folder contains at least %1 items. Loading it may temporarily make FileSail less responsive.").arg(entryCountAtLeast),
                   qsTr("Load folder"), false, false, "", { path, entryCountAtLeast }, focusTarget);
    }
    function openAbout(focusTarget) {
        aboutLoader.active = true;
        aboutLoader.item.open(focusTarget);
    }

    Loader {
        id: promptLoader
        anchors.fill: parent
        active: false
        sourceComponent: ModalPrompt {
            title: root.dialogTitle
            message: root.dialogMessage
            placeholder: root.dialogPlaceholder
            acceptLabel: root.dialogAcceptLabel
            destructive: root.dialogDestructive
            inputVisible: root.dialogInputVisible
            onAccepted: value => {
                if (root.mode === "create") root.session.runOperation("mkdir", { parent: payload.parent, name: value }, true, qsTr("Folder created"));
                else if (root.mode === "rename") root.session.runOperation("rename", { path: payload.path, name: value }, true, qsTr("Item renamed"));
                else if (root.mode === "trash") root.session.runOperation("trash", { paths: payload.paths }, true, qsTr("Moved to Trash"));
                else if (root.mode === "largeDirectory") root.session.loadLargeDirectory(payload.path);
            }
        }
    }

    Loader {
        id: aboutLoader
        anchors.fill: parent
        active: false
        sourceComponent: AboutDialog {}
    }
}
