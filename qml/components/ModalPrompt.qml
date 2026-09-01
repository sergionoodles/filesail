import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Item {
    id: root

    property string title: ""
    property string message: ""
    property string value: ""
    property string placeholder: ""
    property string acceptLabel: "Continue"
    property bool destructive: false
    property bool inputVisible: true
    signal accepted(string value)
    signal rejected

    visible: false
    z: 1000

    function open(initialValue) {
        value = initialValue ?? "";
        visible = true;
        if (inputVisible)
            promptInput.forceActiveFocus();
    }

    function close() {
        visible = false;
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha("#000000", 0.54)
        MouseArea { anchors.fill: parent; onClicked: { root.close(); root.rejected(); } }
    }

    Rectangle {
        width: Math.min(parent.width - Theme.spaceXl * 2, 420 * Theme.scale)
        implicitHeight: promptLayout.implicitHeight + Theme.spaceXl * 2
        anchors.centerIn: parent
        radius: Theme.radiusL
        color: Theme.surfaceVariant
        border.width: 1
        border.color: Qt.alpha(Theme.outline, 0.9)

        ColumnLayout {
            id: promptLayout
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Theme.spaceXl
            spacing: Theme.spaceM

            Text {
                Layout.fillWidth: true
                text: root.title
                color: Theme.text
                font.pixelSize: Theme.fontTitle
                font.weight: Font.DemiBold
            }
            Text {
                Layout.fillWidth: true
                visible: root.message.length > 0
                text: root.message
                color: Theme.textMuted
                font.pixelSize: Theme.fontBody
                wrapMode: Text.Wrap
            }
            TextField {
                id: promptInput
                Layout.fillWidth: true
                visible: root.inputVisible
                text: root.value
                placeholderText: root.placeholder
                color: Theme.text
                placeholderTextColor: Theme.textMuted
                selectByMouse: true
                leftPadding: Theme.spaceM
                rightPadding: Theme.spaceM
                background: Rectangle {
                    implicitHeight: 38 * Theme.scale
                    radius: Theme.radiusS
                    color: Theme.surface
                    border.width: 1
                    border.color: promptInput.activeFocus ? Theme.primary : Theme.outline
                }
                onTextChanged: root.value = text
                onAccepted: acceptButton.clicked()
            }
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: Theme.spaceS
                Button {
                    text: "Cancel"
                    onClicked: { root.close(); root.rejected(); }
                }
                Button {
                    id: acceptButton
                    text: root.acceptLabel
                    enabled: !root.inputVisible || root.value.trim().length > 0
                    onClicked: {
                        const acceptedValue = root.value;
                        root.close();
                        root.accepted(acceptedValue);
                    }
                    background: Rectangle {
                        radius: Theme.radiusS
                        color: root.destructive ? Theme.error : Theme.primary
                        opacity: acceptButton.enabled ? 1 : 0.35
                    }
                    contentItem: Text {
                        text: acceptButton.text
                        color: Theme.primaryText
                        font.pixelSize: Theme.fontBody
                        font.weight: Font.DemiBold
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                }
            }
        }
    }
}
