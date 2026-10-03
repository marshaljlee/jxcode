import Foundation

/// The agent that owns a workspace.
///
/// jxcode launches one agent per tab and leaves the human to decide what each
/// one is for. That works until you want a *second* opinion on a change the
/// first agent already made, or you want one agent to hand a well-scoped job to
/// another — and then the tab strip is a list of equals with no way to say
/// "this one is in charge".
///
/// A `PrimaryAgent` records exactly one thing: which agent id is in charge, and
/// what it has been told about its own reach. Nothing here starts a process or
/// writes an agent's config. Those stay where they are — `AppState.launch` owns
/// launching, `AgentConfigWriter` owns binding — so declaring a primary cannot
/// half-start anything. If the record is wrong the user deletes it and picks
/// again; nothing is stranded.
public struct PrimaryAgent: Codable, Equatable, Sendable {

    /// The `AgentDefinition.id` of the agent in charge.
    ///
    /// Stored as an id and not as a whole `AgentDefinition` on purpose: the
    /// agent's own definition already lives in the registry and can be edited,
    /// and a second copy here would drift from it the moment either changed.
    public var agentID: String

    /// The human-readable name, kept for display so the UI never has to look the
    /// agent up to label the record. Recomputed from the registry whenever the
    /// agent is known, so a rename in the registry cannot leave a stale label
    /// behind.
    public var agentName: String

    /// How many subagents the primary may have open at once.
    ///
    /// Zero is a real value and means "no subagents", which is different from
    /// "unset". A struct cannot tell nil from absent here without making every
    /// read a guess, so the cap is always concrete.
    public var maxSubagents: Int

    /// Whether the primary was told it may install tools into the sandbox.
    ///
    /// Stored rather than assumed because installing is the one power here that
    /// writes to disk without asking. Defaults to off so picking a primary is
    /// never also granting install rights.
    public var canInstallTools: Bool

    public init(
        agentID: String,
        agentName: String,
        maxSubagents: Int = 4,
        canInstallTools: Bool = true
    ) {
        self.agentID = agentID
        self.agentName = agentName
        self.maxSubagents = maxSubagents
        self.canInstallTools = canInstallTools
    }
}

/// Reads and writes the primary record.
///
/// One file, in the sandbox's `state/` directory beside `agents.json`, because
/// that is where the launcher already keeps everything the user has chosen and
/// where `SandboxPaths` already points the CLI harness. It is deliberately not
/// written into the workspace: a primary is a property of how jxcode is being
/// used right now, not of a repository, and storing it per-workspace would mean
/// the answer changes with the folder you happen to be in.
public struct PrimaryAgentStore: Sendable {

    private let paths: SandboxPaths

    public init(paths: SandboxPaths = .default) {
        self.paths = paths
    }

    /// Where the record lives on disk.
    public var fileURL: URL { paths.state.appendingPathComponent("primary.json") }

    /// The current primary, or `nil` when none has been chosen.
    ///
    /// A decode failure is treated as "no primary" rather than as an error to
    /// raise. The file is one small piece of hand-editable state; refusing to
    /// launch anything because it is malformed would turn a typo into a brick,
    /// and there is nothing here worth protecting that the user cannot retype.
    public func load() -> PrimaryAgent? {
        guard let data = try? Data(contentsOf: fileURL),
              let record = try? JSONDecoder().decode(PrimaryAgent.self, from: data)
        else { return nil }
        return record
    }

    @discardableResult
    public func save(_ primary: PrimaryAgent) -> Bool {
        do {
            try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(primary).write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Forget the primary. The workspace keeps running; only the claim on it ends.
    @discardableResult
    public func clear() -> Bool {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }

    /// True when `agentID` is the agent in charge.
    ///
    /// Used to badge the primary's own card, so it answers from the stored
    /// record rather than from anything the UI is tracking — otherwise closing
    /// and reopening a tab could leave the badge on an agent that is no longer
    /// in charge.
    public func isPrimary(_ agentID: String) -> Bool {
        load()?.agentID == agentID
    }
}

/// The instructions handed to the agent that has been chosen as primary.
///
/// A prompt rather than a flag because the thing being asked for — "decide the
/// plan, hand work to other agents, check on them" — is something only the model
/// can act on. jxcode has no channel into a running CLI agent other than what it
/// types, so the primary's charter is typed for it, and the type tool it does
/// not have is the reason a fleet is described here rather than automated.
///
/// The text names commands by their real flag spelling, because an agent handed
/// a command that does not exist will report success on work it never did. Every
/// command named here is one `AgentCatalog`/`AgentRegistry` entry actually
/// ships, and the sibling roster is generated from the live registry rather than
/// typed out, so the two cannot disagree about what exists.
public struct PrimaryCharter {

    public init() {}

    /// The charter body, given the live roster so the primary is told what it can
    /// actually launch.
    ///
    /// `subagents` is the registry's own list. A primary that was told about a
    /// subagent which is not installed would try to launch it and fail; a primary
    /// told about one that is installed can go and do so. So the roster is
    /// filtered to what resolves on the sandbox `PATH`, and the primary is told
    /// plainly that anything not listed is not available.
    public func charter(
        primary: PrimaryAgent,
        subagents: [AgentDefinition],
        environment: [String: String]
    ) -> String {
        let launchable = subagents
            .filter { $0.id != primary.agentID }
            .filter { AgentRegistry().isInstalled($0, environment: environment) }

        let roster = launchable.isEmpty
            ? "  (no other agent is installed in the sandbox right now)"
            : launchable
                .sorted { $0.name < $1.name }
                .map { "  - \($0.name) — launch with: jxcode install \($0.id)  ·  run: \($0.command)" }
                .joined(separator: "\n")

        let installRights = primary.canInstallTools
            ? """
              You may install a tool into the sandbox when a job needs one. Use the \
              agent's own install command (npm i -g … lands inside the sandbox \
              because the sandbox sets npm_config_prefix). Never install anything \
              that needs a payment method, an account, or a card.
              """
            : """
              You may NOT install anything. If a job needs a tool you do not have, \
              say so and stop.
              """

        let subagentLine = primary.maxSubagents == 0
            ? "You may not open subagents for this session."
            : """
              You may open up to \(primary.maxSubagents) subagent\(primary.maxSubagents == 1 ? "" : "s") \
              at the same time. Beyond that, wait for one to finish before opening another.
              """

        return """
        # Primary operator

        You are the agent in charge of this jxcode session. You were chosen as \
        primary; the others are helpers you may call on.

        ## What you own

        - The plan. Decide it yourself. Do not wait to be handed one.
        - The workspace. Read, edit, build, test and run whatever the job needs.
        - The verdict. When work comes back, check it before you report it as done.

        ## Subagents

        \(subagentLine)

        These are installed and available to you:

        \(roster)

        Each subagent is a separate terminal program. To use one, install it if \
        needed, then open it as a tab from the launcher. Give it a self-contained \
        brief: what to change, which files, what "done" looks like, and what to \
        report back. Do not split work so finely that coordinating it costs more \
        than doing it.

        ## Tools

        \(installRights)

        ## Reporting

        - Report what you actually ran. Paste the real output; never describe a \
        result you did not see.
        - When you use a subagent, say which one, what you asked it, what came \
        back, and what is still open.
        - Say plainly when something failed or when you did not check something.

        ## Never

        - Never claim a subagent's result without reading it yourself.
        - Never install or recommend anything that costs money.
        - Never rewrite history or push unless asked.
        """
    }

    /// The CLI form of the charter, for a human to read.
    ///
    /// Same content, flattened for a terminal that has no markdown renderer, and
    /// with no leading `#` run-down so it reads as a briefing rather than as a
    /// pasted file.
    public func plainCharter(
        primary: PrimaryAgent,
        subagents: [AgentDefinition],
        environment: [String: String]
    ) -> String {
        charter(primary: primary, subagents: subagents, environment: environment)
            .replacingOccurrences(of: "## ", with: "")
            .replacingOccurrences(of: "# ", with: "")
    }
}
