import Foundation

/// Binds the shared skills into each agent's own instruction file.
///
/// There is no universal mechanism here. Every agent reads its instructions
/// from a different place, and none of them document a way to point at a shared
/// directory, so binding means writing into the agent's own file. That is why
/// this mirrors `AgentConfigWriter`: documented and stable formats only,
/// fenced region, backup before the first modification, and a report that says
/// what happened for every agent — including the ones nothing could be done
/// for.
///
/// The alternative — copying each skill into each agent's directory — was
/// rejected. Skills are the part of the collection a person edits most, and
/// five copies of the same text is five places for them to drift apart.
public enum SkillBinder {

    /// What happened to one agent.
    public struct Report: Sendable {
        public enum Action: String, Sendable {
            /// The instruction file now lists the shared skills.
            case bound
            /// It already said the right thing.
            case unchanged
            /// The shared skills were removed from this agent.
            case cleared
            /// This agent has no instruction file JXCode knows how to write.
            case notApplicable
        }

        public var agentID: String
        public var agentName: String
        public var action: Action
        public var path: URL?
        public var notes: [String]

        public var summary: String {
            let location = path.map { " — \($0.path)" } ?? ""
            return "\(agentName): \(action.rawValue)\(location)"
        }
    }

    // MARK: - Where each agent reads instructions

    /// The file an agent reads for standing instructions, or `nil`.
    ///
    /// Returning `nil` is a real answer, not a gap: oh-my-pi and Jules
    /// document no instruction file, and inventing one would write a file
    /// nothing ever reads. A `Plain shell` is not an agent at all.
    public static func instructionFile(
        for agent: AgentDefinition,
        paths: SandboxPaths
    ) -> URL? {
        switch agent.id {
        case "claude":   return paths.claudeMemory
        case "codex":    return paths.codexMemory
        case "gemini":   return paths.geminiMemory
        case "opencode": return paths.opencodeMemory
        default:         return nil
        }
    }

    /// Why an agent cannot be bound. Used for the report's note.
    private static func unsupportedReason(for agent: AgentDefinition) -> String {
        if agent.id == "shell" {
            return "a login shell reads no instruction file"
        }
        if agent.webURL != nil {
            return "runs against its own cloud service and takes no local instructions"
        }
        return "this agent documents no instruction file, so there is nowhere to put the skills"
    }

    // MARK: - Applying

    /// Write the shared skill list into every agent that has an instruction file.
    ///
    /// With no enabled skills the fenced region is *removed* rather than
    /// written empty. An empty block is noise in a file the user reads, and it
    /// would make "skills are switched off" indistinguishable from "skills were
    /// never configured".
    @discardableResult
    public static func apply(
        skills: [Skill],
        agents: [AgentDefinition],
        paths: SandboxPaths
    ) throws -> [Report] {
        let enabled = skills.filter(\.enabled)
        var reports: [Report] = []

        for agent in agents {
            guard let file = instructionFile(for: agent, paths: paths) else {
                reports.append(Report(
                    agentID: agent.id,
                    agentName: agent.name,
                    action: .notApplicable,
                    path: nil,
                    notes: [unsupportedReason(for: agent)]
                ))
                continue
            }
            reports.append(try bind(agent: agent, file: file, skills: enabled, paths: paths))
        }

        // Claude Code is the one agent with real skill discovery, so it gets
        // the native treatment as well as the block. Kept separate from the
        // report above because it can fail on its own.
        //
        // No need to also test for claude's presence: `reports` has exactly one
        // entry per agent, so finding its index already proves it is there.
        if let index = reports.firstIndex(where: { $0.agentID == "claude" }) {
            reports[index].notes.append(
                contentsOf: try linkClaudeSkills(skills: enabled, paths: paths)
            )
        }

        return reports
    }

    private static func bind(
        agent: AgentDefinition,
        file: URL,
        skills: [Skill],
        paths: SandboxPaths
    ) throws -> Report {
        let fm = FileManager.default
        try fm.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existed = fm.fileExists(atPath: file.path)
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""

        // Only back up a file we are about to change, and only once — a second
        // run must not overwrite a good backup with an already-modified file.
        let rendered: String
        if skills.isEmpty {
            guard ManagedBlock.contains(current, markers: .markdownSkills) else {
                return Report(
                    agentID: agent.id,
                    agentName: agent.name,
                    action: .unchanged,
                    path: file,
                    notes: ["no shared skills are enabled"]
                )
            }
            // Shape-preserving, and therefore no `+ "\n"` — the writer's
            // `removing` would collapse blank lines the user wrote, and a bind
            // that empties the list is still a bind, not a licence to reformat.
            rendered = ManagedBlock.removingPreservingShape(
                from: current,
                markers: .markdownSkills
            )
        } else {
            rendered = ManagedBlock.inserting(
                block(for: skills, paths: paths),
                into: current,
                markers: .markdownSkills
            )
        }

        if existed, current == rendered {
            return Report(
                agentID: agent.id,
                agentName: agent.name,
                action: .unchanged,
                path: file,
                notes: ["already lists \(skills.count) shared skill(s)"]
            )
        }

        // Only ever back up a file we are adding to. On a removal the file
        // already holds our own block, so a backup taken here would record our
        // content and not the user's — and because `backUp` skips when a backup
        // already exists, that wrong copy would become the permanent one.
        if existed, !skills.isEmpty { backUp(file) }

        // A file that only ever held our block is removed rather than left
        // blank: the state we found was "no file", and reverting means putting
        // it back that way.
        if existed,
           skills.isEmpty,
           rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !hasBackup(file) {
            try? fm.removeItem(at: file)
        } else {
            try rendered.write(to: file, atomically: true, encoding: .utf8)
        }

        return Report(
            agentID: agent.id,
            agentName: agent.name,
            action: skills.isEmpty ? .cleared : .bound,
            path: file,
            notes: skills.isEmpty
                ? ["removed the shared skill list"]
                : ["bound \(skills.count) skill(s)",
                   existed ? "merged into the existing file" : "created the file"]
        )
    }

    /// The fenced region itself.
    ///
    /// Paths are absolute, and that is not a detail to be tidied away later:
    /// `shared/` is a sibling of `env/`, so it is *not* under the sandbox
    /// `$HOME` an agent runs with. A relative path like `shared/skills/…`
    /// resolves to nothing, and the agent would report a missing file rather
    /// than a skill it could not find.
    static func block(for skills: [Skill], paths: SandboxPaths) -> String {
        var lines: [String] = [
            ManagedBlock.Markers.markdownSkills.start,
            "<!-- Managed by JXCode — the shared collection. Rewritten whenever the",
            "     skill list changes, so edit outside these markers. -->",
            "",
            "## Shared skills",
            "",
            "These are shared by every agent in JXCode. Read the relevant file",
            "before doing related work.",
            "",
        ]

        for skill in skills {
            let summary = skill.summary.isEmpty ? "" : " — \(skill.summary)"
            lines.append("- **\(skill.name)**\(summary)")
            // The path is given rather than the content, so a skill stays a
            // single file on disk: editing it takes effect everywhere at once,
            // with nothing to re-sync.
            lines.append("  `\(SkillStore.skillFile(id: skill.id, paths: paths).path)`")
        }

        lines.append(ManagedBlock.Markers.markdownSkills.end)
        return lines.joined(separator: "\n")
    }

    // MARK: - Claude Code's native skills

    /// Link each shared skill into `~/.claude/skills/`, where Claude Code
    /// discovers skills by name.
    ///
    /// A symlink rather than a copy, so the shared directory stays the single
    /// source of truth. A directory that already exists and is *not* one of our
    /// links is left alone and reported: the user may have their own skill
    /// under that name, and silently replacing it would delete their work.
    private static func linkClaudeSkills(skills: [Skill], paths: SandboxPaths) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: paths.claudeSkills, withIntermediateDirectories: true)

        var notes: [String] = []
        var linked = 0
        var kept = 0

        for skill in skills {
            let source = SkillStore.skillDirectory(id: skill.id, paths: paths)
            let link = paths.claudeSkills.appendingPathComponent(skill.id)

            if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if destination == source.path { linked += 1; continue }
                // A link of ours pointing somewhere stale — the skill moved.
                try? fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                kept += 1
                notes.append("left \(skill.id) alone — a skill of that name already exists in ~/.claude/skills")
                continue
            }

            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
            linked += 1
        }

        // Drop links whose skill was disabled or deleted, so switching a skill
        // off actually removes it from Claude Code rather than leaving a
        // dangling entry behind.
        let live = Set(skills.map(\.id))
        let existing = (try? fm.contentsOfDirectory(atPath: paths.claudeSkills.path)) ?? []
        var pruned = 0
        for name in existing where !live.contains(name) {
            let link = paths.claudeSkills.appendingPathComponent(name)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  destination.hasPrefix(paths.sharedSkills.path)
            else { continue }   // not ours — a real directory or a foreign link
            try? fm.removeItem(at: link)
            pruned += 1
        }

        notes.append("Claude Code skill discovery: \(linked) linked"
            + (pruned > 0 ? ", \(pruned) removed" : "")
            + (kept > 0 ? ", \(kept) left alone" : ""))
        return notes
    }

    // MARK: - Reverting

    /// Remove the fenced region from every agent's instruction file.
    @discardableResult
    public static func revert(agents: [AgentDefinition], paths: SandboxPaths) throws -> [String] {
        let fm = FileManager.default
        var messages: [String] = []

        for agent in agents {
            guard let file = instructionFile(for: agent, paths: paths) else { continue }
            guard let current = try? String(contentsOf: file, encoding: .utf8),
                  ManagedBlock.contains(current, markers: .markdownSkills)
            else { continue }

            // Shape-preserving, and therefore no `+ "\n"`: the result already
            // ends the way the file did. Using the writer's `removing` here
            // would reformat the user's text on the way out.
            let stripped = ManagedBlock.removingPreservingShape(
                from: current,
                markers: .markdownSkills
            )

            // A file that held nothing but our block is removed rather than
            // blanked. Leaving a one-byte `AGENTS.md` behind is a change to the
            // agent's tree that the user did not ask for, and it would make
            // "never configured" and "configured, then unbound" look identical.
            //
            // `revert` does not go through `bind`, so this rule has to be
            // repeated here — it is the same decision made on a different path.
            if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !hasBackup(file) {
                try? fm.removeItem(at: file)
            } else {
                try stripped.write(to: file, atomically: true, encoding: .utf8)
            }
            messages.append("cleared the shared skill list from \(file.path)")
        }

        // Only links pointing into our own shared directory are removed.
        let existing = (try? fm.contentsOfDirectory(atPath: paths.claudeSkills.path)) ?? []
        for name in existing {
            let link = paths.claudeSkills.appendingPathComponent(name)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  destination.hasPrefix(paths.sharedSkills.path)
            else { continue }
            try? fm.removeItem(at: link)
            messages.append("unlinked \(name) from Claude Code skills")
        }

        return messages
    }

    private static func backUp(_ file: URL) {
        let backup = file.appendingPathExtension("jxcode-backup")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: file, to: backup)
    }

    /// Whether a backup exists for this file.
    ///
    /// This doubles as the record that the file **predated JXCode**. `backUp`
    /// runs on the first write to a file that was already there, so a missing
    /// backup means we created it — which is what makes it safe to delete it
    /// again on revert, because the state we found was "no file".
    private static func hasBackup(_ file: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: file.appendingPathExtension("jxcode-backup").path
        )
    }
}

/// Canonical locations for a skill on disk.
///
/// Separate from `SandboxPaths` because the id is part of the path and the
/// binders need to build these from a skill that is not the one being loaded.
public enum SkillStore {
    public static func skillDirectory(id: String, paths: SandboxPaths) -> URL {
        paths.sharedSkills.appendingPathComponent(id, isDirectory: true)
    }

    public static func skillFile(id: String, paths: SandboxPaths) -> URL {
        skillDirectory(id: id, paths: paths)
            .appendingPathComponent("SKILL.md", isDirectory: false)
    }
}
