import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "../core"

Rectangle {
    id: root
    required property var signalData
    readonly property var details: ContextBadgeCatalog.details(signalData ?? {})
    readonly property color accent: details.accent ?? "#9aa5ce"
    implicitWidth: content.implicitWidth + Theme.spaceM * 2
    implicitHeight: content.implicitHeight + Theme.spaceXs * 2
    radius: Theme.radiusS
    color: Qt.alpha(accent, 0.22)
    border.width: 1
    border.color: Qt.alpha(accent, 0.5)
    Accessible.name: details.label
    Accessible.role: Accessible.StaticText
    RowLayout {
        id: content
        anchors.centerIn: parent
        spacing: Theme.spaceXs
        LucideIcon { name: root.details.iconName; iconSize: Theme.fontSmall; iconColor: root.accent }
        Text { text: Format.safeText(root.details.label); textFormat: Text.PlainText; color: Theme.text; font.pixelSize: Theme.fontSmall; font.weight: Font.Medium }
    }
    HoverHandler { id: hover }
    ToolTip.visible: hover.hovered
    ToolTip.text: root.details.label + qsTr(" detected from ") + root.details.evidence.join(", ")
    ToolTip.delay: 450
}
