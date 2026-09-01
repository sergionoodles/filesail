import QtQuick
import "../core"

Text {
    id: root

    property string name: "circle"
    property color iconColor: Theme.textMuted
    property int iconSize: Theme.iconSize

    readonly property var codepoints: ({
        "arrow-left": 57416,
        "arrow-right": 57417,
        "arrow-up": 57418,
        "chevron-right": 57455,
        "copy": 57502,
        "eye": 57530,
        "eye-off": 57531,
        "folder": 57559,
        "folder-plus": 57561,
        "house": 57589,
        "list": 57606,
        "monitor": 57629,
        "scissors": 57678,
        "search": 57681,
        "square-pen": 57714,
        "square-terminal": 57866,
        "trash-2": 57742,
        "clipboard-paste": 58344,
        "grid-2x2": 58623
        ,"bookmark": 57444
        ,"briefcase-business": 58841
        ,"map-pinned": 58689
        ,"bot": 57786
        ,"git-branch": 57573
        ,"code-2": 58466
    })

    text: String.fromCharCode(codepoints[name] ?? 57559)
    color: iconColor
    font.family: Theme.lucideFont.name
    font.pixelSize: iconSize
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
}
