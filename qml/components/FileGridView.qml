pragma ComponentBehavior: Bound

import QtQuick
import "../core"

GridView {
    id: gridView

    required property var session
    property var marqueeBaseSelection: []
    property bool marqueeAdditive: false

    function focusView() {
        gridView.forceActiveFocus();
    }

    clip: true
    reuseItems: true
    cacheBuffer: gridView.cellHeight * 2
    cellWidth: 118 * Theme.scale
    cellHeight: 112 * Theme.scale
    boundsBehavior: Flickable.StopAtBounds
    focus: true
    activeFocusOnTab: true
    keyNavigationEnabled: false

    function entryAt(index) {
        return gridView.model && index >= 0 && index < gridView.model.length ? gridView.model[index] : null;
    }

    function columnCount() {
        return Math.max(1, Math.floor(gridView.width / gridView.cellWidth));
    }

    function syncFocusedIndex() {
        let index = -1;
        for (let candidate = 0; candidate < gridView.count; ++candidate) {
            const entry = gridView.entryAt(candidate);
            if (entry && entry.path === gridView.session.focusedPath) {
                index = candidate;
                break;
            }
        }
        if (index < 0 && gridView.count > 0)
            index = 0;
        gridView.currentIndex = index;
    }

    function moveFocusTo(index, modifiers) {
        if (gridView.count === 0)
            return;
        const nextIndex = Math.max(0, Math.min(gridView.count - 1, index));
        const entry = gridView.entryAt(nextIndex);
        if (!entry)
            return;
        gridView.currentIndex = nextIndex;
        gridView.positionViewAtIndex(nextIndex, GridView.Contain);
        gridView.session.moveFocus(entry.path, modifiers);
    }

    function marqueePaths(x, y, width, height) {
        const columns = gridView.columnCount();
        const cellWidth = gridView.cellWidth;
        const cellHeight = gridView.cellHeight;
        const top = y + gridView.contentY;
        const bottom = y + height + gridView.contentY;
        const left = x + gridView.contentX;
        const right = x + width + gridView.contentX;
        const firstRow = Math.max(0, Math.floor(top / cellHeight));
        const lastRow = Math.max(firstRow, Math.floor(Math.max(top, bottom - 0.001) / cellHeight));
        const firstColumn = Math.max(0, Math.floor(left / cellWidth));
        const lastColumn = Math.floor(Math.max(left, right - 0.001) / cellWidth);
        const paths = [];
        for (let row = firstRow; row <= lastRow; ++row) {
            for (let column = firstColumn; column <= lastColumn && column < columns; ++column) {
                const index = row * columns + column;
                const entry = gridView.entryAt(index);
                if (!entry)
                    continue;
                const itemLeft = column * cellWidth;
                const itemTop = row * cellHeight - gridView.contentY;
                const itemRight = itemLeft + gridView.cellWidth - Theme.spaceS;
                const itemBottom = itemTop + gridView.cellHeight - Theme.spaceS;
                if (itemRight > x && itemLeft < x + width && itemBottom > y && itemTop < y + height)
                    paths.push(entry.path);
            }
        }
        return paths;
    }

    function pointInItem(x, y) {
        const columns = gridView.columnCount();
        const contentX = x + gridView.contentX;
        const contentY = y + gridView.contentY;
        const column = Math.floor(contentX / gridView.cellWidth);
        const row = Math.floor(contentY / gridView.cellHeight);
        if (column < 0 || column >= columns || row < 0)
            return false;
        const index = row * columns + column;
        if (!gridView.entryAt(index))
            return false;
        const itemLeft = column * gridView.cellWidth;
        const itemTop = row * gridView.cellHeight;
        return contentX >= itemLeft && contentX < itemLeft + gridView.cellWidth - Theme.spaceS
            && contentY >= itemTop && contentY < itemTop + gridView.cellHeight - Theme.spaceS;
    }

    function updateMarquee(x, y, width, height) {
        gridView.session.setSelection(
            gridView.marqueePaths(x, y, width, height),
            gridView.marqueeAdditive,
            "",
            gridView.marqueeBaseSelection);
    }

    Component.onCompleted: {
        syncFocusedIndex();
        forceActiveFocus();
    }
    onActiveFocusChanged: if (activeFocus) syncFocusedIndex()
    onModelChanged: syncFocusedIndex()
    onCountChanged: syncFocusedIndex()

    Connections {
        target: gridView.session
        function onFocusedPathChanged() { gridView.syncFocusedIndex(); }
    }

    SelectionMarquee {
        id: gridMarquee
        anchors.fill: parent
        selectionView: gridView
        session: gridView.session
        pointInItem: (x, y) => gridView.pointInItem(x, y)
        routeItemClicks: true
        onDragStarted: modifiers => {
            gridView.forceActiveFocus();
            gridView.marqueeBaseSelection = Object.keys(gridView.session.selectedPaths);
            gridView.marqueeAdditive = (modifiers & Qt.ControlModifier) !== 0;
        }
        onDragChanged: (x, y, width, height) => gridView.updateMarquee(x, y, width, height)
        onDragFinished: (x, y, width, height) => {
            const paths = gridView.marqueePaths(x, y, width, height);
            gridView.session.setSelection(paths, gridView.marqueeAdditive, paths[paths.length - 1] ?? "", gridView.marqueeBaseSelection);
            gridView.marqueeBaseSelection = [];
        }
        onItemClicked: (index, modifiers) => {
            const entry = gridView.entryAt(index);
            if (!entry)
                return;
            gridView.forceActiveFocus();
            gridView.session.selectEntry(entry.path, modifiers);
        }
        onItemDoubleClicked: (index, modifiers) => {
            const entry = gridView.entryAt(index);
            if (entry)
                gridView.session.openEntry(entry.path, entry.isDirectory);
        }
    }

    Keys.onPressed: event => {
        const modifiers = event.modifiers;
        const control = (modifiers & Qt.ControlModifier) !== 0;
        const columns = gridView.columnCount();
        let target = gridView.currentIndex < 0 ? 0 : gridView.currentIndex;
        let handled = true;
        if (event.key === Qt.Key_Left)
            target -= 1;
        else if (event.key === Qt.Key_Right)
            target += 1;
        else if (event.key === Qt.Key_Up)
            target -= columns;
        else if (event.key === Qt.Key_Down)
            target += columns;
        else if (event.key === Qt.Key_Home)
            target = 0;
        else if (event.key === Qt.Key_End)
            target = gridView.count - 1;
        else if (event.key === Qt.Key_PageUp)
            target -= columns * Math.max(1, Math.floor(gridView.height / gridView.cellHeight));
        else if (event.key === Qt.Key_PageDown)
            target += columns * Math.max(1, Math.floor(gridView.height / gridView.cellHeight));
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            const entry = gridView.entryAt(target);
            if (entry)
                gridView.session.openEntry(entry.path, entry.isDirectory);
        } else if (event.key === Qt.Key_Space) {
            gridView.session.toggleFocusedEntry();
        } else if (event.key === Qt.Key_Backspace) {
            gridView.session.navigation.up();
        } else if (event.key === Qt.Key_Escape) {
            gridView.session.clearSelection();
        } else if (event.key === Qt.Key_A && control) {
            gridView.session.selectAllVisible();
        } else {
            handled = false;
        }
        if (handled) {
            if (event.key !== Qt.Key_Return && event.key !== Qt.Key_Enter
                    && event.key !== Qt.Key_Space && event.key !== Qt.Key_Backspace
                    && event.key !== Qt.Key_Escape && !(event.key === Qt.Key_A && control))
                gridView.moveFocusTo(target, modifiers);
            event.accepted = true;
        }
    }

    delegate: Rectangle {
        id: gridDelegate
        required property int index
        required property var modelData
        required property string name
        required property string path
        required property bool isDirectory
        required property double size
        required property string modified
        required property string iconName
        required property string mimeType
        width: gridView.cellWidth - Theme.spaceS
        height: gridView.cellHeight - Theme.spaceS
        radius: Theme.radiusM
        Accessible.name: gridDelegate.name
        Accessible.role: Accessible.ListItem
        color: gridView.session.selectedPaths[path] ? Qt.alpha(Theme.primary, 0.16)
             : gridMarquee.hoveredIndex === gridDelegate.index ? Qt.alpha(Theme.text, 0.06) : "transparent"
        border.width: gridView.session.focusedPath === gridDelegate.path && gridView.activeFocus ? 1 : (gridView.session.selectedPaths[path] ? 1 : 0)
        border.color: gridView.session.focusedPath === gridDelegate.path && gridView.activeFocus
            ? Theme.primary : Qt.alpha(Theme.primary, 0.5)
        Column {
            anchors.centerIn: parent
            width: parent.width - Theme.spaceM * 2
            spacing: Theme.spaceS
            FileVisual { id: gridVisual; width: 46 * Theme.scale; height: 46 * Theme.scale; anchors.horizontalCenter: parent.horizontalCenter
                entry: gridDelegate.modelData
                selected: gridView.session.selectedPaths[gridDelegate.path] ?? false }
            Text { width: parent.width; text: Format.safeText(gridDelegate.name); textFormat: Text.PlainText; color: Theme.text; font.pixelSize: Theme.fontBody; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight; maximumLineCount: 2; wrapMode: Text.Wrap }
        }
        GridView.onPooled: gridVisual.releaseConsumer()
        GridView.onReused: gridVisual.acquireConsumer()
    }
}
