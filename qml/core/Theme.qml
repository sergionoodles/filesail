pragma Singleton

import QtQuick

QtObject {
    id: root

    // Host-neutral semantic defaults. Host adapters may bind these properties to
    // their own theme provider; this type deliberately performs no I/O.
    property color primary: "#7aa2f7"
    property color primaryText: "#16161e"
    property color surface: "#1a1b26"
    property color surfaceVariant: "#24283b"
    property color text: "#c0caf5"
    property color textMuted: "#9aa5ce"
    property color outline: "#353d57"
    property color error: "#f7768e"
    // Derived semantic colors keep component styling host-neutral and uniform.
    readonly property color selectionFill: Qt.alpha(primary, 0.18)
    readonly property color controlHover: Qt.alpha(text, 0.08)
    readonly property color divider: Qt.alpha(outline, 0.72)
    property color errorText: "#16161e"

    property real scale: 1.0
    property real radiusRatio: 1.0
    readonly property int spaceXs: Math.round(4 * scale)
    readonly property int spaceS: Math.round(6 * scale)
    readonly property int spaceM: Math.round(9 * scale)
    readonly property int spaceL: Math.round(13 * scale)
    readonly property int spaceXl: Math.round(18 * scale)
    readonly property int radiusS: Math.round(8 * radiusRatio)
    readonly property int radiusM: Math.round(12 * radiusRatio)
    readonly property int radiusL: Math.round(16 * radiusRatio)
    readonly property int fontSmall: Math.round(10 * scale)
    readonly property int fontBody: Math.round(11 * scale)
    readonly property int fontTitle: Math.round(16 * scale)
    property int animationFast: 150
}
