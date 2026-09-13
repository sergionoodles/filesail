import QtQuick
import "../core"

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
    property bool dialogSecret: false
    property string createParent: ""
    property string renameTarget: ""
    property var trashTargets: []
    property var keybindings: []
    property var unlockVolume: null
    property var unlockNavigateCallback: null
    property var unlockErrorCallback: null
    property var unlockNoticeCallback: null
    property var safeRemoveCallback: null
    readonly property bool active: (promptLoader.item ? promptLoader.item.visible : false)
        || (aboutLoader.item ? aboutLoader.item.visible : false)
        || (infoLoader.item ? infoLoader.item.visible : false)
        || (keybindingsLoader.item ? keybindingsLoader.item.visible : false)
        || (volumeErrorLoader.item ? volumeErrorLoader.item.visible : false)
    anchors.fill: parent
    z: 1000

    function openPrompt(nextMode, title, message, acceptLabel, inputVisible, destructive,
                        initialValue, payload, focusTarget, placeholder, secret) {
        mode = nextMode;
        dialogTitle = title;
        dialogMessage = message;
        dialogAcceptLabel = acceptLabel;
        dialogInputVisible = inputVisible;
        dialogDestructive = destructive;
        dialogPlaceholder = placeholder ?? "";
        dialogSecret = secret === true;
        promptLoader.active = true;
        promptLoader.item.open(initialValue ?? "", payload ?? {}, focusTarget);
    }
    function openUnlock(volume, navigateCallback, errorCallback, noticeCallback, focusTarget) {
        unlockVolume = volume;
        unlockNavigateCallback = navigateCallback;
        unlockErrorCallback = errorCallback;
        unlockNoticeCallback = noticeCallback;
        openPrompt("unlock", qsTr("Unlock %1").arg(Format.safeText(volume.label)),
                   qsTr("Enter the encryption passphrase. FileSail will not save it."),
                   qsTr("Unlock and Open"), true, false, "", { volume }, focusTarget,
                   qsTr("Passphrase"), true);
    }
    function openVolumeError(error, retryCallback, focusTarget) {
        volumeErrorLoader.active = true;
        volumeErrorLoader.item.open(error, retryCallback, focusTarget);
    }
    function confirmSafeRemove(drive, callback, focusTarget) {
        safeRemoveCallback = callback;
        openPrompt("safeRemove", qsTr("Safely remove drive?"),
                   Number(drive.affectedSiblingCount ?? 1) > 1
                       ? qsTr("This hardware contains %1 related drives. They will all be unmounted before the device is powered off.").arg(drive.affectedSiblingCount)
                       : qsTr("All mounted volumes on %1 will be unmounted first.").arg(Format.safeText(drive.label)),
                   drive.ejectable ? qsTr("Eject Media") : qsTr("Safely Remove"),
                   false, false, "", { drive }, focusTarget);
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
    function openInfo(entry, focusTarget) {
        if (!entry)
            return;
        infoLoader.active = true;
        infoLoader.item.session = root.session;
        infoLoader.item.open(entry, focusTarget);
    }
    function openKeybindings(groups, focusTarget) {
        keybindings = groups ?? [];
        keybindingsLoader.active = true;
        keybindingsLoader.item.open(keybindings, focusTarget);
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
            secretInput: root.dialogSecret
            onAccepted: value => {
                if (root.mode === "create") root.session.runOperation("mkdir", { parent: payload.parent, name: value }, true, qsTr("Folder created"));
                else if (root.mode === "rename") root.session.runOperation("rename", { path: payload.path, name: value }, true, qsTr("Item renamed"));
                else if (root.mode === "trash") root.session.runOperation("trash", { paths: payload.paths }, true, qsTr("Moved to Trash"));
                else if (root.mode === "largeDirectory") root.session.loadLargeDirectory(payload.path);
                else if (root.mode === "unlock") {
                    const callback = root.unlockNavigateCallback;
                    const errorCallback = root.unlockErrorCallback;
                    const noticeCallback = root.unlockNoticeCallback;
                    root.unlockNavigateCallback = null;
                    root.unlockErrorCallback = null;
                    root.unlockNoticeCallback = null;
                    VolumeModel.unlockAndOpen(payload.volume, value, callback, root.openUnlock,
                                              errorCallback, noticeCallback);
                }
                else if (root.mode === "safeRemove") {
                    const callback = root.safeRemoveCallback;
                    root.safeRemoveCallback = null;
                    if (callback) callback();
                }
            }
            onRejected: {
                if (root.mode === "unlock") {
                    root.unlockNavigateCallback = null;
                    root.unlockErrorCallback = null;
                    root.unlockNoticeCallback = null;
                    root.unlockVolume = null;
                }
                if (root.mode === "safeRemove") root.safeRemoveCallback = null;
            }
        }
    }

    Loader {
        id: aboutLoader
        anchors.fill: parent
        active: false
        sourceComponent: AboutDialog {}
    }

    Loader {
        id: infoLoader
        anchors.fill: parent
        active: false
        sourceComponent: FileInfoDialog {}
    }

    Loader {
        id: keybindingsLoader
        anchors.fill: parent
        active: false
        sourceComponent: KeybindingsDialog {}
    }

    Loader {
        id: volumeErrorLoader
        anchors.fill: parent
        active: false
        sourceComponent: VolumeErrorDialog {}
    }
}
