#pragma once

#include <QJsonObject>
#include <QString>
#include <QStringList>

#include <filesystem>

// Accumulates only fixed markers and three examples per extension family while
// the directory iterator is already open. It deliberately never retains the
// complete directory entry vector a second time.
class FolderContextAccumulator
{
public:
    explicit FolderContextAccumulator(QString directoryPath)
        : m_directoryPath(std::move(directoryPath)) {}

    void add(const QString &name, bool regularFile, bool directory);
    QJsonObject result() const;

private:
    void addEvidence(QStringList &target, const QString &name);
    QString m_directoryPath;
    QStringList m_agent;
    QStringList m_claude;
    QStringList m_gemini;
    QStringList m_cursor;
    QStringList m_windsurf;
    QStringList m_copilot;
    QStringList m_pythonEvidence;
    QStringList m_jvmEvidence;
    QStringList m_cpp;
    QStringList m_dotnet;
    bool m_git = false;
    bool m_node = false;
    bool m_typescript = false;
    bool m_python = false;
    bool m_rust = false;
    bool m_go = false;
    bool m_jvm = false;
    bool m_ruby = false;
    bool m_php = false;
    bool m_swift = false;
};
