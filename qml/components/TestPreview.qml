import QtQuick
import QtQuick.Layouts
import "../core"

// Contract test provider: external providers receive this value from FileSailView.
Rectangle {
    required property string selectedPath
    color: Theme.surfaceVariant

    ColumnLayout {
        anchors.centerIn: parent
        width: parent.width - Theme.spaceXl * 2
        spacing: Theme.spaceS
        Text { text: qsTr("Preview"); color: Theme.text; font.pixelSize: Theme.fontTitle }
        Text { Layout.fillWidth: true; text: selectedPath; color: Theme.textMuted; wrapMode: Text.WrapAnywhere }
    }
}
