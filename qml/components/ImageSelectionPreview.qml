import QtQuick
import QtQuick.Window
import QtQuick.Layouts
import "../core"

Item {
    id: root
    required property var entries
    property int selectionRevision: 0
    readonly property int maximumImages: 16
    readonly property var visibleEntries: entries.slice(0, maximumImages)
    readonly property real gridGap: Theme.spaceS * 2
    readonly property real minimumTileWidth: 140 * Theme.scale
    readonly property real availableGridWidth: Math.max(1, width - Theme.spaceM * 2)
    readonly property real availableGridHeight: Math.max(1, height - Theme.spaceM * 2)
    property var previewStates: ({})

    readonly property real gridAspectRatio: {
        const ratios = root.visibleEntries.map(entry => {
            const state = root.previewStates[root.entryKey(entry)];
            return state && state.aspectRatio > 0
                ? state.aspectRatio : root.entryAspectRatio(entry);
        }).filter(ratio => ratio > 0).sort((left, right) => left - right);
        return ratios.length > 0 ? ratios[Math.floor(ratios.length / 2)] : 0;
    }
    readonly property int columnCount: Math.min(root.visibleEntries.length,
        root.availableGridHeight > root.availableGridWidth ? 2 : 3,
        Math.max(1, Math.floor((root.availableGridWidth + root.gridGap)
            / (root.minimumTileWidth + root.gridGap))))
    readonly property var gridMetrics: {
        if (root.visibleEntries.length <= 1)
            return { columns: 1, rows: 1, tileWidth: root.availableGridWidth,
                tileHeight: root.availableGridHeight };
        const ratio = root.gridAspectRatio > 0 ? root.gridAspectRatio : 1;
        return root.layoutForColumns(root.columnCount, ratio);
    }

    readonly property string previewReadiness: {
        const states = Object.keys(root.previewStates).map(key => root.previewStates[key]);
        if (states.length === 0 || states.some(state => state.readiness === "loading"))
            return "loading";
        return states.some(state => state.readiness === "error") ? "error" : "ready";
    }
    readonly property string previewError: {
        const failures = Object.keys(root.previewStates)
            .map(key => root.previewStates[key])
            .filter(state => state.readiness === "error")
            .map(state => state.name);
        return failures.length > 0
            ? qsTr("%1 image preview(s) unavailable: %2").arg(failures.length).arg(failures.join(", "))
            : "";
    }

    property ListModel previewEntriesModel: ListModel {
        dynamicRoles: true
    }
    property int syncGeneration: 0

    function sameEntry(left, right) {
        return left && right
            && left.path === right.path
            && left.name === right.name
            && left.url === right.url
            && left.size === right.size
            && left.modified === right.modified
            && left.mimeType === right.mimeType
            && left.iconName === right.iconName;
    }

    function entryKey(entry) {
        return JSON.stringify([
            String(entry.path), String(entry.url), Number(entry.size), String(entry.modified)
        ]);
    }

    function entryAspectRatio(entry) {
        return entry.imageWidth > 0 && entry.imageHeight > 0 ? entry.imageWidth / entry.imageHeight : 0;
    }

    function layoutForColumns(columns, ratio) {
        const rows = Math.ceil(root.visibleEntries.length / columns);
        const width = Math.max(1, root.availableGridWidth / columns - root.gridGap);
        const height = Math.max(1, root.availableGridHeight / rows - root.gridGap);
        const tileWidth = Math.min(width, height * ratio);
        const tileHeight = tileWidth / ratio;
        return { columns, rows, tileWidth, tileHeight };
    }

    function setPreviewState(key, readiness, name, aspectRatio) {
        if (!root.visibleEntries.some(entry => root.entryKey(entry) === key))
            return;
        const next = Object.assign({}, root.previewStates);
        next[key] = { readiness, name, aspectRatio };
        root.previewStates = next;
    }

    function removePreviewState(key) {
        if (!root.previewStates[key])
            return;
        const next = Object.assign({}, root.previewStates);
        delete next[key];
        root.previewStates = next;
    }

    function syncPreviewEntries() {
        const wanted = root.visibleEntries;
        const wantedKeys = new Set(wanted.map(entry => root.entryKey(entry)));

        const currentStates = Object.assign({}, root.previewStates);
        for (const key of Object.keys(currentStates)) {
            if (!wantedKeys.has(key))
                delete currentStates[key];
        }
        root.previewStates = currentStates;

        let modelMatches = previewEntriesModel.count === wanted.length;
        for (let index = 0; modelMatches && index < wanted.length; ++index) {
            modelMatches = sameEntry(previewEntriesModel.get(index).entry, wanted[index]);
        }
        if (modelMatches) {
            stateSyncTimer.restart();
            return;
        }

        previewEntriesModel.clear();
        const generation = ++syncGeneration;
        Qt.callLater(() => {
            if (generation !== root.syncGeneration)
                return;
            for (const entry of wanted)
                previewEntriesModel.append({ entry });
            stateSyncTimer.restart();
        });
    }

    function syncVisibleStates() {
        for (let index = 0; index < previewEntriesModel.count; ++index) {
            const delegate = previewGrid.itemAtIndex(index);
            if (delegate && delegate.previewRenderer && delegate.previewRenderer.active)
                delegate.previewRenderer.registerState();
        }
    }

    Component.onCompleted: syncPreviewEntries()
    onEntriesChanged: Qt.callLater(() => root.syncPreviewEntries())
    onVisibleEntriesChanged: syncPreviewEntries()
    onSelectionRevisionChanged: Qt.callLater(() => root.syncPreviewEntries())

    Timer {
        id: stateSyncTimer
        interval: 0
        repeat: false
        onTriggered: root.syncVisibleStates()
    }

    GridView {
        id: previewGrid
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.verticalCenter: parent.verticalCenter
        width: previewEntriesModel.count === 1 ? root.availableGridWidth
            : root.gridMetrics.columns * (root.gridMetrics.tileWidth + root.gridGap)
        height: previewEntriesModel.count === 1
            ? root.availableGridHeight
            : root.gridMetrics.rows * (root.gridMetrics.tileHeight + root.gridGap)
        clip: true
        visible: root.previewEntriesModel.count > 0
        boundsBehavior: Flickable.StopAtBounds
        reuseItems: true
        model: root.previewEntriesModel
        cellWidth: previewEntriesModel.count === 1
            ? Math.max(1, width)
            : root.gridMetrics.tileWidth + root.gridGap
        cellHeight: previewEntriesModel.count === 1
            ? height : root.gridMetrics.tileHeight + root.gridGap

        delegate: Item {
            id: delegateRoot
            required property var entry
            required property int index
            property bool pooled: false
            readonly property bool inViewport: !pooled && previewGrid.visible
                && y < previewGrid.contentY + previewGrid.height
                && y + height > previewGrid.contentY
            width: previewGrid.cellWidth
            height: previewGrid.cellHeight
            Accessible.name: entry.name
            Accessible.role: Accessible.ListItem
            ImageFilePreview {
                id: imageVisual
                anchors.fill: parent
                anchors.margins: previewEntriesModel.count === 1
                    ? Theme.spaceS : root.gridGap / 2
                entry: parent.entry
                active: parent.inViewport

                property string stateKey: root.entryKey(parent.entry)
                property string registeredStateKey: ""

                function registerState() {
                    if (!imageVisual.active)
                        return;
                    if (registeredStateKey && registeredStateKey !== stateKey)
                        root.removePreviewState(registeredStateKey);
                    registeredStateKey = stateKey;
                    root.setPreviewState(stateKey, imageVisual.previewReadiness,
                        parent.entry.name, imageVisual.aspectRatio);
                }

                onStateKeyChanged: registerState()
                onPreviewReadinessChanged: registerState()
                onAspectRatioChanged: registerState()
                onActiveChanged: {
                    if (imageVisual.active)
                        registerState();
                    else if (registeredStateKey) {
                        root.removePreviewState(registeredStateKey);
                        registeredStateKey = "";
                    }
                }
                onEntryChanged: Qt.callLater(() => imageVisual.registerState())
                Component.onCompleted: Qt.callLater(() => imageVisual.registerState())
                Component.onDestruction: if (registeredStateKey) root.removePreviewState(registeredStateKey)
            }
            property var previewRenderer: imageVisual
            GridView.onPooled: {
                delegateRoot.pooled = true;
                if (imageVisual.registeredStateKey) {
                    root.removePreviewState(imageVisual.registeredStateKey);
                    imageVisual.registeredStateKey = "";
                }
            }
            GridView.onReused: {
                delegateRoot.pooled = false;
                Qt.callLater(() => imageVisual.registerState());
            }
        }
    }

    Rectangle {
        anchors.left: parent.left
        anchors.bottom: parent.bottom
        anchors.margins: Theme.spaceM
        visible: root.entries.length > root.maximumImages
        color: Qt.alpha(Theme.surface, 0.9)
        border.color: Theme.outline
        border.width: 1
        Text {
            id: summaryText
            anchors.centerIn: parent
            text: qsTr("%1 of %2 images").arg(root.maximumImages).arg(root.entries.length)
            color: Theme.text
            font.pixelSize: Theme.fontSmall
            Accessible.name: text
        }
        implicitWidth: Math.max(96 * Theme.scale, summaryText.implicitWidth + Theme.spaceS * 2)
        implicitHeight: Theme.fontSmall + Theme.spaceS * 2
    }
}
