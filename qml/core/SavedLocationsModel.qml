pragma Singleton

import QtQuick

QtObject {
    id: root

    readonly property alias projects: projectsModel
    readonly property alias bookmarks: bookmarksModel
    property bool loading: false
    property string error: ""

    signal operationFailed(string message)

    function replace(snapshot) {
        const locations = snapshot ?? {};
        projectsModel.clear();
        bookmarksModel.clear();
        for (const entry of locations.projects ?? [])
            projectsModel.append(entry);
        for (const entry of locations.bookmarks ?? [])
            bookmarksModel.append(entry);
    }

    function reload() {
        loading = true;
        BackendClient.listLocations(result => {
            loading = false;
            error = "";
            replace(result.locations);
        }, message => {
            loading = false;
            error = message;
            Logger.warn("locations", `list failed: ${message}`);
            operationFailed(message);
        });
    }

    function addCurrentDirectory(collection, path, onSuccess, onFailure) {
        if (!path)
            return;
        BackendClient.addLocation(collection, path, result => {
            replace(result.locations);
            if (onSuccess)
                onSuccess(result);
        }, message => {
            error = message;
            if (onFailure)
                onFailure(message);
            else
                operationFailed(message);
        });
    }

    function remove(collection, id, onSuccess, onFailure) {
        BackendClient.removeLocation(collection, id, result => {
            replace(result.locations);
            if (onSuccess)
                onSuccess(result);
        }, message => {
            error = message;
            if (onFailure)
                onFailure(message);
            else
                operationFailed(message);
        });
    }

    Component.onCompleted: reload()

    property Connections backendEvents: Connections {
        target: BackendClient
        function onEventReceived(event, message) {
            if (event === "savedLocationsChanged")
                root.reload();
        }
    }

    property ListModel projectsStorage: ListModel { id: projectsModel }
    property ListModel bookmarksStorage: ListModel { id: bookmarksModel }
}
