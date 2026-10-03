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
    /// Three sources, in this order: `JXCODE_ROOT` (the CLI harness and the
    /// tests, which use it to keep their sandboxes away from the real one),
    /// then the folder the person chose in the app, then this default. See
    /// `SandboxLocationStore.resolvedRoot` for why the env var has to come
    /// first — a saved preference that outranked it would let a leftover file in
    /// Application Support redirect a test run into the user's real directory.
    public static var defaultRoot: URL {
        SandboxLocationStore.resolvedRoot()
    }

    public static var `default`: SandboxPaths {
        SandboxPaths(root: defaultRoot)
    }

    // MARK: - Top level

    public var envRoot: URL { root.appendingPathComponent("env", isDirectory: true) }
    public var workspaces: URL { root.appendingPathComponent("workspaces", isDirectory: true) }
    public var state: URL { root.appendingPathComponent("state", isDirectory: true) }
    public var logs: URL { root.appendingPathComponent("logs", isDirectory: true) }

    /// One log file per alias, under `logs/`.
    ///
    /// A directory rather than a name prefix in the flat `logs/` directory,
    /// because the flat one already holds `router.log` and a session's own
    /// files, and "which of these is a model's output" should not require
    /// knowing the naming convention. See `ModelLogs` for the other three
    /// streams, which stay flat on purpose — they are shared by every model.
    public var modelLogs: URL { logs.appendingPathComponent("models", isDirectory: true) }

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

    /// The dashboard's tool list — the entries the user added themselves.
    ///
    /// A separate file from `agents.json` because the two lists are different
    /// kinds of thing (see `ToolCatalog`): an agent is isolated, a tool is
    /// linked. Keeping them in one file would mean one decoder that has to know
    /// which shape each record is.
    public var toolsFile: URL { state.appendingPathComponent("tools.json") }

    /// The environment policy the user has tuned — see `SandboxConfiguration`.
    ///
    /// In `state/` with the other three rather than at the root: this is
    /// user-owned state that the app rewrites, not a directory of the sandbox's
    /// own layout, and the root is where the environment lives.
    public var sandboxConfigurationFile: URL {
        state.appendingPathComponent("sandbox.json")
    }

    /// The alias table and the idle-unload policy — see `ModelLifecycleStore`.
    ///
    /// A fifth file rather than a section of `providers.json`, even though both
    /// are about backends. A provider is *where a backend is*; an alias is
    /// *what a name means*, and the two change on completely different clocks:
    /// a provider is edited when the user adds a server, an alias when the user
    /// swaps which model is behind a name. Folding them together would make
    /// every profile switch rewrite the file that holds the API keys.
    public var modelsFile: URL {
        state.appendingPathComponent("models.json")
    }

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

    /// The shared system prompt — the source-of-truth file every agent's
    /// bound copy is generated from. A Markdown file, editable in any editor,
    /// for the same reason skills are.
    public var sharedSystemPrompt: URL { shared.appendingPathComponent("system-prompt.md") }

    /// Sidecar for the system prompt: whether it is enabled and when it
    /// changed. The Markdown file stays the source of truth for the content;
    /// the sidecar holds only what the file cannot express.
    public var sharedSystemPromptMeta: URL { shared.appendingPathComponent("system-prompt.json") }

    /// The agent-agnostic MCP manifest.
    ///
    /// Written alongside the per-agent configs so the collection has one
    /// canonical record of what is connected, readable by a tool that knows
    /// nothing about any particular agent's schema.
    public var sharedMCPManifest: URL { shared.appendingPathComponent("mcp.json") }

    /// What the skill bind wrote that cannot be read back off the filesystem.
    ///
    /// The links are recoverable — a symlink into `shared/skills/` is
    /// recognisably ours — but opencode's `permission.skill` entry is a single
    /// JSON key in a file the user also owns. `"*": "allow"` written by JXCode
    /// and `"*": "allow"` written by the user are the same bytes, so unbind has
    /// no way to tell whether removing it is an undo or a regression. This
    /// records the one bit that answers that.
    public var sharedSkillsManifest: URL { shared.appendingPathComponent("skills.json") }

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

    /// `$HOME/.agents` — the parent of the cross-agent skill directory.
    ///
    /// Named separately from the directory inside it because a bind that creates
    /// `skills/` creates this too, and the removal walk has to be able to name
    /// the parent it is climbing into rather than walking an anonymous path.
    public var agentsHome: URL {
        home.appendingPathComponent(".agents", isDirectory: true)
    }

    /// `$HOME/.agents/skills/` — the cross-agent skill directory.
    ///
    /// This is the one worth having. It is read by Codex, by Gemini CLI and by
    /// opencode, so a single link here reaches three agents; `claudeSkills`
    /// reaches Claude Code and opencode. Two symlinks therefore cover four
    /// agents, and the four hand-written markdown blocks that used to be the
    /// only mechanism become a fallback for anything with no skill directory
    /// at all.
    ///
    /// It is deliberately *not* in `requiredDirectories`. A host often
    /// symlinks a skill directory somewhere else — into a dotfiles repo, into
    /// iCloud — and `ImportService.apply` will not replace what it finds at a
    /// destination: it reports "kept existing" and moves on. Pre-creating the
    /// directory would therefore convert that symlink into a real directory,
    /// silently, and duplicate whatever it pointed at. Created on demand by
    /// `SkillBinder` instead.
    public var agentsSkills: URL {
        agentsHome.appendingPathComponent("skills", isDirectory: true)
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

    /// `$HOME/.config/opencode` — opencode's own directory under XDG.
    ///
    /// Named for the same reason as `agentsHome`: both writers that touch it
    /// create it on demand, and both halves of the unbind rule need one name for
    /// it.
    public var opencodeHome: URL {
        xdgConfig.appendingPathComponent("opencode", isDirectory: true)
    }

    /// opencode's config, under XDG rather than its own dot-directory.
    public var opencodeConfig: URL {
        opencodeHome.appendingPathComponent("opencode.json", isDirectory: false)
    }

    /// opencode's instruction file, next to its config.
    public var opencodeMemory: URL {
        opencodeHome.appendingPathComponent("AGENTS.md", isDirectory: false)
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
            // `SkillBinder.link` and `ConnectorBinder.writeJSON`.
            shared, sharedSkills, sharedConnectors, sharedAutomations, sharedBin,
        ]
    }

    /// Every directory a bind may create, and therefore every one an unbind has
    /// to be able to take back.
    ///
    /// The complement of `requiredDirectories`, and the two are only correct
    /// together: a directory that exists before any bind runs can never be owned
    /// by one, and a directory that does not exist must be recorded when a bind
    /// makes it. `claudeSkills` and `opencodeHome` are the pair that actually
    /// differ — both are left out of `requiredDirectories` on purpose, because a
    /// host often symlinks them elsewhere.
    ///
    /// Only the deepest target of each writer is listed. A bind that creates
    /// `agentsSkills` creates `agentsHome` in the same call, and the removal walk
    /// covers ancestors, so naming the parents here would be a second copy of
    /// one fact — and the copy that goes stale.
    public var directoriesABindMayCreate: [URL] {
        [
            claudeConfig, claudeSkills,
            codexHome, geminiHome,
            agentsSkills,
            opencodeHome,
        ]
    }

    /// Create the whole tree. Idempotent.
    ///
    /// Every directory is created `0o700`. The sandbox's entire claim is that it
    /// is private, and `createDirectory` without attributes inherits the umask —
    /// `0o755` on a default account — which leaves `env/home` readable by every
    /// local user. That directory holds `settings.json` with the agent's auth
    /// token, `.claude.json`, connector env tokens and `.gitconfig`.
    @discardableResult
    public func createDirectories() throws -> [URL] {
        let fm = FileManager.default
        for dir in requiredDirectories {
            try fm.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // `attributes` apply only to directories this call actually creates;
            // an existing tree keeps whatever mode it already had. Re-asserting
            // the mode on every pass is therefore both idempotent and a repair
            // for a sandbox created by an earlier version.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
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
