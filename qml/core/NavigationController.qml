import QtQuick
import Quickshell

QtObject {
    id: root

    readonly property string homePath: String(Quickshell.env("HOME") ?? "/")
    property string initialPath: homePath
    property var history: [initialPath]
    property int historyIndex: 0
    readonly property string currentPath: history[historyIndex] ?? homePath
    readonly property bool canGoBack: historyIndex > 0
    readonly property bool canGoForward: historyIndex < history.length - 1

    signal navigationRequested(string path, int historyTarget, string origin)

    function navigate(path, origin) {
        // Leading and trailing spaces are legal filename bytes. Validation and
        // canonicalization are owned by the backend.
        const nextPath = String(path ?? "");
        if (!nextPath || nextPath === currentPath)
            return;
        navigationRequested(nextPath, -1, String(origin ?? "user"));
    }

    function back(origin) {
        if (!canGoBack)
            return;
        navigationRequested(history[historyIndex - 1], historyIndex - 1, String(origin ?? "user"));
    }

    function forward(origin) {
        if (!canGoForward)
            return;
        navigationRequested(history[historyIndex + 1], historyIndex + 1, String(origin ?? "user"));
    }

    function up(origin) {
        if (currentPath === "/")
            return;
        const parts = currentPath.split('/').filter(Boolean);
        parts.pop();
        navigate('/' + parts.join('/'), origin);
    }

    function home(origin) {
        navigate(homePath, origin);
    }

    function commit(path, historyTarget) {
        const resolvedPath = String(path ?? "");
        if (!resolvedPath)
            return;
        if (historyTarget >= 0 && historyTarget < history.length) {
            const resolvedHistory = history.slice();
            resolvedHistory[historyTarget] = resolvedPath;
            history = resolvedHistory;
            historyIndex = historyTarget;
            return;
        }
        if (resolvedPath === currentPath)
            return;
        const nextHistory = history.slice(0, historyIndex + 1);
        nextHistory.push(resolvedPath);
        history = nextHistory;
        historyIndex = history.length - 1;
    }
}
