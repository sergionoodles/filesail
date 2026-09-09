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
    readonly property color subtleDivider: Qt.alpha(outline, 0.42)
    property color errorText: "#16161e"
    // A host may bind this to its appearance setting. Preview providers use it
    // only to select generated syntax colours; they never load host resources.
    property string appearance: "dark"

    property real scale: 1.0
    property real radiusRatio: 1.0
    // Respect the desktop's configured application font. Sizes below use it as
    // their baseline so FileSail remains legible without imposing a typeface.
    property font systemFont: Qt.application.font
    property FontLoader lucideFont: FontLoader { source: "../assets/lucide.ttf" }
    readonly property int spaceXs: Math.round(4 * scale)
    readonly property int spaceS: Math.round(6 * scale)
    readonly property int spaceM: Math.round(9 * scale)
    readonly property int spaceL: Math.round(13 * scale)
    readonly property int spaceXl: Math.round(18 * scale)
    // FileSail uses square corners throughout. Keep the named tokens so host
    // adapters and components share one stable styling contract.
    readonly property int radiusS: 0
    readonly property int radiusM: 0
    readonly property int radiusL: 0
    readonly property int fontSmall: Math.round(Math.max(11, systemFont.pixelSize * 0.9) * scale)
    readonly property int fontBody: Math.round(Math.max(12, systemFont.pixelSize) * scale)
    readonly property int fontTitle: Math.round(Math.max(18, systemFont.pixelSize * 1.45) * scale)
    readonly property int buttonPaddingVertical: Math.round(10 * scale)
    readonly property int buttonPaddingHorizontal: Math.round(16 * scale)
    readonly property int buttonHeight: fontBody + buttonPaddingVertical * 2
    readonly property int iconSize: Math.round(Math.max(20, fontBody * 1.55))
    property int animationFast: 150
}
