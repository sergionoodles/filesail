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
        sourceComponent: root.selectedEntries.length === 0 ? emptyPreview
            : root.allImages ? imagePreview : root.visual ? visualPreview : root.text ? textPreview : root.archive ? archivePreview : metadataPreview
    }
    Component {
        id: emptyPreview
        Item {
            Column {
                anchors.centerIn: parent
                width: Math.min(parent.width - Theme.spaceXl * 2, 250 * Theme.scale)
                spacing: Theme.spaceM

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: 64 * Theme.scale
                    height: width
                    color: Qt.alpha(Theme.primary, 0.10)
                    border.width: 1
                    border.color: Qt.alpha(Theme.primary, 0.38)

                    LucideIcon {
                        anchors.centerIn: parent
                        name: "image"
                        iconSize: 28 * Theme.scale
                        iconColor: Theme.primary
                    }
                }
                Text {
                    width: parent.width
                    text: qsTr("Nothing to preview")
                    color: Theme.text
                    font.pixelSize: Theme.fontTitle
                    font.weight: Font.DemiBold
                    horizontalAlignment: Text.AlignHCenter
                }
                Text {
                    width: parent.width
                    text: qsTr("Select a file to see its preview here.")
                    color: Theme.textMuted
                    font.pixelSize: Theme.fontBody
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.Wrap
                }
            }
        }
    }
    Component { id: metadataPreview; FileMetadataPreview { entries: root.selectedEntries } }
    Component { id: imagePreview; ImageSelectionPreview { entries: root.selectedEntries; selectionRevision: root.selectionRevision } }
    Component { id: visualPreview; VisualFilePreview { entry: root.primary } }
    Component { id: textPreview; TextFilePreview { entry: root.primary } }
    Component { id: archivePreview; ArchivePreview { entry: root.primary } }
}
