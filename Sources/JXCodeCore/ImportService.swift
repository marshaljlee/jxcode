import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// `RENAME_SWAP`, for `renameatx_np`. The macro is not imported into Swift, and
/// the value is verified by test rather than assumed: `renameatx_np` with a
/// wrong flag fails rather than swapping, so a mistake here is loud.
private let jxRenameSwap: UInt32 = 0x0000_0002

/// Seeds a fresh sandbox from the host's existing agent config.
///
/// Isolation is the goal, but starting from an empty sandbox means retyping
/// every setting. This copies a curated subset once, then the two diverge
/// permanently — nothing is symlinked back to the host, so later edits inside
/// the sandbox cannot touch the originals.
///
/// Two deliberate choices:
///
/// - **Symlinks are followed unless following them is safe.** The host
///   `~/.claude/skills` is often a symlink \u2014 into iCloud, or a shared repo.
///   Recreating that link inside the sandbox hands the sandbox a live path to
///   the host: every write to `$HOME/.claude/skills` in there lands on the real
///   one, which is what the sandbox exists to prevent. So a link is recreated
///   only when, once placed at the destination, it resolves inside the sandbox
///   and to something that exists; otherwise the contents are copied in its
///   place. `FileManager.copyItem` is no help here: handed a symlink it copies
///   the symlink, so the escape survives the copy one level down.
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
        /// Where a symlink points, exactly as it is written in the host file.
        public let linkTarget: String?
        /// True when the link, recreated at the destination, would point
        /// somewhere outside the sandbox. Such a link is copied as content
        /// instead, so the sandbox never holds a path back to the host.
        public let escapesSandbox: Bool
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
        let boundary = paths.root.resolvingSymlinksInPath()

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
                // The question is not where the link points at home but where it
                // would point once recreated at the destination, because the
                // host's relative layout is not reproduced inside the sandbox.
                // A target under the real home is absolute far more often than
                // not, and every one of those is outside the sandbox.
                if let target = linkTarget {
                    escapes = !Self.isWithin(
                        Self.relocation(of: target, into: destination),
                        boundary
                    )
                } else {
                    // An unreadable link is treated as escaping: copying is the
                    // only thing that can be done with it, and it is the safe
                    // default.
                    escapes = true
                }
            }

            entries.append(Entry(
                source: source,
                destination: destination,
                kind: kind,
                linkTarget: linkTarget,
                escapesSandbox: escapes
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
            let parent = destination.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)

            // `fileExists` follows links, so a destination that is a *broken*
            // link reads as absent — and the write below then fails with
            // "file exists". `attributesOfItem` is `lstat`: it reports the link
            // itself, broken or not.
            if Self.exists(at: destination, fm: fm) {
                guard overwrite else {
                    messages.append("kept existing \(destination.lastPathComponent)")
                    continue
                }
            }

            // Built beside the destination and swapped in once complete. The
            // destination is never removed first: `removeItem` followed by
            // `copyItem` leaves *nothing* at the destination if the copy fails
            // part way through, which for a large skills directory is a real
            // window and a real loss.
            let staged = parent.appendingPathComponent(
                ".\(destination.lastPathComponent).jxcode-import-\(UUID().uuidString)"
            )
            defer { try? fm.removeItem(at: staged) }

            switch entry.kind {
            case .symlink:
                guard let target = entry.linkTarget else { continue }
                let relocated = Self.relocation(of: target, into: destination)
                if !entry.escapesSandbox, Self.exists(at: relocated, fm: fm) {
                    try fm.createSymbolicLink(atPath: staged.path, withDestinationPath: target)
                    messages.append("linked \(destination.lastPathComponent) -> \(target)")
                } else {
                    let reason = entry.escapesSandbox
                        ? "points outside the sandbox"
                        : "would dangle there"
                    try Self.copyContents(of: entry.source, to: staged, fm: fm)
                    messages.append(
                        "copied \(destination.lastPathComponent) "
                            + "(a link to \(target) that \(reason))"
                    )
                }

            case .file, .directory:
                try Self.copyContents(of: entry.source, to: staged, fm: fm)
                messages.append("copied \(destination.lastPathComponent)")
            }

            try Self.place(staged, at: destination, fm: fm)
        }

        return messages
    }

    // MARK: - Helpers

    /// Whether anything exists at `url`, including a broken symbolic link.
    private static func exists(at url: URL, fm: FileManager) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    /// Where a link would point once recreated at `destination`.
    ///
    /// Resolved, because the comparison that uses this is against a resolved
    /// boundary: `/var` and `/private/var` are one directory, and a string
    /// prefix test against the wrong spelling answers "outside" for both.
    private static func relocation(of target: String, into destination: URL) -> URL {
        URL(fileURLWithPath: target, relativeTo: destination.deletingLastPathComponent())
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    /// True when `url` is `boundary` itself or lies beneath it.
    private static func isWithin(_ url: URL, _ boundary: URL) -> Bool {
        let path = url.path
        let root = boundary.path
        return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Copy what `source` holds, not what it points at.
    ///
    /// `copyItem` alone is not enough: handed a symlink it copies the symlink,
    /// so a tree copied that way still carries a path out of the sandbox. The
    /// resolved source is copied, then every link in the result is replaced by
    /// the thing it points at.
    private static func copyContents(of source: URL, to destination: URL, fm: FileManager) throws {
        let resolved = source.resolvingSymlinksInPath()
        try fm.copyItem(at: resolved, to: destination)
        var seen: Set<String> = [resolved.path]
        try Self.replaceLinks(under: destination, fm: fm, seen: &seen, depth: 0)
    }

    /// How far `replaceLinks` will descend.
    ///
    /// A backstop rather than the defence: a link to a parent directory is a
    /// loop, and `seen` is what stops it.
    private static let maxLinkDepth = 8

    private static func replaceLinks(
        under root: URL,
        fm: FileManager,
        seen: inout Set<String>,
        depth: Int
    ) throws {
        guard depth <= maxLinkDepth else { return }
        // Not a directory: nothing below it to walk.
        guard let children = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []
        ) else { return }

        for child in children {
            let isLink = (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink
                ?? false

            if isLink {
                let target = child.resolvingSymlinksInPath()
                let isDirectory = (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
                    ?? false
                try fm.removeItem(at: child)

                // Both sides are canonicalised before being compared. They
                // disagree otherwise: `contentsOfDirectory` hands back
                // `/private/var/...` while `resolvingSymlinksInPath` returns
                // `/var/...`, and a prefix test between the two spellings
                // answers "not inside" for a link that points at the very
                // directory it sits in.
                let container = child.deletingLastPathComponent().resolvingSymlinksInPath()

                // Checked before the copy, not after, and for two different
                // ways a directory can already be here.
                //
                // `isWithin` catches the link that points at the directory it
                // sits in, or at an ancestor of it. `copyItem` asked to copy a
                // directory into its own subtree does not stop: it discovers
                // the copy it is writing as one of the source's own children
                // and nests it, once per level, until the path grows past what
                // the filesystem accepts. It fails with a name that is too
                // long, not with an error anyone would trace back here.
                //
                // `seen` catches the rest — a cycle of two links, or a second
                // link to a directory already copied. Files are duplicated
                // freely; copying one cannot grow the tree.
                if isDirectory, Self.isWithin(container, target) || seen.contains(target.path) {
                    continue
                }
                // A link to nothing leaves nothing. Dropping it beats
                // recreating a link that would dangle here as it did at home.
                guard Self.exists(at: target, fm: fm) else { continue }

                try fm.copyItem(at: target, to: child)
                guard !isDirectory else {
                    seen.insert(target.path)
                    try Self.replaceLinks(under: child, fm: fm, seen: &seen, depth: depth + 1)
                    continue
                }
                continue
            }

            guard seen.insert(child.resolvingSymlinksInPath().path).inserted else { continue }
            try Self.replaceLinks(under: child, fm: fm, seen: &seen, depth: depth + 1)
        }
    }

    /// Put the finished `staged` item at `destination`.
    ///
    /// Swapped, not removed and rebuilt. `renameatx_np` with `RENAME_SWAP` is
    /// the only thing here that replaces a directory in one step: `rename`
    /// refuses with `ENOTEMPTY`, and `FileManager.replaceItemAt` refuses
    /// outright when the destination is a symbolic link (it reports the
    /// destination as missing, which is worse than a plain failure because it
    /// looks like a bug in the caller). Either way the destination survives
    /// untouched until the replacement already exists.
    private static func place(_ staged: URL, at destination: URL, fm: FileManager) throws {
        guard Self.exists(at: destination, fm: fm) else {
            try fm.moveItem(at: staged, to: destination)
            return
        }

        #if canImport(Darwin)
        if renameatx_np(
            AT_FDCWD, staged.path,
            AT_FDCWD, destination.path,
            jxRenameSwap
        ) == 0 {
            // `staged` now holds the replaced item; the caller's `defer` removes
            // it, which is what overwrite is supposed to mean.
            return
        }
        #endif

        _ = try fm.replaceItemAt(destination, withItemAt: staged)
    }

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
                let escape = entry.escapesSandbox ? "  [escapes the sandbox: contents copied]" : ""
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
