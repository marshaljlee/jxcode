import Foundation

/// Seeds a fresh sandbox from the host's existing agent config.
///
/// Isolation is the goal, but starting from an empty sandbox means retyping
/// every setting. This copies a curated subset once, then the two diverge
/// permanently — nothing is symlinked back to the host, so later edits inside
/// the sandbox cannot touch the originals.
///
/// Two deliberate choices:
///
/// - **Symlinks are recreated, not followed.** The host `~/.claude/skills` is
///   often a symlink (into iCloud, or a shared repo). A plain `cp -r` would
///   dereference it and duplicate gigabytes; `FileManager.copyItem` behaviour
///   here is subtle enough that links are handled explicitly.
/// - **Session state is skipped.** `projects/`, `todos/`, `shell-snapshots/`
///   and history files are large, machine-specific, and useless in a fresh
///   sandbox.
public enum ImportService {

    public enum Kind: String, Sendable {
        case file
        case directory
        case symlink
    }

    public struct Entry: Sendable {
        public let source: URL
        public let destination: URL
        public let kind: Kind
        /// Where a symlink points, when it points outside the host config dir.
        public let linkTarget: String?
        /// True when the link escapes the host config directory.
        public let escapesHostConfig: Bool
    }

    public struct Plan: Sendable {
        public let entries: [Entry]
        public let skipped: [(path: String, reason: String)]

        public var isEmpty: Bool { entries.isEmpty }
    }

    // MARK: - Rules

    /// `(host relative path, sandbox relative path)`.
    private static let rules: [(String, String)] = [
        (".claude/CLAUDE.md",            "home/.claude/CLAUDE.md"),
        (".claude/settings.json",        "home/.claude/settings.json"),
        (".claude/settings.local.json",  "home/.claude/settings.local.json"),
        (".claude/skills",               "home/.claude/skills"),
        (".claude/agents",               "home/.claude/agents"),
        (".claude/commands",             "home/.claude/commands"),
        (".codex/config.toml",           "home/.codex/config.toml"),
        (".codex/AGENTS.md",             "home/.codex/AGENTS.md"),
        (".gemini/settings.json",        "home/.gemini/settings.json"),
        (".zshrc",                       "zsh/.zshrc.user"),
        (".zprofile",                    "zsh/.zprofile.user"),
    ]

    /// Known-large or machine-specific paths we never copy.
    private static let skipReasons: [String: String] = [
        ".claude/projects":          "session history, machine-specific and large",
        ".claude/todos":             "session state",
        ".claude/shell-snapshots":   "shell snapshots",
        ".claude/statsig":           "telemetry cache",
        ".claude/history.jsonl":     "command history",
        ".codex/sessions":           "session history",
        ".codex/log":                "logs",
        ".codex/history.jsonl":      "command history",
    ]

    // MARK: - Planning

    public static func plan(paths: SandboxPaths, realHome: String) -> Plan {
        let fm = FileManager.default
        var entries: [Entry] = []
        var skipped: [(String, String)] = []

        for (sourceRelative, destinationRelative) in rules {
            let source = URL(fileURLWithPath: realHome).appendingPathComponent(sourceRelative)
            // Destinations in `rules` are relative to the environment root, not
            // the sandbox root — so `home/.claude` resolves to $HOME/.claude.
            let destination = paths.envRoot.appendingPathComponent(destinationRelative)

            guard fm.fileExists(atPath: source.path) else {
                skipped.append((sourceRelative, "not present on host"))
                continue
            }

            let kind = kindOf(source, fm: fm)
            var linkTarget: String?
            var escapes = false

            if kind == .symlink {
                linkTarget = try? fm.destinationOfSymbolicLink(atPath: source.path)
                if let target = linkTarget {
                    let resolved = URL(fileURLWithPath: target, relativeTo: source.deletingLastPathComponent())
                    let configRoot = URL(fileURLWithPath: realHome).appendingPathComponent(
                        (sourceRelative as NSString).deletingLastPathComponent
                    )
                    escapes = !resolved.standardizedFileURL.path.hasPrefix(configRoot.standardizedFileURL.path)
                }
            }

            entries.append(Entry(
                source: source,
                destination: destination,
                kind: kind,
                linkTarget: linkTarget,
                escapesHostConfig: escapes
            ))
        }

        for (path, reason) in skipReasons where fm.fileExists(atPath: URL(fileURLWithPath: realHome).appendingPathComponent(path).path) {
            skipped.append((path, reason))
        }

        return Plan(entries: entries, skipped: skipped.sorted { $0.0 < $1.0 })
    }

    // MARK: - Applying

    /// Copy the plan. Existing destinations are left untouched unless
    /// `overwrite` is set.
    @discardableResult
    public static func apply(_ plan: Plan, overwrite: Bool = false) throws -> [String] {
        let fm = FileManager.default
        var messages: [String] = []

        for entry in plan.entries {
            let destination = entry.destination
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            if fm.fileExists(atPath: destination.path) {
                if overwrite {
                    try fm.removeItem(at: destination)
                } else {
                    messages.append("kept existing \(destination.lastPathComponent)")
                    continue
                }
            }

            switch entry.kind {
            case .symlink:
                guard let target = entry.linkTarget else { continue }
                try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
                let flag = entry.escapesHostConfig ? "  (points outside the host config dir)" : ""
                messages.append("linked \(destination.lastPathComponent) -> \(target)\(flag)")

            case .file, .directory:
                try fm.copyItem(at: entry.source, to: destination)
                messages.append("copied \(destination.lastPathComponent)")
            }
        }

        return messages
    }

    // MARK: - Helpers

    private static func kindOf(_ url: URL, fm: FileManager) -> Kind {
        if let attributes = try? fm.attributesOfItem(atPath: url.path),
           let type = attributes[.type] as? FileAttributeType {
            if type == .typeSymbolicLink { return .symlink }
            if type == .typeDirectory { return .directory }
        }
        return .file
    }

    /// Render a plan for confirmation before anything is written.
    public static func render(_ plan: Plan, paths: SandboxPaths) -> String {
        var lines: [String] = []

        if plan.entries.isEmpty {
            lines.append("Nothing to import.")
        } else {
            lines.append("Will copy into the sandbox:")
            for entry in plan.entries {
                let marker: String
                switch entry.kind {
                case .symlink:   marker = "link"
                case .directory: marker = "dir "
                case .file:      marker = "file"
                }
                let escape = entry.escapesHostConfig ? "  [symlink escapes host config]" : ""
                lines.append("  [\(marker)] \(entry.source.path)")
                lines.append("         -> \(paths.display(entry.destination))\(escape)")
            }
        }

        if !plan.skipped.isEmpty {
            lines.append("")
            lines.append("Skipped:")
            for (path, reason) in plan.skipped {
                lines.append("  \(path) — \(reason)")
            }
        }

        return lines.joined(separator: "\n")
    }
}
