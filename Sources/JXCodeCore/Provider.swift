import Foundation

// MARK: - Phase 02 / 03 seam
//
// Pillar 01 (the isolated runtime) is what this prototype implements. Pillars
// 02 and 03 plug in here, and are deliberately left as types plus a documented
// endpoint map so the shape is fixed before any of it is written.
//
// The design intent, so it is not lost:
//
//   - Every provider — remote API or local GGUF — is registered the same way.
//   - A localhost router is the single thing agents talk to. Agents are pointed
//     at it through ANTHROPIC_BASE_URL / OPENAI_BASE_URL, which
//     `SandboxEnvironment` already injects when `options.routerURL` is set.
//   - Because Claude Code speaks the Anthropic Messages API and most
//     self-hosted backends speak OpenAI's, the router has to translate in both
//     directions: system blocks, tool_use / tool_result, streaming event types,
//     and /v1/messages/count_tokens.
//   - A local GGUF provider is just another entry: the app supervises
//     llama-server and registers its OpenAI-compatible endpoint.

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    /// OpenAI `/v1/chat/completions` — vLLM, LM Studio, llama-server, OpenRouter,
    /// Together, and most self-hosted gateways.
    case openAICompatible
    /// Native Anthropic Messages API.
    case anthropic
    /// Ollama's own API, which uses different paths.
    case ollama
    /// A GGUF model served by a llama-server this app supervises.
    case localGGUF

    /// A human-readable name, for pickers and menus.
    ///
    /// Deliberately fuller than the short tag the badge shows. A badge has room
    /// for "gguf"; a picker needs to say whether that means a file on this
    /// machine or a server somewhere, because the two need different settings.
    public var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .anthropic:        return "Anthropic Messages"
        case .ollama:           return "Ollama"
        case .localGGUF:        return "Local GGUF (llama-server)"
        }
    }

    /// Where to list models. `{base}` is the provider's base URL.
    ///
    /// A local llama-server is an OpenAI-compatible server, so it shares these
    /// paths rather than repeating them with the prefix baked in. That is not
    /// cosmetic: `normalizedBaseURL` appends `/v1` to a bare `host:port` for
    /// both kinds, so a path that also began with `/v1` produced
    /// `/v1/v1/chat/completions` — a 404 from llama-server on every chat
    /// request. It went unnoticed because the two endpoints that *were*
    /// exercised do not go through this path: `/v1/models` is synthesised by
    /// the router from its own configuration, and `/props` strips the `/v1`
    /// before asking. Only a real completion through a real local backend
    /// reaches `chatPath`, and nothing did until `RealRouterChainTests`.
    public var modelsPath: String {
        switch self {
        case .openAICompatible, .localGGUF: return "{base}/models"
        case .anthropic:                    return "{base}/v1/models"
        case .ollama:                       return "{base}/api/tags"
        }
    }

    /// Where chat completions go.
    public var chatPath: String {
        switch self {
        case .openAICompatible, .localGGUF: return "{base}/chat/completions"
        case .anthropic:                    return "{base}/v1/messages"
        case .ollama:                       return "{base}/api/chat"
        }
    }

    /// Where an Anthropic Messages body goes, when this backend accepts one.
    ///
    /// `nil` is the honest answer for a backend with no such endpoint, and it is
    /// deliberately a URL rather than a boolean beside one. A flag and a path can
    /// disagree, and the disagreement is a request body posted to an endpoint
    /// that does not speak it — which is the exact failure this capability
    /// exists to prevent. Here the flag *is* the path, so they cannot drift.
    ///
    /// `localGGUF` is on this list because llama-server serves `/v1/messages`
    /// itself: the route is compiled into the installed
    /// `libllama-server-impl.dylib`, and the server logs
    /// `Request converted: Anthropic -> OpenAI Chat Completions` for it. That
    /// makes it a native speaker of both wires, not a backend to be translated
    /// for. It is also the backend most likely to be carrying a thinking model,
    /// which is the case where translating loses the most: `thinking` blocks and
    /// their signatures, `cache_control`, and tool-use ids all survive a proxy
    /// that does not touch them, and none survive a round trip through the
    /// OpenAI shape.
    ///
    /// A note on why the two paths differ: `normalizedBaseURL` appends `/v1` to
    /// a bare `host:port` for the kinds whose paths are relative to that root,
    /// so `localGGUF` must *not* repeat the prefix while Anthropic, which
    /// refuses the automatic prefix, must carry its own. Writing `/v1/messages`
    /// for both produced `/v1/v1/messages` in the same way `chatPath` once did.
    public var messagesPath: String? {
        switch self {
        case .anthropic:                 return "{base}/v1/messages"
        case .localGGUF:                 return "{base}/messages"
        case .openAICompatible, .ollama: return nil
        }
    }

    /// Where a token count is measured, when this backend can measure one.
    ///
    /// Derived from `messagesPath` rather than restated, for the same reason
    /// `requiresTranslation` is derived from it: a backend that gains a native
    /// Anthropic route cannot be left described as needing a translation it no
    /// longer needs, and by the same token cannot be left looking as though it
    /// has no way to count. Every backend that serves the Anthropic wire serves
    /// the counting endpoint beside it, because the endpoint is part of that
    /// wire — llama-server compiles both routes into the same library.
    ///
    /// The derivation is safe because the caller treats it as an attempt and
    /// never as a promise. Measured against a running llama-server,
    /// `/v1/messages/count_tokens` answers `{"input_tokens":18}` in Anthropic's
    /// own shape, and answers an unknown route with a 404 — which is what makes
    /// "this backend has no such endpoint" a fact the router can observe rather
    /// than guess at, and what lets `TokenCountCapability` remember it.
    public var countTokensPath: String? {
        messagesPath.map { $0 + "/count_tokens" }
    }

    /// Where an OpenAI Responses body goes, when this backend accepts one.
    ///
    /// `nil` is the honest answer for Anthropic and Ollama, and it is a URL
    /// rather than a boolean for the reason `messagesPath` gives: a flag and a
    /// path can disagree, and the disagreement is a body posted to an endpoint
    /// that does not speak it.
    ///
    /// **This one is load-bearing, not optional.** OpenAI deprecated
    /// `chat/completions` for Codex on 2025-12-09 and removed it in early
    /// February 2026, at which point `wire_api = "chat"` became a hard startup
    /// error: Codex now speaks `/v1/responses` and nothing else. That makes the
    /// router, which is the proxy between Codex and a local model, the thing
    /// that has to serve it — the deprecation notice says so outright to
    /// gateway operators ("ensure your proxy supports the `responses` API").
    ///
    /// `localGGUF` is on this list because llama-server serves it, verified
    /// live rather than inferred: a minimal `{"input":"…"}` answers 200 with a
    /// proper `object: "response"` body, and so does the array form. Worth
    /// noting what comes back — the output carries a `reasoning` item with
    /// `encrypted_content`, which is the thing 2.2 recorded as *unachievable*
    /// on the OpenAI chat wire. On this wire it is achievable, because the
    /// backend produces it rather than the translator having to.
    ///
    /// `openAICompatible` is on it because that kind's whole premise is
    /// OpenAI's API surface, and OpenAI itself serves this route. A vLLM or
    /// LM Studio behind it may not — so a 404 is reported as exactly that,
    /// naming the backend, rather than being papered over with a translation
    /// that does not exist.
    public var responsesPath: String? {
        switch self {
        case .openAICompatible, .localGGUF: return "{base}/responses"
        case .anthropic, .ollama:           return nil
        }
    }

    /// Whether this backend speaks OpenAI's wire, and so can serve as the target
    /// of a translation.
    ///
    /// Anthropic is the one kind that cannot: there is no `/v1/chat/completions`
    /// on it to fall back to, so a translated body sent there would be refused
    /// after the caller had already paid for the round trip.
    public var speaksOpenAI: Bool { self != .anthropic }

    /// Whether the router must translate Anthropic ⇄ OpenAI for this upstream.
    ///
    /// Derived from `messagesPath` rather than restated, so a backend that gains
    /// a native Anthropic route cannot be left described as needing a
    /// translation it no longer needs.
    public var requiresTranslation: Bool { messagesPath == nil }

    /// One line for the operator, saying what the router will actually do.
    ///
    /// It belongs here rather than in the CLI's `print` because it is a claim
    /// about the wire, and a claim about the wire should be assertable. The
    /// `probe` output is the one place a user looks to find out which endpoint
    /// their agent will reach, so the sentence has to stay true when a kind
    /// changes — which is exactly what this upgrade did to `localGGUF`.
    public var translationSummary: String {
        switch self {
        case .anthropic:
            return "none — the backend speaks the Anthropic wire itself"
        case .localGGUF:
            return "none — llama-server serves the Anthropic wire itself"
        case .openAICompatible, .ollama:
            return "Anthropic ⇄ OpenAI"
        }
    }

    /// One line for the operator, saying where a token count will come from.
    ///
    /// Beside `translationSummary` because it answers the same kind of question
    /// about the same backend — what will the router do with a request for this
    /// — and it belongs in the banner for the same reason. The two answers
    /// differ in accuracy by a factor of three on a tool-bearing request, and
    /// nothing else in the output would tell a user which one they are getting.
    ///
    /// The claim is derived from the path rather than written twice, so this
    /// line cannot promise a measurement the router has no endpoint to take.
    public var countTokensSummary: String {
        switch self {
        case .anthropic:
            return "measured — the backend counts them"
        case .localGGUF:
            return "measured — llama-server counts them"
        case .openAICompatible, .ollama:
            return "estimated — this backend has no counting endpoint"
        }
    }

    /// Headers needed to authenticate. Anthropic uses `x-api-key` plus a version
    /// header rather than a bearer token, which is a common integration bug.
    public func authHeaders(apiKey: String?) -> [String: String] {
        guard let apiKey, !apiKey.isEmpty else { return [:] }
        switch self {
        case .anthropic:
            return ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
        default:
            return ["Authorization": "Bearer \(apiKey)"]
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAICompatible: return "https://api.openai.com/v1"
        case .anthropic:        return "https://api.anthropic.com"
        case .ollama:           return "http://127.0.0.1:11434"
        case .localGGUF:        return "http://127.0.0.1:8080"
        }
    }

    /// Whether this kind's paths already include their own prefix.
    ///
    /// Ollama serves `/api/tags` at the root and Anthropic serves `/v1/messages`
    /// at the root, so neither takes the automatic `/v1` below.
    var acceptsAutomaticV1Prefix: Bool {
        switch self {
        case .openAICompatible, .localGGUF: return true
        case .anthropic, .ollama:           return false
        }
    }

    /// Tidy a user-entered base URL into one that will actually resolve.
    ///
    /// Three things go wrong constantly when someone pastes an endpoint:
    ///
    ///  - A trailing slash produces `//models`, which some servers 404 on.
    ///  - A bare `host:port` with no path is missing the `/v1` that every
    ///    OpenAI-compatible server puts its surface under. `llama-server`
    ///    accepts both `/v1/chat/completions` and `/chat/completions`, but
    ///    LM Studio, vLLM and OpenRouter only accept the former, so defaulting
    ///    to `/v1` is the choice that works more often.
    ///  - A base URL that *already* ends in `/v1` for a kind whose paths carry
    ///    their own prefix — pasting `https://api.anthropic.com/v1` is a very
    ///    natural thing to do — would produce `/v1/v1/messages`.
    ///
    /// The two directions are decided by `acceptsAutomaticV1Prefix`, so a kind
    /// is never both given a prefix and assumed to have one. A URL with any
    /// other path is left alone: if someone typed
    /// `https://gateway.internal/llm/v2`, guessing would break it.
    public func normalizedBaseURL(_ raw: String) -> String {
        var base = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base) else { return base }

        if acceptsAutomaticV1Prefix {
            // This kind's paths are relative to a `/v1` root, so supply one
            // when the user did not.
            if url.path.isEmpty || url.path == "/" { return base + "/v1" }
            return base
        }

        // This kind's paths already carry their own prefix, so a base URL that
        // repeats it must have it removed rather than doubled.
        if url.path == "/v1" { return String(base.dropLast("/v1".count)) }
        return base
    }
}

/// One registered backend.
public struct Provider: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    public var baseURL: String
    public var apiKey: String?
    /// Cached result of the last `/models` probe.
    public var models: [String]
    public var lastSyncedAt: Date?
    /// How many tokens this backend can actually take as input, when known.
    ///
    /// Optional and `decodeIfPresent` by synthesis, so a providers.json written
    /// before this field existed still decodes.
    ///
    /// It belongs here rather than being looked up at bind time because the
    /// backend is the only thing that knows it, and the bind button can be
    /// pressed from a pane that has never heard of a local model. Deriving the
    /// limit from the Models pane selection instead meant binding from the
    /// Providers pane wrote no limit at all — and Claude Code then assumed its
    /// default 200k window for a model that could hold a fraction of it.
    public var contextLength: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        baseURL: String? = nil,
        apiKey: String? = nil,
        models: [String] = [],
        lastSyncedAt: Date? = nil,
        contextLength: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL ?? kind.defaultBaseURL
        self.apiKey = apiKey
        self.models = models
        self.lastSyncedAt = lastSyncedAt
        self.contextLength = contextLength
    }

    /// The base URL after normalisation. All endpoint construction goes through
    /// this, so a trailing slash or a missing `/v1` is fixed in one place.
    public var normalizedBaseURL: String {
        kind.normalizedBaseURL(baseURL)
    }

    /// Absolute models endpoint.
    public var modelsURL: URL? {
        URL(string: kind.modelsPath.replacingOccurrences(of: "{base}", with: normalizedBaseURL))
    }

    /// Absolute chat endpoint.
    public var chatURL: URL? {
        URL(string: kind.chatPath.replacingOccurrences(of: "{base}", with: normalizedBaseURL))
    }

    /// Absolute Anthropic Messages endpoint, when this backend serves one.
    ///
    /// `nil` means the router must translate. The two endpoints are separate
    /// properties rather than one "the URL for this wire" accessor because the
    /// router needs to know *which* wire it is holding: an Anthropic body sent
    /// to `chatURL` reaches `/chat/completions` on a llama-server and is answered
    /// with a 400 that says nothing about the real mistake.
    public var messagesURL: URL? {
        guard let path = kind.messagesPath else { return nil }
        return URL(string: path.replacingOccurrences(of: "{base}", with: normalizedBaseURL))
    }

    /// Absolute token-counting endpoint, when this backend serves one.
    ///
    /// `nil` means the router must answer with the estimate, which is the same
    /// shape of answer `messagesURL` gives for the wire: the capability *is* the
    /// URL, so a flag and a path cannot drift apart and leave the router posting
    /// to an endpoint that does not speak the body.
    public var countTokensURL: URL? {
        guard let path = kind.countTokensPath else { return nil }
        return URL(string: path.replacingOccurrences(of: "{base}", with: normalizedBaseURL))
    }

    /// Absolute Responses endpoint, when this backend serves one.
    public var responsesURL: URL? {
        guard let path = kind.responsesPath else { return nil }
        return URL(string: path.replacingOccurrences(of: "{base}", with: normalizedBaseURL))
    }
}

/// JSON-backed provider list, next to the workspace file.
public final class ProviderStore {

    public private(set) var providers: [Provider] = []
    private let paths: SandboxPaths

    public init(paths: SandboxPaths = .default) {
        self.paths = paths
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: paths.providersFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        providers = (try? decoder.decode([Provider].self, from: data)) ?? []
    }

    public func save() throws {
        // `providers.json` carries the API keys. The directory is created
        // private and the file mode set explicitly rather than inherited from
        // the umask, which on a default macOS account is 022 — leaving a file
        // full of credentials readable by every user on the machine.
        try FileManager.default.createDirectory(
            at: paths.state,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(providers).write(to: paths.providersFile, options: .atomic)
        // After the write, because `.atomic` writes a temporary file and renames
        // it into place — the mode has to be set on the file that survives.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: paths.providersFile.path
        )
    }

    public func add(_ provider: Provider) throws {
        // Collapse on the backend's identity, not just its id.
        //
        // Callers that build a fresh `Provider` each time — the local-model
        // registrar does exactly that — otherwise append a new entry on every
        // run. The list then fills with several entries pointing at one port,
        // most of them stale: pick one after the server has moved and the
        // router answers `500 upstream error: Could not connect`, which says
        // nothing about why. Two entries with the same URL and kind are the
        // same backend, so the newer one replaces the older.
        providers.removeAll {
            $0.id == provider.id
                || ($0.normalizedBaseURL == provider.normalizedBaseURL
                    && $0.kind == provider.kind)
        }
        providers.append(provider)
        try save()
    }

    public func remove(id: UUID) throws {
        providers.removeAll { $0.id == id }
        try save()
    }
}

/// Fetches the model list from a registered backend.
///
/// Kept as a protocol so the phase-02 implementation can be swapped and so the
/// model list can be stubbed in tests without network access.
public protocol ModelCatalogFetching {
    func fetchModels(from provider: Provider) async throws -> [String]
}

public enum ModelCatalogError: Error, CustomStringConvertible {
    case invalidURL(String)
    case httpStatus(Int, String)
    /// The request never completed — server down, DNS failure, TLS refusal.
    case transport(String)
    /// A 2xx response whose body was not the expected shape.
    case decoding(String)
    /// The server answered, but exposed no models.
    case emptyCatalog(String)

    public var description: String {
        switch self {
        case .invalidURL(let url):
            return "invalid URL: \(url)"

        case .httpStatus(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)
            switch code {
            case 401, 403:
                return "HTTP \(code) — the server rejected the credentials. Check the API key. \(detail)"
            case 404:
                return "HTTP 404 — no endpoint there. The base URL may need (or already have) a /v1 suffix. \(detail)"
            case 429:
                return "HTTP 429 — rate limited. \(detail)"
            default:
                return "HTTP \(code): \(detail)"
            }

        case .transport(let message):
            return "could not reach the server: \(message)"

        case .decoding(let message):
            return "the server's reply was not a model list: \(message)"

        case .emptyCatalog(let url):
            return "the server at \(url) returned an empty model list"
        }
    }
}
