import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Rectangle {
    id: root
    required property var folderContext
    readonly property var orderedSignals: {
        const signals = (folderContext?.signals ?? []).slice();
        return signals.sort((first, second) => ContextBadgeCatalog.categoryOrder(first.category) - ContextBadgeCatalog.categoryOrder(second.category));
    }
    readonly property bool aiReady: orderedSignals.some(signal => signal.category === "ai")
    Layout.fillWidth: true
    implicitHeight: 32 * Theme.scale
    color: Qt.alpha(Theme.surfaceVariant, 0.25)
    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Theme.spaceL
        anchors.rightMargin: Theme.spaceL
        spacing: Theme.spaceM
        Text { text: root.aiReady ? qsTr("AI ready in this folder") : qsTr("No AI markers in this folder"); color: root.aiReady ? Theme.primary : Theme.textMuted; font.pixelSize: Theme.fontSmall; font.weight: Font.DemiBold }
        Flickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            contentWidth: badges.implicitWidth
            contentHeight: height
            flickableDirection: Flickable.HorizontalFlick
            Row {
                id: badges
                height: parent.height
                spacing: Theme.spaceS
                Repeater {
                    model: root.orderedSignals
                    delegate: ContextBadge {
                        required property var modelData
                        signalData: modelData
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }
            }
        }
    }
}
