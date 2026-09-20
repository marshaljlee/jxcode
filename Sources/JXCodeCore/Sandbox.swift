import Foundation

public enum SandboxError: Error, CustomStringConvertible {
    case agentNotInstalled(AgentDefinition)
    case commandNotFound(String)

    public var description: String {
        switch self {
        case .agentNotInstalled(let agent):
            var text = "\(agent.name) is not installed in the sandbox."
            if let install = agent.installCommand {
                text += "\nInstall it from a sandbox tab:\n\n    \(install)\n"
            }
            return text
        case .commandNotFound(let command):
            return "command not found in sandbox PATH: \(command)"
        }
    }
}

/// The router target for a `Sandbox`, mutable behind a lock.
///
/// `Sandbox` is `Sendable` but the app changes the router URL at runtime, so
/// the value lives in a box rather than in a stored property.
private final class RouterSeam: @unchecked Sendable {
    private let lock = NSLock()
    private var url: String?
    private var token: String?
    /// Whether `set` has ever been called.
    ///
    /// Distinct from `url != nil`, because "stop routing" is also a statement:
    /// the app calls `setRouter(url: nil)` when the router stops, and that has
    /// to override a URL from `SandboxOptions` rather than fall back to it.
    /// Before the first call the seam has said nothing, so the options stand.
    private var hasBeenSet = false

    func set(url: String?, token: String?) {
        lock.lock()
        self.url = url
        self.token = token
        self.hasBeenSet = true
        lock.unlock()
    }

    func get() -> (url: String?, token: String?, hasBeenSet: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (url, token, hasBeenSet)
    }
}

/// The app's single entry point to the isolated runtime.
///
/// Everything that spawns a process goes through here, so there is exactly one
/// place where the environment is decided.
///
/// `Sendable` because every stored property is an immutable value type — the
/// app hands one instance to background queues, which is how the doctor audit
/// runs without stalling the window.
public final class Sandbox: Sendable {

    public let paths: SandboxPaths
    public let options: SandboxOptions
    public let environment: SandboxEnvironment

    /// Mutable router target.
    ///
    /// A class box rather than a stored `String?` because `Sandbox` is
    /// `Sendable` and is handed to background queues; a mutable stored
    /// property would break that. The lock is cheap and this is read once
    /// per launch.
    private let routerSeam = RouterSeam()

    public init(paths: SandboxPaths = .default, options: SandboxOptions = .default) {
        self.paths = paths
        self.options = options
        self.environment = SandboxEnvironment(paths: paths, options: options)
    }

    // MARK: - Setup

    /// Create the directory tree and install shell init. Idempotent, and cheap
    /// enough to call on every launch.
    @discardableResult
    public func prepare() throws -> [URL] {
        let created = try paths.createDirectories()
        // The shell init must apply the same PATH policy as the environment.
        // Otherwise it re-admits the host tool directories that `buildPath`
        // deliberately excluded.
        try ShellInit.install(paths: paths, includeHostLocalBin: options.includeHostLocalBin)

        // `PATH[0]` is documented as where JXCode's shims live, and until now
        // nothing wrote one. This puts `node`, `npm` and `npx` there so a global
        // install has somewhere to run *and* somewhere to land — see
        // `NodeToolchain` for why the runtime is borrowed rather than copied,
        // and for what that costs.
        //
        // Best effort on purpose: a machine with no Node is still a perfectly
        // usable sandbox, and the app must not refuse to start because of it.
        // The install path reports the missing toolchain properly when it
        // actually matters.
        NodeToolchain.ensureBestEffort(paths: paths)

        return created
    }

    // MARK: - Environment

    public func env(workspace: Workspace? = nil) -> [String: String] {
        // Router seam, applied here so every consumer agrees — a tab launch
        // and a plain `env()` must not disagree about where models come from.
        // Read per call rather than baked in at construction: the router
        // starts and stops while the app is running, and a tab opened after
        // it stopped must not inherit a URL nothing answers.
        //
        // Claude Code is why this is at the process level at all. It decides
        // "am I logged in?" before making a request, and with no base URL and
        // no credential it prints `Not logged in · Please run /login` and
        // exits — a dead end that reads as a broken install.
        //
        // Applied by rebuilding the options rather than by writing the keys a
        // second time. There used to be a copy of this block down in `Sandbox.
        // env()` and it drifted from the one in `SandboxEnvironment.build()`:
        // one listed three credential keys, the other two. Two copies of one
        // rule is the shape of every routing bug in this file's history, so
        // the seam now has exactly one expression.
        let (routerURL, routerToken, hasBeenSet) = routerSeam.get()
        var options = self.options
        // The seam wins once it has been spoken — which includes being spoken
        // with `nil`, meaning the router stopped. Until then the options stand,
        // so a `Sandbox` built with `SandboxOptions(routerURL:)` keeps routing
        // exactly as it was configured.
        if hasBeenSet {
            options.routerURL = routerURL
            options.routerToken = routerToken
        }

        return SandboxEnvironment(paths: paths, options: options).build(workspace: workspace)
    }

    /// Working directory for a new tab: the workspace, or the sandbox home.
    public func workingDirectory(for workspace: Workspace?) -> String {
        guard let workspace else { return paths.home.path }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: workspace.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return workspace.path
        }
        return paths.home.path
    }

    // MARK: - Launching

    /// Start a pty. The one place `PTYSession` is constructed and started.
    ///
    /// This type's doc comment promises "exactly one place where the
    /// environment is decided", and an earlier revision did not honour it:
    /// `TerminalController` and the CLI's `pty` command each carried their own
    /// copy of this sequence, because both need to install `onData`/`onExit`
    /// *before* `start()` runs and so could not call a function that had
    /// already started the session.
    ///
    /// The GUI's copy quietly dropped `agent.environment`. Nothing observable
    /// depended on it yet — every built-in agent ships an empty environment —
    /// which is precisely what made it worth removing: two launch paths that
    /// agree only by coincidence is the shape of the doubled-`/v1` bug.
    ///
    /// Hence `configure`: the caller gets the session before it is started, so
    /// handler wiring stays with the caller while the environment stays here.
    private func startSession(
        executable: String,
        arguments: [String],
        environment: [String: String],
        workspace: Workspace?,
        columns: Int,
        rows: Int,
        configure: ((PTYSession) -> Void)?
    ) throws -> PTYSession {
        let session = PTYSession()
        // Before `start()`, because the pty can deliver its first bytes the
        // moment the child is forked — a handler installed afterwards would
        // drop the shell's opening prompt.
        configure?(session)
        try session.start(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory(for: workspace),
            columns: columns,
            rows: rows
        )
        return session
    }

    /// The environment a tab runs under, with any per-agent overrides applied.
    private func tabEnvironment(
        agent: AgentDefinition?,
        workspace: Workspace?,
        extraEnvironment: [String: String]
    ) -> [String: String] {
        // The router seam is applied inside `env`, so it is picked up here too.
        var environment = env(workspace: workspace)
        for (key, value) in agent?.environment ?? [:] { environment[key] = value }
        for (key, value) in extraEnvironment { environment[key] = value }
        return environment
    }

    /// Point every process launched from here on at the model router.
    ///
    /// Pass `nil` to retract it. Tabs already running keep the environment
    /// they were started with — that is the correct behaviour, since
    /// rewriting a live process is not possible anyway.
    public func setRouter(url: String?, token: String? = nil) {
        routerSeam.set(url: url, token: token)
    }

    /// The router this sandbox is currently pointing agents at, if any.
    public var routerURL: String? { routerSeam.get().url }

    /// Launch a registered agent.
    ///
    /// Throws `agentNotInstalled` rather than falling back to a host binary —
    /// silently running the host's copy would write to the host home, which is
    /// the exact failure this app exists to prevent.
    public func launch(
        agent: AgentDefinition,
        workspace: Workspace? = nil,
        extraEnvironment: [String: String] = [:],
        columns: Int = 120,
        rows: Int = 32,
        configure: ((PTYSession) -> Void)? = nil
    ) throws -> PTYSession {
        try prepare()
        let environment = tabEnvironment(
            agent: agent, workspace: workspace, extraEnvironment: extraEnvironment
        )
        guard let executable = ExecutableResolver.resolve(agent.command, environment: environment) else {
            throw SandboxError.agentNotInstalled(agent)
        }
        return try startSession(
            executable: executable,
            arguments: agent.arguments,
            environment: environment,
            workspace: workspace,
            columns: columns,
            rows: rows,
            configure: configure
        )
    }

    /// Launch an arbitrary command in a tab — what `jxcode pty` needs, and the
    /// only difference from `launch(agent:)` is that nothing is registered.
    public func launchCommand(
        _ command: String,
        arguments: [String] = [],
        workspace: Workspace? = nil,
        extraEnvironment: [String: String] = [:],
        columns: Int = 120,
        rows: Int = 32,
        configure: ((PTYSession) -> Void)? = nil
    ) throws -> PTYSession {
        try prepare()
        let environment = tabEnvironment(
            agent: nil, workspace: workspace, extraEnvironment: extraEnvironment
        )
        guard let executable = ExecutableResolver.resolve(command, environment: environment) else {
            throw SandboxError.commandNotFound(command)
        }
        return try startSession(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workspace: workspace,
            columns: columns,
            rows: rows,
            configure: configure
        )
    }

    /// Run a one-shot command inside the sandbox.
    public func run(
        _ command: String,
        arguments: [String] = [],
        workspace: Workspace? = nil,
        extraEnvironment: [String: String] = [:],
        timeout: TimeInterval = 300
    ) throws -> CommandResult {
        try prepare()
        var environment = env(workspace: workspace)
        for (key, value) in extraEnvironment { environment[key] = value }

        guard let executable = ExecutableResolver.resolve(command, environment: environment) else {
            throw SandboxError.commandNotFound(command)
        }

        return try CommandRunner.run(
            executable: executable,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory(for: workspace),
            timeout: timeout
        )
    }
}
