import QtQuick
import QtQuick.Layouts
import "../core"

RowLayout {
    id: root

    default property alias content: actions.data

    spacing: Theme.spaceS

    Item { Layout.fillWidth: true }

    RowLayout {
        id: actions
        spacing: Theme.spaceS
    }
}
