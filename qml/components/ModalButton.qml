import QtQuick
import QtQuick.Controls
import "../core"

Button {
    id: root

    property bool primary: false
    property bool destructive: false

    implicitHeight: Theme.buttonHeight
    leftPadding: Theme.buttonPaddingHorizontal
    rightPadding: Theme.buttonPaddingHorizontal
    topPadding: Theme.buttonPaddingVertical
    bottomPadding: Theme.buttonPaddingVertical
    hoverEnabled: true

    background: Rectangle {
        color: {
            if (!root.primary)
                return root.down || root.hovered ? Theme.controlHover : "transparent";
            const base = root.destructive ? Theme.error : Theme.primary;
            return root.down ? Qt.alpha(base, 0.72)
                 : root.hovered ? Qt.alpha(base, 0.86)
                 : base;
        }
        border.width: root.primary ? 0 : 1
        border.color: Theme.outline
        opacity: root.enabled ? 1 : 0.35
    }

    contentItem: Text {
        text: root.text
        textFormat: Text.PlainText
        color: root.primary
             ? (root.destructive ? Theme.errorText : Theme.primaryText)
             : Theme.text
        font.pixelSize: Theme.fontBody
        font.weight: root.primary ? Font.DemiBold : Font.Normal
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
    }
}
