import Foundation
import JXCodeCore

// Pillar 02 commands: register a backend, fetch its models, route agents at it.
//
// These exist so the provider layer can be exercised without the GUI — the same
// reason `jxcode prove` exists for the sandbox. `jxcode route` plus `curl` is
// enough to prove an agent's traffic is being translated correctly.

// MARK: - Async bridge

/// Run an async operation from this synchronous top-level script.
///
/// A semaphore is fine here: nothing else is running, and the script exits as
/// soon as the command finishes.
func awaitBlocking<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<T, Error>?
    Task {
        do { outcome = .success(try await operation()) }
        catch { outcome = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    guard let outcome else { throw CLIError.usage("operation produced no result") }
    return try outcome.get()
}

// MARK: - models

func cmdModels(sandbox: Sandbox, flags: Flags) throws {
    guard let raw = flags.positional.first else {
        throw CLIError.usage("jxcode models <base-url> [--kind openAICompatible|anthropic|ollama|localGGUF] [--key KEY]")
    }

    let kindName = flags.value("--kind") ?? ProviderKind.openAICompatible.rawValue
    guard let kind = ProviderKind(rawValue: kindName) else {
        throw CLIError.usage("unknown kind '\(kindName)'. one of: \(ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))")
    }

    let provider = Provider(
        name: "probe",
        kind: kind,
        baseURL: raw,
        apiKey: flags.value("--key")
    )

    print("probing \(provider.normalizedBaseURL)")
    print("  models: \(provider.modelsURL?.absoluteString ?? "—")")
    print("  chat:   \(provider.chatURL?.absoluteString ?? "—")")
    print("")

    let outcome = try awaitBlocking { try await ModelCatalog().probe(provider) }

    for note in outcome.notes { print("  · \(note)") }
    if !outcome.notes.isEmpty { print("") }

    for model in outcome.models {
        // Flag the ones that cannot do tool calling, since an agent pointed at
        // one produces a confusing loop of prose instead of actions.
        let marker = Provider.looksToolCapable(model) ? " " : " (no tool calling)"
        print("  \(model)\(marker)")
    }
    print("")
    print("\(outcome.models.count) model(s)")
}

// MARK: - providers

func cmdProviders(sandbox: Sandbox) throws {
    let store = ProviderStore(paths: sandbox.paths)
    guard !store.providers.isEmpty else {
        print("no providers registered.")
        print("add one with: jxcode provider-add <name> <base-url> [--kind openAICompatible] [--key KEY]")
        return
    }
    for provider in store.providers {
        print("  \(provider.name)  [\(provider.kind.rawValue)]")
        print("    base   \(provider.normalizedBaseURL)")
        print("    key    \(provider.apiKey == nil ? "none" : "set")")
        print("    models \(provider.models.count)")
        if !provider.models.isEmpty {
            print("           \(provider.models.prefix(6).joined(separator: ", "))\(provider.models.count > 6 ? ", …" : "")")
        }
    }
}

func cmdProviderAdd(sandbox: Sandbox, flags: Flags) throws {
    let positional = flags.positional
    guard positional.count >= 2 else {
        throw CLIError.usage("jxcode provider-add <name> <base-url> [--kind openAICompatible] [--key KEY] [--context N] [--fetch]")
    }

    let kindName = flags.value("--kind") ?? ProviderKind.openAICompatible.rawValue
    guard let kind = ProviderKind(rawValue: kindName) else {
        throw CLIError.usage("unknown kind '\(kindName)'")
    }

    var provider = Provider(
        name: positional[0],
        kind: kind,
        baseURL: positional[1],
        apiKey: flags.value("--key"),
        // How much the backend can take in one request. Without it Claude Code
        // assumes 200k, which a local model cannot hold — and the failure is a
        // Metal allocation part way through the first turn, not a clean error.
        contextLength: flags.value("--context").flatMap(Int.init)
    )

    if flags.has("--fetch") {
        let outcome = try awaitBlocking { try await ModelCatalog().probe(provider) }
        provider.models = outcome.models
        provider.lastSyncedAt = Date()
        print("fetched \(outcome.models.count) model(s)")
    }

    let store = ProviderStore(paths: sandbox.paths)
    try store.add(provider)
    print("registered provider '\(provider.name)'")
    print("  \(provider.normalizedBaseURL)")
}

func cmdProviderRemove(sandbox: Sandbox, flags: Flags) throws {
    guard let name = flags.positional.first else {
        throw CLIError.usage("jxcode provider-remove <name>")
    }
    let store = ProviderStore(paths: sandbox.paths)
    guard let provider = store.providers.first(where: { $0.name == name }) else {
        throw CLIError.usage("no provider named '\(name)'")
    }
    try store.remove(id: provider.id)
    print("removed provider '\(name)'")
}

// MARK: - route

func cmdRoute(sandbox: Sandbox, flags: Flags) throws {
    let store = ProviderStore(paths: sandbox.paths)
    guard !store.providers.isEmpty else {
        throw CLIError.usage("no providers registered. see: jxcode provider-add")
    }

    let provider: Provider
    if let name = flags.value("--provider") {
        guard let found = store.providers.first(where: { $0.name == name }) else {
            throw CLIError.usage("no provider named '\(name)'")
        }
        provider = found
    } else {
        provider = store.providers[0]
    }

    guard let model = flags.value("--model") ?? provider.models.first else {
        throw CLIError.usage("no model selected and the provider advertises none. pass --model <name>")
    }

    let port = flags.value("--port").flatMap(UInt16.init) ?? RouterConfiguration.defaultPort

    // Honour the stored auth. The router used to start with auth off always,
    // so the CLI disagreed with the app about whether a token was required —
    // and a CLI router that accepts anything tells the user their agents are
    // fine when the app's router, with the same config, would refuse them.
    let auth = RouterAuth.load(from: sandbox.paths)
    let state = RouterState(
        RouterConfiguration(provider: provider, model: model, port: port),
        auth: auth
    )
    let router = ModelRouter(
        state: state,
        log: RouterLog(fileURL: sandbox.paths.logs.appendingPathComponent("router.log"))
    )

    try router.start(preferredPort: port)

    print("JXCode model router")
    print(String(repeating: "─", count: 64))
    print("  listening   \(router.baseURL)")
    print("  provider    \(provider.name) [\(provider.kind.rawValue)]")
    print("  upstream    \(provider.normalizedBaseURL)")
    print("  model       \(model)")
    print("  translation \(provider.kind.requiresTranslation ? "Anthropic ⇄ OpenAI" : "none (native Anthropic)")")
    print("  auth        \(auth.isEnabled ? "on — a router token is required" : "off — any caller is accepted")")
    print(String(repeating: "─", count: 64))
    print("")
    print("  Point an agent at it with:")
    print("    ANTHROPIC_BASE_URL=\(router.baseURL)")
    print("    OPENAI_BASE_URL=\(router.baseURL)")
    print("")
    print("  Or let the sandbox do it:  jxcode bind --model \(model)")
    print("")
    print("  Ctrl-C to stop.")

    // Clean shutdown so the port is released rather than lingering in TIME_WAIT.
    signal(SIGINT) { _ in
        print("")
        print("stopping router")
        exit(0)
    }

    dispatchMain()
}

// MARK: - bind / unbind

func cmdBind(sandbox: Sandbox, flags: Flags) throws {
    try sandbox.prepare()

    let store = ProviderStore(paths: sandbox.paths)
    guard let provider = store.providers.first else {
        throw CLIError.usage("no providers registered. see: jxcode provider-add")
    }
    guard let model = flags.value("--model") ?? provider.models.first else {
        throw CLIError.usage("no model selected. pass --model <name>")
    }

    let port = flags.value("--port").flatMap(UInt16.init) ?? RouterConfiguration.defaultPort
    let routerURL = flags.value("--router") ?? "http://127.0.0.1:\(port)"

    // The stored auth decides what credential goes into the written config.
    // Writing the placeholder unconditionally meant `jxcode bind` produced a
    // config that worked against a router with auth off and 401'd against the
    // app's router, which had it on — the same agent, the same backend, two
    // different answers depending on which process bound it.
    let auth = RouterAuth.load(from: sandbox.paths)
    let token = auth.isEnabled
        ? (auth.token ?? AgentConfigWriter.placeholderToken)
        : AgentConfigWriter.placeholderToken

    let registry = AgentRegistry(paths: sandbox.paths)
    let reports = try AgentConfigWriter.apply(
        agents: registry.agents,
        paths: sandbox.paths,
        routerURL: routerURL,
        model: model,
        token: token,
        // The backend's own window, so Claude Code does not assume 200k and
        // overflow a local model that can hold a fraction of it.
        contextLength: provider.contextLength
    )

    print("pointing agents at \(routerURL) → \(model)")
    print("  auth \(auth.isEnabled ? "on — agents carry the router token" : "off — agents carry the placeholder")")
    print("")
    for report in reports {
        print("  \(report.summary)")
        for note in report.notes { print("      · \(note)") }
    }
    print("")
    print("Launch an agent with: jxcode pty claude")
}

func cmdUnbind(sandbox: Sandbox, flags: Flags) throws {
    let registry = AgentRegistry(paths: sandbox.paths)
    let messages = try AgentConfigWriter.revert(agents: registry.agents, paths: sandbox.paths)
    if messages.isEmpty {
        print("nothing to revert.")
        return
    }
    for message in messages { print("  \(message)") }
}

// MARK: - translate

func cmdTranslate(sandbox: Sandbox, flags: Flags) throws {
    let input: Data
    if let path = flags.positional.first {
        input = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    } else {
        // Read a request from stdin so a real captured payload can be piped in.
        var buffer = Data()
        while let line = readLine(strippingNewline: false) {
            buffer.append(Data(line.utf8))
        }
        guard !buffer.isEmpty else {
            throw CLIError.usage("jxcode translate <request.json>  (or pipe a request on stdin)")
        }
        input = buffer
    }

    let request = try JSONDecoder().decode(AnthropicRequest.self, from: input)
    let result = Translation.request(request)

    print("Anthropic → OpenAI translation")
    print(String(repeating: "─", count: 64))
    print("  model        \(request.model)")
    print("  messages     \(request.messages.count) → \(result.request.messages.count)")
    print("  tools        \(request.tools?.count ?? 0)")
    print("  input tokens ≈\(TokenEstimator.estimate(request))")
    if !result.notes.isEmpty {
        print("")
        print("  notes:")
        for note in result.notes { print("    · \(note)") }
    }
    print(String(repeating: "─", count: 64))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let output = try encoder.encode(result.request)
    print(String(decoding: output, as: UTF8.self))

    print("")
    print("roles: \(result.request.messages.map(\.role).joined(separator: " → "))")
}
