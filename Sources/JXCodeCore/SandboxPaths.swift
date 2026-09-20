import Foundation

/// The on-disk layout of an isolated runtime.
///
/// Every path a CLI tool might write to lives under `root`. Nothing here
/// overlaps with the user's real home directory, which is the whole point:
/// installing Claude Code inside the sandbox must not create or modify
/// `~/.claude` on the host.
///
///     ~/Library/Application Support/JXCode/
///     ├── env/
///     │   ├── home/          <- $HOME
///     │   ├── bin/           <- PATH[0], JXCode shims
///     │   ├── npm/           <- npm_config_prefix
///     │   ├── brew/          <- HOMEBREW_PREFIX
///     │   ├── zsh/           <- ZDOTDIR
///     │   └── tmp/           <- TMPDIR
///     ├── shared/            <- skills, connectors, automations (app-wide)
///     ├── workspaces/        <- project directories
///     ├── state/             <- workspaces.json, agents.json
///     └── logs/
public struct SandboxPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// Default sandbox location inside Application Support.
    ///
    /// `JXCODE_ROOT` overrides it. The CLI harness and the tests use that to keep
    /// their sandboxes away from the real one, and it makes the app runnable from
    /// an environment that restricts access to Application Support.
    public static var defaultRoot: URL {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["JXCODE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("JXCode", isDirectory: true)
    }

    public static var `default`: SandboxPaths {
        SandboxPaths(root: defaultRoot)
    }

    // MARK: - Top level

    public var envRoot: URL { root.appendingPathComponent("env", isDirectory: true) }
    public var workspaces: URL { root.appendingPathComponent("workspaces", isDirectory: true) }
    public var state: URL { root.appendingPathComponent("state", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    // MARK: - Inside env/

    /// `$HOME` for every sandboxed process.
    public var home: URL { envRoot.appendingPathComponent("home", isDirectory: true) }

    /// `PATH[0]`. JXCode shims are written here so it can intercept
    /// `npm`/`brew`/`pip` and keep global installs inside the sandbox.
    public var bin: URL { envRoot.appendingPathComponent("bin", isDirectory: true) }

    /// `npm_config_prefix` — `npm i -g` writes to `<npmPrefix>/lib/node_modules`.
    public var npmPrefix: URL { envRoot.appendingPathComponent("npm", isDirectory: true) }

    /// `HOMEBREW_PREFIX` — a Homebrew installed *inside* the sandbox.
    public var brewPrefix: URL { envRoot.appendingPathComponent("brew", isDirectory: true) }

    /// `ZDOTDIR` — generated shell init, so `/etc/zprofile` cannot leak config in.
    public var zshDir: URL { envRoot.appendingPathComponent("zsh", isDirectory: true) }

    /// `TMPDIR`.
    public var tmp: URL { envRoot.appendingPathComponent("tmp", isDirectory: true) }

    // MARK: - Inside env/home/

    /// `CLAUDE_CONFIG_DIR`. Claude Code honours this directly, which matters
    /// because it is more reliable than `$HOME` alone (see `Doctor`).
    public var claudeConfig: URL { home.appendingPathComponent(".claude", isDirectory: true) }
    public var codexHome: URL { home.appendingPathComponent(".codex", isDirectory: true) }
    public var geminiHome: URL { home.appendingPathComponent(".gemini", isDirectory: true) }
    public var npmCache: URL { home.appendingPathComponent(".npm", isDirectory: true) }

    public var xdgConfig: URL { home.appendingPathComponent(".config", isDirectory: true) }
    public var xdgData: URL { home.appendingPathComponent(".local/share", isDirectory: true) }
    public var xdgState: URL { home.appendingPathComponent(".local/state", isDirectory: true) }
    public var xdgCache: URL { home.appendingPathComponent(".cache", isDirectory: true) }
    public var xdgRuntime: URL { home.appendingPathComponent(".local/run", isDirectory: true) }
    public var localBin: URL { home.appendingPathComponent(".local/bin", isDirectory: true) }

    public var cargoHome: URL { home.appendingPathComponent(".cargo", isDirectory: true) }
    public var rustupHome: URL { home.appendingPathComponent(".rustup", isDirectory: true) }
    public var goPath: URL { home.appendingPathComponent("go", isDirectory: true) }
    public var gemHome: URL { home.appendingPathComponent(".gem", isDirectory: true) }

    /// Bun's global install root (`bun install -g`). oh-my-pi is distributed
    /// through Bun, so this needs pinning too.
    public var bunInstall: URL { home.appendingPathComponent(".bun", isDirectory: true) }

    /// oh-my-pi (`omp`). It documents **no** config-directory environment
    /// variable — the root is a fixed `~/.omp`. There is no override lever, so
    /// `$HOME` is the only thing that isolates it. This is the clearest single
    /// argument for private-`$HOME` isolation over per-tool env vars.
    public var ompHome: URL { home.appendingPathComponent(".omp", isDirectory: true) }

    /// Google Jules CLI. Same situation as `omp`: no documented override, so it
    /// follows `$HOME`.
    public var julesHome: URL { home.appendingPathComponent(".jules", isDirectory: true) }

    public var gitConfig: URL { home.appendingPathComponent(".gitconfig", isDirectory: false) }
    public var zshHistory: URL { home.appendingPathComponent(".zsh_history", isDirectory: false) }

    // MARK: - State files

    public var workspacesFile: URL { state.appendingPathComponent("workspaces.json") }
    public var agentsFile: URL { state.appendingPathComponent("agents.json") }
    public var providersFile: URL { state.appendingPathComponent("providers.json") }

    // MARK: - The shared collection

    /// Everything that belongs to the app rather than to one workspace.
    ///
    /// Workspaces are the unit of *work*; this is the unit of *capability*. A
    /// skill, a connector or an automation is written once and every agent in
    /// every workspace gets it, which is the opposite of how a per-project
    /// config would behave. Keeping it as a sibling of `workspaces/` rather
    /// than inside one is the whole point — there is no workspace whose
    /// deletion can take the shared collection with it.
    public var shared: URL { root.appendingPathComponent("shared", isDirectory: true) }

    /// Instruction packs. One directory per skill, each holding a `SKILL.md`.
    public var sharedSkills: URL { shared.appendingPathComponent("skills", isDirectory: true) }

    /// MCP server definitions. One directory per connector.
    public var sharedConnectors: URL {
        shared.appendingPathComponent("connectors", isDirectory: true)
    }

    /// Scheduled runs. One JSON file per automation.
    public var sharedAutomations: URL {
        shared.appendingPathComponent("automations", isDirectory: true)
    }

    /// On `PATH` for every agent, which is what makes an install shared.
    ///
    /// Anything an agent installs that lands here — or that a connector's
    /// install step puts here — is visible to every other agent without any
    /// further wiring, because they all resolve against the same `PATH`.
    public var sharedBin: URL { shared.appendingPathComponent("bin", isDirectory: true) }

    /// The agent-agnostic MCP manifest.
    ///
    /// Written alongside the per-agent configs so the collection has one
    /// canonical record of what is connected, readable by a tool that knows
    /// nothing about any particular agent's schema.
    public var sharedMCPManifest: URL { shared.appendingPathComponent("mcp.json") }

    // MARK: - Per-agent instruction and MCP files

    /// Claude Code's user-level memory file, inside the sandbox home.
    public var claudeMemory: URL {
        claudeConfig.appendingPathComponent("CLAUDE.md", isDirectory: false)
    }

    /// Claude Code's user-level MCP config.
    ///
    /// Note the location: `~/.claude.json`, a *sibling* of `~/.claude/`, not a
    /// child of it. Putting it inside the config directory is the natural
    /// guess and it is wrong — Claude Code never reads it there, and the
    /// failure is silent.
    public var claudeMCPFile: URL {
        home.appendingPathComponent(".claude.json", isDirectory: false)
    }

    /// Where Claude Code looks for skills it can load by name.
    public var claudeSkills: URL {
        claudeConfig.appendingPathComponent("skills", isDirectory: true)
    }

    /// Codex's instruction file.
    public var codexMemory: URL {
        codexHome.appendingPathComponent("AGENTS.md", isDirectory: false)
    }

    /// Codex's MCP config — the same `config.toml` the router block lives in.
    public var codexMCPFile: URL {
        codexHome.appendingPathComponent("config.toml", isDirectory: false)
    }

    /// Gemini CLI's instruction file.
    public var geminiMemory: URL {
        geminiHome.appendingPathComponent("GEMINI.md", isDirectory: false)
    }

    /// Gemini CLI keeps `mcpServers` inside its general `settings.json`.
    public var geminiSettings: URL {
        geminiHome.appendingPathComponent("settings.json", isDirectory: false)
    }

    /// opencode's config, under XDG rather than its own dot-directory.
    public var opencodeConfig: URL {
        xdgConfig
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("opencode.json", isDirectory: false)
    }

    /// opencode's instruction file, next to its config.
    public var opencodeMemory: URL {
        xdgConfig
            .appendingPathComponent("opencode", isDirectory: true)
            .appendingPathComponent("AGENTS.md", isDirectory: false)
    }

    // MARK: - Setup

    /// Every directory that must exist before a shell can start.
    public var requiredDirectories: [URL] {
        [
            root, envRoot, workspaces, state, logs,
            home, bin, npmPrefix, brewPrefix, zshDir, tmp,
            claudeConfig, codexHome, geminiHome, npmCache,
            xdgConfig, xdgData, xdgState, xdgCache, xdgRuntime, localBin,
            cargoHome, rustupHome, goPath, gemHome,
            npmPrefix.appendingPathComponent("bin", isDirectory: true),
            npmPrefix.appendingPathComponent("lib/node_modules", isDirectory: true),
            brewPrefix.appendingPathComponent("bin", isDirectory: true),
            brewPrefix.appendingPathComponent("sbin", isDirectory: true),
            // The shared collection. `sharedBin` is created eagerly because it
            // goes on `PATH`: a `PATH` entry that does not exist is harmless,
            // but a shim written into a missing directory is a failure that
            // only shows up the first time someone installs something.
            //
            // `claudeSkills` and `~/.config/opencode` are deliberately absent.
            // Both are directories a host often symlinks elsewhere — iCloud, a
            // shared repo — and `ImportService.apply` will not replace anything
            // already at the destination: it reports "kept existing" and moves
            // on. Pre-creating them therefore converts the user's symlink into
            // a real directory, silently, and duplicates whatever it pointed
            // at. They are created on demand instead, by
            // `SkillBinder.linkClaudeSkills` and `ConnectorBinder.writeJSON`.
            shared, sharedSkills, sharedConnectors, sharedAutomations, sharedBin,
        ]
    }

    /// Create the whole tree. Idempotent.
    @discardableResult
    public func createDirectories() throws -> [URL] {
        let fm = FileManager.default
        for dir in requiredDirectories {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return requiredDirectories
    }

    /// True when `url` is inside the sandbox. Used to assert that generated
    /// config never points back out at the host filesystem.
    public func contains(_ url: URL) -> Bool {
        let target = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return target == base || target.hasPrefix(base + "/")
    }

    /// The path with the sandbox root replaced by `~sandbox`, for display.
    public func display(_ url: URL) -> String {
        let target = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        guard target.hasPrefix(base) else { return target }
        return "~sandbox" + target.dropFirst(base.count)
    }
}
