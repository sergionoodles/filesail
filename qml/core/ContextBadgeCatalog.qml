pragma Singleton

import QtQuick

QtObject {
    function details(signal) {
        signal = signal ?? {};
        const entries = {
            "agent-instructions": [qsTr("Agent instructions"), "bot"], claude: [qsTr("Claude Code"), "bot"],
            gemini: [qsTr("Gemini CLI"), "bot"], cursor: [qsTr("Cursor"), "bot"], windsurf: [qsTr("Windsurf"), "bot"],
            copilot: [qsTr("GitHub Copilot"), "bot"], git: [qsTr("Git"), "git-branch"],
            node: [qsTr("Node.js"), "code-2"], typescript: [qsTr("TypeScript"), "code-2"],
            python: [qsTr("Python"), "code-2"], rust: [qsTr("Rust"), "code-2"], go: [qsTr("Go"), "code-2"],
            jvm: [qsTr("JVM"), "code-2"], cpp: [qsTr("C/C++"), "code-2"], ruby: [qsTr("Ruby"), "code-2"],
            php: [qsTr("PHP"), "code-2"], swift: [qsTr("Swift"), "code-2"], dotnet: [qsTr(".NET"), "code-2"]
        };
        const entry = entries[signal.id] ?? [qsTr("Folder marker"), "folder"];
        return { label: entry[0], iconName: entry[1], evidence: signal.evidence ?? [] };
    }
    function categoryOrder(category) {
        return category === "ai" ? 0 : category === "vcs" ? 1 : 2;
    }
}
