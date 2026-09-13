pragma Singleton

import QtQuick

QtObject {
    id: root

    property bool available: false
    property string unavailableReason: qsTr("Checking for removable drives…")
    property string backendInstance: ""
    property double revision: 0
    property var drives: []
    property var rows: []
    property var operations: ({})
    property var expectedMountPoints: ({})

    signal removalPreparing(var mountPoints)
    signal removalFinished(var mountPoints, bool success)
    signal mountPointsLost(var mountPoints, bool expected, bool disconnected)

    function isWithin(path, parent) {
        const normalized = String(parent ?? "").replace(/\/+$/, "") || "/";
        const child = String(path ?? "");
        return child === normalized || child.startsWith(normalized === "/" ? "/" : normalized + "/");
    }

    function operationFor(id) {
        return operations[String(id)] ?? "";
    }

    function setOperation(id, value) {
        const next = Object.assign({}, operations);
        if (value) next[String(id)] = value;
        else delete next[String(id)];
        operations = next;
    }

    function rebuildRows() {
        const next = [];
        const labelCounts = {};
        for (const sourceDrive of drives) {
            for (const sourceVolume of sourceDrive.volumes ?? []) {
                const key = String(sourceVolume.label ?? "");
                labelCounts[key] = (labelCounts[key] ?? 0) + 1;
            }
        }
        for (const drive of drives) {
            const volumes = Array.isArray(drive.volumes) ? drive.volumes : [];
            if (volumes.length > 1)
                next.push({ rowType: "heading", drive, driveId: drive.driveId,
                            label: drive.label, kind: drive.kind });
            for (const volume of volumes) {
                let visibleLabel = volume.label;
                if (labelCounts[String(volume.label ?? "")] > 1) {
                    const suffix = volume.partitionNumber
                        ? qsTr("partition %1").arg(volume.partitionNumber)
                        : Format.size(Number(volume.sizeBytes ?? 0), false);
                    visibleLabel = qsTr("%1 · %2").arg(volume.label).arg(suffix);
                }
                next.push({ rowType: "volume", drive, volume,
                            driveId: drive.driveId, volumeId: volume.volumeId,
                            label: visibleLabel, kind: volume.locked ? "encrypted" : drive.kind,
                            indented: volumes.length > 1 });
            }
        }
        rows = next;
    }

    function mountedMap(sourceDrives) {
        const result = {};
        for (const drive of sourceDrives ?? []) {
            for (const volume of drive.volumes ?? []) {
                for (const path of volume.mountPoints ?? [])
                    result[path] = true;
            }
        }
        return result;
    }

    function mountOwners(sourceDrives) {
        const result = {};
        for (const drive of sourceDrives ?? []) {
            for (const volume of drive.volumes ?? []) {
                for (const path of volume.mountPoints ?? []) result[path] = volume.volumeId;
            }
        }
        return result;
    }

    function applySnapshot(snapshot) {
        const nextInstance = String(snapshot.backendInstance ?? "");
        const nextRevision = Number(snapshot.revision ?? 0);
        if (backendInstance && nextInstance === backendInstance && nextRevision <= revision)
            return;
        const restarted = backendInstance && nextInstance && nextInstance !== backendInstance;
        const oldMounts = mountedMap(drives);
        const oldOwners = mountOwners(drives);
        const nextDrives = Array.isArray(snapshot.drives) ? snapshot.drives : [];
        const nextMounts = mountedMap(nextDrives);
        const nextVolumeIds = {};
        for (const nextDrive of nextDrives)
            for (const nextVolume of nextDrive.volumes ?? []) nextVolumeIds[nextVolume.volumeId] = true;
        backendInstance = nextInstance;
        if (restarted) {
            operations = ({});
            expectedMountPoints = ({});
        }
        revision = nextRevision;
        available = snapshot.available === true;
        unavailableReason = String(snapshot.unavailableReason ?? "");
        drives = nextDrives;
        rebuildRows();
        if (!available || restarted)
            return;
        const lost = Object.keys(oldMounts).filter(path => !nextMounts[path]);
        if (lost.length > 0) {
            const expectedLost = lost.filter(path => expectedMountPoints[path]);
            const externalLost = lost.filter(path => !expectedMountPoints[path] && nextVolumeIds[oldOwners[path]]);
            const disconnectedLost = lost.filter(path => !expectedMountPoints[path] && !nextVolumeIds[oldOwners[path]]);
            if (expectedLost.length > 0) mountPointsLost(expectedLost, true, false);
            if (externalLost.length > 0) mountPointsLost(externalLost, false, false);
            if (disconnectedLost.length > 0) mountPointsLost(disconnectedLost, false, true);
            const nextExpected = Object.assign({}, expectedMountPoints);
            for (const path of lost) delete nextExpected[path];
            expectedMountPoints = nextExpected;
        }
    }

    function refresh() {
        BackendClient.listVolumes(result => applySnapshot(result), (message, result) => {
            available = false;
            unavailableReason = message;
        });
    }

    function reportFailure(message, result, retry, errorCallback) {
        const details = result && result.details ? result.details : {};
        setOperation(details.volumeId ?? details.driveId ?? "", "");
        if (errorCallback)
            errorCallback(result ?? { ok: false, error: message, errorCode: "system_error" }, retry);
    }

    function activate(volume, navigateCallback, unlockCallback, errorCallback, noticeCallback) {
        if (!volume || operationFor(volume.volumeId)) return;
        if (volume.locked) {
            if (unlockCallback) unlockCallback(volume, navigateCallback, errorCallback, noticeCallback);
            return;
        }
        if (volume.mounted) {
            const path = (volume.mountPoints ?? [])[0];
            if (path) navigateCallback(path);
            return;
        }
        if (!volume.mountable) return;
        setOperation(volume.volumeId, qsTr("Mounting"));
        BackendClient.mountVolume(volume.volumeId, result => {
            setOperation(volume.volumeId, "");
            if (result.mountPath) navigateCallback(result.mountPath);
            if (noticeCallback) noticeCallback(qsTr("%1 mounted").arg(Format.safeText(volume.label)));
            refresh();
        }, (message, result) => {
            setOperation(volume.volumeId, "");
            reportFailure(message, result, () => activate(volume, navigateCallback, unlockCallback, errorCallback, noticeCallback), errorCallback);
        });
    }

    function unlockAndOpen(volume, passphrase, navigateCallback, unlockCallback, errorCallback, noticeCallback) {
        if (!volume || !passphrase || operationFor(volume.volumeId)) return;
        setOperation(volume.volumeId, qsTr("Unlocking"));
        BackendClient.unlockVolume(volume.volumeId, passphrase, true, result => {
            setOperation(volume.volumeId, "");
            if (result.mountPath) navigateCallback(result.mountPath);
            if (noticeCallback) noticeCallback(qsTr("%1 mounted").arg(Format.safeText(volume.label)));
            refresh();
        }, (message, result) => {
            setOperation(volume.volumeId, "");
            reportFailure(message, result, () => {
                if (unlockCallback) unlockCallback(volume, navigateCallback, errorCallback, noticeCallback);
            }, errorCallback);
        });
    }

    function unmount(volume, errorCallback, noticeCallback) {
        if (!volume || operationFor(volume.volumeId)) return;
        setOperation(volume.volumeId, qsTr("Preparing"));
        BackendClient.prepareVolumeRemoval("volume", volume.volumeId, "unmount", undefined, preparation => {
            const paths = preparation.mountPoints ?? [];
            removalPreparing(paths);
            const expected = Object.assign({}, expectedMountPoints);
            for (const path of paths) expected[path] = true;
            expectedMountPoints = expected;
            setOperation(volume.volumeId, qsTr("Unmounting"));
            BackendClient.unmountVolume(volume.volumeId, preparation.reservationId, result => {
                setOperation(volume.volumeId, "");
                removalFinished(paths, true);
                if (noticeCallback) noticeCallback(qsTr("%1 unmounted").arg(Format.safeText(volume.label)));
                refresh();
            }, (message, result) => {
                const nextExpected = Object.assign({}, expectedMountPoints);
                for (const path of paths) delete nextExpected[path];
                expectedMountPoints = nextExpected;
                setOperation(volume.volumeId, "");
                removalFinished(paths, false);
                reportFailure(message, result, () => unmount(volume, errorCallback, noticeCallback), errorCallback);
            });
        }, (message, result) => {
            setOperation(volume.volumeId, "");
            reportFailure(message, result, () => unmount(volume, errorCallback, noticeCallback), errorCallback);
        });
    }

    function safeRemove(drive, errorCallback, noticeCallback) {
        if (!drive || operationFor(drive.driveId)) return;
        setOperation(drive.driveId, qsTr("Preparing"));
        BackendClient.prepareVolumeRemoval("drive", drive.driveId, "safeRemove",
            drive.affectedDriveIds ?? [drive.driveId], preparation => {
            const paths = preparation.mountPoints ?? [];
            removalPreparing(paths);
            const expected = Object.assign({}, expectedMountPoints);
            for (const path of paths) expected[path] = true;
            expectedMountPoints = expected;
            setOperation(drive.driveId, qsTr("Safely removing"));
            BackendClient.safelyRemoveDrive(drive.driveId, preparation.reservationId, result => {
                setOperation(drive.driveId, "");
                removalFinished(paths, true);
                if (noticeCallback) noticeCallback(result.action === "unmount"
                    ? qsTr("%1 can now be safely removed").arg(Format.safeText(drive.label))
                    : qsTr("%1 safely removed").arg(Format.safeText(drive.label)));
                refresh();
            }, (message, result) => {
                setOperation(drive.driveId, "");
                const completedIds = result && result.details
                    && Array.isArray(result.details.completedVolumeIds)
                    ? result.details.completedVolumeIds : [];
                let completedPaths = [];
                for (const sourceDrive of drives) {
                    for (const sourceVolume of sourceDrive.volumes ?? []) {
                        if (completedIds.indexOf(sourceVolume.volumeId) >= 0)
                            completedPaths = completedPaths.concat(sourceVolume.mountPoints ?? []);
                    }
                }
                const nextExpected = Object.assign({}, expectedMountPoints);
                for (const path of paths) delete nextExpected[path];
                expectedMountPoints = nextExpected;
                if (completedPaths.length > 0) removalFinished(completedPaths, true);
                else removalFinished(paths, false);
                reportFailure(message, result, () => safeRemove(drive, errorCallback, noticeCallback), errorCallback);
            });
        }, (message, result) => {
            setOperation(drive.driveId, "");
            reportFailure(message, result, () => safeRemove(drive, errorCallback, noticeCallback), errorCallback);
        });
    }

    property Connections backendEvents: Connections {
        target: BackendClient
        function onEventReceived(event, message) {
            if (event === "volumesChanged") root.applySnapshot(message);
            else if (event === "volumeOperationChanged"
                     && (!message.backendInstance || message.backendInstance === root.backendInstance))
                root.setOperation(message.targetId, message.state);
        }
        function onBackendStopped(message) {
            root.available = false;
            root.unavailableReason = message;
            root.drives = [];
            root.rows = [];
            root.operations = ({});
        }
    }

    Component.onCompleted: refresh()
}
