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
    property bool secretInput: false
    property var payload: ({})
    property Item returnFocus: null
    signal accepted(string value)
    signal rejected

    visible: false
    z: 1000
    Accessible.role: Accessible.Dialog
    Accessible.name: Format.safeText(root.title)

    function open(initialValue, payloadSnapshot, focusToRestore) {
        value = initialValue ?? "";
        payload = Object.assign({}, payloadSnapshot ?? {});
        returnFocus = focusToRestore ?? null;
        visible = true;
        if (inputVisible)
            promptInput.forceActiveFocus();
        else
            acceptButton.forceActiveFocus();
    }

    function close() {
        visible = false;
        if (secretInput) {
            value = "";
            promptInput.clear();
        }
        if (returnFocus)
            returnFocus.forceActiveFocus();
    }

    Rectangle {
        anchors.fill: parent
        color: Qt.alpha("#000000", 0.54)
        MouseArea { anchors.fill: parent } // Deliberately consumes background clicks.
    }

    ModalScaffold {
        id: dialogSurface
        width: Math.min(parent.width - Theme.spaceXl * 2, 420 * Theme.scale)
        height: implicitHeight
        anchors.centerIn: parent
        focus: root.visible
        Keys.onEscapePressed: { root.close(); root.rejected(); event.accepted = true; }
        footerVisible: true

        headerContent: ModalHeader {
            Layout.fillWidth: true
            title: root.title
        }

        bodyContent: ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.spaceM

            Text {
                Layout.fillWidth: true
                visible: root.message.length > 0
                text: Format.safeText(root.message)
                textFormat: Text.PlainText
                color: Theme.textMuted
                font.pixelSize: Theme.fontBody
                wrapMode: Text.Wrap
            }
            ThemedTextField {
                id: promptInput
                Layout.fillWidth: true
                visible: root.inputVisible
                text: root.value
                placeholderText: root.placeholder
                echoMode: root.secretInput ? TextInput.Password : TextInput.Normal
                inputMethodHints: root.secretInput ? Qt.ImhHiddenText | Qt.ImhNoPredictiveText : Qt.ImhNone
                onTextChanged: root.value = text
                onAccepted: acceptButton.clicked()
            }
        }

        footerContent: ModalFooter {
            Layout.fillWidth: true

            ModalButton {
                id: cancelButton
                text: qsTr("Cancel")
                Accessible.name: qsTr("Cancel")
                onClicked: { root.close(); root.rejected(); }
            }
            ModalButton {
                id: acceptButton
                text: root.acceptLabel
                primary: true
                destructive: root.destructive
                enabled: !root.inputVisible || root.value.trim().length > 0
                Accessible.name: root.acceptLabel
                onClicked: {
                    const acceptedValue = root.value;
                    root.close();
                    root.accepted(acceptedValue);
                }
            }
        }
    }
}
