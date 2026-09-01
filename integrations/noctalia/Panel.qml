import QtQuick
import "../../qml/components" as FileSail
import "../../qml/core" as FileSailCore

Item {
    id: root

    property var pluginApi: null
    readonly property var geometryPlaceholder: fileSailView
    property bool allowAttach: true
    property real contentPreferredWidth: 1040 * FileSailCore.Theme.scale
    property real contentPreferredHeight: 760 * FileSailCore.Theme.scale
    property color panelBackgroundColor: FileSailCore.Theme.surface

    anchors.fill: parent

    NoctaliaThemeProvider {
        theme: FileSailCore.Theme
    }

    FileSail.FileSailView {
        id: fileSailView
        anchors.fill: parent
        compact: true
        cornerRadius: FileSailCore.Theme.radiusL
    }
}
