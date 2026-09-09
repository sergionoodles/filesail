pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

ColumnLayout {
    id: root

    readonly property var operations: BackendClient.operations
    readonly property int operationCount: operations.length
    readonly property int pendingCount: operations.filter(operation => operation.state === "queued").length
    readonly property var currentOperation: {
        for (const operation of operations) {
            if (operation.state === "running")
                return operation;
        }
        return operations[0] ?? null;
    }
    readonly property var pendingOperations: operations.filter(operation => operation.id !== currentOperation?.id)
    property bool expanded: false
    property bool activityWasVisible: false

    signal navigate(string path)

    visible: operationCount > 0
    enabled: visible
    spacing: 0
    implicitHeight: visible ? header.implicitHeight + (expanded ? details.implicitHeight : 0) : 0
    Layout.preferredHeight: implicitHeight

    function operationLabel(method, gerund) {
        const labels = {
            "copy": gerund ? qsTr("Copying") : qsTr("Copy"),
            "move": gerund ? qsTr("Moving") : qsTr("Move"),
            "trash": gerund ? qsTr("Removing") : qsTr("Remove"),
            "mkdir": gerund ? qsTr("Creating folder") : qsTr("Create folder"),
            "rename": gerund ? qsTr("Renaming") : qsTr("Rename"),
            "setExecutable": gerund ? qsTr("Updating permissions") : qsTr("Update permissions"),
            "locations.add": gerund ? qsTr("Saving location") : qsTr("Save location"),
            "locations.remove": gerund ? qsTr("Removing location") : qsTr("Remove location")
        };
        return labels[method] ?? Format.safeText(method);
    }

    function fileName(path) {
        const parts = String(path ?? "").split("/").filter(Boolean);
        return Format.safeText(parts.length > 0 ? parts[parts.length - 1] : "/");
    }

    function operationSubject(operation) {
        if (!operation)
            return "";
        const paths = Array.isArray(operation.paths) ? operation.paths : [];
        if (paths.length === 1)
            return fileName(paths[0]);
        if (paths.length > 1)
            return qsTr("%1 items").arg(paths.length);
        return operation.targetDirectory ? fileName(operation.targetDirectory) : qsTr("Working");
    }

    function operationNavigationPath(operation) {
        if (!operation)
            return "";
        if ((operation.method === "copy" || operation.method === "move")
                && typeof operation.targetDirectory === "string")
            return operation.targetDirectory;
        if (Array.isArray(operation.paths) && operation.paths.length > 0)
            return parentPath(operation.paths[0]);
        if (typeof operation.path === "string")
            return parentPath(operation.path);
        if (typeof operation.parent === "string")
            return operation.parent;
        return "";
    }

    function parentPath(path) {
        const value = String(path ?? "");
        const separator = value.lastIndexOf("/");
        return separator <= 0 ? "/" : value.slice(0, separator);
    }

    function compactSummary() {
        return qsTr("%1 / %2").arg(pendingCount).arg(operationCount);
    }

    function syncExpansion() {
        if (operationCount === 0) {
            expanded = false;
            activityWasVisible = false;
        } else if (!activityWasVisible) {
            expanded = true;
            activityWasVisible = true;
        }
    }

    onOperationCountChanged: syncExpansion()
    Component.onCompleted: {
        BackendClient.refreshOperations();
        syncExpansion();
    }

    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 1
        color: Qt.alpha(Theme.outline, 0.55)
    }

    AbstractButton {
        id: header
        Layout.fillWidth: true
        implicitHeight: 34 * Theme.scale
        leftPadding: Theme.spaceS
        rightPadding: Theme.spaceXs
        hoverEnabled: true
        focusPolicy: Qt.StrongFocus
        Accessible.role: Accessible.Button
        Accessible.name: root.expanded ? qsTr("Collapse file activity") : qsTr("Expand file activity")
        onClicked: root.expanded = !root.expanded
        background: Rectangle {
            radius: Theme.radiusS
            color: header.hovered ? Theme.controlHover : "transparent"
        }
        contentItem: RowLayout {
            spacing: Theme.spaceS

            LucideIcon {
                name: "loader"
                iconSize: Theme.fontBody
                iconColor: root.operationCount > 0 ? Theme.primary : Theme.textMuted
            }
            Text {
                text: qsTr("ACTIVITY")
                color: Theme.textMuted
                font.pixelSize: Theme.fontSmall - 1
                font.weight: Font.DemiBold
                font.letterSpacing: 1.1
            }
            Text {
                Layout.fillWidth: true
                text: root.compactSummary()
                color: Theme.textMuted
                font.pixelSize: Theme.fontSmall
                elide: Text.ElideRight
                horizontalAlignment: Text.AlignRight
            }
            LucideIcon {
                name: root.expanded ? "chevron-down" : "chevron-up"
                iconSize: Theme.fontSmall
                iconColor: header.hovered ? Theme.text : Theme.textMuted
            }
        }
        ToolTip.visible: hovered
        ToolTip.text: Accessible.name
        ToolTip.delay: 500
    }

    ColumnLayout {
        id: details
        Layout.fillWidth: true
        visible: root.expanded
        spacing: Theme.spaceXs

        AbstractButton {
            id: currentActivity
            Layout.fillWidth: true
            implicitHeight: 58 * Theme.scale
            enabled: root.operationNavigationPath(root.currentOperation).length > 0
            leftPadding: Theme.spaceS
            rightPadding: Theme.spaceS
            topPadding: Theme.spaceS
            bottomPadding: Theme.spaceS
            hoverEnabled: true
            focusPolicy: Qt.StrongFocus
            Accessible.role: Accessible.ListItem
            Accessible.name: root.currentOperation
                ? root.operationLabel(root.currentOperation.method, true) + " " + root.operationSubject(root.currentOperation)
                : qsTr("Current file activity")
            onClicked: root.navigate(root.operationNavigationPath(root.currentOperation))
            background: Rectangle {
                radius: Theme.radiusS
                color: currentActivity.hovered ? Qt.alpha(Theme.primary, 0.16) : Qt.alpha(Theme.primary, 0.09)
                border.width: currentActivity.visualFocus ? 1 : 0
                border.color: Theme.primary
            }

            RowLayout {
                id: currentRow
                spacing: Theme.spaceS

                Rectangle {
                    Layout.fillHeight: true
                    Layout.preferredWidth: 2 * Theme.scale
                    color: Theme.primary
                }
                LucideIcon {
                    name: root.currentOperation ? (root.currentOperation.method === "trash" ? "trash-2"
                        : root.currentOperation.method === "move" ? "move" : root.currentOperation.method === "copy" ? "copy" : "loader") : "loader"
                    iconSize: Theme.fontBody
                    iconColor: Theme.primary
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 1
                    Text {
                        Layout.fillWidth: true
                        text: root.currentOperation ? root.operationLabel(root.currentOperation.method, true) : qsTr("Working")
                        color: Theme.text
                        font.pixelSize: Theme.fontSmall
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    Text {
                        Layout.fillWidth: true
                        text: root.operationSubject(root.currentOperation)
                        color: Theme.textMuted
                        font.pixelSize: Theme.fontSmall - 1
                        elide: Text.ElideRight
                    }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: root.pendingCount > 0
            spacing: 1

            Text {
                Layout.leftMargin: Theme.spaceS
                text: qsTr("UP NEXT")
                color: Theme.textMuted
                font.pixelSize: Theme.fontSmall - 2
                font.weight: Font.DemiBold
                font.letterSpacing: 1
            }
            ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(contentHeight, 4 * 28 * Theme.scale)
                clip: true
                interactive: contentHeight > height
                model: root.pendingOperations
                delegate: AbstractButton {
                    id: pendingDelegate
                    required property var modelData
                    width: ListView.view.width
                    implicitHeight: 28 * Theme.scale
                    enabled: root.operationNavigationPath(modelData).length > 0
                    leftPadding: Theme.spaceS
                    rightPadding: Theme.spaceS
                    hoverEnabled: true
                    focusPolicy: Qt.StrongFocus
                    Accessible.role: Accessible.ListItem
                    Accessible.name: root.operationLabel(modelData.method, false) + " " + root.operationSubject(modelData)
                    onClicked: root.navigate(root.operationNavigationPath(modelData))
                    background: Rectangle {
                        radius: Theme.radiusS
                        color: pendingDelegate.hovered ? Theme.controlHover : "transparent"
                    }
                    contentItem: RowLayout {
                        spacing: Theme.spaceS

                        LucideIcon {
                            name: "clock"
                            iconSize: Theme.fontSmall
                            iconColor: Theme.textMuted
                        }
                        Text {
                            Layout.fillWidth: true
                            text: root.operationLabel(pendingDelegate.modelData.method, false) + " · " + root.operationSubject(pendingDelegate.modelData)
                            color: Theme.textMuted
                            font.pixelSize: Theme.fontSmall - 1
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }
    }
}
