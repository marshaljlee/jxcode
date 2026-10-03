import Foundation
import JXCodeCore

// MARK: - Workspaces, agents, git and router auth
//
// The GUI is the primary surface for these, but the CLI is how the app is
// verified: `jxcode` drives the same `JXCodeCore` types the window does, so a
// passing CLI check is evidence about the app rather than about a parallel
// implementation. These commands exist so that stays true for the features that
// previously had no CLI at all.

/// Open an existing directory as a workspace.
///
/// Nothing is copied or moved — the workspace is a pointer, and the isolation
/// still applies to the toolchain rather than to the code.
func cmdAdopt(sandbox: Sandbox, flags: Flags) throws {
    guard let raw = flags.positional.first else {
        throw CLIError.usage("jxcode adopt <path> [--name <name>]")
    }
    let expanded = (raw as NSString).expandingTildeInPath

    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw CLIError.usage("\(expanded) is not a directory")
    }

    try sandbox.prepare()
    let store = WorkspaceStore(paths: sandbox.paths)
    let name = flags.value("--name") ?? URL(fileURLWithPath: expanded).lastPathComponent
    let workspace = try store.adopt(name: name, path: expanded)

    Console.line("opened workspace \(workspace.name)")
    Console.line("  \(workspace.path)")
}

/// Every agent the app knows about, built-in and custom.
///
/// The primary is marked in the same table rather than printed as a separate
/// heading. The question this command answers is "what can I launch, and which
/// one is in charge", and both answers belong in one place — a reader who has to
/// run two commands to learn whether the agent they were about to start is the
/// one already in charge will not run the second one.
func cmdAgents(sandbox: Sandbox) throws {
    let registry = AgentRegistry(paths: sandbox.paths)
    let environment = sandbox.env(workspace: nil)
    let primary = PrimaryAgentStore(paths: sandbox.paths).load()

    let builtIn = Set(AgentRegistry.builtIns.map(\.id))
    for agent in registry.agents {
        let origin = builtIn.contains(agent.id) ? "built-in" : "custom"
        let installed = registry.isInstalled(agent, environment: environment) ? "installed" : "not installed"
        let role = primary?.agentID == agent.id ? "PRIMARY" : ""
        Console.line("\(agent.id.padding(toLength: 12, withPad: " ", startingAt: 0))"
            + "\(agent.name.padding(toLength: 18, withPad: " ", startingAt: 0))"
            + "\(origin.padding(toLength: 10, withPad: " ", startingAt: 0))"
            + "\(installed.padding(toLength: 14, withPad: " ", startingAt: 0))\(role)")
    }

    if let primary {
        Console.line("")
        Console.line("primary: \(primary.agentName) (\(primary.agentID))")
        Console.line("  may open \(primary.maxSubagents) subagent(s) at a time")
        Console.line("  may install tools: \(primary.canInstallTools ? "yes" : "no")")
        Console.line("  record: \(PrimaryAgentStore(paths: sandbox.paths).fileURL.path)")
    }
}

/// Name the agent in charge.
///
/// Rejects an agent that is not installed rather than writing a record that
/// points at nothing. The GUI refuses the same choice for the same reason: a
/// primary that cannot be launched is a claim the dashboard would show and
/// nothing could honour.
func cmdPrimarySet(sandbox: Sandbox, flags: Flags) throws {
    guard let id = flags.positional.first else {
        throw CLIError.usage("jxcode primary <agent-id> [--subagents N] [--no-install]")
    }
    let registry = AgentRegistry(paths: sandbox.paths)
    guard let agent = registry.agent(id: id) else {
        throw CLIError.usage("no agent with id “\(id)”. Run jxcode agents to see the list.")
    }
    let environment = sandbox.env(workspace: nil)
    guard registry.isInstalled(agent, environment: environment) else {
        throw CLIError.usage(
            "\(agent.name) is not installed. Run: jxcode install \(agent.id)"
        )
    }

    // Default to whatever is already recorded, so setting the primary twice
    // without naming the numbers does not silently reset them to the defaults.
    let store = PrimaryAgentStore(paths: sandbox.paths)
    let existing = store.load()
    let subagents = flags.intValue("--subagents") ?? existing?.maxSubagents ?? 4
    let canInstall = flags.has("--no-install")
        ? false
        : (existing?.canInstallTools ?? true)

    let record = PrimaryAgent(
        agentID: agent.id,
        agentName: agent.name,
        maxSubagents: max(0, min(16, subagents)),
        canInstallTools: canInstall
    )
    guard store.save(record) else {
        throw CLIError.io("could not write \(store.fileURL.path)")
    }

    Console.line("\(agent.name) is now the primary agent.")
    Console.line("  may open \(record.maxSubagents) subagent(s) at a time")
    Console.line("  may install tools: \(record.canInstallTools ? "yes" : "no")")
    Console.line("")
    Console.line("The app hands it its orders the next time it starts that agent.")
    Console.line("Print them now with: jxcode primary --show")
}

/// Show the current primary, or set nothing.
func cmdPrimaryShow(sandbox: Sandbox, flags: Flags) throws {
    let store = PrimaryAgentStore(paths: sandbox.paths)
    guard let record = store.load() else {
        Console.line("No primary agent. Every agent is on its own.")
        Console.line("Set one with: jxcode primary <agent-id>")
        return
    }
    let registry = AgentRegistry(paths: sandbox.paths)
    let environment = sandbox.env(workspace: nil)

    Console.line("\(record.agentName) (\(record.agentID)) is in charge.")
    Console.line("  may open \(record.maxSubagents) subagent(s) at a time")
    Console.line("  may install tools: \(record.canInstallTools ? "yes" : "no")")
    Console.line("  record: \(store.fileURL.path)")
    Console.line("")

    if flags.has("--charter") {
        let charter = PrimaryCharter().plainCharter(
            primary: record,
            subagents: registry.agents,
            environment: environment
        )
        Console.line(charter)
        return
    }

    let others = registry.agents
        .filter { $0.id != record.agentID }
        .filter { registry.isInstalled($0, environment: environment) }
    if others.isEmpty {
        Console.line("No other agent is installed, so there is nothing to hand work to.")
    } else {
        Console.line("It may call these \(others.count) agent(s):")
        for agent in others.sorted(by: { $0.name < $1.name }) {
            Console.line("  \(agent.name) — jxcode install \(agent.id)")
        }
    }
}

/// Give up the primary. Every agent goes back to being on its own.
func cmdPrimaryClear(sandbox: Sandbox) throws {
    let store = PrimaryAgentStore(paths: sandbox.paths)
    guard store.clear() else {
        throw CLIError.io("could not remove \(store.fileURL.path)")
    }
    Console.line("No primary agent. Every agent is on its own.")
}

/// Install an agent into the sandbox — the same path a click on the launcher
/// takes.
///
/// It exists so the install can be exercised without the window, and it calls
/// the same `AgentInstaller` the app does: a passing run here is evidence about
/// the app rather than about a parallel implementation.
func cmdAgentInstall(sandbox: Sandbox, flags: Flags) throws {
    guard let id = flags.positional.first else {
        throw CLIError.usage("jxcode install <agent-id>   (see: jxcode agents)")
    }
    let registry = AgentRegistry(paths: sandbox.paths)
    guard let agent = registry.agent(id: id) else {
        throw CLIError.usage("no agent named '\(id)'. see: jxcode agents")
    }

    let workspace = try resolveWorkspace(sandbox: sandbox, flags: flags)
    try sandbox.prepare()

    Console.line("installing \(agent.name) inside \(sandbox.paths.display(sandbox.paths.envRoot))")
    if let install = agent.installCommand { Console.line("  \(install)") }
    Console.line("")

    let outcome = AgentInstaller.install(
        agent: agent,
        sandbox: sandbox,
        workspace: workspace,
        onProgress: { Console.line("  \($0)") }
    )

    Console.line("")
    switch outcome.status {
    case .installed(let path):
        Console.line("installed  \(sandbox.paths.display(URL(fileURLWithPath: path)))")
        exit(0)
    case .failed(let stage, let message):
        Console.line("failed during \(stage.rawValue)")
        Console.line(message)
        exit(1)
    }
}

/// Register a CLI the built-in list does not know about.
func cmdAgentAdd(sandbox: Sandbox, flags: Flags) throws {
    guard let name = flags.value("--name") else {
        throw CLIError.usage("jxcode agent-add --name <name> --command <command> [--args \"…\"] [--install \"…\"]")
    }
    guard let command = flags.value("--command") else {
        throw CLIError.usage("jxcode agent-add --name <name> --command <command> [--args \"…\"] [--install \"…\"]")
    }

    try sandbox.prepare()
    let registry = AgentRegistry(paths: sandbox.paths)

    let arguments = (flags.value("--args") ?? "")
        .split(separator: " ")
        .map(String.init)
        .filter { !$0.isEmpty }

    let install = flags.value("--install")
    let agent = AgentDefinition(
        id: slug(for: name),
        name: name,
        command: command,
        arguments: arguments,
        installCommand: install
    )

    try registry.add(agent)
    Console.line("registered agent \(agent.name) as '\(agent.id)'")
    Console.line("  command: \(([agent.command] + agent.arguments).joined(separator: " "))")
    if let install {
        Console.line("  install: \(install)")
    }
    Console.line("")
    Console.line("It runs inside the sandbox, so anything it installs stays inside the app.")
}

/// A stable id from a display name, matching what the GUI does.
func slug(for name: String) -> String {
    Identifier.slug(name, fallback: "agent")
}

/// Git state for every workspace.
///
/// Read with the sandbox environment, so `git` is the same one an agent would
/// find — otherwise this reports on a toolchain the app never uses.
func cmdGit(sandbox: Sandbox, flags: Flags) throws {
    let store = WorkspaceStore(paths: sandbox.paths)
    let environment = sandbox.env(workspace: nil)

    let workspaces = store.workspaces
    guard !workspaces.isEmpty else {
        Console.line("no workspaces. create one with: jxcode new <name>")
        return
    }

    for workspace in workspaces {
        let status = GitStatus.read(at: workspace.path, environment: environment)
        Console.line("\(workspace.name)")
        Console.line("  \(workspace.path)")

        if !status.isRepository {
            let reason = status.error ?? "not a git repository"
            Console.line("  \(reason)")
        } else {
            Console.line("  \(status.summary)")
            if let subject = status.lastCommitSubject {
                Console.line("  last commit: \(subject)")
            }
        }
        Console.line("")
    }

    if flags.has("--json") {
        // Printed after the human view so both are available in one run.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = workspaces.map { workspace -> [String: String] in
            let status = GitStatus.read(at: workspace.path, environment: environment)
            return ["name": workspace.name, "path": workspace.path, "status": status.summary]
        }
        if let data = try? encoder.encode(payload),
           let text = String(data: data, encoding: .utf8) {
            Console.line(text)
        }
    }
}

/// Inspect or change the router's access token.
func cmdAuth(sandbox: Sandbox, flags: Flags) throws {
    try sandbox.prepare()
    var auth = RouterAuth.load(from: sandbox.paths)

    if flags.has("--enable") {
        auth.isEnabled = true
        if auth.token?.isEmpty != false {
            auth.token = RouterAuth.generateToken()
        }
        try auth.save(to: sandbox.paths)
        Console.line("access control enabled")
    }

    if flags.has("--disable") {
        auth.isEnabled = false
        try auth.save(to: sandbox.paths)
        Console.line("access control disabled")
    }

    if flags.has("--regenerate") {
        auth.token = RouterAuth.generateToken()
        try auth.save(to: sandbox.paths)
        Console.line("token regenerated")
    }

    Console.line("")
    Console.line("enabled  \(auth.isEnabled ? "yes" : "no")")
    if let token = auth.token, !token.isEmpty {
        // Shown because the user has to copy it into any client that is not
        // bound by this app. Never logged anywhere else.
        Console.line("token    \(token)")
    } else {
        Console.line("token    (none)")
    }

    if auth.isEnabled {
        Console.line("")
        Console.line("Clients must send it as x-api-key or Authorization: Bearer.")
        Console.line("Agents bound by this app are rewritten with it automatically.")
    } else {
        Console.line("")
        Console.line("Without a token, any process on this machine that can reach the")
        Console.line("router's port can use your API keys.")
    }
}
