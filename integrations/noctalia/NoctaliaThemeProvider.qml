import QtQuick
import qs.Commons

// Maps Noctalia's live singleton tokens into FileSail's host-neutral contract.
// Noctalia updates these values when its selected scheme changes.
QtObject {
    id: root

    property var theme: null

    // QtObject has no default child property, so each Binding must be owned by
    // an explicit property rather than declared as an implicit child.
    property Binding primaryBinding: Binding { target: root.theme; property: "primary"; value: Color.mPrimary; when: root.theme }
    property Binding primaryTextBinding: Binding { target: root.theme; property: "primaryText"; value: Color.mOnPrimary; when: root.theme }
    property Binding surfaceBinding: Binding { target: root.theme; property: "surface"; value: Color.mSurface; when: root.theme }
    property Binding surfaceVariantBinding: Binding { target: root.theme; property: "surfaceVariant"; value: Color.mSurfaceVariant; when: root.theme }
    property Binding textBinding: Binding { target: root.theme; property: "text"; value: Color.mOnSurface; when: root.theme }
    property Binding textMutedBinding: Binding { target: root.theme; property: "textMuted"; value: Color.mOnSurfaceVariant; when: root.theme }
    property Binding outlineBinding: Binding { target: root.theme; property: "outline"; value: Color.mOutline; when: root.theme }
    property Binding errorBinding: Binding { target: root.theme; property: "error"; value: Color.mError; when: root.theme }
    property Binding errorTextBinding: Binding { target: root.theme; property: "errorText"; value: Color.mOnError; when: root.theme }
    property Binding appearanceBinding: Binding { target: root.theme; property: "appearance"; value: Settings.data.colorSchemes.darkMode ? "dark" : "light"; when: root.theme }
    property Binding scaleBinding: Binding { target: root.theme; property: "scale"; value: Style.uiScaleRatio; when: root.theme }
    property Binding radiusRatioBinding: Binding { target: root.theme; property: "radiusRatio"; value: Settings.data.general.radiusRatio; when: root.theme }
    property Binding animationFastBinding: Binding { target: root.theme; property: "animationFast"; value: Style.animationFast; when: root.theme }
}
