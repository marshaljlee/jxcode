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

        // A skill with a blocking finding is bound nowhere — not linked, and
        // not listed in the markdown block either. A bind is a claim that the
        // agent will find the skill, and making that claim about a file the
        // agent rejects is worse than not binding: the link is on disk, the
        // report says success, and the skill never loads.
        let bindable = enabled.filter(\.isBindableNatively)
        let refused = enabled.filter { !$0.isBindableNatively }

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
            reports.append(try bind(agent: agent, file: file, skills: bindable, paths: paths))
        }

        // Everything from here is the native half: symlinks into the
        // directories the agents scan themselves, so each agent does its own
        // discovery and its own progressive disclosure. The markdown block
        // above stays for any agent that has no such directory.
        for target in nativeTargets(paths: paths) {
            let notes = try link(
                skills: bindable,
                refused: refused,
                into: target,
                paths: paths
            )
            // The same notes on every agent that reads this directory. One link
            // has several readers, and a report that mentioned it under only
            // one of them would read as though the others had been skipped.
            for id in target.agentIDs {
                guard let index = reports.firstIndex(where: { $0.agentID == id }) else { continue }
                reports[index].notes.append(contentsOf: notes)
            }
        }

        // opencode discovers a skill and then hides it again unless
        // `permission.skill` allows it, so for that agent the link above is
        // only half a bind. Written in the same pass, deliberately: a link
        // without the permission is a bind that looks applied and does
        // nothing, which is the failure this whole file exists to avoid.
        if let note = try allowOpencodeSkills(skills: bindable, paths: paths),
           let index = reports.firstIndex(where: { $0.agentID == "opencode" }) {
            reports[index].notes.append(note)
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
                    notes: ["no shared skills to list"]
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
        // content and not the user's — and because `ConfigFiles.backUp` skips when a backup
        // already exists, that wrong copy would become the permanent one.
        //
        // A file that did not exist is recorded as ours instead. The instruction
        // files are written by `SystemPrompt` too, and without this the second
        // writer would back up the first one's file and claim the user wrote it.
        //
        // The directory is created *here* rather than at the top, because every
        // path above can return without writing anything. Making it up front put
        // `~/.config/opencode/` and both `skills/` directories into an agent's
        // home as a side effect of a bind that had nothing to bind — a bind that
        // printed "no shared skills to list" and left three directories behind.
        try ConfigFiles.createDirectory(at: file.deletingLastPathComponent(), upTo: paths.home)

        if existed, !skills.isEmpty {
            ConfigFiles.backUp(file)
        } else if !existed {
            ConfigFiles.markCreated(file)
        }

        // A file that only ever held our block is removed rather than left
        // blank: the state we found was "no file", and reverting means putting
        // it back that way.
        if existed,
           skills.isEmpty,
           rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !ConfigFiles.hasBackup(file) {
            ConfigFiles.remove(file)
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

    // MARK: - Native skill directories

    /// A directory an agent scans for skills by itself, and who reads it.
    public struct NativeTarget: Sendable, Equatable {
        public var label: String
        public var directory: URL
        /// The agents that discover skills here. opencode appears in both
        /// targets, because it scans both directories.
        public var agentIDs: [String]
    }

    /// Every directory JXCode links into, in the order it links them.
    ///
    /// Two targets, four agents. The overlap is the one thing worth knowing
    /// about this table: opencode scans `~/.claude/skills/` **and**
    /// `~/.agents/skills/`, so a skill linked into both is discovered twice and
    /// opencode resolves that collision last-writer-wins, with a warning. The
    /// content is byte-identical — both links resolve to the same directory —
    /// so the warning is the whole cost, and it is worth paying to avoid
    /// leaving either Claude Code, or Codex and Gemini, without native skills.
    ///
    /// Linking into a single directory is not an option. `~/.claude/skills/`
    /// alone reaches two of the four agents; `~/.agents/skills/` alone reaches
    /// three and misses the one agent that has had skill discovery longest.
    public static func nativeTargets(paths: SandboxPaths) -> [NativeTarget] {
        [
            NativeTarget(
                label: "Claude Code",
                directory: paths.claudeSkills,
                agentIDs: ["claude", "opencode"]
            ),
            NativeTarget(
                label: "Codex, Gemini and opencode",
                directory: paths.agentsSkills,
                agentIDs: ["codex", "gemini", "opencode"]
            ),
        ]
    }

    /// Link every bindable skill into one native directory.
    ///
    /// A symlink rather than a copy, so the shared directory stays the single
    /// source of truth and an edit is live in every agent at once. A directory
    /// that already exists and is *not* one of our links is left alone and
    /// reported: the user may have their own skill under that name, and
    /// silently replacing it would delete their work.
    private static func link(
        skills: [Skill],
        refused: [Skill],
        into target: NativeTarget,
        paths: SandboxPaths
    ) throws -> [String] {
        let fm = FileManager.default

        // Created only when there is something to put in it. An empty bind must
        // not make `~/.claude/skills/` or `~/.agents/skills/` exist: each is the
        // container for our links, and with no links there is nothing to
        // contain. The prune below still runs either way — a directory that
        // already exists can hold links whose skills were disabled, and clearing
        // those is a real part of what an empty bind does.
        if !skills.isEmpty {
            try ConfigFiles.createDirectory(at: target.directory, upTo: paths.home)
        }

        var notes: [String] = []
        var linked = 0
        var kept = 0

        for skill in skills {
            let source = SkillStore.skillDirectory(id: skill.id, paths: paths)
            let link = target.directory.appendingPathComponent(skill.id)

            if let destination = try? fm.destinationOfSymbolicLink(atPath: link.path) {
                if destination == source.path { linked += 1; continue }
                // A link of ours pointing somewhere stale — the skill moved.
                try? fm.removeItem(at: link)
            } else if fm.fileExists(atPath: link.path) {
                kept += 1
                notes.append("left \(skill.id) alone — a skill of that name already exists in "
                    + paths.display(target.directory))
                continue
            }

            try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: source.path)
            linked += 1
        }

        // Drop links whose skill was disabled or deleted, so switching a skill
        // off actually removes it from the agent rather than leaving a dangling
        // entry behind. Only links pointing into our own shared directory are
        // removed; a real directory or a foreign link under the same name is
        // not ours to delete.
        let live = Set(skills.map(\.id))
        let existing = (try? fm.contentsOfDirectory(atPath: target.directory.path)) ?? []
        var pruned = 0
        for name in existing where !live.contains(name) {
            let link = target.directory.appendingPathComponent(name)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path),
                  linkURL(destination, at: link).isContained(in: paths.sharedSkills)
            else { continue }
            try? fm.removeItem(at: link)
            pruned += 1
        }

        // Said out loud rather than counted. A bind that quietly skips a skill
        // is the same silent failure as a bind that quietly succeeds at one the
        // agent will reject, and the reason is the only part the user can act
        // on.
        for skill in refused {
            let reason = skill.findings.first { $0.severity == .blocking }?.message
                ?? "it does not meet the skill specification"
            notes.append("refused to link \(skill.id) — \(reason)")
        }

        notes.append("\(target.label) skill discovery: \(linked) linked"
            + (pruned > 0 ? ", \(pruned) removed" : "")
            + (kept > 0 ? ", \(kept) left alone" : ""))
        return notes
    }

    // MARK: - opencode's permission gate

    /// Let the shared skills through opencode's `permission.skill` gate.
    ///
    /// The entry is written only when the key is **absent**. A user who has
    /// written `"*": "deny"` has said something JXCode has no business
    /// overruling, and flipping it to `allow` on their behalf — during a bind
    /// they asked for, for reasons that had nothing to do with permissions — is
    /// a silent security change. A value that is already there is therefore
    /// reported and left exactly as it was.
    ///
    /// With no bindable skills the grant is *taken back* rather than written.
    /// Writing it for an empty collection was worse than untidy: it created
    /// `opencode.json` and a manifest claiming a grant, on a bind that had
    /// nothing to bind and printed "no shared skills to list". The rule is the
    /// one the markdown block already follows — an empty list removes the entry
    /// rather than writing an empty one, so "switched off" and "never
    /// configured" stay distinguishable.
    ///
    /// Returns a note when there is something to say, and `nil` when there is
    /// not.
    static func allowOpencodeSkills(skills: [Skill], paths: SandboxPaths) throws -> String? {
        let fm = FileManager.default
        let file = paths.opencodeConfig

        guard !skills.isEmpty else { return revokeOpencodeSkills(paths: paths) }

        let existed = fm.fileExists(atPath: file.path)
        let current = existed ? ((try? String(contentsOf: file, encoding: .utf8)) ?? "") : ""

        var root: [String: Any] = [:]
        if existed, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(current.utf8)),
                  let object = parsed as? [String: Any]
            else {
                // Refuse rather than overwrite, for the same reason
                // `ConnectorBinder` refuses: the file is the user's, it holds
                // settings JXCode knows nothing about, and replacing it would
                // delete all of them.
                return "left opencode.json alone — it is not a JSON object, so its "
                    + "skill permission could not be set"
            }
            root = object
        }

        let permission = (root["permission"] as? [String: Any]) ?? [:]
        let skill = (permission["skill"] as? [String: Any]) ?? [:]

        if let existing = skill["*"] {
            guard (existing as? String) == "allow" else {
                return "left opencode's skill permission alone — it is set to "
                    + "\(describe(existing)), and a bind does not overrule the user"
            }
            return nil   // already allowed, by us or by the user; nothing to say
        }

        var updatedSkill = skill
        updatedSkill["*"] = "allow"
        var updatedPermission = permission
        updatedPermission["skill"] = updatedSkill
        root["permission"] = updatedPermission

        let rendered = try ConnectorBinder.render(root)
        if existed, current == rendered { return nil }

        // The directory comes first. `markCreated` writes a sidecar *beside* the
        // file, so writing the record before the directory existed made it fail
        // in silence — `markCreated` swallows the error on purpose — and a
        // missing record is what makes the next writer back up our own file and
        // record the user as its author. Reached only when `~/.config/opencode/`
        // is absent, which is exactly when the record matters.
        try ConfigFiles.createDirectory(at: file.deletingLastPathComponent(), upTo: paths.home)

        if existed {
            ConfigFiles.backUp(file)
        } else {
            // `opencode.json` is also written by `ConnectorBinder`. Recording
            // that we made it is what stops the connector pass backing it up
            // and recording the user as its author — after which revert would
            // leave `{}` behind instead of removing it.
            ConfigFiles.markCreated(file)
        }
        try rendered.write(to: file, atomically: true, encoding: .utf8)

        var manifest = readManifest(paths: paths)
        manifest.opencodeSkillPermission = true
        writeManifest(manifest, paths: paths)

        return "allowed the shared skills in opencode (`permission.skill`)"
    }

    private static func describe(_ value: Any) -> String {
        (value as? String).map { "“\($0)”" } ?? "\(value)"
    }

    // MARK: - The ownership record

    /// The one bit of a skill bind that cannot be read back off the filesystem.
    ///
    /// The links are recoverable: a symlink into `shared/skills/` is
    /// recognisably ours, and `revert` finds them exactly that way. opencode's
    /// `permission.skill` entry is not. `"*": "allow"` written by JXCode and
    /// `"*": "allow"` written by the user are the same bytes, so an unbind has
    /// no way to tell whether removing it is an undo or a regression. This
    /// records the one bit that answers that.
    public struct Manifest: Codable, Sendable, Equatable {
        public var opencodeSkillPermission: Bool

        public init(opencodeSkillPermission: Bool = false) {
            self.opencodeSkillPermission = opencodeSkillPermission
        }

        public static let empty = Manifest()
    }

    /// Read the manifest, or an empty one.
    ///
    /// A corrupt manifest yields `empty` rather than throwing, which leaves the
    /// opencode entry behind on revert. Untidy, and strictly better than
    /// removing a permission the user may have set themselves.
    public static func readManifest(paths: SandboxPaths) -> Manifest {
        guard let data = try? Data(contentsOf: paths.sharedSkillsManifest),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return .empty }
        return manifest
    }

    static func writeManifest(_ manifest: Manifest, paths: SandboxPaths) {
        guard let text = try? JSONText.encode(manifest) else { return }
        try? text.write(to: paths.sharedSkillsManifest, atomically: true, encoding: .utf8)
    }

    /// Take back the opencode permission this bind added, and only that.
    ///
    /// Guarded by the manifest rather than by the value, because the value
    /// cannot distinguish our `"allow"` from the user's.
    static func revokeOpencodeSkills(paths: SandboxPaths) -> String? {
        var manifest = readManifest(paths: paths)
        guard manifest.opencodeSkillPermission else { return nil }

        let file = paths.opencodeConfig
        guard let current = try? String(contentsOf: file, encoding: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: Data(current.utf8)),
              var root = parsed as? [String: Any]
        else { return nil }

        // Deliberately lenient about the intermediate levels. A file where
        // `permission.skill` has already gone is the state we were trying to
        // reach, not a reason to give up and leave the manifest claiming a
        // grant that is no longer there.
        var permission = (root["permission"] as? [String: Any]) ?? [:]
        var skill = (permission["skill"] as? [String: Any]) ?? [:]

        skill.removeValue(forKey: "*")
        if skill.isEmpty {
            permission.removeValue(forKey: "skill")
        } else {
            permission["skill"] = skill
        }
        if permission.isEmpty {
            root.removeValue(forKey: "permission")
        } else {
            root["permission"] = permission
        }

        if root.isEmpty, !ConfigFiles.hasBackup(file) {
            // A file that only ever held our entry is removed rather than left
            // behind as `{}`: reverting means putting the tree back how it was
            // found, and it was found without this file. A file that predated
            // us keeps whatever else the user has in it.
            ConfigFiles.remove(file)
        } else if let rendered = try? ConnectorBinder.render(root), current != rendered {
            try? rendered.write(to: file, atomically: true, encoding: .utf8)
        }

        manifest.opencodeSkillPermission = false
        // The same rule for the record itself. An absent manifest already reads
        // as an empty one, so a file whose only content is `false` is a file
        // that exists to say nothing.
        if manifest == .empty {
            try? FileManager.default.removeItem(at: paths.sharedSkillsManifest)
        } else {
            writeManifest(manifest, paths: paths)
        }
        return "removed opencode's shared-skill permission"
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
               !ConfigFiles.hasBackup(file) {
                ConfigFiles.remove(file)
            } else {
                try stripped.write(to: file, atomically: true, encoding: .utf8)
            }
            messages.append("cleared the shared skill list from \(file.path)")
        }

        // Only links pointing into our own shared directory are removed, and
        // every native directory is swept — not just the one Claude Code reads.
        // A revert that cleared `~/.claude/skills/` and left
        // `~/.agents/skills/` full would unbind one agent and leave three
        // bound, while reporting success.
        for target in nativeTargets(paths: paths) {
            let existing = (try? fm.contentsOfDirectory(atPath: target.directory.path)) ?? []
            for name in existing {
                let link = target.directory.appendingPathComponent(name)
                guard let destination = try? fm.destinationOfSymbolicLink(atPath: link.path),
                      linkURL(destination, at: link).isContained(in: paths.sharedSkills)
                else { continue }
                try? fm.removeItem(at: link)
                messages.append("unlinked \(name) from \(target.label) skills")
            }
        }

        // The link and the permission go on together and come off together.
        // Removing the permission while the links stay would leave the skills
        // visible and hidden at once; removing the links and leaving the
        // permission would leave a grant behind that the user never made.
        if let message = revokeOpencodeSkills(paths: paths) {
            messages.append(message)
        }

        // Directories last, and only once the files are out of them: a directory
        // still holding one of our configs is not empty, and the rule is to take
        // back the container we made, never its contents. The same list is swept
        // by every binder's revert, because the record on disk decides and not
        // the caller — a marked directory is ours whoever created it, and an
        // empty one we made has no reader left either way. A second sweep finds
        // nothing and says nothing.
        messages.append(contentsOf: ConfigFiles.removeCreatedDirectories(
            paths.directoriesABindMayCreate,
            upTo: paths.home
        ))

        return messages
    }

    /// Where a link's destination actually points, ready to be compared.
    ///
    /// `destinationOfSymbolicLink` hands back the target exactly as it was
    /// written, which for a link someone else created can be relative — and a
    /// relative path is resolved from the directory holding the link, not from
    /// wherever we happen to be running.
    private static func linkURL(_ destination: String, at link: URL) -> URL {
        let directory = link.deletingLastPathComponent()
        // Appended to the directory and standardised by `isContained(in:)`,
        // which is what resolves the `..`. Asking for a URL relative to the
        // directory instead leaves the result *relative*, and a relative path
        // is never inside anything.
        return destination.hasPrefix("/")
            ? URL(fileURLWithPath: destination)
            : directory.appendingPathComponent(destination)
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
