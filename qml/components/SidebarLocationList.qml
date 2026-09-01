import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

ColumnLayout {
    id: root

    required property string collection
    required property string currentPath
    required property var locationsModel
    signal navigate(string path)
    signal addRequested()
    signal removeRequested(string id)
    spacing: Theme.spaceS

    readonly property bool projects: collection === "projects"
    readonly property string title: projects ? qsTr("PROJECTS") : qsTr("BOOKMARKS")
    readonly property string emptyTitle: projects ? qsTr("No projects yet") : qsTr("No bookmarks yet")
    readonly property string emptyHint: projects ? qsTr("Add the current folder to use it as a project.") : qsTr("Add the current folder for quick access.")

    RowLayout {
        Layout.fillWidth: true
        Text { Layout.fillWidth: true; text: root.title; color: Theme.textMuted; font.pixelSize: Theme.fontSmall - 1; font.weight: Font.DemiBold; font.letterSpacing: 1.2 }
        IconButton { iconName: "folder-plus"; tooltip: qsTr("Add current folder"); onClicked: root.addRequested() }
    }
    ColumnLayout {
        Layout.fillWidth: true
        visible: root.locationsModel.count === 0
        spacing: Theme.spaceS
        Text { Layout.fillWidth: true; text: root.emptyTitle; color: Theme.text; font.pixelSize: Theme.fontBody; font.weight: Font.DemiBold; wrapMode: Text.WordWrap }
        Text { Layout.fillWidth: true; text: root.emptyHint; color: Theme.textMuted; font.pixelSize: Theme.fontSmall; wrapMode: Text.WordWrap }
        AbstractButton {
            text: qsTr("Add current folder")
            Layout.alignment: Qt.AlignHCenter
            Layout.leftMargin: Theme.spaceS
            Layout.rightMargin: Theme.spaceS
            hoverEnabled: true
            implicitHeight: Theme.buttonHeight
            leftPadding: Theme.buttonPaddingHorizontal
            rightPadding: Theme.buttonPaddingHorizontal
            topPadding: Theme.buttonPaddingVertical
            bottomPadding: Theme.buttonPaddingVertical
            focusPolicy: Qt.StrongFocus
            Accessible.name: text
            onClicked: root.addRequested()
            background: Rectangle {
                radius: Theme.radiusS
                color: parent.hovered ? Theme.controlHover : Theme.surfaceVariant
                border.width: parent.visualFocus ? 1 : 0
                border.color: Theme.primary
            }
            contentItem: Text {
                text: parent.text
                color: Theme.text
                font.pixelSize: Theme.fontBody
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
    Repeater {
        model: root.locationsModel
        delegate: RowLayout {
            required property string id
            required property string label
            required property string path
            required property bool available
            Layout.fillWidth: true
            spacing: Theme.spaceXs
            AbstractButton {
                id: location
                Layout.fillWidth: true
                implicitHeight: 34 * Theme.scale
                leftPadding: Theme.spaceM
                rightPadding: Theme.spaceM
                enabled: available
                hoverEnabled: true
                focusPolicy: Qt.StrongFocus
                Accessible.name: label
                Accessible.role: Accessible.ListItem
                onClicked: root.navigate(path)
                background: Rectangle { radius: Theme.radiusS; color: root.currentPath === path ? Theme.selectionFill : location.hovered ? Theme.controlHover : "transparent" }
                contentItem: RowLayout {
                    spacing: Theme.spaceS
                    LucideIcon { name: "folder"; iconColor: available ? (root.currentPath === path ? Theme.primary : Theme.textMuted) : Theme.error }
                    Text { Layout.fillWidth: true; text: Format.safeText(label); textFormat: Text.PlainText; color: Theme.text; font.pixelSize: Theme.fontBody; elide: Text.ElideRight }
                }
                ToolTip.visible: hovered && !available
                ToolTip.text: qsTr("Folder is unavailable")
            }
            IconButton { iconName: "trash-2"; tooltip: qsTr("Remove"); onClicked: root.removeRequested(id) }
        }
    }
    Item { Layout.fillHeight: true }
}
