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

    Console.line("shared collection  \(sandbox.paths.display(sandbox.paths.shared))")
    Console.line("")

    Console.line("skills  (\(store.skills.count))")
    if store.skills.isEmpty {
        Console.line("  none — add one with: jxcode skill-add --name \"Release checklist\"")
    }
    for skill in store.skills {
        let mark = skill.enabled ? "on " : "off"
        Console.line("  [\(mark)] \(skill.id.padding(toLength: 20, withPad: " ", startingAt: 0))\(skill.name)")
        if !skill.summary.isEmpty {
            Console.line("        \(skill.summary)")
        }
        // Shown here rather than only at bind time. A finding that first
        // appears when the collection is applied arrives long after the author
        // stopped thinking about the skill, which is the wrong moment to be
        // told it will never load.
        for finding in skill.findings {
            Console.line("        \(finding.rendered)")
        }
    }
    Console.line("")

    let environment = sandbox.env(workspace: nil)
    Console.line("agents  (\(registry.agents.count))")
    for agent in registry.agents {
        let installed = registry.isInstalled(agent, environment: environment)
        Console.line("  [\(installed ? "ok " : "   ")] \(agent.id.padding(toLength: 20, withPad: " ", startingAt: 0))\(agent.name)")
    }
    Console.line("")

    Console.line("connectors  (\(store.connectors.count))")
    if store.connectors.isEmpty {
        Console.line("  none — add one with: jxcode connector-add --name filesystem --command npx --args \"-y @modelcontextprotocol/server-filesystem\"")
    }
    for connector in store.connectors {
        let mark = connector.enabled ? "on " : "off"
        let detail = connector.transport == .stdio
            ? connector.argv.joined(separator: " ")
            : connector.url
        Console.line("  [\(mark)] \(connector.id.padding(toLength: 20, withPad: " ", startingAt: 0))\(detail)")
        // The names, never the values — which is the same rule the binder
        // follows and the reason this line is safe to put in a log.
        let referenced = connector.referencedVariables
        if !referenced.isEmpty {
            Console.line("        names \(referenced.joined(separator: ", "))")
        }
        // A connector that arrived by hand edit or from an older JXCode is
        // reported here rather than only at bind time. The store refuses to
        // write one, so this is the surface that tells the user it is there.
        for finding in connector.inlinedCredentials {
            Console.line("        \(finding.rendered)")
        }
    }
    Console.line("")

    Console.line("automations  (\(store.automations.count))")
    if store.automations.isEmpty {
        Console.line("  none — add one with: jxcode automation-add --name nightly --agent claude --prompt \"triage open issues\"")
    }
    for automation in store.automations {
        let mark = automation.enabled ? "on " : "off"
        Console.line("  [\(mark)] \(automation.id.padding(toLength: 20, withPad: " ", startingAt: 0))"
            + "\(automation.schedule.summary)  →  \(automation.agentID)")
        if let result = automation.lastResult {
            Console.line("        last: \(result)")
        }
    }
    Console.line("")

    let manifest = ConnectorBinder.readManifest(paths: sandbox.paths)
    Console.line("registered connectors  \(manifest.managed.isEmpty ? "none" : manifest.managed.joined(separator: ", "))")
    Console.line("apply the collection to every agent with: jxcode shared-bind")
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
        onProgress: { _, message in Console.line("  \(message)") }
    )
    Console.line("binding skills")
    for report in try SkillBinder.apply(
        skills: skills,
        agents: registry.agents,
        paths: sandbox.paths
    ) {
        Console.line("  \(report.summary)")
        for note in report.notes { Console.line("      \(note)") }
    }

    Console.line("")
    Console.line("binding connectors")
    let bound = try ConnectorBinder.apply(
        connectors: connectors,
        agents: registry.agents,
        paths: sandbox.paths
    )
    for report in bound {
        Console.line("  \(report.summary)")
        for note in report.notes { Console.line("      \(note)") }
    }

    // A bind that printed what went wrong and then exited 0 told a script
    // nothing: `shared-bind && run` carried on against a sandbox that is only
    // half bound. Failures are collected rather than printed where they happen,
    // so each one is reported once and the exit code can follow from them.
    let failures = SharedBind.failures(installs: installs, connectors: bound)
    guard failures.isEmpty else {
        Console.line("")
        Console.line("\(failures.count) \(failures.count == 1 ? "thing did" : "things did") not bind:")
        for failure in failures { Console.line("  \(failure.line)") }
        exit(1)
    }
}

/// Remove every binding the collection wrote.
func cmdSharedRevert(sandbox: Sandbox, flags: Flags) throws {
    try sandbox.prepare()
    let registry = AgentRegistry(paths: sandbox.paths)

    for message in try SkillBinder.revert(agents: registry.agents, paths: sandbox.paths) {
        Console.line(message)
    }
    for message in try ConnectorBinder.revert(agents: registry.agents, paths: sandbox.paths) {
        Console.line(message)
    }
    Console.line("the shared collection is unbound. Its contents are untouched.")
}

// MARK: - Skills

/// What a good description looks like, and why it is the whole interface.
///
/// A command rather than a paragraph inside `--help`, because the moment an
/// author needs it is the moment they are deciding what to type, and `--help`
/// is a screen people scroll past. The text itself lives in `SkillAuthoring`,
/// so the pane shows the same three rules and the same examples — a second copy
/// here is how the two surfaces start disagreeing.
func cmdSkillHelp(sandbox: Sandbox, flags: Flags) throws {
    Console.line(SkillAuthoring.helpText)
}

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
    let written = try store.writeSkill(skill)

    Console.line("wrote \(sandbox.paths.display(SkillStore.skillFile(id: id, paths: sandbox.paths)))")

    // Said now, while the author is still looking at it. `writeSkill` refuses
    // anything that would make the file unloadable, so what is left here is the
    // advisory half — a skill that loads and is not what the author meant.
    let findings = written.findings
    if !findings.isEmpty {
        Console.line("")
        for finding in findings { Console.line("  \(finding.rendered)") }
    }

    // The authoring half, which is a different question from "does it load".
    // Shown only when there is something to say: a hint printed on every add is
    // a hint nobody reads by the third one. This is also the only surface that
    // can catch the two cases no finding covers — a description that is the
    // slug of the name, and one that describes the skill rather than the task.
    if let hint = SkillAuthoring.hint(name: written.name, description: written.summary) {
        Console.line("")
        Console.line("  \(hint)")
        Console.line("  all three rules: jxcode skill-help")
    }

    Console.line("")
    Console.line("apply it to every agent with: jxcode shared-bind")
}

/// Judge the skills on disk the way an agent will.
///
/// The other half of "validate on write, refuse on read". `skill-add` judges
/// the value it is about to store; this judges the bytes that are actually
/// there, which is the only view that can catch a file edited by hand, or one
/// written by an older version of JXCode. It exits non-zero on a blocking
/// finding, so `jxcode skill-check && jxcode shared-bind` cannot bind a
/// collection that half of the agents will reject.
func cmdSkillCheck(sandbox: Sandbox, flags: Flags) throws {
    try sandbox.prepare()
    let store = SharedStore(paths: sandbox.paths)

    let wanted = flags.positional.first
    let skills = wanted.map { id in store.skills.filter { $0.id == id } } ?? store.skills

    guard !skills.isEmpty else {
        Console.line(wanted.map { "no skill called \($0)" } ?? "no skills to check")
        return
    }

    var blocking = 0
    for skill in skills {
        let file = SkillStore.skillFile(id: skill.id, paths: sandbox.paths)
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""

        var findings = SkillSpec.findings(id: skill.id, text: text)
        // Unknown fields are ignored by every agent, so they are not a reason
        // to refuse — but the packaging and upload path fails hard on them, so
        // a skill headed for claude.ai has to be clean.
        findings += SkillSpec.unrecognisedFields(in: text).map {
            SkillSpec.Finding(
                severity: .advisory,
                message: "`\($0)` is not a field the specification recognises",
                fix: "the agents ignore it; the upload path does not"
            )
        }

        blocking += findings.filter { $0.severity == .blocking }.count
        Console.line("\(skill.id)  \(sandbox.paths.display(file))")
        if findings.isEmpty {
            Console.line("  ✓ loads everywhere")
        }
        for finding in findings { Console.line("  \(finding.rendered)") }
    }

    guard blocking == 0 else {
        Console.line("")
        Console.line("\(blocking) blocking \(blocking == 1 ? "problem" : "problems") — "
            + "an agent will reject the file or never load it")
        exit(1)
    }
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
    Console.line("removed skill \(id)")
    Console.line("its bindings are still in each agent's instruction file — run `jxcode shared-bind` to update them")
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
    Console.line("\(enabled ? "enabled" : "disabled") skill \(id)")
    Console.line("run `jxcode shared-bind` to apply it")
}

// MARK: - Connectors

func cmdConnectorAdd(sandbox: Sandbox, flags: Flags) throws {
    guard let name = flags.value("--name"), !name.isEmpty else {
        throw CLIError.usage("jxcode connector-add --name <name> "
            + "[--command <cmd> --args \"…\"] [--url <url>] [--header \"K=V,…\"] "
            + "[--env \"K=V,…\"] [--install \"…\"]")
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
        headers: Assignments.parse(flags.value("--header")),
        environment: Assignments.parse(flags.value("--env")),
        installCommand: flags.value("--install").flatMap { $0.isEmpty ? nil : $0 }
    )

    if let problem = connector.validationError {
        throw CLIError.usage(problem)
    }

    let store = SharedStore(paths: sandbox.paths)

    // A definition that holds a secret is refused here rather than at bind time,
    // and the thrown error carries the finding and the fix. Refusing at the
    // front door is the point: by bind time the value would already have been
    // copied into four config files, and a warning after the copy is a warning
    // about a leak that has happened.
    try store.writeConnector(connector)

    Console.line("registered connector \(connector.id)")
    Console.line("  \(connector.transport == .stdio ? connector.argv.joined(separator: " ") : connector.url)")

    // What the user has to arrange for this to work, said at the moment they
    // wrote it rather than at the moment the server fails to authenticate.
    let referenced = connector.referencedVariables
    if !referenced.isEmpty {
        Console.line("")
        Console.line("  names \(referenced.count == 1 ? "a secret" : "\(referenced.count) secrets") "
            + "rather than holding \(referenced.count == 1 ? "it" : "them"): "
            + referenced.joined(separator: ", "))
        Console.line("  each one has to be set in the environment the agents run in —")
        Console.line("  the sandbox, not this shell: jxcode env set \(referenced[0])=…")
        // `NAME`, not one of the names that happens to be in this connector.
        // Interpolating the first name here printed `${GITHUB_TOKEN}` above a
        // connector whose only secret was `ACME_TOKEN` — a reason that
        // contradicts the value next to it, which is the shape of defect a
        // reader believes rather than checks.
        Console.line("  stored as \(CredentialSyntax.shell.render("NAME")) and rewritten into each "
            + "agent's own spelling when you bind, so the value never reaches a config file")
    }

    Console.line("")
    Console.line("apply it to every agent with: jxcode shared-bind")
}

func cmdConnectorRemove(sandbox: Sandbox, flags: Flags) throws {
    guard let id = flags.positional.first else {
        throw CLIError.usage("jxcode connector-remove <id>   (see: jxcode shared)")
    }
    let store = SharedStore(paths: sandbox.paths)
    try store.removeConnector(id: id)
    Console.line("removed connector \(id)")
    Console.line("run `jxcode shared-bind` to take it out of each agent's MCP config")
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

    Console.line("registered automation \(automation.id)")
    Console.line("  \(schedule.summary)  →  \(agentID)")
    Console.line("")
    Console.line("run it now with: jxcode automation-run \(automation.id)")
}

func cmdAutomationRemove(sandbox: Sandbox, flags: Flags) throws {
    guard let id = flags.positional.first else {
        throw CLIError.usage("jxcode automation-remove <id>   (see: jxcode shared)")
    }
    let store = SharedStore(paths: sandbox.paths)
    try store.removeAutomation(id: id)
    Console.line("removed automation \(id)")
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
            Console.line("nothing is due right now")
            for automation in store.automations where automation.enabled {
                Console.line("  \(automation.id): \(automation.schedule.summary)"
                    + (automation.lastRun.map { ", last ran \($0)" } ?? ", never run"))
            }
            return
        }
    }

    var failures = 0
    for automation in targets {
        Console.line("running \(automation.name) → \(automation.agentID)")
        let result = AutomationRunner.run(
            automation,
            agents: registry.agents,
            workspaces: workspaces,
            sandbox: sandbox,
            store: store
        )
        Console.line("  \(result.succeeded ? "ok" : "failed"): \(result.message)")
        if !result.succeeded { failures += 1 }
    }

    if failures > 0 { exit(1) }
}
