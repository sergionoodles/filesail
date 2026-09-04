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
    signal navigate(string path)
    signal addCurrentDirectoryRequested(string collection)
    signal removeLocationRequested(string collection, string id)
    color: Qt.alpha(Theme.surfaceVariant, 0.58)

    ColumnLayout {
        anchors.fill: parent; anchors.margins: Theme.spaceM; spacing: Theme.spaceS
        RowLayout {
            Layout.fillWidth: true; Layout.bottomMargin: Theme.spaceM
            ButtonGroup { id: sectionGroup }
            SidebarTabButton { iconName: "folder"; tooltip: qsTr("Places"); checked: root.activeSection === "places"; ButtonGroup.group: sectionGroup; onClicked: root.activeSection = "places" }
            SidebarTabButton { iconName: "code"; tooltip: qsTr("Projects"); checked: root.activeSection === "projects"; ButtonGroup.group: sectionGroup; onClicked: root.activeSection = "projects" }
            SidebarTabButton { iconName: "star"; tooltip: qsTr("Bookmarks"); checked: root.activeSection === "bookmarks"; ButtonGroup.group: sectionGroup; onClicked: root.activeSection = "bookmarks" }
            SidebarTabButton { iconName: "house"; tooltip: qsTr("Home"); checkable: false; onClicked: root.navigate(root.homePath) }
        }
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
        OperationQueue {
            Layout.fillWidth: true
            onNavigate: path => root.navigate(path)
        }
    }

    Component {
        id: placesPage
        ColumnLayout {
            spacing: Theme.spaceXs
            Text { Layout.leftMargin: Theme.spaceS; Layout.bottomMargin: Theme.spaceXs; text: qsTr("PLACES"); color: Theme.textMuted; font.pixelSize: Theme.fontSmall - 1; font.weight: Font.DemiBold; font.letterSpacing: 1.2 }
            ListView {
                Layout.fillWidth: true; Layout.fillHeight: true
                clip: true; reuseItems: true; model: root.placesModel
                delegate: AbstractButton {
                    id: placeDelegate
                    required property string label; required property string iconName; required property string path
                    width: ListView.view.width; implicitHeight: 34 * Theme.scale; hoverEnabled: true; focusPolicy: Qt.StrongFocus
                    leftPadding: Theme.spaceM; rightPadding: Theme.spaceM
                    Accessible.name: label; Accessible.role: Accessible.ListItem
                    onClicked: root.navigate(path)
                    background: Rectangle { radius: Theme.radiusS; color: root.currentPath === path ? Theme.selectionFill : parent.hovered ? Theme.controlHover : "transparent" }
                    contentItem: RowLayout {
                        spacing: Theme.spaceM
                        LucideIcon { name: placeDelegate.iconName === "user-home" ? "house" : placeDelegate.iconName === "user-desktop" ? "monitor" : placeDelegate.iconName === "user-trash" ? "trash-2" : "folder"; iconColor: root.currentPath === path ? Theme.primary : Theme.textMuted }
                        Text { Layout.fillWidth: true; text: Format.safeText(label); textFormat: Text.PlainText; color: Theme.text; font.pixelSize: Theme.fontBody; elide: Text.ElideRight }
                    }
                }
            }
        }
    }
    Component { id: projectsPage; SidebarLocationList { collection: "projects"; currentPath: root.currentPath; locationsModel: root.projectsModel; onNavigate: path => root.navigate(path); onAddRequested: root.addCurrentDirectoryRequested("projects"); onRemoveRequested: id => root.removeLocationRequested("projects", id) } }
    Component { id: bookmarksPage; SidebarLocationList { collection: "bookmarks"; currentPath: root.currentPath; locationsModel: root.bookmarksModel; onNavigate: path => root.navigate(path); onAddRequested: root.addCurrentDirectoryRequested("bookmarks"); onRemoveRequested: id => root.removeLocationRequested("bookmarks", id) } }
}
