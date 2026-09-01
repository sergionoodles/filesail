import QtQuick
import QtQuick.Layouts
import Quickshell
import "../core"

Rectangle {
    id: root

    property string currentPath: ""
    signal navigate(string path)

    readonly property string homePath: String(Quickshell.env("HOME") ?? "/")
    readonly property var places: [
        { name: "Home", icon: "⌂", path: homePath },
        { name: "Desktop", icon: "▣", path: homePath + "/Desktop" },
        { name: "Documents", icon: "▤", path: homePath + "/Documents" },
        { name: "Downloads", icon: "↓", path: homePath + "/Downloads" },
        { name: "Pictures", icon: "◫", path: homePath + "/Pictures" },
        { name: "Music", icon: "♪", path: homePath + "/Music" },
        { name: "Videos", icon: "▶", path: homePath + "/Videos" }
    ]

    color: Qt.alpha(Theme.surfaceVariant, 0.58)

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: Theme.spaceM
        spacing: Theme.spaceXs

        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Theme.spaceS
            Layout.rightMargin: Theme.spaceS
            Layout.bottomMargin: Theme.spaceM

            Rectangle {
                implicitWidth: 28 * Theme.scale
                implicitHeight: implicitWidth
                radius: Theme.radiusS
                color: Theme.primary

                Text {
                    anchors.centerIn: parent
                    text: "◢"
                    color: Theme.primaryText
                    font.pixelSize: 15 * Theme.scale
                    font.bold: true
                }
            }

            ColumnLayout {
                spacing: -2
                Text {
                    text: "FILESAIL"
                    color: Theme.text
                    font.pixelSize: Theme.fontBody
                    font.weight: Font.Bold
                    font.letterSpacing: 1.4
                }
                Text {
                    text: "LOCAL NAVIGATOR"
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontSmall - 2
                    font.letterSpacing: 0.8
                }
            }
        }

        Text {
            Layout.leftMargin: Theme.spaceS
            Layout.bottomMargin: Theme.spaceXs
            text: "PLACES"
            color: Theme.textMuted
            font.pixelSize: Theme.fontSmall - 1
            font.weight: Font.DemiBold
            font.letterSpacing: 1.2
        }

        Repeater {
            model: root.places

            delegate: Rectangle {
                required property var modelData
                Layout.fillWidth: true
                implicitHeight: 34 * Theme.scale
                radius: Theme.radiusS
                color: root.currentPath === modelData.path ? Qt.alpha(Theme.primary, 0.16)
                      : placeMouse.containsMouse ? Qt.alpha(Theme.text, 0.07) : "transparent"

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spaceM
                    anchors.rightMargin: Theme.spaceM
                    spacing: Theme.spaceM

                    Text {
                        text: modelData.icon
                        color: root.currentPath === modelData.path ? Theme.primary : Theme.textMuted
                        font.pixelSize: 15 * Theme.scale
                    }
                    Text {
                        Layout.fillWidth: true
                        text: modelData.name
                        color: Theme.text
                        font.pixelSize: Theme.fontBody
                        elide: Text.ElideRight
                    }
                }

                MouseArea {
                    id: placeMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.navigate(modelData.path)
                }
            }
        }

        Item { Layout.fillHeight: true }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 34 * Theme.scale
            radius: Theme.radiusS
            color: trashMouse.containsMouse ? Qt.alpha(Theme.text, 0.07) : "transparent"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Theme.spaceM
                anchors.rightMargin: Theme.spaceM
                spacing: Theme.spaceM
                Text { text: "♲"; color: Theme.textMuted; font.pixelSize: 16 * Theme.scale }
                Text { Layout.fillWidth: true; text: "Trash"; color: Theme.text; font.pixelSize: Theme.fontBody }
            }

            MouseArea {
                id: trashMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.navigate(root.homePath + "/.local/share/Trash/files")
            }
        }
    }
}
