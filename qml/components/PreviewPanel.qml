import QtQuick
import QtQuick.Layouts
import "../core"

Rectangle {
    id: root
    property var selectedEntries: []
    property int selectionRevision: 0
    color: Theme.surfaceVariant
    radius: Theme.radiusM
    clip: true
    readonly property bool allImages: selectedEntries.length > 0 && selectedEntries.every(entry => entry.mimeType.indexOf("image/") === 0)
    readonly property var primary: selectedEntries.length === 1 ? selectedEntries[0] : null
    readonly property bool visual: primary && (primary.mimeType.indexOf("video/") === 0 || primary.mimeType === "application/pdf")
    readonly property bool text: primary && (primary.mimeType.indexOf("text/") === 0 || primary.name.match(/\.(md|markdown|mdown|cpp|c|h|qml|js|ts|json|py|sh)$/i))
    readonly property bool archive: primary && primary.name.match(/\.(zip|tar|tgz|gz|xz|zst|7z|rar|cpio|iso)$/i)
    Loader {
        id: providerLoader
        anchors.fill: parent
        sourceComponent: root.allImages ? imagePreview : root.visual ? visualPreview : root.text ? textPreview : root.archive ? archivePreview : metadataPreview
    }
    Component { id: metadataPreview; FileMetadataPreview { entries: root.selectedEntries } }
    Component { id: imagePreview; ImageSelectionPreview { entries: root.selectedEntries; selectionRevision: root.selectionRevision } }
    Component { id: visualPreview; VisualFilePreview { entry: root.primary } }
    Component { id: textPreview; TextFilePreview { entry: root.primary } }
    Component { id: archivePreview; ArchivePreview { entry: root.primary } }
}
