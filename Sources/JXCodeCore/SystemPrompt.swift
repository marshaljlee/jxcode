import Foundation

// MARK: - The shared system prompt

/// One system prompt, written once, carried by every agent.
///
/// Stored as `shared/system-prompt.md` — a plain Markdown file, editable in any
/// editor, for the same reason skills are `SKILL.md` files. That file is the
/// **source of truth** for the content; the sibling `system-prompt.json`
/// sidecar holds only what the file cannot express: whether the prompt is
/// enabled, and when it changed.
///
/// Binding writes the prompt into each agent's own instruction file inside a
/// fenced managed block (`ManagedBlock.markdownSystemPrompt`), the same
/// mechanism skills use, so the user's own text around it is never touched and
/// the *file* stays the one copy to edit. Claude Code's block lands in
/// `CLAUDE.md` — its native memory file — so the prompt is read on every
/// session without any per-agent discovery machinery of its own.
public struct SystemPrompt: Codable, Equatable, Sendable {
    public var body: String
    public var enabled: Bool
    public var updatedAt: Date

    public init(body: String, enabled: Bool = true, updatedAt: Date = Date()) {
        self.body = body
        self.enabled = enabled
        self.updatedAt = updatedAt
    }

    /// The managed block as it is written into an agent's file.
    public func rendered() -> String {
        let markers = ManagedBlock.Markers.markdownSystemPrompt
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(markers.start)\n# Shared system prompt\n\n\(content)\n\(markers.end)"
    }
}

/// Reads and writes the shared system prompt, and binds it into agents.
///
/// Separated from `SharedStore` rather than folded into it because the prompt
/// is one file, not a collection — a store of one thing is a document, and the
/// API should say so.
public final class SystemPromptStore {
    private let paths: SandboxPaths
    private let fileManager = FileManager.default

    public init(paths: SandboxPaths = .default) {
        self.paths = paths
    }

    /// The current prompt. A missing file is an empty, disabled prompt — a
    /// fresh sandbox has nothing to say yet, which is a normal state rather
    /// than an error.
    public func load() -> SystemPrompt {
        let body = (try? String(contentsOf: paths.sharedSystemPrompt, encoding: .utf8)) ?? ""
        struct Sidecar: Codable { var enabled: Bool; var updatedAt: Date }
        if let data = try? Data(contentsOf: paths.sharedSystemPromptMeta),
           let meta = try? JSONDecoder().decode(Sidecar.self, from: data) {
            return SystemPrompt(body: body, enabled: meta.enabled, updatedAt: meta.updatedAt)
        }
        return SystemPrompt(body: body, enabled: !body.isEmpty)
    }

    /// Write the source of truth. The file gets the prose, the sidecar gets
    /// the metadata, and the body is trimmed of leading/trailing blank lines —
    /// the editor's trailing newline is not content.
    public func save(_ prompt: SystemPrompt) throws -> SystemPrompt {
        var prompt = prompt
        prompt.body = prompt.body.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt.updatedAt = Date()

        try fileManager.createDirectory(at: paths.shared, withIntermediateDirectories: true)
        try prompt.body.write(to: paths.sharedSystemPrompt, atomically: true, encoding: .utf8)
        struct Sidecar: Codable { var enabled: Bool; var updatedAt: Date }
        let meta = Sidecar(enabled: prompt.enabled, updatedAt: prompt.updatedAt)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(meta).write(to: paths.sharedSystemPromptMeta, options: .atomic)
        return prompt
    }

    // MARK: - Binding

    public struct Report: Sendable {
        public enum Action: String, Sendable {
            case bound, unchanged, cleared, notApplicable
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

    /// Write the prompt into every agent that has an instruction file.
    ///
    /// Mirrors `SkillBinder.apply`: same instruction-file table, same managed
    /// block rules, same shape-preserving removal when disabled. Deliberately
    /// *not* sharing code with the skill binder beyond `ManagedBlock` — the two
    /// binders hold different markers and different empty-state notes, and a
    /// shared abstraction over "write a block into a file" would hide the one
    /// thing each has to get right.
    @discardableResult
    public static func bind(
        prompt: SystemPrompt,
        agents: [AgentDefinition],
        paths: SandboxPaths
    ) throws -> [Report] {
        let markers = ManagedBlock.Markers.markdownSystemPrompt
        var reports: [Report] = []

        for agent in agents {
            guard let file = SkillBinder.instructionFile(for: agent, paths: paths) else {
                reports.append(Report(
                    agentID: agent.id,
                    agentName: agent.name,
                    action: .notApplicable,
                    path: nil,
                    notes: ["this agent reads no instruction file"]
                ))
                continue
            }

            let fm = FileManager.default
            let existed = fm.fileExists(atPath: file.path)
            let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""

            let rendered: String
            let notes: [String]
            if prompt.enabled, !prompt.body.isEmpty {
                rendered = ManagedBlock.inserting(prompt.rendered(), into: current, markers: markers)
                notes = ["bound the shared system prompt"]
            } else {
                guard ManagedBlock.contains(current, markers: markers) else {
                    reports.append(Report(agentID: agent.id, agentName: agent.name,
                                          action: .unchanged, path: file,
                                          notes: ["the shared system prompt is off"]))
                    continue
                }
                rendered = ManagedBlock.removingPreservingShape(from: current, markers: markers)
                notes = ["removed the shared system prompt"]
            }

            if existed, current == rendered {
                reports.append(Report(agentID: agent.id, agentName: agent.name,
                                      action: .unchanged, path: file,
                                      notes: ["already up to date"]))
                continue
            }
            // Both paths above can return without writing anything, and neither
            // should leave a directory behind — the same rule the skill binder
            // follows, and the reason a disabled prompt does not make
            // `~/.config/opencode/` exist in an agent's home.
            try ConfigFiles.createDirectory(at: file.deletingLastPathComponent(), upTo: paths.home)

            if existed, prompt.enabled {
                ConfigFiles.backUp(file)
            } else if !existed {
                // The same instruction file also carries the shared skill list,
                // written by `SkillBinder`. Recording that we made it is what
                // stops that binder backing it up and recording the user as its
                // author — after which revert would leave an empty file behind
                // instead of removing it.
                ConfigFiles.markCreated(file)
            }

            // A file that only ever held our block is removed rather than
            // left blank — the state found was "no file".
            if existed, !prompt.enabled,
               rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !ConfigFiles.hasBackup(file) {
                ConfigFiles.remove(file)
            } else {
                try rendered.write(to: file, atomically: true, encoding: .utf8)
            }

            reports.append(Report(agentID: agent.id, agentName: agent.name,
                                  action: prompt.enabled ? .bound : .cleared,
                                  path: file, notes: notes))
        }

        return reports
    }

    /// Take the prompt back out of every agent's file.
    @discardableResult
    public static func unbind(agents: [AgentDefinition], paths: SandboxPaths) throws -> [Report] {
        try bind(prompt: SystemPrompt(body: "", enabled: false),
                 agents: agents, paths: paths)
    }

    // MARK: - Backup helpers

}

// MARK: - YOLO mode

/// The per-agent flags that switch an agent's approval gates off, and the
/// reason each is safe to hand out blindly.
///
/// This is a table rather than a string on `AgentDefinition` because the flags
/// are a *fact about the upstream CLI* — they change when the CLI changes, and
/// a custom agent added by the user gets `.none` rather than a guess. YOLO mode
/// means "skip the approval prompt", not "skip the safety thinking": the table
/// documents what each flag actually does so the UI can show the risk instead
/// of hiding it behind a novelty name.
public enum YOLOMode {

    /// What YOLO means for one agent.
    public struct Flags: Sendable {
        /// Arguments appended at launch.
        public let arguments: [String]
        /// Extra environment when the agent is gated by env rather than argv.
        public let environment: [String: String]
        /// One line for the UI: what the agent will now do without asking.
        public let note: String

        public init(arguments: [String] = [], environment: [String: String] = [:], note: String) {
            self.arguments = arguments
            self.environment = environment
            self.note = note
        }
    }

    public static func flags(for agentID: String) -> Flags? {
        switch agentID {
        case "claude":
            return Flags(
                arguments: ["--dangerously-skip-permissions"],
                note: "skips every permission prompt — edits and commands run without asking"
            )
        case "codex":
            return Flags(
                arguments: ["--yolo"],
                note: "skips approvals and runs with network access"
            )
        case "gemini":
            return Flags(
                arguments: ["--yolo"],
                note: "auto-approves every tool call"
            )
        case "opencode":
            return Flags(
                arguments: [],
                environment: ["OPENCODE_PERMISSION": "bypass-all"],
                note: "bypasses tool permission checks via environment"
            )
        case "omp":
            return Flags(
                arguments: ["--yolo"],
                note: "auto-approves tool use"
            )
        case "jules":
            // A cloud VM with its own sandbox; there is nothing local to
            // approve, so there is nothing for a flag to skip.
            return nil
        default:
            return nil
        }
    }

    /// Whether the agent has any YOLO surface at all — drives the UI's
    /// disabled state for custom agents.
    public static func isSupported(agentID: String) -> Bool {
        flags(for: agentID) != nil
    }
}
