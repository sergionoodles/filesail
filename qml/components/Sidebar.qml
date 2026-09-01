import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Rectangle {
    id: root

    property string currentPath: ""
    // Inject a ListModel using PlacesModel's label, iconName, path, and kind roles
    // to add favourites or volumes without changing this component.
    property var placesModel: PlacesModel.model
    signal navigate(string path)

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

            Image {
                Layout.preferredWidth: 28 * Theme.scale
                Layout.preferredHeight: Layout.preferredWidth
                source: "../../logo.png"
                fillMode: Image.PreserveAspectFit
                smooth: true
            }

            ColumnLayout {
                spacing: -2
                Text {
                    text: qsTr("FILESAIL")
                    color: Theme.text
                    font.pixelSize: Theme.fontBody
                    font.weight: Font.Bold
                    font.letterSpacing: 1.4
                }
                Text {
                    text: qsTr("LOCAL NAVIGATOR")
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontSmall - 2
                    font.letterSpacing: 0.8
                }
            }
        }

        Text {
            Layout.leftMargin: Theme.spaceS
            Layout.bottomMargin: Theme.spaceXs
            text: qsTr("PLACES")
            color: Theme.textMuted
            font.pixelSize: Theme.fontSmall - 1
            font.weight: Font.DemiBold
            font.letterSpacing: 1.2
        }

        Repeater {
            model: root.placesModel

            delegate: AbstractButton {
                id: placeDelegate
                required property string label
                required property string iconName
                required property string path
                Layout.fillWidth: true
                implicitHeight: 34 * Theme.scale
                hoverEnabled: true
                focusPolicy: Qt.StrongFocus
                Accessible.name: label
                Accessible.role: Accessible.ListItem
                onClicked: root.navigate(path)

                background: Rectangle {
                    radius: Theme.radiusS
                    color: root.currentPath === path ? Theme.selectionFill
                          : parent.hovered ? Theme.controlHover : "transparent"
                }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Theme.spaceM
                    anchors.rightMargin: Theme.spaceM
                    spacing: Theme.spaceM

                    LucideIcon {
                        Layout.preferredWidth: 17 * Theme.scale
                        Layout.preferredHeight: Layout.preferredWidth
                        name: placeDelegate.iconName === "user-home" ? "house"
                            : placeDelegate.iconName === "user-desktop" ? "monitor"
                            : placeDelegate.iconName === "user-trash" ? "trash-2" : "folder"
                        iconColor: root.currentPath === path ? Theme.primary : Theme.textMuted
                        iconSize: Layout.preferredWidth
                    }
                    Text {
                        Layout.fillWidth: true
                        text: label
                        color: Theme.text
                        font.pixelSize: Theme.fontBody
                        elide: Text.ElideRight
                    }
                }
            }
        }

        Item { Layout.fillHeight: true }
    }
}
