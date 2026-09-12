import QtQuick
import QtQuick.Layouts
import "../core"

RowLayout {
    id: root

    property alias leadingContent: leadingSlot.data
    property bool leadingVisible: false
    property string title: ""
    property string subtitle: ""
    property string trailingText: ""

    spacing: Theme.spaceL

    Item {
        id: leadingSlot
        visible: root.leadingVisible
        Layout.preferredWidth: visible ? 56 * Theme.scale : 0
        Layout.preferredHeight: visible ? 56 * Theme.scale : 0
        Layout.alignment: Qt.AlignTop
    }

    ColumnLayout {
        Layout.fillWidth: true
        spacing: Theme.spaceXs

        Text {
            Layout.fillWidth: true
            text: Format.safeText(root.title)
            textFormat: Text.PlainText
            color: Theme.text
            font.pixelSize: Theme.fontTitle
            font.weight: Font.DemiBold
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }

        Text {
            Layout.fillWidth: true
            visible: root.subtitle.length > 0
            text: Format.safeText(root.subtitle)
            textFormat: Text.PlainText
            color: Theme.textMuted
            font.pixelSize: Theme.fontBody
            wrapMode: Text.Wrap
            maximumLineCount: 2
            elide: Text.ElideRight
        }
    }

    Text {
        visible: root.trailingText.length > 0
        Layout.alignment: Qt.AlignTop
        text: Format.safeText(root.trailingText)
        textFormat: Text.PlainText
        color: Theme.textMuted
        font.family: "monospace"
        font.pixelSize: Theme.fontSmall
    }
}
