import QtQuick
import "../../qml/components" as FileSail
import "../../qml/core" as FileSailCore

Item {
    id: root

    property var pluginApi: null
    readonly property bool panelActive: pluginApi !== null && pluginApi.panelOpenScreen !== null
    readonly property var geometryPlaceholder: geometryPlaceholderItem
    property bool allowAttach: true
    property real contentPreferredWidth: 1040 * FileSailCore.Theme.scale
    property real contentPreferredHeight: 760 * FileSailCore.Theme.scale
    property color panelBackgroundColor: FileSailCore.Theme.surface

    anchors.fill: parent

    NoctaliaThemeProvider {
        theme: FileSailCore.Theme
    }

    // Noctalia keeps the panel slot alive between opens. Keep only the
    // geometry contract resident and destroy the browser/session tree while
    // the slot is closed.
    Item {
        id: geometryPlaceholderItem
        anchors.fill: parent
        implicitWidth: root.contentPreferredWidth
        implicitHeight: root.contentPreferredHeight
    }

    Loader {
        id: fileSailLoader
        anchors.fill: parent
        active: root.panelActive
        sourceComponent: FileSail.FileSailView {
            compact: true
            cornerRadius: 0
        }
    }
}
