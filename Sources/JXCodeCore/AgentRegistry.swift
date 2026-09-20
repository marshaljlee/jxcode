import Foundation

/// How an agent is pointed at the local model router.
///
/// Every agent inherits `ANTHROPIC_BASE_URL` / `OPENAI_BASE_URL` from the
/// sandbox environment, which is enough for most of them. A few need a config
/// file as well, either because they ignore those variables or because they
/// require a model name and an auth token to be set somewhere persistent.
public enum RouterBinding: String, Codable, Sendable {
    /// Environment variables only. The default, and all that is needed for any
    /// agent that honours `OPENAI_BASE_URL` or `ANTHROPIC_BASE_URL`.
    case environment
    /// Also writes `settings.json` under `CLAUDE_CONFIG_DIR`.
    case claudeSettings
    /// Also writes `config.toml` under `CODEX_HOME`.
    case codexConfig
    /// No routing: the agent runs entirely against its own cloud service.
    case none
}

/// A CLI agent the app can launch inside the sandbox.
public struct AgentDefinition: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Bare command name, resolved against the sandbox `PATH`.
    public var command: String
    public var arguments: [String]
    /// Shown when the binary is missing, e.g. `npm i -g @anthropic-ai/claude-code`.
    public var installCommand: String?
    /// Extra environment, applied on top of the sandbox environment.
    public var environment: [String: String]
    public var isBuiltIn: Bool

    /// When set, this agent can also be opened as an embedded web panel.
    ///
    /// Jules needs this: it is an *async cloud* agent, so the CLI only
    /// dispatches and pulls remote sessions — the dashboard where you actually
    /// watch a session run is a web UI. Embedding it keeps the whole loop
    /// inside the app instead of bouncing to a browser.
    public var webURL: String?

    /// How the router is wired into this agent's configuration.
    public var routerBinding: RouterBinding

    public init(
        id: String,
        name: String,
        command: String,
        arguments: [String] = [],
        installCommand: String? = nil,
        environment: [String: String] = [:],
        isBuiltIn: Bool = true,
        webURL: String? = nil,
        routerBinding: RouterBinding = .environment
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.arguments = arguments
        self.installCommand = installCommand
        self.environment = environment
        self.isBuiltIn = isBuiltIn
        self.webURL = webURL
        self.routerBinding = routerBinding
    }
}

/// The agents offered in the UI, plus the install state of each.
///
/// `@unchecked Sendable` with one documented invariant: `agents` is only ever
/// mutated on the main actor (through `add`/`saveCustom`). Reads from a
/// background queue — the doctor audit walks the list — are therefore safe, but
/// the compiler cannot verify it, hence the unchecked conformance rather than a
/// silent data race.
public final class AgentRegistry: @unchecked Sendable {

    public private(set) var agents: [AgentDefinition]
    private let paths: SandboxPaths

    public init(paths: SandboxPaths = .default) {
        self.paths = paths
        self.agents = Self.builtIns
        loadCustom()
    }

    public static let builtIns: [AgentDefinition] = [
        AgentDefinition(
            id: "claude",
            name: "Claude Code",
            command: "claude",
            installCommand: "npm i -g @anthropic-ai/claude-code",
            // Reads ANTHROPIC_BASE_URL, but also needs a token and a model name
            // to be present, so a settings.json is written as well.
            routerBinding: .claudeSettings
        ),
        AgentDefinition(
            id: "codex",
            name: "Codex CLI",
            command: "codex",
            installCommand: "npm i -g @openai/codex",
            // Codex selects a provider by name from config.toml and ignores a
            // bare OPENAI_BASE_URL.
            routerBinding: .codexConfig
        ),
        AgentDefinition(
            id: "gemini",
            name: "Gemini CLI",
            command: "gemini",
            installCommand: "npm i -g @google/gemini-cli"
        ),
        AgentDefinition(
            id: "opencode",
            name: "opencode",
            command: "opencode",
            installCommand: "npm i -g opencode-ai"
        ),
        // Installed through npm rather than omp.sh's curl installer or the
        // Homebrew tap: `npm i -g` honours npm_config_prefix, so the binary
        // lands in the sandbox. The curl installer writes to a path of its own
        // choosing and would likely escape.
        AgentDefinition(
            id: "omp",
            name: "oh-my-pi",
            command: "omp",
            installCommand: "npm i -g @oh-my-pi/pi-coding-agent"
        ),
        // Jules is async: `jules remote new` hands work to a cloud VM that
        // clones the repo and opens a pull request. The CLI dispatches and
        // pulls; the dashboard is web. Its model runs on Google's side, so
        // there is nothing to route.
        AgentDefinition(
            id: "jules",
            name: "Google Jules",
            command: "jules",
            installCommand: "npm i -g @google/jules",
            webURL: "https://jules.google.com",
            routerBinding: .none
        ),
        AgentDefinition(
            id: "shell",
            name: "Plain shell",
            command: "/bin/zsh",
            arguments: ["-l"],
            isBuiltIn: true,
            routerBinding: .none
        ),
    ]

    // MARK: - Persistence

    private func loadCustom() {
        guard let data = try? Data(contentsOf: paths.agentsFile),
              let custom = try? JSONDecoder().decode([AgentDefinition].self, from: data)
        else { return }
        // Custom entries override built-ins with the same id.
        for agent in custom {
            if let index = agents.firstIndex(where: { $0.id == agent.id }) {
                agents[index] = agent
            } else {
                agents.append(agent)
            }
        }
    }

    public func saveCustom() throws {
        try FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
        let custom = agents.filter { !$0.isBuiltIn }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(custom).write(to: paths.agentsFile, options: .atomic)
    }

    /// Register a custom agent, replacing any existing entry with the same id.
    ///
    /// `isBuiltIn` is forced to `false` rather than taken from the argument.
    /// `saveCustom()` persists only the non-built-in entries, so anything added
    /// here is custom by definition — and both callers were relying on the
    /// `AgentDefinition` initialiser's default of `true`, which meant `add()`
    /// appeared to work (the entry went into the in-memory list and was
    /// reported back to the user) while writing an empty array to disk. The
    /// agent was gone on the next launch, and `jxcode install <id>` could not
    /// see it at all, because that runs in a fresh process.
    public func add(_ agent: AgentDefinition) throws {
        var agent = agent
        agent.isBuiltIn = false
        agents.removeAll { $0.id == agent.id }
        agents.append(agent)
        try saveCustom()
    }

    // MARK: - Resolution

    public func agent(id: String) -> AgentDefinition? {
        agents.first { $0.id == id }
    }

    /// Where this agent's binary resolves to inside the sandbox, or `nil`.
    public func resolvedPath(for agent: AgentDefinition, environment: [String: String]) -> String? {
        ExecutableResolver.resolve(agent.command, environment: environment)
    }

    public func isInstalled(_ agent: AgentDefinition, environment: [String: String]) -> Bool {
        resolvedPath(for: agent, environment: environment) != nil
    }

    /// True when the resolved binary sits outside the sandbox. That is a leak,
    /// not a success — the agent would write to the host home.
    ///
    /// System directories are exempt. `Plain shell` is `/bin/zsh`, which is
    /// *always* outside the sandbox and always will be: the OS shell is shared
    /// with the host on purpose (see `SandboxEnvironment.baseSystemDirectories`).
    /// Counting it as a leak made `doctor` report "1 failing" on a perfectly
    /// healthy install — and a leak report that is wrong once is a leak report
    /// nobody reads.
    public func isEscaping(_ agent: AgentDefinition, environment: [String: String]) -> Bool {
        guard let resolved = resolvedPath(for: agent, environment: environment) else { return false }
        if SandboxEnvironment.isSharedSystemPath(resolved) { return false }
        return !paths.contains(URL(fileURLWithPath: resolved))
    }
}
