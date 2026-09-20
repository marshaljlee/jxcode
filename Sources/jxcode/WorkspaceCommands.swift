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

    print("opened workspace \(workspace.name)")
    print("  \(workspace.path)")
}

/// Every agent the app knows about, built-in and custom.
func cmdAgents(sandbox: Sandbox) throws {
    let registry = AgentRegistry(paths: sandbox.paths)
    let environment = sandbox.env(workspace: nil)

    let builtIn = Set(AgentRegistry.builtIns.map(\.id))
    for agent in registry.agents {
        let origin = builtIn.contains(agent.id) ? "built-in" : "custom"
        let installed = registry.isInstalled(agent, environment: environment) ? "installed" : "not installed"
        print("\(agent.id.padding(toLength: 12, withPad: " ", startingAt: 0))"
            + "\(agent.name.padding(toLength: 18, withPad: " ", startingAt: 0))"
            + "\(origin.padding(toLength: 10, withPad: " ", startingAt: 0))\(installed)")
    }
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

    print("installing \(agent.name) inside \(sandbox.paths.display(sandbox.paths.envRoot))")
    if let install = agent.installCommand { print("  \(install)") }
    print("")

    let outcome = AgentInstaller.install(
        agent: agent,
        sandbox: sandbox,
        workspace: workspace,
        onProgress: { print("  \($0)") }
    )

    print("")
    switch outcome.status {
    case .installed(let path):
        print("installed  \(sandbox.paths.display(URL(fileURLWithPath: path)))")
        exit(0)
    case .failed(let stage, let message):
        print("failed during \(stage.rawValue)")
        print(message)
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
    print("registered agent \(agent.name) as '\(agent.id)'")
    print("  command: \(([agent.command] + agent.arguments).joined(separator: " "))")
    if let install {
        print("  install: \(install)")
    }
    print("")
    print("It runs inside the sandbox, so anything it installs stays inside the app.")
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
        print("no workspaces. create one with: jxcode new <name>")
        return
    }

    for workspace in workspaces {
        let status = GitStatus.read(at: workspace.path, environment: environment)
        print("\(workspace.name)")
        print("  \(workspace.path)")

        if !status.isRepository {
            let reason = status.error ?? "not a git repository"
            print("  \(reason)")
        } else {
            print("  \(status.summary)")
            if let subject = status.lastCommitSubject {
                print("  last commit: \(subject)")
            }
        }
        print("")
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
            print(text)
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
        print("access control enabled")
    }

    if flags.has("--disable") {
        auth.isEnabled = false
        try auth.save(to: sandbox.paths)
        print("access control disabled")
    }

    if flags.has("--regenerate") {
        auth.token = RouterAuth.generateToken()
        try auth.save(to: sandbox.paths)
        print("token regenerated")
    }

    print("")
    print("enabled  \(auth.isEnabled ? "yes" : "no")")
    if let token = auth.token, !token.isEmpty {
        // Shown because the user has to copy it into any client that is not
        // bound by this app. Never logged anywhere else.
        print("token    \(token)")
    } else {
        print("token    (none)")
    }

    if auth.isEnabled {
        print("")
        print("Clients must send it as x-api-key or Authorization: Bearer.")
        print("Agents bound by this app are rewritten with it automatically.")
    } else {
        print("")
        print("Without a token, any process on this machine that can reach the")
        print("router's port can use your API keys.")
    }
}
