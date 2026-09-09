import QtQuick
import QtQuick.Controls
import "../core"

Item {
    id: root

    property bool previewEnabled: false
    property url previewSource: ""
    property Component previewComponent: null
    property var previewContext: null
    readonly property bool hasExternalPreview: previewSource.toString().length > 0 || Boolean(previewComponent)

    SplitView.preferredWidth: previewEnabled ? 300 * Theme.scale : 0
    SplitView.minimumWidth: previewEnabled ? 220 * Theme.scale : 0

    Loader {
        id: builtInPreview
        anchors.fill: parent
        active: root.previewEnabled && !root.hasExternalPreview
        sourceComponent: PreviewPanel {
            selectedEntries: root.previewEnabled && root.previewContext ? root.previewContext.selectedEntries : []
            selectionRevision: root.previewEnabled && root.previewContext ? root.previewContext.selectionRevision : 0
        }
    }

    Loader {
        id: previewLoader
        anchors.fill: parent
        active: root.previewEnabled && root.hasExternalPreview
        visible: active
        sourceComponent: root.previewSource.toString().length === 0 ? root.previewComponent : null

        property string selectedPath: root.previewEnabled && root.previewContext ? root.previewContext.selectedPath : ""

        function loadPreview() {
            if (active && root.previewSource.toString().length > 0 && root.previewContext)
                setSource(root.previewSource, { selectedPath: root.previewContext.selectedPath });
        }

        Component.onCompleted: loadPreview()
        onActiveChanged: if (active) loadPreview()
        onLoaded: {
            if (item && typeof item.selectedPath !== "undefined")
                item.selectedPath = Qt.binding(() => root.previewEnabled && root.previewContext ? root.previewContext.selectedPath : "");
            if (item && typeof item.selectedEntries !== "undefined")
                item.selectedEntries = Qt.binding(() => root.previewEnabled && root.previewContext ? root.previewContext.selectedEntries : []);
            if (item && typeof item.selectionRevision !== "undefined")
                item.selectionRevision = Qt.binding(() => root.previewEnabled && root.previewContext ? root.previewContext.selectionRevision : 0);
        }
    }

    Connections {
        target: root
        function onPreviewSourceChanged() { previewLoader.loadPreview(); }
    }
}
