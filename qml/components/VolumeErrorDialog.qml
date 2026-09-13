import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Item {
    id: root

    property var error: ({})
    property var retryCallback: null
    property Item returnFocus: null
    visible: false
    z: 1000
    Accessible.role: Accessible.Dialog
    Accessible.name: qsTr("Drive operation failed")

    function open(nextError, retry, focusTarget) {
        error = nextError ?? {};
        retryCallback = retry ?? null;
        returnFocus = focusTarget ?? null;
        detailsToggle.checked = false;
        visible = true;
        cancelButton.forceActiveFocus();
    }

    function close() {
        visible = false;
        if (returnFocus) returnFocus.forceActiveFocus();
    }

    readonly property string detailText: {
        const details = error.details ?? {};
        const lines = [];
        if (details.systemMessage) lines.push(String(details.systemMessage));
        if (details.remoteError) lines.push(String(details.remoteError));
        if (Array.isArray(details.completedVolumeIds) && details.completedVolumeIds.length > 0)
            lines.push(qsTr("Volumes already unmounted: %1").arg(details.completedVolumeIds.length));
        return lines.join("\n");
    }

    Rectangle { anchors.fill: parent; color: Qt.alpha("#000000", 0.54); MouseArea { anchors.fill: parent } }

    ModalScaffold {
        width: Math.min(parent.width - Theme.spaceXl * 2, 480 * Theme.scale)
        height: implicitHeight
        anchors.centerIn: parent
        focus: root.visible
        footerVisible: true
        Keys.onEscapePressed: { root.close(); event.accepted = true; }

        headerContent: ModalHeader { Layout.fillWidth: true; title: qsTr("Drive operation failed") }
        bodyContent: ColumnLayout {
            Layout.fillWidth: true
            spacing: Theme.spaceM
            Text {
                Layout.fillWidth: true
                text: Format.safeText(root.error.error ?? qsTr("The drive operation failed"))
                textFormat: Text.PlainText
                color: Theme.text
                font.pixelSize: Theme.fontBody
                wrapMode: Text.Wrap
            }
            CheckBox {
                id: detailsToggle
                visible: root.detailText.length > 0
                text: qsTr("Details")
                font.pixelSize: Theme.fontBody
            }
            TextArea {
                Layout.fillWidth: true
                visible: detailsToggle.visible && detailsToggle.checked
                text: Format.safeText(root.detailText)
                textFormat: Text.PlainText
                readOnly: true
                wrapMode: TextEdit.Wrap
                color: Theme.textMuted
                font.pixelSize: Theme.fontSmall
                background: Rectangle { color: Theme.surfaceVariant; border.width: 1; border.color: Theme.divider; radius: Theme.radiusS }
            }
        }
        footerContent: ModalFooter {
            Layout.fillWidth: true
            ModalButton { id: cancelButton; text: qsTr("Cancel"); onClicked: root.close() }
            ModalButton {
                visible: root.retryCallback !== null
                text: qsTr("Retry")
                primary: true
                onClicked: { const retry = root.retryCallback; root.close(); if (retry) retry(); }
            }
        }
    }
}
