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
    readonly property int crumbHeight: 28 * Theme.scale
    readonly property int editReserve: Math.round(32 * Theme.scale)
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

    function revealCurrentCrumb() {
        if (root.editing)
            return;
        breadcrumbFlick.contentX = Math.max(0, breadcrumbRow.implicitWidth - breadcrumbFlick.width);
    }

    readonly property var crumbs: {
        const parts = path.split("/").filter(Boolean);
        if (parts.length === 0)
            return [{ label: "/", path: "/" }];
        const result = [];
        let current = "";
        for (const part of parts) {
            current += "/" + part;
            result.push({ label: part, path: current });
        }
        return result;
    }

    implicitHeight: 36 * Theme.scale

    onPathChanged: Qt.callLater(root.revealCurrentCrumb)

    Rectangle {
        anchors.fill: parent
        radius: Theme.radiusS
        color: Qt.alpha(Theme.surfaceVariant, 0.72)
        border.width: 1
        border.color: root.editing ? Theme.primary : Qt.alpha(Theme.outline, 0.72)

        Behavior on border.color { ColorAnimation { duration: Theme.animationFast } }
    }

    Flickable {
        id: breadcrumbFlick
        anchors.left: parent.left
        anchors.leftMargin: Theme.spaceXs
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: {
            const trailing = Math.min(root.editReserve, Math.max(Theme.spaceL, parent.width / 6));
            const available = Math.max(0, parent.width - Theme.spaceXs - trailing);
            return Math.min(breadcrumbRow.implicitWidth, available);
        }
        visible: !root.editing
        contentWidth: breadcrumbRow.implicitWidth
        contentHeight: height
        clip: true
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentWidth > width

        Row {
            id: breadcrumbRow
            height: parent.height
            spacing: 0

            Repeater {
                model: root.crumbs

                delegate: MouseArea {
                    id: crumbButton
                    required property int index
                    required property var modelData

                    readonly property bool isCurrent: index === root.crumbs.length - 1
                    readonly property bool isFirst: index === 0

                    anchors.verticalCenter: parent.verticalCenter
                    height: root.crumbHeight
                    width: crumbContent.implicitWidth + Theme.spaceS + (isCurrent ? Theme.spaceS : Theme.spaceXs)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    acceptedButtons: Qt.LeftButton
                    Accessible.name: modelData.label
                    Accessible.role: Accessible.Button
                    onClicked: root.navigate(modelData.path)

                    Rectangle {
                        anchors.fill: parent
                        radius: Theme.radiusS
                        color: crumbButton.pressed ? Qt.alpha(Theme.primary, 0.26)
                             : crumbButton.isCurrent ? Theme.selectionFill
                             : crumbButton.containsMouse ? Theme.controlHover
                             : "transparent"

                        Behavior on color { ColorAnimation { duration: Theme.animationFast } }
                    }

                    Row {
                        id: crumbContent
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spaceS
                        spacing: Theme.spaceXs

                        LucideIcon {
                            visible: crumbButton.isFirst
                            name: "folder"
                            iconSize: Theme.fontBody
                            iconColor: crumbButton.isCurrent || crumbButton.containsMouse ? Theme.primary : Theme.textMuted
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        Text {
                            text: Format.safeText(crumbButton.modelData.label)
                            textFormat: Text.PlainText
                            color: crumbButton.isCurrent ? Theme.text : Theme.textMuted
                            font.pixelSize: Theme.fontBody
                            font.weight: crumbButton.isCurrent ? Font.DemiBold : Font.Medium
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        LucideIcon {
                            visible: !crumbButton.isCurrent
                            name: "chevron-right"
                            iconSize: Theme.fontSmall
                            iconColor: Theme.textMuted
                            opacity: crumbButton.containsMouse ? 1 : 0.7
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    ToolTip.visible: containsMouse
                    ToolTip.text: Format.safeText(modelData.path)
                    ToolTip.delay: 450
                }
            }
        }
    }

    MouseArea {
        id: editArea
        anchors.left: breadcrumbFlick.right
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        visible: !root.editing
        hoverEnabled: true
        cursorShape: Qt.IBeamCursor
        acceptedButtons: Qt.LeftButton
        onClicked: root.beginEditing()
        Accessible.name: qsTr("Edit location")
        Accessible.role: Accessible.Button
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

    property Timer completionDelay: Timer {
        interval: 120
        onTriggered: root.refreshCompletions()
    }

    Connections {
        target: breadcrumbRow
        function onImplicitWidthChanged() { root.revealCurrentCrumb(); }
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
