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

    Rectangle {
        width: dialogSurface.width
        height: dialogSurface.height
        x: dialogSurface.x + 6 * Theme.scale
        y: dialogSurface.y + 6 * Theme.scale
        color: Qt.alpha("#000000", 0.55)
    }

    FocusScope {
        id: dialogSurface
        width: Math.min(parent.width - Theme.spaceXl * 2, 420 * Theme.scale)
        height: frame.implicitHeight
        anchors.centerIn: parent
        focus: root.visible
        activeFocusOnTab: true

        Rectangle {
            id: frame
            anchors.fill: parent
            implicitHeight: aboutLayout.implicitHeight + 8 * Theme.scale
            color: Theme.surface
            radius: Theme.radiusL
            border.width: 1
            border.color: Theme.primary

            MouseArea { anchors.fill: parent }

            Rectangle {
                id: innerFrame
                anchors.fill: parent
                anchors.margins: 4 * Theme.scale
                color: Theme.surface
                radius: Theme.radiusL
                border.width: 1
                border.color: Theme.primary

                ColumnLayout {
                    id: aboutLayout
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    spacing: 0

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Theme.spaceXl + 8 * Theme.scale
                    }

                    Image {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 72 * Theme.scale
                        Layout.preferredHeight: 72 * Theme.scale
                        source: Qt.resolvedUrl("../../logo.png")
                        sourceSize: Qt.size(Math.ceil(72 * Theme.scale), Math.ceil(72 * Theme.scale))
                        fillMode: Image.PreserveAspectFit
                        smooth: true
                        asynchronous: true
                        Accessible.ignored: true
                    }

                    Item {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: Theme.spaceL
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
                        Layout.topMargin: Theme.spaceL
                        Layout.leftMargin: Theme.spaceXl
                        Layout.rightMargin: Theme.spaceXl
                        text: qsTr("Designed for tiling window managers. It follows the OS theme so it can sneak into a tile and pretend it has always lived there.")
                        color: Theme.textMuted
                        font.family: "monospace"
                        font.pixelSize: Theme.fontBody
                        wrapMode: Text.Wrap
                        horizontalAlignment: Text.AlignHCenter
                    }

                    AbstractButton {
                        id: githubLink
                        Layout.alignment: Qt.AlignHCenter
                        Layout.topMargin: Theme.spaceXl
                        implicitWidth: githubLinkText.implicitWidth + Theme.spaceM * 2
                        implicitHeight: githubLinkText.implicitHeight + Theme.spaceS
                        hoverEnabled: true
                        focusPolicy: Qt.NoFocus
                        Accessible.role: Accessible.Link
                        Accessible.name: qsTr("Open FileSail GitHub repository")
                        onClicked: root.openGithub()

                        HoverHandler { cursorShape: Qt.PointingHandCursor }

                        background: Rectangle {
                            radius: Theme.radiusS
                            color: githubLink.down ? Theme.selectionFill
                                 : githubLink.hovered ? Theme.controlHover : "transparent"
                        }
                        contentItem: Text {
                            id: githubLinkText
                            text: "> " + root.githubHost
                            color: Theme.primary
                            font.family: "monospace"
                            font.pixelSize: Theme.fontBody
                            font.underline: githubLink.hovered
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.preferredHeight: Theme.spaceXl
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: 1
                        color: Theme.primary
                    }

                    Text {
                        Layout.fillWidth: true
                        Layout.leftMargin: Theme.spaceM
                        Layout.rightMargin: Theme.spaceM
                        Layout.topMargin: Theme.spaceS
                        Layout.bottomMargin: Theme.spaceS
                        text: qsTr("Press ESC to close")
                        color: Theme.textMuted
                        font.family: "monospace"
                        font.pixelSize: Theme.fontSmall
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }
        }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: -Math.round(implicitHeight * 0.45) + 1
            text: qsTr(" ABOUT ")
            color: Theme.primary
            font.family: "monospace"
            font.pixelSize: Theme.fontSmall
            font.letterSpacing: 2
            z: 2

            Rectangle {
                z: -1
                anchors.fill: parent
                color: Theme.surface
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
