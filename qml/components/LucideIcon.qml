import QtQuick
import "../core"

Text {
    id: root

    property string name: "circle"
    property color iconColor: Theme.textMuted
    property int iconSize: Theme.iconSize

    // The bundled font maps Lucide names through its GSUB ligature table.
    text: name
    color: iconColor
    font.family: Theme.lucideFont.name
    font.pixelSize: iconSize
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
}
