import QtQuick
import QtQuick.Layouts
import "../core"

FocusScope {
    id: root

    property alias headerContent: headerSection.data
    property alias bodyContent: bodySection.data
    property alias footerContent: footerSection.data
    property bool footerVisible: false
    property bool bodyFillsHeight: false

    implicitHeight: sections.implicitHeight
    activeFocusOnTab: true

    Rectangle {
        anchors.fill: parent
        color: Theme.surface
        border.width: 1
        border.color: Theme.divider

        // Prevent clicks inside the modal from reaching a dismissing backdrop.
        MouseArea { anchors.fill: parent }

        ColumnLayout {
            id: sections
            anchors.fill: parent
            spacing: 0

            ColumnLayout {
                id: headerSection
                Layout.fillWidth: true
                Layout.leftMargin: Theme.spaceXl
                Layout.rightMargin: Theme.spaceXl
                Layout.topMargin: Theme.spaceXl
                Layout.bottomMargin: Theme.spaceXl
                spacing: 0
            }

            Rectangle {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Theme.divider
            }

            ColumnLayout {
                id: bodySection
                Layout.fillWidth: true
                Layout.fillHeight: root.bodyFillsHeight
                Layout.leftMargin: Theme.spaceXl
                Layout.rightMargin: Theme.spaceXl
                Layout.topMargin: Theme.spaceXl
                Layout.bottomMargin: Theme.spaceXl
                spacing: 0
            }

            Rectangle {
                Layout.fillWidth: true
                visible: root.footerVisible
                implicitHeight: visible ? 1 : 0
                color: Theme.subtleDivider
            }

            ColumnLayout {
                id: footerSection
                Layout.fillWidth: true
                visible: root.footerVisible
                Layout.leftMargin: Theme.spaceXl
                Layout.rightMargin: Theme.spaceXl
                Layout.topMargin: Theme.spaceM
                Layout.bottomMargin: Theme.spaceM
                spacing: 0
            }
        }
    }
}
