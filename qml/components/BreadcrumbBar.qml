import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import "../core"

Item {
    id: root

    property string path: "/"
    property bool editing: false
    signal navigate(string path)

    readonly property var crumbs: {
        const parts = path.split('/').filter(Boolean);
        const result = [{ label: "Computer", path: "/" }];
        let current = "";
        for (const part of parts) {
            current += "/" + part;
            result.push({ label: part, path: current });
        }
        return result;
    }

    implicitHeight: 36 * Theme.scale

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusS
        color: Qt.alpha(Theme.surfaceVariant, 0.72)
        border.width: 1
        border.color: Qt.alpha(Theme.outline, 0.72)
    }

    Flickable {
        id: breadcrumbFlick
        anchors.fill: parent
        anchors.leftMargin: Theme.spaceS
        anchors.rightMargin: Theme.spaceS
        visible: !root.editing
        contentWidth: breadcrumbRow.implicitWidth
        contentHeight: height
        clip: true

        Row {
            id: breadcrumbRow
            height: parent.height
            spacing: 1

            Repeater {
                model: root.crumbs

                delegate: Row {
                    required property int index
                    required property var modelData
                    height: breadcrumbRow.height

                    Text {
                        visible: index > 0
                        text: "›"
                        color: Theme.textMuted
                        anchors.verticalCenter: parent.verticalCenter
                        font.pixelSize: Theme.fontBody
                    }

                    Rectangle {
                        width: crumbText.implicitWidth + Theme.spaceM * 2
                        height: 28 * Theme.scale
                        anchors.verticalCenter: parent.verticalCenter
                        radius: Theme.radiusS
                        color: crumbMouse.containsMouse ? Qt.alpha(Theme.text, 0.08) : "transparent"

                        Text {
                            id: crumbText
                            anchors.centerIn: parent
                            text: modelData.label
                            color: index === root.crumbs.length - 1 ? Theme.text : Theme.textMuted
                            font.pixelSize: Theme.fontBody
                            font.weight: index === root.crumbs.length - 1 ? Font.DemiBold : Font.Normal
                            elide: Text.ElideMiddle
                        }

                        MouseArea {
                            id: crumbMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.navigate(modelData.path)
                        }
                    }
                }
            }
        }
    }

    ThemedTextField {
        id: addressInput
        anchors.fill: parent
        visible: root.editing
        text: root.path
        background: Item {}

        onAccepted: {
            root.editing = false;
            root.navigate(text);
        }
        onVisibleChanged: if (visible) {
            text = root.path;
            forceActiveFocus();
            selectAll();
        }
        Keys.onEscapePressed: root.editing = false
    }

    MouseArea {
        anchors.fill: parent
        visible: !root.editing
        acceptedButtons: Qt.MiddleButton
        onClicked: root.editing = true
    }
}
