#include "foldercontext.h"

#include <QFile>
#include <QJsonArray>

#include <algorithm>
#include <system_error>

namespace {
QJsonObject signal(const char *id, const char *category, const QStringList &evidence)
{
    QJsonArray values;
    for (const QString &item : evidence) values.append(item);
    return {{"id", QString::fromLatin1(id)}, {"category", QString::fromLatin1(category)}, {"evidence", values}};
}

QJsonObject signalIf(const char *id, const char *category, QStringList evidence)
{
    evidence.removeAll({});
    if (evidence.isEmpty()) return {};
    std::sort(evidence.begin(), evidence.end());
    evidence.removeDuplicates();
    return signal(id, category, evidence.sliced(0, std::min<qsizetype>(3, evidence.size())));
}

bool isRegularFile(const std::filesystem::path &path)
{
    std::error_code error;
    return std::filesystem::is_regular_file(std::filesystem::symlink_status(path, error));
}

bool isDirectory(const std::filesystem::path &path)
{
    std::error_code error;
    return std::filesystem::is_directory(std::filesystem::symlink_status(path, error));
}
}

void FolderContextAccumulator::addEvidence(QStringList &target, const QString &name)
{
    if (!target.contains(name)) target.append(name);
}

void FolderContextAccumulator::add(const QString &name, bool regularFile, bool directory)
{
    auto marker = [&](const QString &file, const QString &dir, QStringList &target) {
        if (regularFile && name == file) addEvidence(target, file);
        if (directory && name == dir) addEvidence(target, dir);
    };
    marker("AGENTS.md", ".agents", m_agent);
    marker("CLAUDE.md", ".claude", m_claude);
    marker("GEMINI.md", ".gemini", m_gemini);
    marker(".cursorrules", ".cursor", m_cursor);
    marker(".windsurfrules", ".windsurf", m_windsurf);
    if (directory && name == ".github") {
        const std::filesystem::path root(QFile::encodeName(m_directoryPath).constData());
        if (isDirectory(root / ".github" / "instructions")) addEvidence(m_copilot, ".github/instructions/");
        if (isRegularFile(root / ".github" / "copilot-instructions.md")) addEvidence(m_copilot, ".github/copilot-instructions.md");
    }
    if ((regularFile || directory) && (name == ".git")) m_git = true;
    if (regularFile && name == "package.json") m_node = true;
    if (regularFile && name == "tsconfig.json") m_typescript = true;
    if (regularFile && (name == "pyproject.toml" || name == "setup.py" || name == "Pipfile" || name == "requirements.txt")) { m_python = true; addEvidence(m_pythonEvidence, name); }
    if (regularFile && name == "Cargo.toml") m_rust = true;
    if (regularFile && name == "go.mod") m_go = true;
    if (regularFile && (name == "pom.xml" || name == "build.gradle" || name == "build.gradle.kts")) { m_jvm = true; addEvidence(m_jvmEvidence, name); }
    if (regularFile && name == "Gemfile") m_ruby = true;
    if (regularFile && name == "composer.json") m_php = true;
    if (regularFile && name == "Package.swift") m_swift = true;
    if (regularFile && (name == "CMakeLists.txt" || name == "meson.build")) addEvidence(m_cpp, name);
    if (regularFile && (name.endsWith(".c") || name.endsWith(".cc") || name.endsWith(".cpp") || name.endsWith(".h") || name.endsWith(".hpp"))) addEvidence(m_cpp, name);
    if (regularFile && (name.endsWith(".sln") || name.endsWith(".csproj") || name.endsWith(".fsproj"))) addEvidence(m_dotnet, name);
}

QJsonObject FolderContextAccumulator::result() const
{
    QJsonArray signalArray;
    const auto add = [&](const char *id, const char *category, QStringList evidence) {
        const QJsonObject item = signalIf(id, category, std::move(evidence));
        if (!item.isEmpty()) signalArray.append(item);
    };
    add("agent-instructions", "ai", m_agent);
    add("claude", "ai", m_claude);
    add("gemini", "ai", m_gemini);
    add("cursor", "ai", m_cursor);
    add("windsurf", "ai", m_windsurf);
    add("copilot", "ai", m_copilot);
    if (m_git) add("git", "vcs", {".git"});
    if (m_node) add("node", "technology", {"package.json"});
    if (m_typescript) add("typescript", "technology", {"tsconfig.json"});
    if (m_python) add("python", "technology", m_pythonEvidence);
    if (m_rust) add("rust", "technology", {"Cargo.toml"});
    if (m_go) add("go", "technology", {"go.mod"});
    if (m_jvm) add("jvm", "technology", m_jvmEvidence);
    add("cpp", "technology", m_cpp);
    if (m_ruby) add("ruby", "technology", {"Gemfile"});
    if (m_php) add("php", "technology", {"composer.json"});
    if (m_swift) add("swift", "technology", {"Package.swift"});
    add("dotnet", "technology", m_dotnet);
    return {{"version", 1}, {"signals", signalArray}};
}
