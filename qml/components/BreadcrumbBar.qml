import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import "../core"

Item {
    id: root

    property string path: "/"
    property bool editing: false
    property var completions: []
    property int completionRequest: -1
    signal navigate(string path)

    function beginEditing() {
        editing = true;
    }

    function complete(path) {
        addressInput.text = path;
        editing = false;
        navigate(path);
    }

    function refreshCompletions() {
        const value = addressInput.text.trim();
        if (!value.startsWith("/")) {
            completions = [];
            return;
        }

        const slash = value.lastIndexOf("/");
        const parentPath = slash <= 0 ? "/" : value.slice(0, slash);
        const prefix = value.slice(slash + 1);
        if (completionRequest >= 0)
            BackendClient.cancel(completionRequest);
        let requestId = -1;
        requestId = BackendClient.listDirectory({
            path: parentPath,
            showHidden: true,
            filter: prefix,
            sortBy: "name"
        }, result => {
            if (requestId !== completionRequest)
                return;
            completionRequest = -1;
            completions = (result.entries ?? []).filter(entry => entry.isDirectory).slice(0, 8);
        }, () => {
            if (requestId === completionRequest)
                completionRequest = -1;
            completions = [];
        });
        completionRequest = requestId;
    }

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
                        color: "transparent"

                        Text {
                            id: crumbText
                            anchors.centerIn: parent
                            text: Format.safeText(modelData.label)
                            textFormat: Text.PlainText
                            color: index === root.crumbs.length - 1 ? Theme.text : Theme.textMuted
                            font.pixelSize: Theme.fontBody
                            font.weight: index === root.crumbs.length - 1 ? Font.DemiBold : Font.Normal
                            elide: Text.ElideMiddle
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

        onAccepted: root.complete(text)
        onTextEdited: completionDelay.restart()
        onVisibleChanged: if (visible) {
            text = root.path;
            forceActiveFocus();
            selectAll();
            completionDelay.restart();
        }
        Keys.onEscapePressed: {
            root.editing = false;
            root.completions = [];
        }
    }

    MouseArea {
        anchors.fill: parent
        visible: !root.editing
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        cursorShape: Qt.IBeamCursor
        onClicked: root.beginEditing()
    }

    property Timer completionDelay: Timer {
        interval: 120
        onTriggered: root.refreshCompletions()
    }

    Popup {
        id: completionPopup
        x: 0
        y: root.height + Theme.spaceXs
        width: root.width
        padding: Theme.spaceXs
        visible: root.editing && root.completions.length > 0
        closePolicy: Popup.NoAutoClose
        background: Rectangle {
            radius: Theme.radiusS
            color: Theme.surface
            border.color: Theme.divider
            border.width: 1
        }
        contentItem: Column {
            spacing: 1
            Repeater {
                model: root.completions
                delegate: AbstractButton {
                    required property var modelData
                    width: completionPopup.availableWidth
                    height: 32 * Theme.scale
                    hoverEnabled: true
                    onClicked: root.complete(modelData.path)
                    background: Rectangle {
                        radius: Theme.radiusS
                        color: parent.hovered ? Theme.controlHover : "transparent"
                    }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Theme.spaceM
                        anchors.rightMargin: Theme.spaceM
                        spacing: Theme.spaceS
                        LucideIcon {
                            Layout.preferredWidth: Theme.fontBody
                            Layout.preferredHeight: Layout.preferredWidth
                            Layout.alignment: Qt.AlignVCenter
                            name: "folder"
                            iconSize: Layout.preferredWidth
                        }
                        Text {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignVCenter
                            text: Format.safeText(modelData.path)
                            textFormat: Text.PlainText
                            color: Theme.text
                            font.pixelSize: Theme.fontBody
                            elide: Text.ElideMiddle
                        }
                    }
                }
            }
        }
    }
}
