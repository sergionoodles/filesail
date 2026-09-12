import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import "../core"

Item {
    id: root

    readonly property string githubUrl: "https://github.com/sergionoodles/filesail"
    readonly property string githubHost: "github.com/sergionoodles/filesail"
    readonly property string titleFull: "FILESAIL"
    property Item returnFocus: null
    property bool caretVisible: true
    property bool typingTitle: false
    property string titleTyped: ""

    visible: false
    z: 1000
    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("About FileSail")

    function open(focusToRestore) {
        returnFocus = focusToRestore ?? null;
        titleTyped = "";
        typingTitle = true;
        caretVisible = true;
        visible = true;
        dialogSurface.forceActiveFocus();
        typewriterTimer.restart();
    }

    function close() {
        typewriterTimer.stop();
        typingTitle = false;
        visible = false;
        if (returnFocus)
            returnFocus.forceActiveFocus();
    }

    function openGithub() {
        Quickshell.execDetached(["xdg-open", root.githubUrl]);
    }

    Shortcut {
        sequences: ["Esc", "Back"]
        enabled: root.visible
        onActivated: root.close()
    }
    Shortcut {
        sequences: ["Return", "Enter"]
        enabled: root.visible
        onActivated: root.openGithub()
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha("#000000", 0.54)
        MouseArea {
            anchors.fill: parent
            onClicked: root.close()
        }
    }

    ModalScaffold {
        id: dialogSurface
        width: Math.min(parent.width - Theme.spaceXl * 2, 420 * Theme.scale)
        height: implicitHeight
        anchors.centerIn: parent
        focus: root.visible
        footerVisible: true

        headerContent: ModalHeader {
            Layout.fillWidth: true
            leadingVisible: true
            title: qsTr("About FileSail")
            subtitle: qsTr("A file manager for tiling window managers")
            trailingText: qsTr("ESC to close")

            leadingContent: Image {
                anchors.fill: parent
                source: Qt.resolvedUrl("../../logo.png")
                sourceSize: Qt.size(Math.ceil(width), Math.ceil(height))
                fillMode: Image.PreserveAspectFit
                smooth: true
                asynchronous: true
                Accessible.ignored: true
            }
        }

        bodyContent: ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.spaceL

            Item {
                Layout.alignment: Qt.AlignHCenter
                implicitWidth: titleMetrics.width + Theme.spaceS + titleCaret.width
                implicitHeight: Math.max(titleMetrics.height, titleCaret.height)

                TextMetrics {
                    id: titleMetrics
                    font.family: "monospace"
                    font.pixelSize: Theme.fontTitle
                    font.letterSpacing: 3
                    text: root.titleFull
                }

                Text {
                    id: typedTitle
                    text: root.titleTyped
                    color: Theme.text
                    font.family: "monospace"
                    font.pixelSize: Theme.fontTitle
                    font.letterSpacing: 3
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                }
                Rectangle {
                    id: titleCaret
                    width: Math.max(8, Math.round(Theme.fontTitle * 0.48))
                    height: Theme.fontTitle
                    x: typedTitle.x + typedTitle.contentWidth + (root.titleTyped.length > 0 ? Theme.spaceS : 0)
                    anchors.verticalCenter: parent.verticalCenter
                    color: Theme.primary
                    opacity: root.caretVisible ? 1 : 0
                }
            }

            Text {
                Layout.fillWidth: true
                text: qsTr("Designed for tiling window managers. It follows the OS theme so it can sneak into a tile and pretend it has always lived there.")
                color: Theme.textMuted
                font.family: "monospace"
                font.pixelSize: Theme.fontBody
                wrapMode: Text.Wrap
                horizontalAlignment: Text.AlignHCenter
            }

            Text {
                Layout.fillWidth: true
                text: root.githubHost
                color: Theme.primary
                font.family: "monospace"
                font.pixelSize: Theme.fontSmall
                horizontalAlignment: Text.AlignHCenter
            }
        }

        footerContent: ModalFooter {
            Layout.fillWidth: true
            ModalButton {
                text: qsTr("Close")
                Accessible.name: qsTr("Close About FileSail")
                onClicked: root.close()
            }
            ModalButton {
                text: qsTr("Open GitHub")
                primary: true
                Accessible.name: qsTr("Open FileSail GitHub repository")
                onClicked: root.openGithub()
            }
        }
    }

    Timer {
        id: typewriterTimer
        interval: 75
        repeat: true
        onTriggered: {
            if (root.titleTyped.length < root.titleFull.length) {
                root.titleTyped = root.titleFull.substring(0, root.titleTyped.length + 1);
                root.caretVisible = true;
                return;
            }
            stop();
            root.typingTitle = false;
            root.caretVisible = true;
        }
    }

    Timer {
        interval: 530
        running: root.visible && !root.typingTitle
        repeat: true
        onTriggered: root.caretVisible = !root.caretVisible
    }
}
