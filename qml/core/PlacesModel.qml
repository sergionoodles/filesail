pragma Singleton

import QtCore
import QtQml
import QtQml.Models

QtObject {
    id: root

    // A shared shape for built-in places, host-provided favourites, and future
    // volume entries. Hosts can inject a ListModel with the same roles into
    // Sidebar without teaching the view where a location lives.
    readonly property ListModel model: ListModel {}
    readonly property string homePath: writablePath(StandardPaths.HomeLocation)

    function localPath(location) {
        const value = String(location);
        if (!value.startsWith("file://"))
            return value;
        return decodeURIComponent(value.slice(7));
    }

    function writablePath(location) {
        return localPath(StandardPaths.writableLocation(location));
    }

    function appendPlace(label, icon, path, kind) {
        if (path.length === 0)
            return;
        model.append({
            label: label,
            iconName: icon,
            path: path,
            kind: kind
        });
    }

    function reload() {
        model.clear();

        appendPlace(qsTr("Home"), "user-home", homePath, "place");
        appendPlace(qsTr("Desktop"), "user-desktop", writablePath(StandardPaths.DesktopLocation), "place");
        appendPlace(qsTr("Documents"), "folder-documents", writablePath(StandardPaths.DocumentsLocation), "place");
        appendPlace(qsTr("Downloads"), "folder-download", writablePath(StandardPaths.DownloadLocation), "place");
        appendPlace(qsTr("Pictures"), "folder-pictures", writablePath(StandardPaths.PicturesLocation), "place");
        appendPlace(qsTr("Music"), "folder-music", writablePath(StandardPaths.MusicLocation), "place");
        appendPlace(qsTr("Videos"), "folder-videos", writablePath(StandardPaths.MoviesLocation), "place");

        // Qt resolves GenericDataLocation through XDG_DATA_HOME. This is the
        // freedesktop per-user Trash; future mounted-volume entries use the
        // same { label, icon, path, kind } contract.
        appendPlace(qsTr("Trash"), "user-trash", writablePath(StandardPaths.GenericDataLocation) + "/Trash/files", "trash");
    }

    Component.onCompleted: reload()
}
