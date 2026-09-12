import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Item {
    id: root

    property var groups: []
    property Item returnFocus: null

    visible: false
    z: 1000
    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Keyboard shortcuts")

    function open(nextGroups, focusToRestore) {
        groups = nextGroups ?? [];
        returnFocus = focusToRestore ?? null;
        visible = true;
        dialogSurface.forceActiveFocus();
    }

    function close() {
        visible = false;
        if (returnFocus)
            returnFocus.forceActiveFocus();
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
        width: Math.min(parent.width - Theme.spaceXl * 2, 760 * Theme.scale)
        height: Math.min(parent.height - Theme.spaceXl * 2, 600 * Theme.scale)
        anchors.centerIn: parent
        focus: root.visible
        activeFocusOnTab: true

        Rectangle {
            anchors.fill: parent
            color: Theme.surface
            border.width: 1
            border.color: Theme.primary

            // Keep clicks inside the recap from reaching the dismissing
            // backdrop MouseArea.
            MouseArea { anchors.fill: parent }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.spaceXl
                spacing: Theme.spaceM

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spaceM

                    Text {
                        text: qsTr("Keyboard shortcuts")
                        color: Theme.text
                        font.pixelSize: Theme.fontTitle
                        font.weight: Font.DemiBold
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: qsTr("ESC to close")
                        color: Theme.textMuted
                        font.family: "monospace"
                        font.pixelSize: Theme.fontSmall
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 1
                    color: Theme.primary
                }

                ScrollView {
                    id: shortcutScroll
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

                    GridLayout {
                        width: shortcutScroll.availableWidth
                        columns: width < 520 * Theme.scale ? 1 : 2
                        columnSpacing: Theme.spaceXl * 2
                        rowSpacing: Theme.spaceXl

                        Repeater {
                            model: root.groups

                            delegate: ColumnLayout {
                                required property var modelData
                                Layout.fillWidth: true
                                Layout.alignment: Qt.AlignTop
                                spacing: Theme.spaceS

                                Text {
                                    Layout.fillWidth: true
                                    text: modelData.title
                                    color: Theme.text
                                    font.family: "monospace"
                                    font.pixelSize: Theme.fontBody
                                    font.weight: Font.DemiBold
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 1
                                    color: Theme.subtleDivider
                                }

                                Repeater {
                                    model: modelData.entries

                                    delegate: RowLayout {
                                        required property var modelData
                                        Layout.fillWidth: true
                                        spacing: Theme.spaceM

                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.label
                                            textFormat: Text.PlainText
                                            color: Theme.textMuted
                                            font.family: "monospace"
                                            font.pixelSize: Theme.fontSmall
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            Layout.minimumWidth: 150 * Theme.scale
                                            text: modelData.shortcut
                                            textFormat: Text.PlainText
                                            color: Theme.primary
                                            font.family: "monospace"
                                            font.pixelSize: Theme.fontSmall
                                            horizontalAlignment: Text.AlignRight
                                            elide: Text.ElideLeft
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

            }
        }
    }
}
