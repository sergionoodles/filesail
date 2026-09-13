import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

ColumnLayout {
    id: root

    signal activateVolume(var volume)
    signal unmountVolume(var volume)
    signal safeRemoveDrive(var drive)

    spacing: Theme.spaceXs

    function iconFor(kind) {
        if (kind === "usb") return "usb";
        if (kind === "card") return "sd-card";
        if (kind === "optical") return "disc-3";
        if (kind === "encrypted") return "lock-keyhole";
        return "hard-drive";
    }

    function statusFor(volume) {
        if (volume.status === "path_unrepresentable") return qsTr("Mount path unavailable");
        if (volume.locked) return qsTr("Locked");
        if (volume.readOnly && volume.mounted) return qsTr("Read-only");
        if (volume.mounted) return qsTr("Mounted");
        if (volume.mountable) return qsTr("Not mounted");
        return volume.filesystemType ? qsTr("Unsupported %1").arg(volume.filesystemType) : qsTr("Unsupported media");
    }

    function detailFor(volume) {
        const status = statusFor(volume);
        const bytes = Number(volume.sizeBytes ?? 0);
        return bytes > 0 ? status + " · " + Format.size(bytes, false) : status;
    }

    Text {
        Layout.leftMargin: Theme.spaceS
        Layout.topMargin: Theme.spaceM
        Layout.bottomMargin: Theme.spaceXs
        text: qsTr("DEVICES")
        color: Theme.textMuted
        font.pixelSize: Theme.fontSmall - 1
        font.weight: Font.DemiBold
        font.letterSpacing: 1.2
    }

    Text {
        Layout.fillWidth: true
        Layout.leftMargin: Theme.spaceS
        Layout.rightMargin: Theme.spaceS
        visible: !VolumeModel.available
        text: Format.safeText(VolumeModel.unavailableReason || qsTr("Removable drives are unavailable"))
        textFormat: Text.PlainText
        color: Theme.textMuted
        font.pixelSize: Theme.fontSmall
        wrapMode: Text.Wrap
    }

    Text {
        Layout.fillWidth: true
        Layout.leftMargin: Theme.spaceS
        visible: VolumeModel.available && VolumeModel.rows.length === 0
        text: qsTr("No removable drives")
        color: Theme.textMuted
        font.pixelSize: Theme.fontSmall
    }

    Repeater {
        model: VolumeModel.rows

        delegate: Item {
            id: row
            required property var modelData
            readonly property var volume: modelData.volume ?? ({})
            readonly property var drive: modelData.drive ?? ({})
            Layout.fillWidth: true
            implicitHeight: modelData.rowType === "heading" ? 28 * Theme.scale : 42 * Theme.scale

            Text {
                anchors.left: parent.left
                anchors.leftMargin: Theme.spaceS
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Theme.spaceM * 2
                visible: row.modelData.rowType === "heading"
                text: Format.safeText(row.modelData.label)
                textFormat: Text.PlainText
                color: Theme.textMuted
                font.pixelSize: Theme.fontSmall
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }

            AbstractButton {
                id: volumeButton
                anchors.fill: parent
                visible: row.modelData.rowType === "volume"
                enabled: visible && !VolumeModel.operationFor(row.modelData.volumeId)
                hoverEnabled: true
                focusPolicy: Qt.StrongFocus
                Accessible.role: Accessible.ListItem
                Accessible.name: Format.safeText(row.modelData.label + ", " + root.detailFor(row.modelData.volume))
                onClicked: {
                    if (row.modelData.volume.mounted || row.modelData.volume.mountable || row.modelData.volume.locked)
                        root.activateVolume(row.modelData.volume);
                }

                background: Rectangle {
                    radius: Theme.radiusS
                    color: volumeButton.down ? Qt.alpha(Theme.primary, 0.2)
                         : volumeButton.hovered ? Theme.controlHover : "transparent"
                    border.width: volumeButton.visualFocus ? 1 : 0
                    border.color: Theme.primary
                }

                contentItem: RowLayout {
                    spacing: Theme.spaceS
                    Item { Layout.preferredWidth: row.modelData.indented ? Theme.spaceM : 0 }
                    LucideIcon { name: root.iconFor(row.modelData.kind); iconColor: Theme.textMuted }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        Text { Layout.fillWidth: true; text: Format.safeText(row.modelData.label); textFormat: Text.PlainText; color: Theme.text; font.pixelSize: Theme.fontBody; elide: Text.ElideRight }
                        Text {
                            Layout.fillWidth: true
                            text: Format.safeText(VolumeModel.operationFor(row.modelData.volumeId)
                                  || VolumeModel.operationFor(row.modelData.driveId)
                                  || root.detailFor(row.modelData.volume))
                            textFormat: Text.PlainText; color: Theme.textMuted; font.pixelSize: Theme.fontSmall; elide: Text.ElideRight
                        }
                    }
                    BusyIndicator {
                        id: busyIndicator
                        visible: running
                        running: !!VolumeModel.operationFor(row.modelData.volumeId)
                              || !!VolumeModel.operationFor(row.modelData.driveId)
                        implicitWidth: 22 * Theme.scale; implicitHeight: 22 * Theme.scale
                    }
                    IconButton {
                        visible: !busyIndicator.running
                        checkable: false
                        iconName: row.modelData.volume.mounted || row.modelData.drive.ejectable ? "eject" : row.modelData.volume.locked ? "lock-keyhole" : "mountain"
                        tooltip: row.modelData.volume.mounted || row.modelData.drive.ejectable
                            ? qsTr("Safely remove %1").arg(Format.safeText(row.modelData.drive.label))
                            : row.modelData.volume.locked ? qsTr("Unlock and open %1").arg(Format.safeText(row.modelData.label))
                            : qsTr("Mount and open %1").arg(Format.safeText(row.modelData.label))
                        implicitWidth: 30 * Theme.scale; implicitHeight: 30 * Theme.scale
                        onClicked: {
                            if (row.modelData.volume.mounted || row.modelData.drive.ejectable) root.safeRemoveDrive(row.modelData.drive);
                            else root.activateVolume(row.modelData.volume);
                        }
                    }
                }

                TapHandler {
                    acceptedButtons: Qt.RightButton
                    onTapped: deviceMenu.popup()
                }
            }

            Menu {
                id: deviceMenu
                width: 220 * Theme.scale
                background: Rectangle {
                    color: Theme.surfaceVariant
                    border.width: 1
                    border.color: Theme.divider
                    radius: Theme.radiusS
                }
                ThemedMenuItem {
                    text: row.volume.mounted ? qsTr("Open")
                        : row.volume.locked ? qsTr("Unlock and Open") : qsTr("Mount and Open")
                    enabled: row.modelData.rowType === "volume"
                          && (row.volume.mounted || row.volume.mountable || row.volume.locked)
                    onTriggered: root.activateVolume(row.modelData.volume)
                }
                ThemedMenuItem {
                    text: qsTr("Unmount Volume")
                    visible: row.modelData.rowType === "volume" && row.volume.mounted
                    onTriggered: root.unmountVolume(row.modelData.volume)
                }
                ThemedMenuItem {
                    text: row.drive.ejectable ? qsTr("Eject Media") : qsTr("Safely Remove Drive")
                    enabled: row.modelData.drive !== undefined
                    onTriggered: root.safeRemoveDrive(row.modelData.drive)
                }
            }
        }
    }
}
