import QtQuick
import QtQuick.Layouts
import "../core"

Item {
    id: root
    required property var folderContext
    readonly property var orderedSignals: {
        const signals = (folderContext?.signals ?? []).slice();
        return signals.sort((first, second) => ContextBadgeCatalog.categoryOrder(first.category) - ContextBadgeCatalog.categoryOrder(second.category));
    }
    Layout.fillWidth: true
    Layout.fillHeight: true
    implicitHeight: 28 * Theme.scale
    clip: true

    Flickable {
        id: flick
        anchors.fill: parent
        clip: true
        contentWidth: Math.max(width, badges.implicitWidth)
        contentHeight: height
        flickableDirection: Flickable.HorizontalFlick
        boundsBehavior: Flickable.StopAtBounds

        Row {
            id: badges
            x: Math.max(0, flick.width - implicitWidth)
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
