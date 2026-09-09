import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Item {
    id: root

    property var entry: ({})
    property var session: null
    property Item returnFocus: null
    property bool updatingExecutable: false

    readonly property bool hasEntry: entry !== null && entry !== undefined && entry.path !== undefined && entry.path !== ""

    readonly property string friendlyKind: {
        if (!root.hasEntry)
            return "";
        if (root.entry.isDirectory)
            return qsTr("Folder");
        const mime = String(root.entry.mimeType ?? "");
        return mime.length > 0 ? mime : qsTr("File");
    }
    readonly property string location: {
        if (!root.hasEntry)
            return "";
        const path = String(root.entry.path);
        const name = String(root.entry.name ?? "");
        if (path.length > name.length + 1 && path.endsWith("/" + name))
            return path.substring(0, path.length - name.length - 1) || "/";
        const slash = path.lastIndexOf("/");
        return slash > 0 ? path.substring(0, slash) : "/";
    }
    readonly property string extension: {
        if (!root.hasEntry || root.entry.isDirectory)
            return "";
        const name = String(root.entry.name ?? "");
        const dot = name.lastIndexOf(".");
        return dot > 0 ? name.substring(dot) : "";
    }
    readonly property string accessLabel: {
        if (!root.hasEntry)
            return "";
        const readable = root.entry.isReadable ?? true;
        const writable = root.entry.isWritable ?? true;
        if (readable && writable)
            return qsTr("Read & write");
        if (readable)
            return qsTr("Read-only");
        if (writable)
            return qsTr("Write-only");
        return qsTr("No access");
    }
    readonly property string permissionString: {
        if (!root.hasEntry)
            return "";
        return String(root.entry.permissions ?? "");
    }
    readonly property bool hasCreated: {
        if (!root.hasEntry)
            return false;
        return String(root.entry.created ?? "").length > 0;
    }
    readonly property bool isFile: root.hasEntry && root.entry.isDirectory !== true

    visible: false
    z: 1000
    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("File information")

    function open(entrySnapshot, focusToRestore) {
        entry = Object.assign({}, entrySnapshot ?? {});
        returnFocus = focusToRestore ?? null;
        updatingExecutable = false;
        visible = true;
        syncExecutableSwitch();
        closeButton.forceActiveFocus();
    }

    function close() {
        visible = false;
        updatingExecutable = false;
        if (returnFocus)
            returnFocus.forceActiveFocus();
    }

    function syncExecutableSwitch() {
        executableSwitch.checked = root.hasEntry && root.entry.isExecutable === true;
    }

    // The directory refresh triggered by the executable toggle (or an
    // external chmod) bumps selectionRevision. Re-resolve the snapshot by
    // path so the permission string and switch track the live entry.
    function refreshEntryFromSession() {
        if (!root.visible || !root.hasEntry || root.session === null)
            return false;
        const path = String(root.entry.path);
        const candidates = root.session.directory.entries.concat(root.session.selectedEntries);
        for (const candidate of candidates) {
            if (candidate && candidate.path === path) {
                entry = Object.assign({}, candidate);
                return true;
            }
        }
        return false;
    }

    function setFileExecutable(executable) {
        if (!root.hasEntry || root.session === null)
            return;
        root.updatingExecutable = true;
        executableFallback.restart();
        root.session.runOperation("setExecutable", { path: String(root.entry.path), executable: executable },
                                  true,
                                  executable ? qsTr("Executable permission enabled")
                                             : qsTr("Executable permission removed"),
                                  false, false);
    }

    onEntryChanged: syncExecutableSwitch()

    Connections {
        target: root.session
        function onSelectionRevisionChanged() {
            if (!root.visible)
                return;
            root.updatingExecutable = false;
            if (root.refreshEntryFromSession())
                root.syncExecutableSwitch();
        }
    }

    Timer {
        id: executableFallback
        interval: 4000
        onTriggered: {
            root.updatingExecutable = false;
            root.syncExecutableSwitch();
        }
    }

    Shortcut {
        sequences: ["Esc", "Back"]
        enabled: root.visible
        onActivated: root.close()
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha("#000000", 0.54)
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }
    }

    FocusScope {
        id: dialogSurface
        width: Math.min(parent.width - Theme.spaceXl * 2, 460 * Theme.scale)
        height: frame.implicitHeight
        anchors.centerIn: parent
        focus: root.visible
        activeFocusOnTab: true

        Rectangle {
            id: frame
            anchors.fill: parent
            implicitHeight: infoLayout.implicitHeight + Theme.spaceXl * 2
            color: Theme.surfaceVariant
            radius: Theme.radiusL
            border.width: 1
            border.color: Qt.alpha(Theme.outline, 0.9)

            MouseArea { anchors.fill: parent }

            ColumnLayout {
                id: infoLayout
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Theme.spaceXl
                spacing: Theme.spaceM

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spaceL

                    Loader {
                        Layout.preferredWidth: 56 * Theme.scale
                        Layout.preferredHeight: 56 * Theme.scale
                        Layout.alignment: Qt.AlignTop
                        active: root.hasEntry
                        sourceComponent: FileVisual {
                            entry: root.entry
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spaceXs

                        Text {
                            Layout.fillWidth: true
                            text: root.hasEntry ? Format.safeText(root.entry.name) : ""
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.pixelSize: Theme.fontTitle
                            font.weight: Font.DemiBold
                            wrapMode: Text.Wrap
                            maximumLineCount: 2
                            elide: Text.ElideRight
                        }
                        Text {
                            Layout.fillWidth: true
                            text: Format.safeText(root.friendlyKind)
                            textFormat: Text.PlainText
                            color: Theme.textMuted
                            font.pixelSize: Theme.fontBody
                            elide: Text.ElideRight
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 1
                    color: Qt.alpha(Theme.outline, 0.7)
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spaceM

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: Theme.spaceL
                        rowSpacing: Theme.spaceS

                        Text { text: qsTr("Location"); color: Theme.textMuted; font.pixelSize: Theme.fontSmall }
                        Text {
                            Layout.fillWidth: true
                            text: Format.safeText(root.location)
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.pixelSize: Theme.fontBody
                            wrapMode: Text.Wrap
                            elide: Text.ElideRight
                            maximumLineCount: 2
                        }

                        Text { text: qsTr("Type"); color: Theme.textMuted; font.pixelSize: Theme.fontSmall }
                        Text {
                            Layout.fillWidth: true
                            text: root.hasEntry && !root.entry.isDirectory ? Format.safeText(String(root.entry.mimeType ?? "")) : Format.safeText(root.friendlyKind)
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.pixelSize: Theme.fontBody
                            elide: Text.ElideRight
                        }

                        Text { visible: root.extension.length > 0; text: qsTr("Extension"); color: Theme.textMuted; font.pixelSize: Theme.fontSmall }
                        Text {
                            visible: root.extension.length > 0
                            Layout.fillWidth: true
                            text: Format.safeText(root.extension)
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.pixelSize: Theme.fontBody
                        }
                    }

                    Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.spaceS }

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: Theme.spaceL
                        rowSpacing: Theme.spaceS

                        Text { text: qsTr("Modified"); color: Theme.textMuted; font.pixelSize: Theme.fontSmall }
                        Text {
                            Layout.fillWidth: true
                            text: root.hasEntry ? Format.date(root.entry.modified) : ""
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.pixelSize: Theme.fontBody
                        }

                        Text { visible: root.hasCreated; text: qsTr("Created"); color: Theme.textMuted; font.pixelSize: Theme.fontSmall }
                        Text {
                            visible: root.hasCreated
                            Layout.fillWidth: true
                            text: root.hasEntry ? Format.date(root.entry.created) : ""
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.pixelSize: Theme.fontBody
                        }
                    }

                    Item { Layout.fillWidth: true; Layout.preferredHeight: Theme.spaceS }

                    GridLayout {
                        Layout.fillWidth: true
                        columns: 2
                        columnSpacing: Theme.spaceL
                        rowSpacing: Theme.spaceS

                        Text { text: qsTr("Size"); color: Theme.textMuted; font.pixelSize: Theme.fontSmall }
                        Text {
                            Layout.fillWidth: true
                            text: root.hasEntry ? Format.size(root.entry.size, root.entry.isDirectory) : ""
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.pixelSize: Theme.fontBody
                        }

                        Text { text: qsTr("Permissions"); color: Theme.textMuted; font.pixelSize: Theme.fontSmall }
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spaceS
                            Text {
                                text: Format.safeText(root.accessLabel)
                                textFormat: Text.PlainText
                                color: Theme.text
                                font.pixelSize: Theme.fontBody
                            }
                            Text {
                                visible: root.permissionString.length > 0
                                Layout.fillWidth: true
                                text: "(" + root.permissionString + ")"
                                textFormat: Text.PlainText
                                color: Theme.textMuted
                                font.pixelSize: Theme.fontBody
                                font.family: "monospace"
                                elide: Text.ElideRight
                            }
                        }

                        Text { visible: root.isFile; text: qsTr("Executable"); color: Theme.textMuted; font.pixelSize: Theme.fontSmall }
                        RowLayout {
                            visible: root.isFile
                            Layout.fillWidth: true
                            spacing: Theme.spaceM

                            Text {
                                Layout.fillWidth: true
                                text: root.updatingExecutable ? qsTr("Updating…") : qsTr("Allow running as a program")
                                textFormat: Text.PlainText
                                color: Theme.textMuted
                                font.pixelSize: Theme.fontSmall
                                elide: Text.ElideRight
                            }

                            AbstractButton {
                                id: executableSwitch
                                checkable: true
                                enabled: root.hasEntry && !root.updatingExecutable
                                opacity: enabled ? 1 : 0.4
                                implicitWidth: 44 * Theme.scale
                                implicitHeight: 24 * Theme.scale
                                hoverEnabled: true
                                focusPolicy: Qt.StrongFocus
                                Accessible.role: Accessible.CheckBox
                                Accessible.name: qsTr("Executable permission")
                                Layout.leftMargin: Theme.spaceS
                                onToggled: root.setFileExecutable(checked)
                                background: Rectangle {
                                    radius: Theme.radiusS
                                    color: executableSwitch.checked ? Theme.primary
                                         : executableSwitch.hovered ? Theme.controlHover
                                         : Qt.alpha(Theme.text, 0.14)
                                    border.width: 1
                                    border.color: executableSwitch.checked ? Theme.primary
                                         : Qt.alpha(Theme.text, 0.35)
                                    Behavior on color { ColorAnimation { duration: Theme.animationFast } }
                                }
                                contentItem: Item {
                                    Rectangle {
                                        width: 14 * Theme.scale
                                        height: 14 * Theme.scale
                                        x: executableSwitch.checked ? parent.width - width - 5 * Theme.scale : 5 * Theme.scale
                                        y: (parent.height - height) / 2
                                        radius: Theme.radiusS
                                        color: executableSwitch.checked ? Theme.primaryText : Theme.text
                                        Behavior on x { NumberAnimation { duration: Theme.animationFast } }
                                    }
                                }
                                ToolTip.visible: hovered
                                ToolTip.text: qsTr("Allow executing as a program")
                                ToolTip.delay: 450
                            }
                        }
                    }
                }

                Flow {
                    Layout.fillWidth: true
                    visible: root.hasEntry && (root.entry.isSymlink === true || root.entry.isHidden === true)
                    spacing: Theme.spaceS

                    Rectangle {
                        visible: root.hasEntry && root.entry.isSymlink === true
                        width: symlinkLabel.implicitWidth + Theme.spaceM * 2
                        height: symlinkLabel.implicitHeight + Theme.spaceS * 2
                        radius: Theme.radiusS
                        color: Qt.alpha(Theme.primary, 0.16)
                        border.width: 1
                        border.color: Qt.alpha(Theme.primary, 0.5)
                        Text {
                            id: symlinkLabel
                            anchors.centerIn: parent
                            text: qsTr("Symlink")
                            color: Theme.primary
                            font.pixelSize: Theme.fontSmall
                        }
                    }
                    Rectangle {
                        visible: root.hasEntry && root.entry.isHidden === true
                        width: hiddenLabel.implicitWidth + Theme.spaceM * 2
                        height: hiddenLabel.implicitHeight + Theme.spaceS * 2
                        radius: Theme.radiusS
                        color: Qt.alpha(Theme.primary, 0.16)
                        border.width: 1
                        border.color: Qt.alpha(Theme.primary, 0.5)
                        Text {
                            id: hiddenLabel
                            anchors.centerIn: parent
                            text: qsTr("Hidden")
                            color: Theme.primary
                            font.pixelSize: Theme.fontSmall
                        }
                    }
                }

                RowLayout {
                    Layout.alignment: Qt.AlignRight
                    spacing: Theme.spaceS

                    Button {
                        id: closeButton
                        text: qsTr("Close")
                        implicitHeight: Theme.buttonHeight
                        leftPadding: Theme.buttonPaddingHorizontal
                        rightPadding: Theme.buttonPaddingHorizontal
                        topPadding: Theme.buttonPaddingVertical
                        bottomPadding: Theme.buttonPaddingVertical
                        Accessible.name: qsTr("Close file information")
                        onClicked: root.close()
                        background: Rectangle {
                            radius: Theme.radiusS
                            color: closeButton.down ? Theme.controlHover : "transparent"
                            border.width: 1
                            border.color: Theme.outline
                        }
                        contentItem: Text {
                            text: closeButton.text
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.pixelSize: Theme.fontBody
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }
                }
            }
        }
    }
}
