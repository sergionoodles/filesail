import QtQuick
import qs.Commons
import "../../qml/components" as FileSail
import "../../qml/core" as FileSailCore

Item {
    id: root

    property var pluginApi: null
    readonly property var geometryPlaceholder: fileSailView
    property bool allowAttach: true
    property real contentPreferredWidth: 1040 * Style.uiScaleRatio
    property real contentPreferredHeight: 760 * Style.uiScaleRatio
    property color panelBackgroundColor: Color.mSurface

    anchors.fill: parent

    Component.onCompleted: FileSailCore.Theme.apply({
        primary: Color.mPrimary,
        primaryText: Color.mOnPrimary,
        secondary: Color.mSecondary,
        surface: Color.mSurface,
        surfaceVariant: Color.mSurfaceVariant,
        text: Color.mOnSurface,
        textMuted: Color.mOnSurfaceVariant,
        outline: Color.mOutline,
        hover: Color.mHover,
        error: Color.mError,
        scale: Style.uiScaleRatio,
        radiusRatio: Settings.data.general.radiusRatio,
        animationFast: Style.animationFast,
        animationNormal: Style.animationNormal
    })

    FileSail.FileSailView {
        id: fileSailView
        anchors.fill: parent
        panelMode: true
    }
}
