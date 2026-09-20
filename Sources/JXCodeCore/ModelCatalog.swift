import Foundation

/// What a probe of a registered backend found.
public struct ProbeOutcome: Sendable {
    public var models: [String]
    /// Human-readable observations worth showing in the UI — which shape the
    /// server answered in, whether the base URL had to be adjusted, and so on.
    public var notes: [String]

    public init(models: [String], notes: [String] = []) {
        self.models = models
        self.notes = notes
    }
}

/// Fetches model lists from registered backends.
///
/// Four shapes have to be handled, and guessing wrong is the single most common
/// reason a self-hosted provider "doesn't work":
///
///  - `{data:[{id}]}` — OpenAI, vLLM, LM Studio, llama-server, OpenRouter,
///    Together, and Anthropic's own `/v1/models`.
///  - `{models:[{name}]}` — Ollama's native API.
///  - `{data:[{id}]}` at the *root* rather than under `/v1` — llama-server
///    again, depending on version and flags.
///  - A bare JSON array of strings — some small self-hosted gateways.
///
/// The last three are why `fetchModels` falls back rather than failing on the
/// first shape mismatch.
public struct ModelCatalog: ModelCatalogFetching {

    private let session: URLSession
    private let timeout: TimeInterval

    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        // A model list is worth re-fetching; never let a cached one hide a
        // server that has been restarted with different models loaded.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: configuration)
        self.timeout = timeout
    }

    // MARK: - Public API

    public func fetchModels(from provider: Provider) async throws -> [String] {
        try await probe(provider).models
    }

    /// Fetch the model list and report how the server answered.
    public func probe(_ provider: Provider) async throws -> ProbeOutcome {
        var notes: [String] = []

        let normalized = provider.normalizedBaseURL
        if normalized != provider.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            notes.append("base URL normalised to \(normalized)")
        }

        guard let primary = provider.modelsURL else {
            throw ModelCatalogError.invalidURL(provider.baseURL)
        }

        let (data, response) = try await get(primary, provider: provider)

        // A 404 on the primary path is usually a wrong prefix rather than a
        // wrong host, so try the root form before giving up. This is what makes
        // an older llama-server build work without the user knowing why.
        if response.statusCode == 404, provider.kind.acceptsAutomaticV1Prefix {
            if let rootURL = rootModelsURL(for: provider) {
                let (rootData, rootResponse) = try await get(rootURL, provider: provider)
                if (200..<300).contains(rootResponse.statusCode) {
                    let models = try decodeModels(rootData, provider: provider)
                    if !models.isEmpty {
                        notes.append("models found at \(rootURL.path) — this server does not use a /v1 prefix")
                        return ProbeOutcome(models: models, notes: notes)
                    }
                }
            }
        }

        guard (200..<300).contains(response.statusCode) else {
            throw ModelCatalogError.httpStatus(
                response.statusCode,
                String(decoding: data, as: UTF8.self)
            )
        }

        let models = try decodeModels(data, provider: provider)
        guard !models.isEmpty else {
            throw ModelCatalogError.emptyCatalog(normalized)
        }

        notes.append("\(models.count) model(s) from \(primary.path)")
        return ProbeOutcome(models: models, notes: notes)
    }

    // MARK: - Requests

    private func get(_ url: URL, provider: Provider) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in provider.kind.authHeaders(apiKey: provider.apiKey) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ModelCatalogError.decoding("response was not HTTP")
            }
            return (data, http)
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.transport(error.localizedDescription)
        }
    }

    /// The model list at the server root, ignoring the `/v1` convention.
    private func rootModelsURL(for provider: Provider) -> URL? {
        var base = provider.normalizedBaseURL
        if base.hasSuffix("/v1") { base.removeLast(3) }
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/models")
    }

    // MARK: - Decoding

    /// Try each known envelope in turn.
    ///
    /// Order matters only for speed; the shapes are mutually exclusive in
    /// practice, since one has a `data` key, one has `models`, and one is a bare
    /// array.
    ///
    /// A recognised envelope is returned even when it is *empty*, which is what
    /// makes `ModelCatalogError.emptyCatalog` reachable. Previously every branch
    /// required a non-empty result and the function threw on the way out, so an
    /// empty catalog was impossible to report: a server that was running fine
    /// with nothing loaded — the most ordinary state a local backend is ever in
    /// — produced a `decoding` failure whose message was the raw JSON body
    /// instead of "no models loaded".
    private func decodeModels(_ data: Data, provider: Provider) throws -> [String] {
        let decoder = JSONDecoder()

        if let list = try? decoder.decode(OpenAIModelList.self, from: data) {
            return sorted(list.data.map(\.id).filter { !$0.isEmpty })
        }

        if let list = try? decoder.decode(OllamaTagList.self, from: data) {
            return sorted(list.models.map(\.name).filter { !$0.isEmpty })
        }

        // A bare array of strings, which some minimal gateways return.
        if let names = try? decoder.decode([String].self, from: data) {
            return sorted(names.filter { !$0.isEmpty })
        }

        // Last resort: pull every `id` or `name` out of whatever structure this
        // is. Better than failing outright on a server that is otherwise usable
        // — but if even this finds nothing, report a decode failure rather than
        // an empty catalog, because "there are no models" would be a guess.
        if let value = try? decoder.decode(JSONValue.self, from: data) {
            let harvested = harvestIdentifiers(value)
            if !harvested.isEmpty {
                return sorted(harvested)
            }
        }

        let preview = String(decoding: data.prefix(200), as: UTF8.self)
        throw ModelCatalogError.decoding(preview.isEmpty ? "(empty body)" : preview)
    }

    /// Walk an arbitrary JSON tree collecting `id` / `name` string values.
    private func harvestIdentifiers(_ value: JSONValue) -> [String] {
        switch value {
        case .object(let object):
            // Only accept the well-known keys at the object level, so a model's
            // own metadata field called `name` is not mistaken for an id.
            if let id = object["id"]?.stringValue, !id.isEmpty { return [id] }
            if let name = object["name"]?.stringValue, !name.isEmpty { return [name] }

            var found: [String] = []
            for key in ["data", "models", "model", "result", "items"] {
                if let nested = object[key] {
                    found.append(contentsOf: harvestIdentifiers(nested))
                }
            }
            return found

        case .array(let values):
            return values.flatMap { harvestIdentifiers($0) }

        case .string(let value):
            return value.isEmpty ? [] : [value]

        default:
            return []
        }
    }

    /// Alphabetical, case-insensitive, de-duplicated.
    ///
    /// Stable ordering matters because the model picker keeps its selection by
    /// index in some views, and a server that returns its list in a different
    /// order each call would make the selection jump.
    private func sorted(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names
            .filter { seen.insert($0).inserted }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: - Model name helpers

public extension Provider {
    /// Whether a model looks like it can do tool calling.
    ///
    /// Used to warn in the UI rather than to block anything. Base models and
    /// most non-instruct models cannot, and an agent pointed at one produces a
    /// confusing loop of plain text where tool calls were expected.
    static func looksToolCapable(_ model: String) -> Bool {
        let lowered = model.lowercased()
        let disqualifying = ["embed", "rerank", "whisper", "tts", "vision-only", "base"]
        return !disqualifying.contains { lowered.contains($0) }
    }
}
