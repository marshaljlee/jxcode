import Foundation
import Darwin
import JXCodeCore

// JXCode headless harness.
//
// Exists so the isolation can be exercised and verified without the GUI. Every
// command here goes through the same `Sandbox` the app uses, so a passing
// `jxcode prove` is evidence about the app, not about a parallel code path.

// MARK: - Entry

let arguments = Array(CommandLine.arguments.dropFirst())

guard let command = arguments.first, !["-h", "--help", "help"].contains(command) else {
    printUsage()
    exit(0)
}

let flags = parseFlags(Array(arguments.dropFirst()))
let sandbox = Sandbox(
    paths: .default,
    options: SandboxOptions(
        includeHostLocalBin: flags.has("--include-host-local-bin"),
        routerURL: flags.value("--router")
    )
)

do {
    switch command {
    case "env":
        try cmdEnv(sandbox: sandbox, flags: flags)
    case "paths":
        try cmdPaths(sandbox: sandbox)
    case "doctor":
        try cmdDoctor(sandbox: sandbox, flags: flags)
    case "prove":
        try cmdProve(sandbox: sandbox)
    case "run":
        try cmdRun(sandbox: sandbox, flags: flags, arguments: Array(arguments.dropFirst()))
    case "pty":
        try cmdPTY(sandbox: sandbox, flags: flags, arguments: Array(arguments.dropFirst()))
    case "import":
        try cmdImport(sandbox: sandbox, flags: flags)
    case "ls":
        try cmdList(sandbox: sandbox)
    case "new":
        try cmdNew(sandbox: sandbox, flags: flags)
    case "adopt":
        try cmdAdopt(sandbox: sandbox, flags: flags)
    case "git":
        try cmdGit(sandbox: sandbox, flags: flags)
    case "agents":
        try cmdAgents(sandbox: sandbox)
    case "install":
        try cmdAgentInstall(sandbox: sandbox, flags: flags)
    case "agent-add":
        try cmdAgentAdd(sandbox: sandbox, flags: flags)
    case "shared":
        try cmdShared(sandbox: sandbox, flags: flags)
    case "shared-bind":
        try cmdSharedBind(sandbox: sandbox, flags: flags)
    case "shared-revert":
        try cmdSharedRevert(sandbox: sandbox, flags: flags)
    case "skill-add":
        try cmdSkillAdd(sandbox: sandbox, flags: flags)
    case "skill-remove":
        try cmdSkillRemove(sandbox: sandbox, flags: flags)
    case "skill-enable":
        try cmdSkillToggle(sandbox: sandbox, flags: flags, enabled: true)
    case "skill-disable":
        try cmdSkillToggle(sandbox: sandbox, flags: flags, enabled: false)
    case "connector-add":
        try cmdConnectorAdd(sandbox: sandbox, flags: flags)
    case "connector-remove":
        try cmdConnectorRemove(sandbox: sandbox, flags: flags)
    case "automation-add":
        try cmdAutomationAdd(sandbox: sandbox, flags: flags)
    case "automation-remove":
        try cmdAutomationRemove(sandbox: sandbox, flags: flags)
    case "automation-run":
        try cmdAutomationRun(sandbox: sandbox, flags: flags)
    case "auth":
        try cmdAuth(sandbox: sandbox, flags: flags)
    case "models":
        try cmdModels(sandbox: sandbox, flags: flags)
    case "providers":
        try cmdProviders(sandbox: sandbox)
    case "provider-add":
        try cmdProviderAdd(sandbox: sandbox, flags: flags)
    case "provider-remove":
        try cmdProviderRemove(sandbox: sandbox, flags: flags)
    case "route":
        try cmdRoute(sandbox: sandbox, flags: flags)
    case "bind":
        try cmdBind(sandbox: sandbox, flags: flags)
    case "unbind":
        try cmdUnbind(sandbox: sandbox, flags: flags)
    case "translate":
        try cmdTranslate(sandbox: sandbox, flags: flags)
    case "scan":
        try cmdScan(sandbox: sandbox, flags: flags)
    case "model-info":
        try cmdModelInfo(sandbox: sandbox, flags: flags)
    case "llama-plan":
        try cmdLlamaPlan(sandbox: sandbox, flags: flags)
    case "runtime":
        try cmdRuntime(sandbox: sandbox, flags: flags)
    case "serve":
        try cmdServe(sandbox: sandbox, flags: flags)
    default:
        FileHandle.standardError.write(Data("unknown command: \(command)\n\n".utf8))
        printUsage()
        exit(2)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

// MARK: - Commands

func cmdEnv(sandbox: Sandbox, flags: Flags) throws {
    let workspace = try resolveWorkspace(sandbox: sandbox, flags: flags)
    print(sandbox.environment.report(workspace: workspace))
}

func cmdPaths(sandbox: Sandbox) throws {
    let paths = sandbox.paths
    print("sandbox root      \(paths.root.path)")
    print("")
    let rows: [(String, URL)] = [
        ("$HOME", paths.home),
        ("PATH[0]", paths.bin),
        ("npm prefix", paths.npmPrefix),
        ("brew prefix", paths.brewPrefix),
        ("ZDOTDIR", paths.zshDir),
        ("$TMPDIR", paths.tmp),
        ("claude config", paths.claudeConfig),
        ("codex home", paths.codexHome),
        ("workspaces", paths.workspaces),
        ("state", paths.state),
    ]
    for (label, url) in rows {
        let exists = FileManager.default.fileExists(atPath: url.path) ? " " : " (not created)"
        print("\(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(url.path)\(exists)")
    }
}

func cmdDoctor(sandbox: Sandbox, flags: Flags) throws {
    try sandbox.prepare()
    let registry = AgentRegistry(paths: sandbox.paths)
    let report = Doctor.run(sandbox: sandbox, registry: registry)
    print(report.rendered(verbose: !flags.has("--quiet")))
    exit(report.isHealthy ? 0 : 1)
}

func cmdList(sandbox: Sandbox) throws {
    let store = WorkspaceStore(paths: sandbox.paths)
    guard !store.workspaces.isEmpty else {
        print("no workspaces. create one with: jxcode new <name>")
        return
    }
    for workspace in store.workspaces {
        print("  \(workspace.name)")
        print("    \(workspace.path)")
    }
}

func cmdNew(sandbox: Sandbox, flags: Flags) throws {
    guard let name = flags.positional.first else {
        throw CLIError.usage("jxcode new <name>")
    }
    try sandbox.prepare()
    let store = WorkspaceStore(paths: sandbox.paths)
    let workspace = try store.create(name: name)
    print("created workspace \(workspace.name)")
    print("  \(workspace.path)")
}

func cmdRun(sandbox: Sandbox, flags: Flags, arguments: [String]) throws {
    let command = flags.positional
    guard let executable = command.first else {
        throw CLIError.usage("jxcode run <command> [args...]")
    }
    let workspace = try resolveWorkspace(sandbox: sandbox, flags: flags)
    let result = try sandbox.run(
        executable,
        arguments: Array(command.dropFirst()),
        workspace: workspace
    )
    FileHandle.standardOutput.write(Data(result.stdout.utf8))
    FileHandle.standardError.write(Data(result.stderr.utf8))
    exit(result.exitCode)
}

func cmdImport(sandbox: Sandbox, flags: Flags) throws {
    try sandbox.prepare()
    let realHome = NSHomeDirectory()
    let plan = ImportService.plan(paths: sandbox.paths, realHome: realHome)

    print(ImportService.render(plan, paths: sandbox.paths))
    print("")

    if flags.has("--dry-run") {
        print("dry run — nothing written.")
        return
    }

    let messages = try ImportService.apply(plan, overwrite: flags.has("--overwrite"))
    for message in messages { print("  \(message)") }
    print("")
    print("Import complete. The sandbox and the host now diverge independently.")
}

func cmdPTY(sandbox: Sandbox, flags: Flags, arguments: [String]) throws {
    let command = flags.positional
    guard let executable = command.first else {
        throw CLIError.usage("jxcode pty <command> [args...]")
    }
    let workspace = try resolveWorkspace(sandbox: sandbox, flags: flags)
    let (columns, rows) = terminalSize()

    let original = makeRaw()
    defer { restore(original) }

    let finished = DispatchSemaphore(value: 0)
    var exitCode: Int32 = 0

    // Handlers are installed through `configure` rather than after the fact.
    // Assigning `onData` once `start()` has returned races the child: the pty
    // can have bytes ready the instant it is forked, and anything delivered
    // before the assignment is dropped — which for an interactive shell means
    // losing its opening prompt.
    let session = try sandbox.launchCommand(
        executable,
        arguments: Array(command.dropFirst()),
        workspace: workspace,
        columns: columns,
        rows: rows
    ) { session in
        session.onData = { data in
            FileHandle.standardOutput.write(data)
        }
        session.onExit = { code in
            exitCode = code
            finished.signal()
        }
    }

    // stdin -> pty
    DispatchQueue.global().async {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(STDIN_FILENO, &buffer, buffer.count)
            if count <= 0 { break }
            session.write(Data(buffer[0..<count]))
        }
    }

    finished.wait()
    restore(original)
    print("")
    exit(exitCode)
}

// MARK: - prove
//
// Dynamic verification. Unlike `doctor`, which inspects configuration, this
// actually spawns processes inside the sandbox and checks where they land.

func cmdProve(sandbox: Sandbox) throws {
    try sandbox.prepare()
    let paths = sandbox.paths
    let realHome = NSHomeDirectory()
    let hostClaude = URL(fileURLWithPath: realHome).appendingPathComponent(".claude")

    var results: [(String, Bool, String)] = []

    func check(_ title: String, _ body: () throws -> (Bool, String)) {
        do {
            let (ok, detail) = try body()
            results.append((title, ok, detail))
        } catch {
            results.append((title, false, "\(error)"))
        }
    }

    // 1. $HOME inside a spawned shell.
    check("shell $HOME resolves inside the sandbox") {
        let result = try sandbox.run("/bin/zsh", arguments: ["-lc", "print -n $HOME"])
        let value = result.combined
        return (paths.contains(URL(fileURLWithPath: value)), value)
    }

    // 2. `cd ~` lands in the sandbox, not the host home.
    check("tilde expansion resolves inside the sandbox") {
        let result = try sandbox.run("/bin/zsh", arguments: ["-lc", "cd ~ && pwd"])
        let value = result.combined
        return (paths.contains(URL(fileURLWithPath: value)), value)
    }

    // 3. Writing to $HOME stays inside.
    check("writing to $HOME stays inside the sandbox") {
        let marker = "jxcode-prove-\(UUID().uuidString.prefix(8))"
        let script = "print -n \(marker) > $HOME/.\(marker) && print -n $HOME/.\(marker)"
        let result = try sandbox.run("/bin/zsh", arguments: ["-lc", script])
        let written = result.combined
        let ok = paths.contains(URL(fileURLWithPath: written))
            && FileManager.default.fileExists(atPath: written)
        return (ok, written)
    }

    // 4. Claude Code's config root. This is the check the whole app turns on.
    check("CLAUDE_CONFIG_DIR resolves inside the sandbox") {
        let result = try sandbox.run("/bin/zsh", arguments: ["-lc", "print -n $CLAUDE_CONFIG_DIR"])
        let value = result.combined
        return (value == paths.claudeConfig.path, value)
    }

    // 5. And that the global memory file an agent would read is the sandbox one.
    check("global CLAUDE.md resolves to the sandbox copy") {
        let result = try sandbox.run(
            "/bin/zsh",
            arguments: ["-lc", "print -n $CLAUDE_CONFIG_DIR/CLAUDE.md"]
        )
        let value = result.combined
        return (value == paths.claudeConfig.appendingPathComponent("CLAUDE.md").path, value)
    }

    // 6. npm global prefix. If this is wrong, `npm i -g` writes to the host.
    check("npm global prefix resolves inside the sandbox") {
        let result = try sandbox.run("/bin/zsh", arguments: ["-lc", "print -n $npm_config_prefix"])
        let value = result.combined
        return (value == paths.npmPrefix.path, value)
    }

    // 7. PATH must not expose host-wide tool directories.
    check("PATH exposes no host tool directories") {
        let result = try sandbox.run("/bin/zsh", arguments: ["-lc", "print -n $PATH"])
        let entries = result.combined.split(separator: ":").map(String.init)
        let offenders = entries.filter {
            $0.hasPrefix("/opt/homebrew") || $0.hasPrefix("/usr/local/bin")
        }
        return (offenders.isEmpty, offenders.isEmpty ? "\(entries.count) entries, all sandbox or system"
                                                     : "offenders: \(offenders.joined(separator: ", "))")
    }

    // 8. `which` for the agents we care about.
    check("agent binaries resolve inside the sandbox (or are absent)") {
        let result = try sandbox.run(
            "/bin/zsh",
            arguments: ["-lc", "for c in claude codex gemini; do print -n \"$c=$(whence -p $c || print -n none) \"; done"]
        )
        let output = result.combined
        let escaping = output.split(separator: " ").compactMap { pair -> String? in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1] != "none" else { return nil }
            return paths.contains(URL(fileURLWithPath: parts[1])) ? nil : parts[1]
        }
        return (escaping.isEmpty, escaping.isEmpty ? output : "escaping: \(escaping.joined(separator: ", "))")
    }

    // 9. The host config is untouched.
    check("host ~/.claude was not modified") {
        guard FileManager.default.fileExists(atPath: hostClaude.path) else {
            return (true, "host ~/.claude does not exist")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: hostClaude.path)
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        let age = Date().timeIntervalSince(modified)
        // The sandbox was created moments ago; if the host dir moved too, we leaked.
        return (age > 60, "last modified \(Int(age))s ago — untouched by this run")
    }

    // Report
    print("JXCode isolation proof")
    print(String(repeating: "─", count: 64))
    var failures = 0
    for (title, ok, detail) in results {
        if !ok { failures += 1 }
        print("[\(ok ? "  ok  " : " FAIL ")] \(title)")
        print("         \(detail)")
    }
    print(String(repeating: "─", count: 64))
    print("\(results.count - failures)/\(results.count) checks passed")

    if failures == 0 {
        print("Isolation verified. Agents launched here cannot reach the host toolchain.")
    } else {
        print("Isolation is leaking — see FAIL entries above.")
    }
    exit(failures == 0 ? 0 : 1)
}

// MARK: - Support

enum CLIError: Error, CustomStringConvertible {
    case usage(String)

    var description: String {
        switch self {
        case .usage(let text): return "usage: \(text)"
        }
    }
}

struct Flags {
    var positional: [String] = []
    var options: [String: String] = [:]

    func has(_ name: String) -> Bool { options[name] != nil }
    func value(_ name: String) -> String? { options[name] }
}

func parseFlags(_ arguments: [String]) -> Flags {
    var flags = Flags()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        if argument.hasPrefix("--") {
            // `--key value` when a value follows and is not itself a flag.
            if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                flags.options[argument] = arguments[index + 1]
                index += 2
                continue
            }
            flags.options[argument] = ""
        } else {
            flags.positional.append(argument)
        }
        index += 1
    }
    return flags
}

func resolveWorkspace(sandbox: Sandbox, flags: Flags) throws -> Workspace? {
    guard let name = flags.value("--workspace") else { return nil }
    let store = WorkspaceStore(paths: sandbox.paths)
    guard let workspace = store.workspaces.first(where: { $0.name == name }) else {
        throw CLIError.usage("no workspace named '\(name)'. see: jxcode ls")
    }
    return workspace
}

func terminalSize() -> (columns: Int, rows: Int) {
    var size = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0, size.ws_col > 0 {
        return (Int(size.ws_col), Int(size.ws_row))
    }
    return (120, 32)
}

func makeRaw() -> termios {
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    return original
}

func restore(_ original: termios) {
    var value = original
    tcsetattr(STDIN_FILENO, TCSANOW, &value)
}

func printUsage() {
    print("""
    jxcode — JXCode sandbox harness

    USAGE
      jxcode <command> [options]

    COMMANDS
      env                     Dump the resolved sandbox environment
      paths                   Show the sandbox directory layout
      doctor                  Audit the sandbox for leaks
      prove                   Spawn processes and verify isolation dynamically
      run <cmd> [args...]     Run a command inside the sandbox
      pty <cmd> [args...]     Run a command in a pty, interactively
      import [--dry-run]      Seed the sandbox from your host agent config
      ls                      List workspaces
      new <name>              Create a workspace
      adopt <path>            Open an existing directory as a workspace
      git                     Git state for every workspace (--json)

    AGENTS
      agents                  List built-in and custom agents
      install <agent-id>      Install an agent into the sandbox, as the launcher does
      agent-add --name <name> --command <cmd>
                              Register a CLI the built-in list lacks
                              (--args "…", --install "…")

    SHARED COLLECTION (app-wide, not per workspace)
      shared                  Skills, agents, connectors and automations at a glance
      shared-bind             Apply the collection to every agent
      shared-revert           Remove every binding the collection wrote
      skill-add --name <name> [--description "…"] [--file <path> | --body "…"]
                              Write a shared instruction pack
      skill-remove <id>       Delete a skill
      skill-enable <id>       Turn a skill on
      skill-disable <id>      Turn a skill off, keeping it
      connector-add --name <name> [--command <cmd> --args "…" | --url <url>]
                              Register an MCP server for every agent
                              (--install "…", --env "K=V,…")
      connector-remove <id>   Delete a connector
      automation-add --name <name> --agent <id> --prompt "…"
                              Schedule an agent run
                              (--cadence daily|weekly|interval, --hour, --minute,
                               --weekday, --interval, --workspace)
      automation-remove <id>  Delete an automation
      automation-run [<id>]   Run one now, or everything that is due

    PROVIDERS
      models <base-url>       Probe a backend and list the models it serves
      providers               List registered backends
      provider-add <name> <base-url>
                              Register a backend (--kind, --key, --fetch)
      provider-remove <name>  Forget a backend

    ROUTING
      route                   Serve every agent from the selected backend
      bind                    Write agent configs to point at the router
      unbind                  Undo `bind`
      translate <file>        Show how an Anthropic request is translated
      auth                    Show the router's access token
                              (--enable, --disable, --regenerate)

    LOCAL MODELS
      scan [dir...]           List local GGUF models and their vision projectors
      model-info <file>       Dump a GGUF file's metadata
      llama-plan <file>       Show how llama-server would be configured
      runtime                 Show where llama-server was looked for
      serve <file>            Serve a local model (--port, --register)

    OPTIONS
      --workspace <name>      Target a workspace
      --name <name>           Display name for `adopt` and `agent-add`
      --command <cmd>         Executable to launch for `agent-add`
      --args "…"              Default arguments for `agent-add`
      --install "…"           Install command shown for `agent-add`
      --json                  Machine-readable output where supported
      --router <url>          Point agents at a local model router
      --provider <name>       Select a backend for `route`
      --model <name>          Select a model
      --port <n>              Router port (default \(RouterConfiguration.defaultPort))
      --kind <kind>           openAICompatible | anthropic | ollama | localGGUF
      --key <key>             API key for a backend
      --fetch                 Fetch the model list when registering
      --models <dir>          Model directory for `scan`
      --names-only            Skip reading metadata when scanning (much faster)
      --plan                  Include the computed llama-server plan in `scan`
      --paths                 Show full file paths in `scan`
      --memory <policy>       safe | balanced | maximal  (default safe)
      --cache <policy>        quality | balanced | context  (default balanced)
      --register              Register a served model as a backend
      --all-keys              Show every GGUF metadata key in `model-info`
      --template              Print the chat template in `model-info`
      --include-host-local-bin
                              Add /usr/local/bin to PATH (off by default)
      --quiet                 Terse output
      --overwrite             Overwrite existing files when importing
    """)
}
