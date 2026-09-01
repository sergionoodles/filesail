import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Rectangle {
    id: root
    required property var signalData
    readonly property var details: ContextBadgeCatalog.details(signalData ?? {})
    implicitWidth: content.implicitWidth + Theme.spaceM * 2
    implicitHeight: 28 * Theme.scale
    radius: Theme.radiusS
    color: Theme.surfaceVariant
    Accessible.name: details.label
    Accessible.role: Accessible.StaticText
    RowLayout {
        id: content
        anchors.centerIn: parent
        spacing: Theme.spaceXs
        LucideIcon { name: root.details.iconName; iconSize: Theme.fontBody; iconColor: Theme.textMuted }
        Text { text: Format.safeText(root.details.label); textFormat: Text.PlainText; color: Theme.text; font.pixelSize: Theme.fontSmall; font.weight: Font.Medium }
    }
    HoverHandler { id: hover }
    ToolTip.visible: hover.hovered
    ToolTip.text: root.details.label + qsTr(" detected from ") + root.details.evidence.join(", ")
    ToolTip.delay: 450
}
