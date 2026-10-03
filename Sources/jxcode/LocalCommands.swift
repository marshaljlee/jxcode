import Foundation
import JXCodeCore

// Track 1.3 commands: the model lifecycle.
//
// `jxcode serve <file.gguf>` already exists and loads one named file. This is
// the other half of the same feature and the reason 1.3 exists: an *alias* is
// the stable name an agent's config holds, a *profile* decides what that name
// means right now, and a supervisor starts the model the first time something
// asks for the name and stops it when nothing has for a while.
//
// The split between the two commands is worth stating, because they overlap:
//
//   - `jxcode serve <file.gguf>` is a one-off. It loads what you name, and it
//     is what you reach for to look at a file.
//   - `jxcode local serve <alias>` goes through the supervisor, which means it
//     resolves the alias through the active profile, applies that alias's
//     memory/cache/sampling policy, writes all four log streams, and unloads
//     itself on the idle timeout — the last of which is the whole feature and
//     is invisible in the one-off path.
//
// Everything printed here is rendered by `ModelLifecycleReport` in the core, so
// the terminal and the Models pane cannot disagree about what a name means.

// MARK: - local

func cmdLocal(sandbox: Sandbox, flags: Flags) throws {
    let store = ModelLifecycleStore(paths: sandbox.paths)
    let subcommand = flags.positional.first

    switch subcommand {
    case nil, "show", "list":
        try localShow(sandbox: sandbox, store: store)

    case "alias":
        try localAlias(store: store, flags: flags)

    case "unbind":
        try localUnbind(store: store, flags: flags)

    case "idle":
        try localIdle(store: store, flags: flags)

    case "profile":
        try localProfile(store: store, flags: flags)

    case "profile-add":
        try localProfileAdd(store: store, flags: flags)

    case "profile-remove":
        try localProfileRemove(store: store, flags: flags)

    case "logs":
        try localLogs(sandbox: sandbox, flags: flags)

    case "serve":
        try localServe(sandbox: sandbox, store: store, flags: flags)

    case "policy":
        try localPolicy(sandbox: sandbox, store: store)

    default:
        throw CLIError.usage(
            "jxcode local [show | alias <name> <file> | unbind <name> | idle <seconds> | "
                + "profile [<name>] | profile-add <name> | profile-remove <name> | "
                + "logs [proxy|http|upstream|model] [alias] | serve <alias> | policy]"
        )
    }
}

// MARK: - show

private func localShow(sandbox: Sandbox, store: ModelLifecycleStore) throws {
    Console.line(ModelLifecycleReport.profiles(store))

    // What is loaded *by other processes* — the app, or a `jxcode local serve`
    // running in another terminal. A supervisor's registry is in-process, so a
    // freshly started CLI knows about nothing; asking `pgrep` is the only way
    // this command can answer "what is running" honestly rather than by
    // reporting its own empty table.
    let running = try awaitBlocking { await RunningServers.list() }
    let matched = ModelLifecycleReport.runningElsewhere(running, store: store)

    Console.line("")
    Console.line(ModelLifecycleReport.foreignServers(matched))
}

// MARK: - policy

/// The one-router decision, with this machine's own facts attached.
///
/// A command rather than a paragraph in the README, because two of the three
/// things worth knowing are not knowable from a document: whether the installed
/// binary even has router mode, and whether anything on this machine is in it
/// right now. Both are read here rather than asserted.
private func localPolicy(sandbox: Sandbox, store: ModelLifecycleStore) throws {
    let capabilities = LlamaRuntimeLocator(paths: sandbox.paths).capabilities()

    // The same call `jxcode local show` makes, for the same reason: a
    // supervisor's registry lives in the process that made it, so a freshly
    // started CLI knows about no server at all — and a router-mode server is
    // exactly the kind this app never started.
    let running = try awaitBlocking { await RunningServers.list() }
    let foreign = ModelLifecycleReport.runningElsewhere(running, store: store)

    Console.line(ModelLifecycleReport.servingPolicy(
        store,
        capabilities: capabilities,
        foreignServers: foreign
    ))
}

// MARK: - alias

private func localAlias(store: ModelLifecycleStore, flags: Flags) throws {
    let arguments = Array(flags.positional.dropFirst())
    guard arguments.count == 2 else {
        throw CLIError.usage("jxcode local alias <name> <file.gguf> [--idle <seconds>]")
    }

    let idle: TimeInterval?
    if let raw = flags.value("--idle") {
        guard let seconds = TimeInterval(raw), seconds >= 0 else {
            throw CLIError.usage("--idle takes a number of seconds, or 0 to keep the model loaded")
        }
        idle = seconds
    } else {
        idle = nil
    }

    let alias = ModelAlias(
        name: arguments[0],
        modelPath: arguments[1],
        memory: flags.value("--memory").flatMap(MemoryPolicy.init(rawValue:)),
        cache: flags.value("--cache").flatMap(CachePolicy.init(rawValue:)),
        sampling: flags.value("--sampling").flatMap(SamplingPreset.init(rawValue:)),
        idleTimeout: idle
    )
    try store.setAlias(alias)

    let profile = store.activeProfile
    let effective = ModelLifecycleReport.effectiveIdle(alias, in: profile)

    Console.line("\(alias.name) → \((alias.modelPath as NSString).expandingTildeInPath)")
    Console.line("  profile       \(profile.name)")
    // The effective value, not the form. `--idle` absent does not mean "no
    // timeout"; it means the profile's number is the one that will be used, and
    // a user who reads this as "no timeout" leaves a 16 GB model resident.
    //
    // No `idle timeout` label here: `idleLine` prints one, and adding a second
    // produced `idle timeout  idle timeout  10m 0s`.
    Console.line("  \(ModelLifecycleReport.idleLine(effective, origin: ModelLifecycleReport.idleOrigin(alias)))")
    Console.line("")
    Console.line("  Agents can now ask for '\(alias.name)'. It is loaded on the first request")
    Console.line("  and unloaded \(effective > 0 ? "after \(RunningModel.duration(effective)) idle" : "only when stopped by hand").")
}

private func localUnbind(store: ModelLifecycleStore, flags: Flags) throws {
    let arguments = Array(flags.positional.dropFirst())
    guard let name = arguments.first else {
        throw CLIError.usage("jxcode local unbind <name>")
    }
    // `false` rather than a throw: unbinding something that is not bound is the
    // state the caller asked for, and an error there would make a cleanup
    // script fail on its second run.
    Console.line(try store.removeAlias(named: name)
        ? "\(name) unbound"
        : "\(name) was not bound in profile '\(store.activeProfile.name)'")
}

private func localIdle(store: ModelLifecycleStore, flags: Flags) throws {
    let arguments = Array(flags.positional.dropFirst())
    guard let raw = arguments.first, let seconds = TimeInterval(raw), seconds >= 0 else {
        throw CLIError.usage(
            "jxcode local idle <seconds>  (0 keeps every model loaded until it is stopped by hand)"
        )
    }
    try store.setIdleTimeout(seconds)
    let profile = store.activeProfile

    Console.line("profile '\(profile.name)' now unloads an idle model "
        + (seconds > 0 ? "after \(RunningModel.duration(seconds))" : "never"))
    // Said out loud because it is the question a user actually has: this is the
    // *default*, and an alias that set its own wins over it.
    let overriding = profile.aliases.filter { $0.idleTimeout != nil }.map(\.name)
    if !overriding.isEmpty {
        Console.line("  \(overriding.joined(separator: ", ")) "
            + "\(overriding.count == 1 ? "sets its own" : "set their own") and "
            + "\(overriding.count == 1 ? "is" : "are") not affected")
    }
}

// MARK: - profiles

private func localProfile(store: ModelLifecycleStore, flags: Flags) throws {
    let arguments = Array(flags.positional.dropFirst())

    guard let name = arguments.first else {
        let width = store.knownProfileNames.map(\.count).max() ?? 0
        for profile in store.profiles {
            let mark = profile.name == store.activeProfile.name ? "▸" : " "
            Console.line("\(mark) \(ModelReport.pad(profile.name, to: max(width, 5) + 2))"
                + "\(profile.aliases.count) alias\(profile.aliases.count == 1 ? "" : "es")"
                + "  ·  \(ModelLifecycleReport.idleLine(profile.idleTimeout, origin: "the profile"))")
        }
        return
    }

    try store.selectProfile(named: name)
    Console.line("profile '\(store.activeProfile.name)' is now active")
    // The consequence, not the action. Switching a profile re-points every
    // alias, which is the entire reason it is a separate concept from an alias
    // — and it is invisible unless it is said.
    let aliases = store.knownAliases
    Console.line(aliases.isEmpty
        ? "  It has no aliases, so nothing resolves through it yet."
        : "  \(aliases.joined(separator: ", ")) now resolve through it.")
}

private func localProfileAdd(store: ModelLifecycleStore, flags: Flags) throws {
    let arguments = Array(flags.positional.dropFirst())
    guard let name = arguments.first else {
        throw CLIError.usage("jxcode local profile-add <name> [--idle <seconds>]")
    }
    let idle = flags.value("--idle").flatMap(TimeInterval.init) ?? ModelProfile.defaultIdleTimeout
    try store.addProfile(named: name, idleTimeout: idle)
    Console.line("profile '\(name)' added with a \(RunningModel.duration(idle)) idle timeout")
    Console.line("  It is empty and not active. Bind aliases after switching to it:")
    Console.line("    jxcode local profile \(name)")
}

private func localProfileRemove(store: ModelLifecycleStore, flags: Flags) throws {
    let arguments = Array(flags.positional.dropFirst())
    guard let name = arguments.first else {
        throw CLIError.usage("jxcode local profile-remove <name>")
    }
    try store.removeProfile(named: name)
    Console.line("profile '\(name)' removed; '\(store.activeProfile.name)' is active")
}

// MARK: - logs

private func localLogs(sandbox: Sandbox, flags: Flags) throws {
    let arguments = Array(flags.positional.dropFirst())

    var stream = ModelLogStream.proxy
    if let raw = arguments.first {
        guard let parsed = ModelLogStream(rawValue: raw) else {
            throw CLIError.usage(
                "unknown stream '\(raw)'. one of: "
                    + ModelLogStream.allCases.map(\.rawValue).joined(separator: ", ")
            )
        }
        stream = parsed
    }
    let alias = arguments.count > 1 ? arguments[1] : nil

    let logs = ModelLogs(paths: sandbox.paths)
    guard let url = logs.fileURL(stream, alias: alias) else {
        // `model` is the only per-model stream, and answering a per-model
        // question from the shared file would look like it worked.
        throw CLIError.usage(
            "the '\(stream.rawValue)' stream is per model — name one: jxcode local logs model <alias>"
        )
    }

    Console.line(ModelLifecycleReport.logStreams(sandbox.paths, alias: alias))
    Console.line("")
    Console.line("─ \(sandbox.paths.display(url)) " + String(repeating: "─", count: 40))

    let tail = logs.tail(stream, alias: alias)
    Console.line(tail.isEmpty ? "(nothing written yet)" : tail)
}

// MARK: - serve

/// Load an alias on demand and serve it in the foreground.
///
/// The foreground is deliberate and it is what makes the idle timeout visible:
/// a background load would leave the process holding the model with no way to
/// see it unload itself, which is the behaviour this whole track is about.
private func localServe(sandbox: Sandbox, store: ModelLifecycleStore, flags: Flags) throws {
    let arguments = Array(flags.positional.dropFirst())
    guard let name = arguments.first else {
        throw CLIError.usage("jxcode local serve <alias> [--port 8080]")
    }

    try sandbox.prepare()

    let preferredPort = flags.value("--port").flatMap(Int.init) ?? 8_080
    let supervisor = LlamaServerSupervisor(
        store: store,
        paths: sandbox.paths,
        defaults: LlamaServerSupervisor.Defaults(
            memory: flags.value("--memory").flatMap(MemoryPolicy.init(rawValue:)) ?? .safe,
            cache: flags.value("--cache").flatMap(CachePolicy.init(rawValue:)) ?? .balanced,
            sampling: flags.value("--sampling").flatMap(SamplingPreset.init(rawValue:)) ?? .default,
            preferredPort: preferredPort
        )
    )

    Console.line("resolving '\(name)' in profile '\(store.activeProfile.name)'…")
    let record = try awaitBlocking { try await supervisor.start(alias: name) }

    Console.line("")
    Console.line(ModelLifecycleReport.running([record]))
    Console.line("")
    Console.line("  log  \(sandbox.paths.display(record.logURL))")

    if let health = try? awaitBlocking({ await supervisor.health(alias: record.alias) }) {
        Console.line("  \(ModelLifecycleReport.health(record.alias, health))")
    }
    if let report = try? awaitBlocking({ await supervisor.metrics(alias: record.alias) }) {
        Console.line("")
        Console.line(ModelLifecycleReport.metrics(record.alias, report))
    }

    Console.line("")
    Console.line(ModelLifecycleReport.logStreams(sandbox.paths, alias: record.alias))
    Console.line("")

    guard record.unloadsWhenIdle else {
        Console.line("This alias never unloads on idle (idle timeout 0). Press Ctrl-C to stop.")
        signal(SIGINT, handleLocalServeSignal)
        signal(SIGTERM, handleLocalServeSignal)
        while localServeInterruptRequested == 0 { sleep(1) }
        _ = try awaitBlocking { await supervisor.stopAll() }
        Console.line("stopped")
        return
    }

    Console.line("Press Ctrl-C to stop. Nothing has used it yet, so it unloads itself in "
        + "\(RunningModel.duration(record.idleTimeout)) unless something does.")
    supervisor.startSweeping()

    signal(SIGINT, handleLocalServeSignal)
    signal(SIGTERM, handleLocalServeSignal)

    while localServeInterruptRequested == 0 {
        sleep(1)
        // Reported from the supervisor's own view rather than from a timer here,
        // because the sweep is what decides — this loop only says what happened.
        let stillLoaded = supervisor.running().contains {
            $0.alias.caseInsensitiveCompare(record.alias) == .orderedSame
        }
        if !stillLoaded {
            // The *measured* idle, not the threshold. The sweep runs on its own
            // interval, so a 10s timeout is not acted on until the next sweep —
            // up to 40s later — and printing the threshold read as a precise
            // claim the sweep had never made. The supervisor's own log line
            // reports the elapsed time; this now agrees with it.
            let idle = Date().timeIntervalSince(record.lastUsedAt)
            Console.line("")
            Console.line("'\(record.alias)' was unloaded by the idle sweep: "
                + "\(RunningModel.duration(idle)) idle, threshold "
                + "\(RunningModel.duration(record.idleTimeout)).")
            Console.line("The next request for '\(record.alias)' starts it again — that is the whole design.")
            supervisor.stopSweeping()
            exit(0)
        }
    }

    Console.line("")
    Console.line("stopping…")
    supervisor.stopSweeping()
    _ = try awaitBlocking { await supervisor.stopAll() }
    Console.line("stopped")
}

/// Set by the SIGINT/SIGTERM handler, read by the wait loop in `localServe`.
///
/// A separate `sig_atomic_t` from `serveInterruptRequested` in `ModelCommands`
/// rather than a shared one: the two commands never run at once, but a shared
/// flag would make one of them exit on the other's signal the day that changes.
private var localServeInterruptRequested: sig_atomic_t = 0

private func handleLocalServeSignal(_ signalNumber: Int32) {
    localServeInterruptRequested = 1
}
