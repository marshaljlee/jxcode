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

    Console.line("probing \(provider.normalizedBaseURL)")
    Console.line("  models:   \(provider.modelsURL?.absoluteString ?? "—")")
    Console.line("  chat:     \(provider.chatURL?.absoluteString ?? "—")")
    // The endpoint Claude Code actually reaches. Printing it here is the only
    // way to tell a native backend from a translated one before a turn is spent
    // finding out: `—` means the router rewrites the body on the way through.
    Console.line("  messages: \(provider.messagesURL?.absoluteString ?? "— (translated from the chat wire)")")
    Console.line("")

    let outcome = try awaitBlocking { try await ModelCatalog().probe(provider) }

    for note in outcome.notes { Console.line("  · \(note)") }
    if !outcome.notes.isEmpty { Console.line("") }

    for model in outcome.models {
        // Flag the ones that cannot do tool calling, since an agent pointed at
        // one produces a confusing loop of prose instead of actions.
        let marker = Provider.looksToolCapable(model) ? " " : " (no tool calling)"
        Console.line("  \(model)\(marker)")
    }
    Console.line("")
    Console.line("\(outcome.models.count) model(s)")
}

// MARK: - providers

func cmdProviders(sandbox: Sandbox) throws {
    let store = ProviderStore(paths: sandbox.paths)
    guard !store.providers.isEmpty else {
        Console.line("no providers registered.")
        Console.line("add one with: jxcode provider-add <name> <base-url> [--kind openAICompatible] [--key KEY]")
        return
    }
    for provider in store.providers {
        Console.line("  \(provider.name)  [\(provider.kind.rawValue)]")
        Console.line("    base   \(provider.normalizedBaseURL)")
        Console.line("    key    \(provider.apiKey == nil ? "none" : "set")")
        Console.line("    models \(provider.models.count)")
        if !provider.models.isEmpty {
            Console.line("           \(provider.models.prefix(6).joined(separator: ", "))\(provider.models.count > 6 ? ", …" : "")")
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
        Console.line("fetched \(outcome.models.count) model(s)")
    }

    let store = ProviderStore(paths: sandbox.paths)
    try store.add(provider)
    Console.line("registered provider '\(provider.name)'")
    Console.line("  \(provider.normalizedBaseURL)")
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
    Console.line("removed provider '\(name)'")
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

    Console.line("JXCode model router")
    Console.line(String(repeating: "─", count: 64))
    Console.line("  listening   \(router.baseURL)")
    Console.line("  provider    \(provider.name) [\(provider.kind.rawValue)]")
    Console.line("  upstream    \(provider.normalizedBaseURL)")
    Console.line("  model       \(model)")
    Console.line("  translation \(provider.kind.translationSummary)")
    Console.line("  count       \(provider.kind.countTokensSummary)")
    Console.line("  auth        \(auth.isEnabled ? "on — a router token is required" : "off — any caller is accepted")")
    Console.line(String(repeating: "─", count: 64))
    Console.line("")
    Console.line("  Point an agent at it with:")
    Console.line("    ANTHROPIC_BASE_URL=\(router.baseURL)")
    Console.line("    OPENAI_BASE_URL=\(router.baseURL)")
    Console.line("")
    Console.line("  Or let the sandbox do it:  jxcode bind --model \(model)")
    Console.line("")
    Console.line("  Ctrl-C to stop.")

    // Clean shutdown so the port is released rather than lingering in TIME_WAIT.
    signal(SIGINT) { _ in
        Console.line("")
        Console.line("stopping router")
        exit(0)
    }

    dispatchMain()
}

// MARK: - bind / unbind

/// Parse `agent=wire,agent=wire` into a wire map, refusing an unknown wire.
///
/// `Assignments` does the splitting; what it cannot do is know which wires
/// exist. So an unrecognised value is an error here rather than a dropped
/// entry: this field decides which protocol an agent speaks to the router, and
/// a typo in it would otherwise bind an agent to the wrong wire with nothing
/// said. The accepted spellings are listed in the message because "which of the
/// three" is not a question worth making the user go and look up.
func parseWireOverrides(_ text: String?) throws -> [String: AgentWire] {
    var result: [String: AgentWire] = [:]
    for (agentID, raw) in Assignments.parse(text) {
        guard let wire = AgentWire.parse(raw) else {
            throw CLIError.usage(
                "unknown wire '\(raw)' for '\(agentID)'. one of: "
                + AgentWire.acceptedSpellings
            )
        }
        result[agentID] = wire
    }
    return result
}

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
        // Per-agent wire, so an agent can be pinned to the protocol its
        // backend actually serves. Only a Codex config carries one today, and
        // the writer says so for any other agent rather than accepting a
        // setting that would do nothing.
        wires: try parseWireOverrides(flags.value("--wire")),
        // The backend's own window, so Claude Code does not assume 200k and
        // overflow a local model that can hold a fraction of it.
        contextLength: provider.contextLength
    )

    Console.line("pointing agents at \(routerURL) → \(model)")
    Console.line("  auth \(auth.isEnabled ? "on — agents carry the router token" : "off — agents carry the placeholder")")
    Console.line("")
    for report in reports {
        Console.line("  \(report.summary)")
        for note in report.notes { Console.line("      · \(note)") }
    }
    Console.line("")
    Console.line("Launch an agent with: jxcode pty claude")
}

func cmdUnbind(sandbox: Sandbox, flags: Flags) throws {
    let registry = AgentRegistry(paths: sandbox.paths)
    let messages = try AgentConfigWriter.revert(agents: registry.agents, paths: sandbox.paths)
    if messages.isEmpty {
        Console.line("nothing to revert.")
        return
    }
    for message in messages { Console.line("  \(message)") }
}

// MARK: - translate

/// Translate one body, in any of the three directions the router performs.
///
/// The default direction is the one an Anthropic-speaking agent hits: a Messages
/// request on its way to an OpenAI-compatible backend. The other two exist
/// because the router has them and nothing else could exercise them by hand —
/// `openai-to-anthropic` is what a Codex or Gemini CLI request goes through, and
/// `--response` is the *reply* direction, where a dropped block is invisible
/// because the answer still looks well formed.
///
/// The notes are the point of the command. A translation that cannot carry a
/// block still returns a valid body, so the only way to see the loss is to be
/// told about it — and being told is what turns "the model stopped using tools"
/// into "the tool_result blocks were dropped".
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
            throw CLIError.usage(
                "jxcode translate <body.json>  (or pipe a body on stdin) "
                    + "[--direction anthropic-to-openai|openai-to-anthropic] [--response]"
            )
        }
        input = buffer
    }

    let direction = flags.value("--direction") ?? "anthropic-to-openai"
    let asResponse = flags.has("--response")
    let decoder = JSONDecoder()

    func report(title: String, summary: [(String, String)], notes: [String]) {
        Console.line(title)
        Console.line(String(repeating: "─", count: 64))
        for (label, value) in summary {
            Console.line("  \(label.padding(toLength: 13, withPad: " ", startingAt: 0))\(value)")
        }
        if notes.isEmpty {
            Console.line("")
            Console.line("  notes: none — everything the client sent has an equivalent upstream")
        } else {
            Console.line("")
            Console.line("  notes:")
            for note in notes { Console.line("    · \(note)") }
        }
        Console.line(String(repeating: "─", count: 64))
    }

    func emit<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        Console.line(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    switch (direction, asResponse) {
    case ("anthropic-to-openai", false):
        let request = try decoder.decode(AnthropicRequest.self, from: input)
        let result = Translation.request(request)
        report(
            title: "Anthropic request → OpenAI request",
            summary: [
                ("model", request.model),
                ("messages", "\(request.messages.count) → \(result.request.messages.count)"),
                ("tools", "\(request.tools?.count ?? 0)"),
                ("input tokens", "≈\(TokenEstimator.estimate(request))"),
            ],
            notes: result.notes
        )
        try emit(result.request)
        Console.line("")
        Console.line("roles: \(result.request.messages.map(\.role).joined(separator: " → "))")

    case ("openai-to-anthropic", false):
        let request = try decoder.decode(OpenAIChatRequest.self, from: input)
        let result = Translation.anthropicRequest(from: request)
        report(
            title: "OpenAI request → Anthropic request",
            summary: [
                ("model", request.model),
                ("messages", "\(request.messages.count) → \(result.request.messages.count)"),
                ("max_tokens", "\(result.request.maxTokens) (Anthropic requires one)"),
                ("input tokens", "≈\(TokenEstimator.estimate(result.request))"),
            ],
            notes: result.notes
        )
        try emit(result.request)

    case ("anthropic-to-openai", true):
        let response = try decoder.decode(AnthropicResponse.self, from: input)
        let result = Translation.openAIResponse(from: response)
        let choice = result.response.first
        report(
            title: "Anthropic response → OpenAI response",
            summary: [
                ("model", response.model),
                ("blocks", "\(response.content.map(\.typeName).joined(separator: ", "))"),
                ("finish", choice?.finishReason ?? "—"),
                ("tool calls", "\(choice?.payload?.toolCalls?.count ?? 0)"),
            ],
            notes: result.notes
        )
        try emit(result.response)

    default:
        throw CLIError.usage(
            "unknown --direction '\(direction)'. one of: anthropic-to-openai, openai-to-anthropic"
        )
    }
}

// MARK: - probe

/// Ask a backend to call a tool, and report what it actually did.
///
/// The command exists because the alternative answer to "can this model call
/// tools?" is a heuristic over a chat template, and a heuristic cannot be
/// argued with. This can: it sends one user message and one JSON-Schema tool
/// and looks at the reply. Exits non-zero unless a tool call came back, so
/// `jxcode probe … && claude` is a usable guard.
func cmdProbe(sandbox: Sandbox, flags: Flags) throws {
    guard let raw = flags.positional.first else {
        throw CLIError.usage(
            "jxcode probe <base-url> [--model NAME] [--kind openAICompatible|ollama|localGGUF] "
                + "[--key KEY] [--template-kwargs JSON]"
        )
    }

    let kindName = flags.value("--kind") ?? ProviderKind.openAICompatible.rawValue
    guard let kind = ProviderKind(rawValue: kindName) else {
        throw CLIError.usage(
            "unknown kind '\(kindName)'. one of: \(ProviderKind.allCases.map(\.rawValue).joined(separator: ", "))"
        )
    }

    let provider = Provider(name: "probe", kind: kind, baseURL: raw, apiKey: flags.value("--key"))

    // Without a named model, ask the catalog. A probe that demanded a model
    // name would put a lookup in front of the only question the user has, and
    // a server with exactly one model loaded is the common case for a local
    // backend.
    let model: String
    if let named = flags.value("--model") {
        model = named
    } else {
        let catalog = try awaitBlocking { try await ModelCatalog().probe(provider) }
        guard let first = catalog.models.first else {
            throw CLIError.usage(
                "no model to probe at \(provider.normalizedBaseURL). name one with --model."
            )
        }
        model = first
        if catalog.models.count > 1 {
            Console.line("no --model given, so probing '\(model)'. The server also has: "
                + "\(catalog.models.dropFirst().prefix(5).joined(separator: ", "))")
            Console.line("")
        }
    }

    Console.line("probing \(provider.chatURL?.absoluteString ?? provider.normalizedBaseURL)")
    Console.line("")

    // A probe of a local llama-server has to ask in the environment that server
    // was *started* in, and this command only has a URL — so it cannot look the
    // environment up. A template that gates its tool handling behind
    // `enable_thinking` behaves differently depending on it, and without a way
    // to state it the probe would measure an environment no agent will be in.
    // `jxcode llama-plan` prints what to pass.
    let templateKwargs: [String: JSONValue]?
    if let raw = flags.value("--template-kwargs") {
        guard case .object(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) else {
            throw CLIError.usage("--template-kwargs must be a JSON object, got '\(raw)'")
        }
        templateKwargs = fields
    } else {
        templateKwargs = nil
    }

    let outcome = try awaitBlocking {
        await ToolProbe(templateKwargs: templateKwargs).run(provider: provider, model: model)
    }
    Console.line(ModelReport.toolProbe(outcome))
    Console.line("")

    // Inconclusive is not a pass. A script that gates on this needs the
    // difference between "it called the tool" and "we could not find out".
    exit(outcome.isVerified ? 0 : 1)
}
