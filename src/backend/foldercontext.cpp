#include "foldercontext.h"

#include <QFile>
#include <QJsonArray>

#include <algorithm>
#include <filesystem>
#include <system_error>

namespace {
using Type = FolderContextEntry::Type;

bool hasEntry(const std::vector<FolderContextEntry> &entries, const QString &name, Type type)
{
    return std::any_of(entries.cbegin(), entries.cend(), [&](const auto &entry) {
        return entry.name == name && entry.type == type;
    });
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

QJsonObject signal(const char *id, const char *category, const QStringList &evidence)
{
    QJsonArray jsonEvidence;
    for (const QString &item : evidence)
        jsonEvidence.append(item);
    return {{"id", QString::fromLatin1(id)}, {"category", QString::fromLatin1(category)},
            {"evidence", jsonEvidence}};
}

QStringList extensionEvidence(const std::vector<FolderContextEntry> &entries,
                              const QStringList &extensions)
{
    QStringList names;
    for (const auto &entry : entries) {
        if (entry.type != Type::RegularFile)
            continue;
        for (const QString &extension : extensions) {
            if (entry.name.endsWith(extension, Qt::CaseSensitive)) {
                names.append(entry.name);
                break;
            }
        }
    }
    std::sort(names.begin(), names.end());
    names.removeDuplicates();
    return names.sliced(0, std::min<qsizetype>(3, names.size()));
}
}

QJsonObject FolderContextDetector::detect(const QString &directoryPath,
                                          const std::vector<FolderContextEntry> &entries)
{
    QJsonArray contextSignals;
    const auto add = [&](const char *id, const char *category, QStringList evidence) {
        evidence.removeAll({});
        if (!evidence.isEmpty())
            contextSignals.append(signal(id, category, evidence));
    };
    const auto file = [&](const QString &name) { return hasEntry(entries, name, Type::RegularFile); };
    const auto directory = [&](const QString &name) { return hasEntry(entries, name, Type::Directory); };

    add("agent-instructions", "ai", {file("AGENTS.md") ? "AGENTS.md" : QString(),
                                        file("AGENTS.override.md") ? "AGENTS.override.md" : QString(),
                                        directory(".agents") ? ".agents" : QString()});
    add("claude", "ai", {file("CLAUDE.md") ? "CLAUDE.md" : QString(),
                            directory(".claude") ? ".claude" : QString()});
    add("gemini", "ai", {file("GEMINI.md") ? "GEMINI.md" : QString(),
                            directory(".gemini") ? ".gemini" : QString()});
    add("cursor", "ai", {directory(".cursor") ? ".cursor" : QString(),
                            file(".cursorrules") ? ".cursorrules" : QString()});
    add("windsurf", "ai", {directory(".windsurf") ? ".windsurf" : QString(),
                              file(".windsurfrules") ? ".windsurfrules" : QString()});

    // Copilot's two markers are the only fixed nested probes. Both the parent
    // and the marker must be real directories/files, never symlinks.
    QStringList copilot;
    const std::filesystem::path root(QFile::encodeName(directoryPath).constData());
    if (directory(".github")) {
        const auto github = root / ".github";
        if (isDirectory(github / "instructions"))
            copilot.append(".github/instructions/");
        if (isRegularFile(github / "copilot-instructions.md"))
            copilot.append(".github/copilot-instructions.md");
    }
    add("copilot", "ai", copilot);

    if (directory(".git") || file(".git"))
        add("git", "vcs", {".git"});
    add("node", "technology", file("package.json") ? QStringList{"package.json"} : QStringList{});
    add("typescript", "technology", file("tsconfig.json") ? QStringList{"tsconfig.json"} : QStringList{});
    add("python", "technology", {file("pyproject.toml") ? "pyproject.toml" : QString(),
                                     file("setup.py") ? "setup.py" : QString(),
                                     file("Pipfile") ? "Pipfile" : QString(),
                                     file("requirements.txt") ? "requirements.txt" : QString()});
    add("rust", "technology", file("Cargo.toml") ? QStringList{"Cargo.toml"} : QStringList{});
    add("go", "technology", file("go.mod") ? QStringList{"go.mod"} : QStringList{});
    add("jvm", "technology", {file("pom.xml") ? "pom.xml" : QString(),
                                  file("build.gradle") ? "build.gradle" : QString(),
                                  file("build.gradle.kts") ? "build.gradle.kts" : QString()});
    QStringList cppEvidence{file("CMakeLists.txt") ? "CMakeLists.txt" : QString(),
                            file("meson.build") ? "meson.build" : QString()};
    cppEvidence.removeAll({});
    cppEvidence.append(extensionEvidence(entries, {".c", ".cc", ".cpp", ".h", ".hpp"}));
    cppEvidence = cppEvidence.sliced(0, std::min<qsizetype>(3, cppEvidence.size()));
    add("cpp", "technology", cppEvidence);
    add("ruby", "technology", file("Gemfile") ? QStringList{"Gemfile"} : QStringList{});
    add("php", "technology", file("composer.json") ? QStringList{"composer.json"} : QStringList{});
    add("swift", "technology", file("Package.swift") ? QStringList{"Package.swift"} : QStringList{});
    add("dotnet", "technology", extensionEvidence(entries, {".sln", ".csproj", ".fsproj"}));

    return {{"version", 1}, {"signals", contextSignals}};
}
