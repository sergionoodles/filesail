pragma Singleton

import QtQuick

QtObject {
    readonly property var entries: ({
            "agent-instructions": [qsTr("Agent instructions"), "bot", "#7aa2f7"],
            claude: [qsTr("Claude Code"), "bot", "#ff9e64"],
            gemini: [qsTr("Gemini CLI"), "bot", "#7dcfff"],
            cursor: [qsTr("Cursor"), "bot", "#bb9af7"],
            windsurf: [qsTr("Windsurf"), "bot", "#2ac3de"],
            copilot: [qsTr("GitHub Copilot"), "bot", "#9ece6a"],
            git: [qsTr("Git"), "git-branch", "#f7768e"],
            node: [qsTr("Node.js"), "code-2", "#73daca"],
            typescript: [qsTr("TypeScript"), "code-2", "#82aaff"],
            python: [qsTr("Python"), "code-2", "#e0af68"],
            rust: [qsTr("Rust"), "code-2", "#e07a5f"],
            go: [qsTr("Go"), "code-2", "#4fd6be"],
            jvm: [qsTr("JVM"), "code-2", "#ff6c6b"],
            cpp: [qsTr("C/C++"), "code-2", "#89ddff"],
            ruby: [qsTr("Ruby"), "code-2", "#e06c75"],
            php: [qsTr("PHP"), "code-2", "#9d7cd8"],
            swift: [qsTr("Swift"), "code-2", "#fca7ea"],
            dotnet: [qsTr(".NET"), "code-2", "#c4a7e7"]
        })
    function details(signal) {
        signal = signal ?? {};
        const entry = entries[signal.id] ?? [qsTr("Folder marker"), "folder", "#9aa5ce"];
        return { label: entry[0], iconName: entry[1], accent: entry[2], evidence: signal.evidence ?? [] };
    }
    function categoryOrder(category) {
        return category === "ai" ? 0 : category === "vcs" ? 1 : 2;
    }
}
