import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import "qml/components" as Components

ShellRoot {
    id: root

    property var entries: JSON.parse(String(Quickshell.env("FILESAIL_IMAGE_PREVIEW_ENTRIES") ?? "[]"))
    property var firstEntry: JSON.parse(String(Quickshell.env("FILESAIL_IMAGE_PREVIEW_ENTRIES") ?? "[]"))[0]
    property var secondEntry: JSON.parse(String(Quickshell.env("FILESAIL_IMAGE_PREVIEW_SECOND") ?? "{}"))
    property real probeWidth: 730.5
    property real probeHeight: 311.25

    Window {
        id: testWindow
        visible: true
        width: 1200
        height: 420

        Components.ImageSelectionPreview {
            id: provider
            anchors.fill: parent
            entries: root.entries
        }

        Components.ImageFilePreview {
            id: probe
            x: 0
            y: 0
            width: root.probeWidth
            height: root.probeHeight
            active: true
            entry: root.entries.length > 0 ? root.entries[0] : ({
                path: "/missing", url: "file:///missing", name: "missing",
                size: 0, modified: "", mimeType: "image/png", iconName: "image-x-generic"
            })
        }
    }

    IpcHandler {
        target: "imagePreviewTest"

        function snapshot(): string {
            return JSON.stringify({
                providerReadiness: provider.previewReadiness,
                providerError: provider.previewError,
                windowWidth: testWindow.width,
                columns: provider.columnCount,
                gridAspectRatio: provider.gridAspectRatio,
                tileWidth: provider.gridMetrics.tileWidth,
                tileHeight: provider.gridMetrics.tileHeight,
                probeReadiness: probe.previewReadiness,
                probeError: probe.previewError,
                aspectRatio: probe.aspectRatio,
                sourceUrl: probe.sourceUrl.toString(),
                probeWidth: probe.width,
                decodedWidth: probe.decodedPixelWidth,
                decodedHeight: probe.decodedPixelHeight,
                loadGeneration: probe.loadGeneration
            });
        }

        function selectSecond(): void {
            root.entries = [root.secondEntry];
        }

        function selectFirst(size: string, modified: string): void {
            const next = Object.assign({}, root.firstEntry, {
                size: Number(size), modified: String(modified)
            });
            root.entries = [next];
        }

        function resizeProbe(width: string, height: string): void {
            root.probeWidth = Number(width);
            root.probeHeight = Number(height);
        }

        function resizeWindow(width: string, height: string): void {
            testWindow.width = Number(width);
            testWindow.height = Number(height);
        }
    }
}
