import Foundation
import JXCodeCore

// MARK: - The shared collection
//
// The GUI is the primary surface, but the CLI is how it is verified: these
// commands drive the same `SharedStore`, `SkillBinder`, `ConnectorBinder` and
// `AutomationRunner` the window does, so a passing run here is evidence about
// the app rather than about a parallel implementation.
//
// The collection is app-wide. It is deliberately *not* reachable through
// `--workspace`, because the point of it is that a skill, connector or
// automation is written once and every workspace sees it.

/// The whole collection at a glance.
func cmdShared(sandbox: Sandbox, flags: Flags) throws {
    try sandbox.prepare()
    let store = SharedStore(paths: sandbox.paths)
    let registry = AgentRegistry(paths: sandbox.paths)

    print("shared collection  \(sandbox.paths.display(sandbox.paths.shared))")
    print("")

    print("skills  (\(store.skills.count))")
    if store.skills.isEmpty {
        print("  none — add one with: jxcode skill-add --name \"Release checklist\"")
    }
    for skill in store.skills {
        let mark = skill.enabled ? "on " : "off"
        print("  [\(mark)] \(skill.id.padding(toLength: 20, withPad: " ", startingAt: 0))\(skill.name)")
        if !skill.summary.isEmpty {
            print("        \(skill.summary)")
        }
    }
    print("")

    let environment = sandbox.env(workspace: nil)
    print("agents  (\(registry.agents.count))")
    for agent in registry.agents {
        let installed = registry.isInstalled(agent, environment: environment)
        print("  [\(installed ? "ok " : "   ")] \(agent.id.padding(toLength: 20, withPad: " ", startingAt: 0))\(agent.name)")
    }
    print("")

    print("connectors  (\(store.connectors.count))")
    if store.connectors.isEmpty {
        print("  none — add one with: jxcode connector-add --name filesystem --command npx --args \"-y @modelcontextprotocol/server-filesystem\"")
    }
    for connector in store.connectors {
        let mark = connector.enabled ? "on " : "off"
        let detail = connector.transport == .stdio
            ? connector.argv.joined(separator: " ")
            : connector.url
        print("  [\(mark)] \(connector.id.padding(toLength: 20, withPad: " ", startingAt: 0))\(detail)")
    }
    print("")

    print("automations  (\(store.automations.count))")
    if store.automations.isEmpty {
        print("  none — add one with: jxcode automation-add --name nightly --agent claude --prompt \"triage open issues\"")
    }
    for automation in store.automations {
        let mark = automation.enabled ? "on " : "off"
        print("  [\(mark)] \(automation.id.padding(toLength: 20, withPad: " ", startingAt: 0))"
            + "\(automation.schedule.summary)  →  \(automation.agentID)")
        if let result = automation.lastResult {
            print("        last: \(result)")
        }
    }
    print("")

    let manifest = ConnectorBinder.readManifest(paths: sandbox.paths)
    print("registered connectors  \(manifest.managed.isEmpty ? "none" : manifest.managed.joined(separator: ", "))")
    print("apply the collection to every agent with: jxcode shared-bind")
}

/// Bind skills and connectors into every agent that can take them.
func cmdSharedBind(sandbox: Sandbox, flags: Flags) throws {
    try sandbox.prepare()
    let store = SharedStore(paths: sandbox.paths)
    let registry = AgentRegistry(paths: sandbox.paths)

    let skills = store.skills
    let connectors = store.connectors

    // Connector installs first: binding a connector whose binary does not exist
    // yet registers a server that cannot start, and the agent reports a
    // connection failure rather than a missing install.
    let installs = ConnectorBinder.installShared(
        connectors: connectors,
        sandbox: sandbox,
        onProgress: { _, message in print("  \(message)") }
    )
    print("binding skills")
    for report in try SkillBinder.apply(
        skills: skills,
        agents: registry.agents,
        paths: sandbox.paths
    ) {
        print("  \(report.summary)")
        for note in report.notes { print("      \(note)") }
    }

    print("")
    print("binding connectors")
    let bound = try ConnectorBinder.apply(
        connectors: connectors,
        agents: registry.agents,
        paths: sandbox.paths
    )
    for report in bound {
        print("  \(report.summary)")
        for note in report.notes { print("      \(note)") }
    }

    // A bind that printed what went wrong and then exited 0 told a script
    // nothing: `shared-bind && run` carried on against a sandbox that is only
    // half bound. Failures are collected rather than printed where they happen,
    // so each one is reported once and the exit code can follow from them.
    let failures = SharedBind.failures(installs: installs, connectors: bound)
    guard failures.isEmpty else {
        print("")
        print("\(failures.count) \(failures.count == 1 ? "thing did" : "things did") not bind:")
        for failure in failures { print("  \(failure.line)") }
        exit(1)
    }
}

/// Remove every binding the collection wrote.
func cmdSharedRevert(sandbox: Sandbox, flags: Flags) throws {
    try sandbox.prepare()
    let registry = AgentRegistry(paths: sandbox.paths)

    for message in try SkillBinder.revert(agents: registry.agents, paths: sandbox.paths) {
        print(message)
    }
    for message in try ConnectorBinder.revert(agents: registry.agents, paths: sandbox.paths) {
        print(message)
    }
    print("the shared collection is unbound. Its contents are untouched.")
}

// MARK: - Skills

func cmdSkillAdd(sandbox: Sandbox, flags: Flags) throws {
    guard let name = flags.value("--name"), !name.isEmpty else {
        throw CLIError.usage("jxcode skill-add --name <name> [--description <text>] "
            + "[--body <text> | --file <path>]")
    }

    let store = SharedStore(paths: sandbox.paths)
    let id = flags.value("--id").flatMap { $0.isEmpty ? nil : $0 } ?? Identifier.slug(name, fallback: "skill")

    // The body can come from a flag or from a file. The file form is the one
    // that matters in practice — a skill is prose, and prose does not belong on
    // a command line.
    let body: String
    if let path = flags.value("--file"), !path.isEmpty {
        let expanded = (path as NSString).expandingTildeInPath
        body = try String(contentsOfFile: expanded, encoding: .utf8)
    } else {
        body = flags.value("--body") ?? ""
    }

    let summary = flags.value("--description") ?? ""
    let skill = Skill(id: id, name: name, summary: summary, body: body)
    try store.writeSkill(skill)

    print("wrote \(sandbox.paths.display(SkillStore.skillFile(id: id, paths: sandbox.paths)))")
    print("")
    print("apply it to every agent with: jxcode shared-bind")
}

func cmdSkillRemove(sandbox: Sandbox, flags: Flags) throws {
    guard let id = flags.positional.first else {
        throw CLIError.usage("jxcode skill-remove <id>   (see: jxcode shared)")
    }
    let store = SharedStore(paths: sandbox.paths)
    guard store.skills.contains(where: { $0.id == id }) else {
        throw SharedCollectionError.missingSkill(id)
    }
    try store.removeSkill(id: id)
    print("removed skill \(id)")
    print("its bindings are still in each agent's instruction file — run `jxcode shared-bind` to update them")
}

func cmdSkillToggle(sandbox: Sandbox, flags: Flags, enabled: Bool) throws {
    guard let id = flags.positional.first else {
        throw CLIError.usage("jxcode \(enabled ? "skill-enable" : "skill-disable") <id>")
    }
    let store = SharedStore(paths: sandbox.paths)
    guard store.skills.contains(where: { $0.id == id }) else {
        throw SharedCollectionError.missingSkill(id)
    }
    try store.setSkillEnabled(id: id, enabled: enabled)
    print("\(enabled ? "enabled" : "disabled") skill \(id)")
    print("run `jxcode shared-bind` to apply it")
}

// MARK: - Connectors

func cmdConnectorAdd(sandbox: Sandbox, flags: Flags) throws {
    guard let name = flags.value("--name"), !name.isEmpty else {
        throw CLIError.usage("jxcode connector-add --name <name> "
            + "[--command <cmd> --args \"…\"] [--url <url>] [--install \"…\"] [--env \"K=V,…\"]")
    }

    let url = flags.value("--url") ?? ""
    let command = flags.value("--command") ?? ""
    let transport: ConnectorTransport = url.isEmpty ? .stdio : .http

    let arguments = (flags.value("--args") ?? "")
        .split(separator: " ")
        .map(String.init)
        .filter { !$0.isEmpty }

    let connector = Connector(
        id: flags.value("--id").flatMap { $0.isEmpty ? nil : $0 }
            ?? Identifier.slug(name, fallback: "connector"),
        name: name,
        transport: transport,
        command: command,
        arguments: arguments,
        url: url,
        environment: parseAssignments(flags.value("--env")),
        installCommand: flags.value("--install").flatMap { $0.isEmpty ? nil : $0 }
    )

    if let problem = connector.validationError {
        throw CLIError.usage(problem)
    }

    let store = SharedStore(paths: sandbox.paths)
    try store.writeConnector(connector)

    print("registered connector \(connector.id)")
    print("  \(connector.transport == .stdio ? connector.argv.joined(separator: " ") : connector.url)")
    print("")
    print("apply it to every agent with: jxcode shared-bind")
}

func cmdConnectorRemove(sandbox: Sandbox, flags: Flags) throws {
    guard let id = flags.positional.first else {
        throw CLIError.usage("jxcode connector-remove <id>   (see: jxcode shared)")
    }
    let store = SharedStore(paths: sandbox.paths)
    try store.removeConnector(id: id)
    print("removed connector \(id)")
    print("run `jxcode shared-bind` to take it out of each agent's MCP config")
}

/// `K=V,K2=V2` — one flag, because the flag parser keeps a single value per
/// name and a connector rarely needs more than a token or two.
func parseAssignments(_ text: String?) -> [String: String] {
    guard let text, !text.isEmpty else { return [:] }
    var result: [String: String] = [:]
    for pair in text.split(separator: ",") {
        guard let equals = pair.firstIndex(of: "=") else { continue }
        let key = String(pair[pair.startIndex..<equals]).trimmingCharacters(in: .whitespaces)
        let value = String(pair[pair.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { continue }
        result[key] = value
    }
    return result
}

// MARK: - Automations

func cmdAutomationAdd(sandbox: Sandbox, flags: Flags) throws {
    guard let name = flags.value("--name"), !name.isEmpty else {
        throw CLIError.usage("jxcode automation-add --name <name> --agent <id> --prompt \"…\" "
            + "[--cadence daily|weekly|interval] [--hour N] [--minute N] [--weekday N] [--interval N]")
    }
    guard let agentID = flags.value("--agent"), !agentID.isEmpty else {
        throw CLIError.usage("jxcode automation-add needs --agent <id>   (see: jxcode agents)")
    }
    guard let prompt = flags.value("--prompt"), !prompt.isEmpty else {
        throw CLIError.usage("jxcode automation-add needs --prompt \"…\"")
    }

    let registry = AgentRegistry(paths: sandbox.paths)
    guard registry.agent(id: agentID) != nil else {
        throw CLIError.usage("no agent has the id '\(agentID)'. see: jxcode agents")
    }

    let cadence = AutomationSchedule.Cadence(
        rawValue: (flags.value("--cadence") ?? "daily").lowercased()
    ) ?? .daily

    var schedule = AutomationSchedule(cadence: cadence)
    if let hour = flags.value("--hour").flatMap(Int.init) { schedule.hour = hour }
    if let minute = flags.value("--minute").flatMap(Int.init) { schedule.minute = minute }
    if let weekday = flags.value("--weekday").flatMap(Int.init) { schedule.weekday = weekday }
    if let interval = flags.value("--interval").flatMap(Int.init) { schedule.intervalMinutes = interval }

    var workspaceID: UUID?
    if let name = flags.value("--workspace") {
        let store = WorkspaceStore(paths: sandbox.paths)
        guard let workspace = store.workspaces.first(where: { $0.name == name }) else {
            throw CLIError.usage("no workspace named '\(name)'. see: jxcode ls")
        }
        workspaceID = workspace.id
    }

    let store = SharedStore(paths: sandbox.paths)
    let automation = Automation(
        id: flags.value("--id").flatMap { $0.isEmpty ? nil : $0 }
            ?? Identifier.slug(name, fallback: "automation"),
        name: name,
        agentID: agentID,
        prompt: prompt,
        workspaceID: workspaceID,
        schedule: schedule
    )
    try store.writeAutomation(automation)

    print("registered automation \(automation.id)")
    print("  \(schedule.summary)  →  \(agentID)")
    print("")
    print("run it now with: jxcode automation-run \(automation.id)")
}

func cmdAutomationRemove(sandbox: Sandbox, flags: Flags) throws {
    guard let id = flags.positional.first else {
        throw CLIError.usage("jxcode automation-remove <id>   (see: jxcode shared)")
    }
    let store = SharedStore(paths: sandbox.paths)
    try store.removeAutomation(id: id)
    print("removed automation \(id)")
}

/// Run one automation by id, or everything that is due.
func cmdAutomationRun(sandbox: Sandbox, flags: Flags) throws {
    try sandbox.prepare()
    let store = SharedStore(paths: sandbox.paths)
    let registry = AgentRegistry(paths: sandbox.paths)
    let workspaces = WorkspaceStore(paths: sandbox.paths).workspaces

    let targets: [Automation]
    if let id = flags.positional.first {
        guard let automation = store.automations.first(where: { $0.id == id }) else {
            throw CLIError.usage("no automation has the id '\(id)'. see: jxcode shared")
        }
        // Asking for one by name means run it now, schedule or not.
        targets = [automation]
    } else {
        targets = AutomationRunner.due(automations: store.automations)
        if targets.isEmpty {
            print("nothing is due right now")
            for automation in store.automations where automation.enabled {
                print("  \(automation.id): \(automation.schedule.summary)"
                    + (automation.lastRun.map { ", last ran \($0)" } ?? ", never run"))
            }
            return
        }
    }

    var failures = 0
    for automation in targets {
        print("running \(automation.name) → \(automation.agentID)")
        let result = AutomationRunner.run(
            automation,
            agents: registry.agents,
            workspaces: workspaces,
            sandbox: sandbox,
            store: store
        )
        print("  \(result.succeeded ? "ok" : "failed"): \(result.message)")
        if !result.succeeded { failures += 1 }
    }

    if failures > 0 { exit(1) }
}
