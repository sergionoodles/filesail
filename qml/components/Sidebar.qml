import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Rectangle {
    id: root
    property string currentPath: ""
    property string homePath: PlacesModel.homePath
    property string activeSection: "places"
    property var placesModel: PlacesModel.model
    property var projectsModel
    property var bookmarksModel
    // Keep the sidebar header aligned with the explorer toolbar divider.
    property real topSectionHeight: 0
    signal navigate(string path)
    signal addCurrentDirectoryRequested(string collection)
    signal removeLocationRequested(string collection, string id)
    signal activateVolume(var volume)
    signal unmountVolume(var volume)
    signal safeRemoveDrive(var drive)
    color: Qt.alpha(Theme.surfaceVariant, 0.58)

    function placeIconName(iconName) {
        switch (iconName) {
        case "user-home": return "house";
        case "user-desktop": return "monitor";
        case "user-trash": return "trash-2";
        case "folder-documents": return "file-text";
        case "folder-download": return "folder-down";
        case "folder-pictures": return "image";
        case "folder-music": return "music";
        case "folder-videos": return "video";
        default: return "folder";
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: Math.max(root.topSectionHeight, 40 * Theme.scale + Theme.spaceM * 2)

            RowLayout {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: Theme.spaceM
                anchors.rightMargin: Theme.spaceM
                anchors.topMargin: Theme.spaceM
                spacing: Theme.spaceS

                ButtonGroup { id: sectionGroup }
                SidebarTabButton { Layout.fillWidth: true; iconName: "folder"; tooltip: qsTr("Places"); checked: root.activeSection === "places"; ButtonGroup.group: sectionGroup; onClicked: root.activeSection = "places" }
                SidebarTabButton { Layout.fillWidth: true; iconName: "code"; tooltip: qsTr("Projects"); checked: root.activeSection === "projects"; ButtonGroup.group: sectionGroup; onClicked: root.activeSection = "projects" }
                SidebarTabButton { Layout.fillWidth: true; iconName: "star"; tooltip: qsTr("Bookmarks"); checked: root.activeSection === "bookmarks"; ButtonGroup.group: sectionGroup; onClicked: root.activeSection = "bookmarks" }
                SidebarTabButton { Layout.fillWidth: true; iconName: "house"; tooltip: qsTr("Home"); checkable: false; onClicked: root.navigate(root.homePath) }
            }

        }

        ColumnLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.leftMargin: Theme.spaceM
            Layout.rightMargin: Theme.spaceM
            Layout.topMargin: Theme.spaceM
            Layout.bottomMargin: Theme.spaceM
            spacing: Theme.spaceS

            StackLayout {
                Layout.fillWidth: true; Layout.fillHeight: true
                currentIndex: 0
                Loader {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    active: true
                    sourceComponent: root.activeSection === "places" ? placesPage
                        : root.activeSection === "projects" ? projectsPage : bookmarksPage
                }
            }

        }

        OperationQueue {
            Layout.fillWidth: true
            onNavigate: path => root.navigate(path)
        }
    }

    Component {
        id: placesPage
        ScrollView {
            clip: true
            contentWidth: availableWidth
            ColumnLayout {
                width: parent.width
                spacing: Theme.spaceXs
                Text { Layout.leftMargin: Theme.spaceS; Layout.bottomMargin: Theme.spaceXs; text: qsTr("PLACES"); color: Theme.textMuted; font.pixelSize: Theme.fontSmall - 1; font.weight: Font.DemiBold; font.letterSpacing: 1.2 }
                Repeater {
                    model: root.placesModel
                    delegate: AbstractButton {
                    id: placeDelegate
                    required property string label; required property string iconName; required property string path
                    Layout.fillWidth: true; implicitHeight: 34 * Theme.scale; hoverEnabled: true; focusPolicy: Qt.StrongFocus
                    leftPadding: Theme.spaceM; rightPadding: Theme.spaceM
                    Accessible.name: label; Accessible.role: Accessible.ListItem
                    onClicked: root.navigate(path)
                    background: Rectangle { radius: Theme.radiusS; color: root.currentPath === path ? Theme.selectionFill : parent.hovered ? Theme.controlHover : "transparent" }
                    contentItem: RowLayout {
                        spacing: Theme.spaceM
                        LucideIcon { name: root.placeIconName(placeDelegate.iconName); iconColor: root.currentPath === path ? Theme.primary : Theme.textMuted }
                        Text { Layout.fillWidth: true; text: Format.safeText(label); textFormat: Text.PlainText; color: Theme.text; font.pixelSize: Theme.fontBody; elide: Text.ElideRight }
                    }
                }
                }
                DeviceList {
                    Layout.fillWidth: true
                    onActivateVolume: volume => root.activateVolume(volume)
                    onUnmountVolume: volume => root.unmountVolume(volume)
                    onSafeRemoveDrive: drive => root.safeRemoveDrive(drive)
                }
                Item { Layout.fillWidth: true; Layout.fillHeight: true; implicitHeight: Theme.spaceM }
            }
        }
    }
    Component { id: projectsPage; SidebarLocationList { collection: "projects"; currentPath: root.currentPath; locationsModel: root.projectsModel; onNavigate: path => root.navigate(path); onAddRequested: root.addCurrentDirectoryRequested("projects"); onRemoveRequested: id => root.removeLocationRequested("projects", id) } }
    Component { id: bookmarksPage; SidebarLocationList { collection: "bookmarks"; currentPath: root.currentPath; locationsModel: root.bookmarksModel; onNavigate: path => root.navigate(path); onAddRequested: root.addCurrentDirectoryRequested("bookmarks"); onRemoveRequested: id => root.removeLocationRequested("bookmarks", id) } }
}
