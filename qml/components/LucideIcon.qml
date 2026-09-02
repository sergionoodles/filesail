import QtQuick
import "../core"

Text {
    id: root

    property string name: "circle"
    property color iconColor: Theme.textMuted
    property int iconSize: Theme.iconSize

    text: String.fromCharCode(LucideCodes.values[name] ?? 57559)
    color: iconColor
    font.family: Theme.lucideFont.name
    font.pixelSize: iconSize
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
}
