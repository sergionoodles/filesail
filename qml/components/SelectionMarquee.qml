import QtQuick
import "../core"

Item {
    id: root

    required property var selectionView
    required property var session
    property var pointInItem: null
    property bool routeItemClicks: false
    property int hoveredIndex: -1
    property bool dragging: false
    property bool moved: false
    property bool marqueeGesture: false
    property real startX: 0
    property real startY: 0
    property real currentX: 0
    property real currentY: 0

    signal dragStarted(int modifiers)
    signal dragChanged(real x, real y, real width, real height)
    signal dragFinished(real x, real y, real width, real height)
    signal itemClicked(int index, int modifiers)
    signal itemDoubleClicked(int index, int modifiers)

    readonly property real rectX: Math.max(0, Math.min(startX, currentX))
    readonly property real rectY: Math.max(0, Math.min(startY, currentY))
    readonly property real rectRight: Math.min(width, Math.max(startX, currentX))
    readonly property real rectBottom: Math.min(height, Math.max(startY, currentY))
    readonly property real rectWidth: Math.max(0, rectRight - rectX)
    readonly property real rectHeight: Math.max(0, rectBottom - rectY)

    z: 20
    focus: dragging

    MouseArea {
        id: mouseArea
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton
        preventStealing: true
        hoverEnabled: root.routeItemClicks

        onPressed: mouse => {
            root.marqueeGesture = false;
            const index = root.selectionView.indexAt(
                mouse.x + root.selectionView.contentX,
                mouse.y + root.selectionView.contentY);
            const inItem = root.pointInItem
                ? root.pointInItem(mouse.x, mouse.y) : index >= 0;
            if (inItem) {
                if (!root.routeItemClicks)
                    mouse.accepted = false;
                return;
            }
            root.marqueeGesture = true;
            root.startX = mouse.x;
            root.startY = mouse.y;
            root.currentX = mouse.x;
            root.currentY = mouse.y;
            root.moved = false;
            root.dragging = true;
            root.forceActiveFocus();
            root.dragStarted(mouse.modifiers);
        }

        onPositionChanged: mouse => {
            if (root.routeItemClicks && !root.dragging) {
                const index = root.selectionView.indexAt(
                    mouse.x + root.selectionView.contentX,
                    mouse.y + root.selectionView.contentY);
                root.hoveredIndex = root.pointInItem && root.pointInItem(mouse.x, mouse.y)
                    ? index : -1;
            }
            if (!root.dragging)
                return;
            root.currentX = mouse.x;
            root.currentY = mouse.y;
            root.moved = root.moved || Math.abs(mouse.x - root.startX) > 3 || Math.abs(mouse.y - root.startY) > 3;
            root.dragChanged(root.rectX, root.rectY, root.rectWidth, root.rectHeight);
        }

        onReleased: mouse => {
            if (!root.dragging)
                return;
            root.currentX = mouse.x;
            root.currentY = mouse.y;
            if (root.moved)
                root.dragFinished(root.rectX, root.rectY, root.rectWidth, root.rectHeight);
            else
                root.session.clearSelection();
            root.dragging = false;
            root.selectionView.forceActiveFocus();
        }

        onCanceled: {
            root.dragging = false;
            root.moved = false;
            root.selectionView.forceActiveFocus();
        }

        onClicked: mouse => {
            if (!root.routeItemClicks)
                return;
            if (root.marqueeGesture) {
                root.marqueeGesture = false;
                return;
            }
            const index = root.selectionView.indexAt(
                mouse.x + root.selectionView.contentX,
                mouse.y + root.selectionView.contentY);
            if (index >= 0 && root.pointInItem && root.pointInItem(mouse.x, mouse.y))
                root.itemClicked(index, mouse.modifiers);
        }

        onDoubleClicked: mouse => {
            if (!root.routeItemClicks)
                return;
            if (root.marqueeGesture) {
                root.marqueeGesture = false;
                return;
            }
            const index = root.selectionView.indexAt(
                mouse.x + root.selectionView.contentX,
                mouse.y + root.selectionView.contentY);
            if (index >= 0 && root.pointInItem && root.pointInItem(mouse.x, mouse.y))
                root.itemDoubleClicked(index, mouse.modifiers);
        }

        onExited: root.hoveredIndex = -1
    }

    Keys.onEscapePressed: event => {
        if (!root.dragging)
            return;
        root.dragging = false;
        root.moved = false;
        root.selectionView.forceActiveFocus();
        event.accepted = true;
    }

    Rectangle {
        visible: root.dragging && root.moved
        x: root.rectX
        y: root.rectY
        width: root.rectWidth
        height: root.rectHeight
        color: Qt.alpha(Theme.primary, 0.12)
        border.width: 1
        border.color: Theme.primary
    }

}
