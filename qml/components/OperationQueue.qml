pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

ColumnLayout {
    id: root

    readonly property var operations: BackendClient.operations
    readonly property int operationCount: operations.length
    readonly property int recoveryCount: BackendClient.recoveryRecords.length
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

    visible: operationCount > 0 || recoveryCount > 0
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
            return qsTr("%1 and %2 more").arg(fileName(paths[0])).arg(paths.length - 1);
        if (typeof operation.path === "string" && operation.path.length > 0)
            return fileName(operation.path);
        if (typeof operation.name === "string" && operation.name.length > 0)
            return Format.safeText(operation.name);
        return operation.targetDirectory ? fileName(operation.targetDirectory) : qsTr("Working");
    }

    function operationDetail(operation) {
        const subject = operationSubject(operation);
        const currentPath = String(operation?.progress?.currentPath ?? "");
        const current = currentPath ? fileName(currentPath) : "";
        return current && current !== subject ? subject + " · " + current : subject;
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
        if (operationCount === 0)
            return qsTr("%1 needs attention").arg(recoveryCount);
        const running = operations.filter(operation => operation.state === "running").length;
        return qsTr("%1 running · %2 queued").arg(running).arg(pendingCount);
    }

    function cancelState(operation) {
        return operation ? BackendClient.operationCancelState(operation.id) : "";
    }

    function statusText(operation) {
        if (!operation) return qsTr("Working");
        const localState = cancelState(operation);
        if (localState === "requesting") return qsTr("Requesting cancellation…");
        if (operation.cancellationRequested || localState === "cancelling") {
            const phase = String(operation.progress?.phase ?? "");
            if (phase === "restoringSource") return qsTr("Restoring source…");
            if (phase === "cleaningUp") return qsTr("Cleaning up…");
            return qsTr("Cancelling…");
        }
        if (operation.state === "queued") return qsTr("Waiting");
        const phase = String(operation.progress?.phase ?? "");
        if (phase === "scanning") return qsTr("Scanning…");
        if (phase === "preparing") return qsTr("Preparing…");
        if (phase === "committing") return qsTr("Finishing current item…");
        if (phase === "cleaningUp") return qsTr("Cleaning up…");
        if (phase === "restoringSource") return qsTr("Restoring source…");
        return operationLabel(operation.method, true);
    }

    function safeCount(value) {
        const number = Number(value);
        return Number.isFinite(number) && number >= 0 ? Math.floor(number) : 0;
    }

    function progressText(operation) {
        const progress = operation?.progress ?? {};
        const entries = safeCount(progress.entriesDone);
        const entriesTotal = safeCount(progress.entriesTotal);
        const bytes = Number(progress.bytesDone);
        const bytesTotal = Number(progress.bytesTotal);
        if (String(progress.phase ?? "") === "scanning") {
            let scanningText = entriesTotal > 0 ? qsTr("%1 entries found").arg(entriesTotal) : qsTr("Discovering contents");
            if (Number.isFinite(bytesTotal) && bytesTotal > 0 && bytesTotal <= Number.MAX_SAFE_INTEGER)
                scanningText += " · " + Format.size(bytesTotal, false);
            return scanningText;
        }
        let text = entriesTotal > 0 ? qsTr("%1 of %2 entries").arg(entries).arg(entriesTotal) : "";
        if (Number.isFinite(bytes) && Number.isFinite(bytesTotal) && bytesTotal > 0
                && bytes >= 0 && bytes <= Number.MAX_SAFE_INTEGER && bytesTotal <= Number.MAX_SAFE_INTEGER)
            text += (text ? " · " : "") + qsTr("%1 of %2").arg(Format.size(bytes, false)).arg(Format.size(bytesTotal, false));
        return text;
    }

    function overallRatio(operation) {
        const progress = operation?.progress ?? {};
        if (!progress.overallProgressActive) return 0;
        const byteTotal = Number(progress.bytesTotal);
        const useBytes = Number.isFinite(byteTotal) && byteTotal > 0;
        const done = Number(useBytes ? progress.bytesDone : progress.entriesDone);
        const total = Number(useBytes ? progress.bytesTotal : progress.entriesTotal);
        if (!Number.isFinite(done) || !Number.isFinite(total) || total <= 0) return 0;
        let ratio = Math.max(0, Math.min(1, done / total));
        const selectedDone = safeCount(progress.topLevelDone);
        const selectedTotal = safeCount(progress.topLevelTotal);
        if (ratio >= 1 && selectedTotal > 0 && selectedDone < selectedTotal)
            ratio = 0.99;
        return ratio;
    }

    function requestCancel(operation) {
        if (!operation || !operation.canCancel || cancelState(operation)) return;
        BackendClient.cancelOperation(operation.id, BackendClient.operationsBackendInstance,
            null, message => console.warn("Could not cancel operation: " + message));
    }

    function syncExpansion() {
        if (operationCount === 0 && recoveryCount === 0) {
            expanded = false;
            activityWasVisible = false;
        } else if (!activityWasVisible) {
            expanded = true;
            activityWasVisible = true;
        }
    }

    onOperationCountChanged: syncExpansion()
    onRecoveryCountChanged: syncExpansion()
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

        Rectangle {
            id: currentActivity
            visible: root.currentOperation !== null
            Layout.fillWidth: true
            implicitHeight: currentContent.implicitHeight + Theme.spaceS * 2
            radius: Theme.radiusS
            color: Qt.alpha(Theme.primary, 0.09)

            ColumnLayout {
                id: currentContent
                anchors.fill: parent
                anchors.margins: Theme.spaceS
                spacing: Theme.spaceXs

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spaceS

                    AbstractButton {
                        id: currentNavigation
                        Layout.fillWidth: true
                        implicitHeight: 34 * Theme.scale
                        enabled: root.operationNavigationPath(root.currentOperation).length > 0
                        hoverEnabled: true
                        focusPolicy: Qt.StrongFocus
                        Accessible.role: Accessible.ListItem
                        Accessible.name: root.currentOperation
                            ? root.statusText(root.currentOperation) + " " + root.operationSubject(root.currentOperation)
                            : qsTr("Current file activity")
                        onClicked: root.navigate(root.operationNavigationPath(root.currentOperation))
                        background: Rectangle { color: currentNavigation.hovered ? Qt.alpha(Theme.primary, 0.12) : "transparent"; radius: Theme.radiusS }
                        contentItem: RowLayout {
                            spacing: Theme.spaceS
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                Text { Layout.fillWidth: true; text: root.statusText(root.currentOperation); color: Theme.text; font.pixelSize: Theme.fontSmall; font.weight: Font.DemiBold; elide: Text.ElideRight }
                                Text { Layout.fillWidth: true; text: root.operationDetail(root.currentOperation); color: Theme.textMuted; font.pixelSize: Theme.fontSmall - 1; elide: Text.ElideRight }
                            }
                        }
                        ToolTip.visible: hovered
                        ToolTip.text: root.currentOperation ? Format.safeText(root.currentOperation.progress?.currentPath ?? root.operationNavigationPath(root.currentOperation)) : ""
                        ToolTip.delay: 500
                    }
                    IconButton {
                        Layout.preferredWidth: 28 * Theme.scale
                        Layout.preferredHeight: 28 * Theme.scale
                        checkable: false
                        iconName: "octagon-x"
                        iconSize: Theme.fontBody
                        tooltip: qsTr("Stop remaining work; items already completed are kept")
                        visible: !!root.currentOperation?.canCancel || root.cancelState(root.currentOperation).length > 0
                        enabled: !!root.currentOperation?.canCancel && root.cancelState(root.currentOperation).length === 0
                        Accessible.name: qsTr("Cancel %1 %2").arg(root.operationLabel(root.currentOperation?.method, false)).arg(root.operationSubject(root.currentOperation))
                        onClicked: root.requestCancel(root.currentOperation)
                    }
                }

                ProgressBar {
                    Layout.fillWidth: true
                    Layout.minimumHeight: 4 * Theme.scale
                    Layout.preferredHeight: 4 * Theme.scale
                    Layout.maximumHeight: 4 * Theme.scale
                    implicitHeight: 4 * Theme.scale
                    visible: root.currentOperation?.state === "running"
                    indeterminate: root.currentOperation?.progress?.phase === "scanning"
                        || !root.currentOperation?.progress?.overallProgressActive
                    from: 0; to: 1; value: root.overallRatio(root.currentOperation)
                    Accessible.name: indeterminate ? qsTr("Operation in progress") : qsTr("Overall operation progress")
                    Accessible.description: indeterminate ? root.statusText(root.currentOperation) : Math.round(value * 100) + "%"
                }
                Text {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: root.progressText(root.currentOperation)
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontSmall - 1
                    elide: Text.ElideRight
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
                delegate: RowLayout {
                    id: pendingDelegate
                    required property var modelData
                    width: ListView.view.width
                    implicitHeight: 28 * Theme.scale
                    spacing: Theme.spaceXs

                    AbstractButton {
                        id: pendingNavigation
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        enabled: root.operationNavigationPath(pendingDelegate.modelData).length > 0
                        leftPadding: Theme.spaceS
                        hoverEnabled: true
                        focusPolicy: Qt.StrongFocus
                        Accessible.role: Accessible.ListItem
                        Accessible.name: root.statusText(pendingDelegate.modelData) + " " + root.operationSubject(pendingDelegate.modelData)
                        onClicked: root.navigate(root.operationNavigationPath(pendingDelegate.modelData))
                        background: Rectangle { radius: Theme.radiusS; color: pendingNavigation.hovered ? Theme.controlHover : "transparent" }
                        contentItem: RowLayout {
                            spacing: Theme.spaceS

                            Text {
                                Layout.fillWidth: true
                                text: root.statusText(pendingDelegate.modelData) + " · " + root.operationSubject(pendingDelegate.modelData)
                                color: Theme.textMuted
                                font.pixelSize: Theme.fontSmall - 1
                                elide: Text.ElideRight
                            }
                        }
                    }
                    IconButton {
                        Layout.preferredWidth: 26 * Theme.scale
                        Layout.preferredHeight: 26 * Theme.scale
                        checkable: false
                        iconName: "octagon-x"
                        iconSize: Theme.fontSmall
                        tooltip: qsTr("Cancel this waiting operation")
                        visible: !!pendingDelegate.modelData.canCancel || root.cancelState(pendingDelegate.modelData).length > 0
                        enabled: !!pendingDelegate.modelData.canCancel && root.cancelState(pendingDelegate.modelData).length === 0
                        Accessible.name: qsTr("Cancel %1 %2").arg(root.operationLabel(pendingDelegate.modelData.method, false)).arg(root.operationSubject(pendingDelegate.modelData))
                        onClicked: root.requestCancel(pendingDelegate.modelData)
                    }
                }
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            visible: root.recoveryCount > 0
            spacing: Theme.spaceXs

            Text {
                Layout.leftMargin: Theme.spaceS
                text: qsTr("RECOVERY NEEDED")
                color: Theme.error
                font.pixelSize: Theme.fontSmall - 2
                font.weight: Font.DemiBold
                font.letterSpacing: 1
            }
            ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(contentHeight, 3 * 92 * Theme.scale)
                clip: true
                interactive: contentHeight > height
                model: BackendClient.recoveryRecords
                delegate: Rectangle {
                    id: recoveryDelegate
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    implicitHeight: recoveryRow.implicitHeight + Theme.spaceS * 2
                    color: Qt.alpha(Theme.error, 0.1)
                    border.width: 1
                    border.color: Qt.alpha(Theme.error, 0.5)
                    radius: Theme.radiusS

                    RowLayout {
                        id: recoveryRow
                        anchors.fill: parent
                        anchors.margins: Theme.spaceS
                        spacing: Theme.spaceS
                        TextEdit {
                            Layout.fillWidth: true
                            readOnly: true
                            selectByMouse: true
                            wrapMode: TextEdit.Wrap
                            text: qsTr("%1\n%2\n%3")
                                .arg(Format.safeText(recoveryDelegate.modelData.kind ?? qsTr("Recovery failed")))
                                .arg(recoveryDelegate.modelData.recoveryPath
                                    ? qsTr("Recovery path: %1").arg(Format.safeText(recoveryDelegate.modelData.recoveryPath))
                                    : recoveryDelegate.modelData.destination
                                        ? qsTr("Destination: %1").arg(Format.safeText(recoveryDelegate.modelData.destination))
                                        : "")
                                .arg(Format.safeText(recoveryDelegate.modelData.error ?? ""))
                            color: Theme.text
                            selectionColor: Theme.selectionFill
                            selectedTextColor: Theme.text
                            font.pixelSize: Theme.fontSmall - 1
                            Accessible.name: qsTr("Filesystem recovery details")
                        }
                        ModalButton {
                            text: qsTr("Dismiss")
                            Accessible.name: qsTr("Dismiss recovery details")
                            onClicked: BackendClient.dismissRecovery(recoveryDelegate.index)
                        }
                    }
                }
            }
        }
    }
}
