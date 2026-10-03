import Foundation

/// Tunable isolation policy.
public struct SandboxOptions: Sendable {
    /// Include `/usr/local/bin` on `PATH`.
    ///
    /// Defaults to `false`. On macOS that directory is where a host-wide
    /// Homebrew lives, so including it would let sandboxed agents find and
    /// execute tools that were never installed inside the sandbox — which is
    /// exactly the leak this app exists to prevent.
    public var includeHostLocalBin: Bool

    /// Extra entries prepended to `PATH`, highest priority first.
    public var extraPathEntries: [String]

    /// Extra environment variables. Applied last, so these win.
    public var extraEnv: [String: String]

    /// Point agents at a local model router once phase 02 lands.
    public var routerURL: String?

    /// The credential routed agents must present to the router.
    ///
    /// Only meaningful alongside `routerURL`. When it is nil the placeholder is
    /// used, which is what an unauthenticated router expects; when router auth
    /// is on it has to be the real token or every request is answered 401.
    public var routerToken: String?

    public init(
        includeHostLocalBin: Bool = false,
        extraPathEntries: [String] = [],
        extraEnv: [String: String] = [:],
        routerURL: String? = nil,
        routerToken: String? = nil
    ) {
        self.includeHostLocalBin = includeHostLocalBin
        self.extraPathEntries = extraPathEntries
        self.extraEnv = extraEnv
        self.routerURL = routerURL
        self.routerToken = routerToken
    }

    public static let `default` = SandboxOptions()
}

/// Builds the environment dictionary handed to every process the app spawns.
///
/// This is the single source of truth for isolation. A process is "inside the
/// sandbox" if and only if it was started with the dictionary this type
/// produces, so there is exactly one place to audit.
///
/// Design notes:
///
/// - The host `PATH` is **not** inherited. It is rebuilt from scratch, because
///   a single inherited entry can point at a host-wide tool.
/// - Variables that resolve to a home directory are set explicitly rather than
///   left to fall back to `$HOME`. Several tools (notably Claude Code) read a
///   dedicated variable, and leaving it unset risks a `getpwuid()` fallback
///   that returns the *real* home regardless of `$HOME`.
/// - Nothing secret is copied in. Only a small allowlist of host variables
///   crosses the boundary.
public struct SandboxEnvironment: Sendable {
    public let paths: SandboxPaths
    public let options: SandboxOptions

    /// Host variables that are safe and useful to forward.
    ///
    /// Deliberately short. Anything home-derived, credential-bearing, or
    /// toolchain-related is excluded and rebuilt below.
    public static let passthroughAllowlist: Set<String> = [
        "TERM", "LANG", "LC_ALL", "LC_CTYPE", "TZ",
        "USER", "LOGNAME",
        "SSH_AUTH_SOCK",   // keeps `git push` working; a socket path, not a home path
        "COLORTERM",
    ]

    public init(paths: SandboxPaths, options: SandboxOptions = .default) {
        self.paths = paths
        self.options = options
    }

    // MARK: - Environment

    /// The complete environment for a sandboxed process.
    public func build(workspace: Workspace? = nil) -> [String: String] {
        var env: [String: String] = [:]

        // 1. Curated passthrough from the host.
        let host = ProcessInfo.processInfo.environment
        for key in Self.passthroughAllowlist {
            if let value = host[key] { env[key] = value }
        }

        // 2. Home and identity. This is the core of the isolation.
        env["HOME"] = paths.home.path
        env["JXCODE_HOME"] = paths.home.path
        env["JXCODE_REAL_HOME"] = NSHomeDirectory()
        env["JXCODE_ENV_ROOT"] = paths.envRoot.path
        env["JXCODE_SANDBOX"] = "1"

        // 3. XDG. Many CLIs prefer these over $HOME, so both must agree.
        env["XDG_CONFIG_HOME"] = paths.xdgConfig.path
        env["XDG_DATA_HOME"] = paths.xdgData.path
        env["XDG_STATE_HOME"] = paths.xdgState.path
        env["XDG_CACHE_HOME"] = paths.xdgCache.path
        env["XDG_RUNTIME_DIR"] = paths.xdgRuntime.path

        // 4. Shell plumbing.
        env["SHELL"] = "/bin/zsh"
        env["ZDOTDIR"] = paths.zshDir.path
        env["TMPDIR"] = paths.tmp.path
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["TERM_PROGRAM"] = "JXCode"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"

        // 5. Package managers, each pinned inside the sandbox so a global
        //    install cannot reach the host.
        env["npm_config_prefix"] = paths.npmPrefix.path
        env["NPM_CONFIG_PREFIX"] = paths.npmPrefix.path
        env["npm_config_cache"] = paths.npmCache.path
        env["npm_config_userconfig"] = paths.home.appendingPathComponent(".npmrc").path
        env["NODE_REPL_HISTORY"] = paths.home.appendingPathComponent(".node_repl_history").path

        env["PIP_CACHE_DIR"] = paths.xdgCache.appendingPathComponent("pip").path
        env["PYTHONUSERBASE"] = paths.home.appendingPathComponent(".local").path
        env["PYTHONPYCACHEPREFIX"] = paths.xdgCache.appendingPathComponent("pycache").path

        env["CARGO_HOME"] = paths.cargoHome.path
        env["RUSTUP_HOME"] = paths.rustupHome.path
        env["GOPATH"] = paths.goPath.path
        env["GOMODCACHE"] = paths.goPath.appendingPathComponent("pkg/mod").path
        env["GOBIN"] = paths.goPath.appendingPathComponent("bin").path

        env["GEM_HOME"] = paths.gemHome.path
        env["GEM_SPEC_CACHE"] = paths.gemHome.appendingPathComponent("specs").path
        env["BUNDLE_USER_HOME"] = paths.home.appendingPathComponent(".bundle").path

        // Bun, used by oh-my-pi's `bun install -g`. Without this, a global Bun
        // install would resolve its own prefix under the host home.
        env["BUN_INSTALL"] = paths.bunInstall.path

        // 6. Homebrew, sandboxed. These four must move together or brew will
        //    resolve its own prefix and write to the host.
        env["HOMEBREW_PREFIX"] = paths.brewPrefix.path
        env["HOMEBREW_CELLAR"] = paths.brewPrefix.appendingPathComponent("Cellar").path
        env["HOMEBREW_REPOSITORY"] = paths.brewPrefix.path
        env["HOMEBREW_CACHE"] = paths.xdgCache.appendingPathComponent("Homebrew").path
        env["HOMEBREW_LOGS"] = paths.xdgCache.appendingPathComponent("Homebrew/Logs").path
        env["HOMEBREW_TEMP"] = paths.xdgCache.appendingPathComponent("Homebrew/Temp").path
        env["HOMEBREW_NO_ANALYTICS"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"

        // 7. Agent config roots, set explicitly.
        //
        //    These matter more than $HOME. Claude Code, Codex and Gemini each
        //    read a dedicated variable, and if it is unset they may resolve
        //    home via getpwuid() — which ignores $HOME entirely and returns the
        //    real user directory. Setting them removes that fallback.
        env["CLAUDE_CONFIG_DIR"] = paths.claudeConfig.path
        env["CODEX_HOME"] = paths.codexHome.path
        env["GEMINI_CONFIG_DIR"] = paths.geminiHome.path
        env["GEMINI_CLI_HOME"] = paths.home.path

        //    oh-my-pi and Jules document no such variable. Their config roots
        //    are fixed at ~/.omp and ~/.jules, so they are isolated by $HOME
        //    alone — which is exactly why $HOME is the primary mechanism here
        //    rather than a per-tool variable. See SandboxPaths.ompHome.

        // 8. Workspace context.
        if let workspace {
            env["JXCODE_WORKSPACE"] = workspace.name
            env["JXCODE_WORKSPACE_DIR"] = workspace.path
        }

        // 9. Model router seam (phase 02). Agents read these when the router
        //    is running; unset means "talk to the provider directly".
        if let routerURL = options.routerURL {
            env["JXCODE_ROUTER_URL"] = routerURL
            env["ANTHROPIC_BASE_URL"] = routerURL
            env["OPENAI_BASE_URL"] = routerURL
            // A base URL alone is not enough for Claude Code: it still needs a
            // credential present or it concludes it is not logged in and exits
            // before dialling the router at all. This mirrors what
            // `AgentConfigWriter` writes into settings.json so the CLI and the
            // app produce the same environment.
            //
            // Every shape comes from `RouterAuth.agentEnvironment` rather than
            // being listed here. Writing only the two Anthropic keys meant an
            // OpenAI-shaped agent — Gemini, opencode, oh-my-pi — was handed a
            // base URL with no credential, and Codex was handed a config
            // naming `JXCODE_API_KEY` that nothing ever exported. Turn router
            // auth on and each of them was answered 401, which looks exactly
            // like routing being broken.
            let credential = RouterAuth(
                isEnabled: true,
                token: options.routerToken ?? AgentConfigWriter.placeholderToken
            )
            for (name, value) in credential.agentEnvironment { env[name] = value }
        }

        // 10. PATH, rebuilt from scratch. Order is priority order.
        env["PATH"] = buildPath().joined(separator: ":")

        // 11. Caller overrides win.
        for (key, value) in options.extraEnv { env[key] = value }

        return env
    }

    /// OS-supplied directories the sandbox shares with the host on purpose.
    ///
    /// These are on `PATH` by design: a sandbox with no `sh`, `sed` or `git`
    /// cannot run an agent at all. Sharing them is not a leak — they are
    /// read-only system locations, and the sandbox's own shell init depends on
    /// them (`SHELL` is `/bin/zsh`).
    ///
    /// Named once and referenced from both `buildPath()` and
    /// `AgentRegistry.isEscaping`, so "what we put on `PATH`" and "what we are
    /// willing to call reachable" cannot drift apart.
    public static let baseSystemDirectories: [String] = [
        "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        "/System/Cryptexes/App/usr/bin",
    ]

    /// True when `path` sits inside one of `baseSystemDirectories`.
    ///
    /// Compares whole components rather than raw prefixes, so `/binary/foo`
    /// is not mistaken for a child of `/bin`.
    public static func isSharedSystemPath(_ path: String) -> Bool {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        return baseSystemDirectories.contains { directory in
            candidate == directory || candidate.hasPrefix(directory + "/")
        }
    }

    /// `PATH` for a sandboxed process, highest priority first.
    ///
    /// Note what is absent: `/opt/homebrew/bin` and, unless explicitly opted
    /// in, `/usr/local/bin`. Both are host-wide tool locations.
    public func buildPath() -> [String] {
        var entries: [String] = []

        entries.append(contentsOf: options.extraPathEntries)
        entries.append(paths.bin.path)
        // The shared collection's bin, immediately after the shims.
        //
        // This one entry is what makes an install *shared*: every agent
        // resolves against this same list, so a connector — or anything an
        // agent puts here — is visible to all of them with no further wiring.
        //
        // It sits above the package-manager directories on purpose. The shared
        // collection is the curated layer, so a connector that pins a version
        // should win over a stray `npm i -g` of the same name rather than being
        // shadowed by it.
        entries.append(paths.sharedBin.path)
        entries.append(paths.npmPrefix.appendingPathComponent("bin").path)
        entries.append(paths.localBin.path)
        entries.append(paths.cargoHome.appendingPathComponent("bin").path)
        entries.append(paths.brewPrefix.appendingPathComponent("bin").path)
        entries.append(paths.brewPrefix.appendingPathComponent("sbin").path)
        entries.append(paths.goPath.appendingPathComponent("bin").path)
        entries.append(paths.gemHome.appendingPathComponent("bin").path)
        entries.append(paths.bunInstall.appendingPathComponent("bin").path)

        if options.includeHostLocalBin {
            entries.append("/usr/local/bin")
        }

        // Base system tools only.
        entries.append(contentsOf: Self.baseSystemDirectories)

        // De-duplicate while preserving order.
        var seen = Set<String>()
        return entries.filter { seen.insert($0).inserted }
    }

    /// `execve`-ready form, sorted for deterministic output.
    public func environmentArray(workspace: Workspace? = nil) -> [String] {
        build(workspace: workspace)
            .map { "\($0.key)=\($0.value)" }
            .sorted()
    }

    // MARK: - Reporting

    /// Human-readable dump for `jxcode env` and the app's inspector.
    public func report(workspace: Workspace? = nil) -> String {
        let env = build(workspace: workspace)
        var lines: [String] = []
        lines.append("sandbox root   \(paths.root.path)")
        lines.append("")

        let groups: [(String, [String])] = [
            ("identity", ["HOME", "JXCODE_HOME", "JXCODE_REAL_HOME", "USER", "SHELL"]),
            ("xdg", ["XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME"]),
            ("packages", ["npm_config_prefix", "PIP_CACHE_DIR", "CARGO_HOME", "GOPATH", "GEM_HOME"]),
            ("homebrew", ["HOMEBREW_PREFIX", "HOMEBREW_CELLAR", "HOMEBREW_CACHE"]),
            ("agents", ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GEMINI_CONFIG_DIR"]),
            ("session", ["ZDOTDIR", "TMPDIR", "TERM", "JXCODE_SANDBOX"]),
        ]

        for (title, keys) in groups {
            lines.append("\(title):")
            for key in keys {
                guard let value = env[key] else { continue }
                let shown = value.hasPrefix(paths.root.path)
                    ? paths.display(URL(fileURLWithPath: value))
                    : value
                lines.append("  \(key.padding(toLength: 20, withPad: " ", startingAt: 0))\(shown)")
            }
            lines.append("")
        }

        lines.append("path:")
        for entry in buildPath() {
            let marker = paths.contains(URL(fileURLWithPath: entry)) ? "sandbox" : "host   "
            let shown = entry.hasPrefix(paths.root.path)
                ? paths.display(URL(fileURLWithPath: entry))
                : entry
            lines.append("  [\(marker)] \(shown)")
        }

        return lines.joined(separator: "\n")
    }
}
