import Foundation
import JXCodeCore

// Pillar 02/03's one-click path, headless.
//
// The app has a single Activate button that loads a model if needed, registers
// the backend, starts the router, points every agent at it and then sends one
// real request through the whole chain. This is the same sequence from a
// terminal — and it is the *same* sequence, not a re-implementation: the order,
// the step names, the failure wording and the remedies all come from
// `RoutingActivation`, so `jxcode activate` and the button cannot describe
// different outcomes.
//
// It stays in the foreground on purpose. Activation ends with a router that is
// listening, and a command that exited would take the router with it — the
// report would say "listening" and the very next request would get a connection
// refused.

/// The objects a run has to keep alive after the chain returns.
///
/// A reference type because the handles are closures and capture by value: a
/// `LlamaServer` held in a local would be released the moment the closure
/// returned, taking the loaded model with it.
final class ActivationSession {
    var server: LlamaServer?
    var router: ModelRouter?
}

func cmdActivate(sandbox: Sandbox, flags: Flags) throws {
    try sandbox.prepare()

    let paths = sandbox.paths
    let port = flags.value("--port").flatMap(UInt16.init) ?? RouterConfiguration.defaultPort
    let auth = RouterAuth.load(from: paths)
    let store = ProviderStore(paths: paths)
    let registry = AgentRegistry(paths: paths)

    // What to activate: a GGUF on disk, or a backend already registered.
    let positional = flags.positional.first
    let source: ActivationSource
    if let path = positional {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
        guard exists || path.lowercased().hasSuffix(".gguf") else {
            throw CLIError.usage(
                "no such file: \(expanded)\n"
                    + "       jxcode activate <file.gguf>   serve and route a local model\n"
                    + "       jxcode activate                route the selected registered backend"
            )
        }
        source = .localModel(
            path: expanded,
            memory: memoryPolicy(flags: flags),
            cache: cachePolicy(flags: flags),
            sampling: samplingPreset(flags: flags)
        )
    } else {
        let provider: Provider?
        if let name = flags.value("--provider") {
            guard let found = store.providers.first(where: { $0.name == name }) else {
                throw CLIError.usage("no provider named '\(name)'. see: jxcode providers")
            }
            provider = found
        } else {
            provider = store.providers.first
        }
        // "Nothing is registered" is not a usage error and does not get its own
        // sentence here. It is the first hop of the chain, and the chain already
        // knows what that hop is called and what to do about it — passing the
        // empty selection through means the terminal prints the same report the
        // Activate button shows, instead of a second wording that can drift.
        source = .registered(id: provider?.id, model: flags.value("--model"))
    }

    let session = ActivationSession()

    let handles = ActivationHandles(
        serveLocal: { source in
            guard case .localModel(let path, let memory, let cache, let sampling) = source else {
                throw CLIError.usage("internal: a local model was expected")
            }
            return try await startLocalModel(
                at: path,
                memory: memory,
                cache: cache,
                sampling: sampling,
                sandbox: sandbox,
                flags: flags,
                session: session
            )
        },
        providers: { store.providers },
        register: { provider in
            try store.add(provider)
            return provider
        },
        startRouter: { provider, model, port in
            let state = RouterState(
                RouterConfiguration(provider: provider, model: model, port: port),
                auth: auth
            )
            let router = ModelRouter(
                state: state,
                log: RouterLog(fileURL: paths.logs.appendingPathComponent("router.log"))
            )
            try router.start(preferredPort: port)
            session.router = router

            guard await RouterSelfTest.waitUntilListening(routerURL: router.baseURL) else {
                throw CLIError.usage("the router bound port \(router.port) but is not answering")
            }
            return router.baseURL
        },
        bind: { base, model in
            try AgentConfigWriter.apply(
                agents: registry.agents,
                paths: paths,
                routerURL: base,
                model: model,
                token: auth.isEnabled
                    ? (auth.token ?? AgentConfigWriter.placeholderToken)
                    : AgentConfigWriter.placeholderToken,
                // The backend's own window, so Claude Code does not assume 200k
                // and overflow a local model that can hold a fraction of it.
                contextLength: store.providers.first { $0.normalizedBaseURL == base }?.contextLength
            )
        },
        probeModels: { provider in
            try await ModelCatalog().probe(provider).models
        },
        auth: { auth }
    )

    let request = ActivationRequest(
        source: source,
        port: port,
        bindAgents: !flags.has("--no-bind"),
        verify: !flags.has("--no-verify")
    )

    let report = try awaitBlocking { await RoutingActivation.run(request, handles: handles) }

    Console.line(report.rendered())
    Console.line("")

    guard report.isWorking else { exit(1) }

    // Nothing to keep alive if the chain stopped before the router.
    guard session.router != nil || session.server != nil else { return }

    Console.line("  Agents are routed. Ctrl-C to stop.")
    Console.line("")

    signal(SIGINT, handleActivateSignal)
    signal(SIGTERM, handleActivateSignal)

    while activateInterruptRequested == 0 {
        sleep(1)
    }

    Console.line("")
    Console.line("stopping…")
    session.router?.stop()
    session.server?.stop()
    Console.line("router stopped, model unloaded.")
}

/// Load a GGUF and return once it is answering.
///
/// The same steps `jxcode serve` takes, minus the printing: the plan, the
/// free-port search, the log file, and the wait for the server to be ready.
private func startLocalModel(
    at path: String,
    memory: MemoryPolicy,
    cache: CachePolicy,
    sampling: SamplingPreset,
    sandbox: Sandbox,
    flags: Flags,
    session: ActivationSession
) async throws -> ServedLocalModel {
    guard let runtime = LlamaRuntimeLocator(paths: sandbox.paths).locate() else {
        throw CLIError.usage(
            "no llama-server found. Run `jxcode runtime` to see where it was looked for."
        )
    }

    let model = try resolveLocalModel(at: path, scanner: modelScanner(flags: flags))
    let plan = try ModelOptimizer(
        hardware: .current(),
        policy: memory,
        cachePolicy: cache,
        sampling: sampling,
        // The runtime was located two lines up, so this asks that exact binary
        // rather than searching for one again — a second `locate()` could in
        // principle answer with a different build than the one being launched.
        capabilities: LlamaServerCapabilities.cached(binary: runtime.binary)
    ).plan(for: model)

    let preferred = flags.value("--port").flatMap(Int.init) ?? 8_080
    guard let port = PortAllocator.firstFree(from: preferred) else {
        throw CLIError.usage("no free port at or above \(preferred)")
    }

    let slug = model.model.filename
        .replacingOccurrences(of: ".gguf", with: "")
        .replacingOccurrences(of: " ", with: "-")
    let logURL = sandbox.paths.logs.appendingPathComponent("llama-server-\(slug).log")

    let server = LlamaServer(
        configuration: LlamaServerConfiguration(
            binary: runtime.binary,
            plan: plan,
            port: port,
            logURL: logURL
        ),
        paths: sandbox.paths
    )
    session.server = server

    let others = await RunningServers.list()
    try await server.start()

    // The server's own answer for the window, which is what the agent config
    // needs — the plan is a prediction from the GGUF header.
    let props = await server.props()
    let contextLength = props?.agentContextLength ?? plan.contextLength

    return ServedLocalModel(
        displayName: model.displayName,
        filename: model.model.filename,
        port: port,
        contextLength: contextLength,
        warnings: plan.warnings + (others.isEmpty
            ? []
            : ["\(others.count) other llama-server process(es) are running and share unified memory."])
    )
}

/// Set by the SIGINT/SIGTERM handler, read by the wait loop in `cmdActivate`.
private var activateInterruptRequested: sig_atomic_t = 0

private func handleActivateSignal(_ signalNumber: Int32) {
    activateInterruptRequested = 1
}

// MARK: - The tool list

func cmdTools(sandbox: Sandbox, flags: Flags) throws {
    let registry = ToolRegistry(paths: sandbox.paths)
    let environment = sandbox.env(workspace: nil)

    guard !registry.tools.isEmpty else {
        Console.line("no tools.")
        return
    }

    for tool in registry.tools {
        let origin = tool.isBuiltIn ? "built-in" : "added"
        let location = ToolLocator.locate(tool, environment: environment)
        let where_ = location.map { "\($0.isInSandbox ? "sandbox" : "host") \($0.path)" }
            ?? "not installed"
        Console.line("  \(tool.id)  [\(origin)]")
        Console.line("    name      \(tool.name)")
        Console.line("    command   \(tool.binary)\(tool.arguments.isEmpty ? "" : " " + tool.arguments.joined(separator: " "))")
        Console.line("    found     \(where_)")
        if let install = tool.installCommand, !install.isEmpty {
            Console.line("    install   \(install)")
        }
    }
}

func cmdToolSuggest(sandbox: Sandbox, flags: Flags) throws {
    let registry = ToolRegistry(paths: sandbox.paths)
    let environment = sandbox.env(workspace: nil)
    let suggestions = ToolCatalog.suggestions(absentFrom: registry.tools)

    guard !suggestions.isEmpty else {
        Console.line("every catalog tool is already on the dashboard.")
        return
    }

    Console.line("Not on the dashboard yet. Add one with: jxcode tool-add --name <name> --command <cmd>")
    Console.line("")
    for tool in suggestions {
        let found = ToolLocator.locate(tool, environment: environment)
        let state = found.map { $0.isInSandbox ? "ready in sandbox" : "on your Mac" }
            ?? "not installed"
        Console.line("  \(tool.id.padding(toLength: 14, withPad: " ", startingAt: 0))\(tool.name)  — \(state)")
        Console.line("    \(tool.tagline)")
        if let install = tool.installCommand, !install.isEmpty {
            Console.line("    install: \(install)")
        }
    }
}

func cmdToolAdd(sandbox: Sandbox, flags: Flags) throws {
    guard let name = flags.value("--name"), let command = flags.value("--command") else {
        throw CLIError.usage(
            "jxcode tool-add --name <name> --command <cmd> [--args \"…\"] [--description \"…\"] [--install \"…\"] [--id <id>]"
        )
    }

    let registry = ToolRegistry(paths: sandbox.paths)
    let arguments = (flags.value("--args") ?? "")
        .split(separator: " ")
        .map(String.init)
        .filter { !$0.isEmpty }

    let tool = ToolDefinition(
        id: flags.value("--id") ?? ToolRegistry.slug(for: name),
        name: name,
        binary: command,
        arguments: arguments,
        tagline: flags.value("--description") ?? "Added by you",
        installCommand: flags.value("--install")
    )

    try registry.add(tool)
    Console.line("added tool '\(tool.name)' as '\(tool.id)'")
    Console.line("  \(tool.binary)\(arguments.isEmpty ? "" : " " + arguments.joined(separator: " "))")
}

func cmdToolRemove(sandbox: Sandbox, flags: Flags) throws {
    guard let id = flags.positional.first else {
        throw CLIError.usage("jxcode tool-remove <id>")
    }
    let registry = ToolRegistry(paths: sandbox.paths)
    guard try registry.remove(id: id) else {
        throw CLIError.usage(
            "'\(id)' is not a tool you added. Built-in tools cannot be removed — see: jxcode tools"
        )
    }
    Console.line("removed tool '\(id)'")
}

// MARK: - The agent list

func cmdAgentSuggest(sandbox: Sandbox, flags: Flags) throws {
    let registry = AgentRegistry(paths: sandbox.paths)
    let suggestions = AgentCatalog.suggestions(absentFrom: registry.agents)

    guard !suggestions.isEmpty else {
        Console.line("every catalog agent is already offered.")
        return
    }

    Console.line("Agents the launcher does not offer yet:")
    Console.line("")
    for agent in suggestions {
        Console.line("  \(agent.id.padding(toLength: 14, withPad: " ", startingAt: 0))\(agent.name)")
        if let tagline = agent.tagline { Console.line("    \(tagline)") }
        if let install = agent.installCommand { Console.line("    install: \(install)") }
    }
    Console.line("")
    Console.line("Add one from the dashboard, or with: jxcode agent-add --name <name> --command <cmd>")
}
