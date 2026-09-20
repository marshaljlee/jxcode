import XCTest
import Network
@testable import JXCodeCore

/// A loopback HTTP server that answers with whatever a test tells it to.
///
/// `FakeUpstream` in `RouterTests` is deliberately opinionated — it always
/// behaves like a working OpenAI-compatible server, which is what the router
/// tests want. `ModelCatalog` needs the opposite: arbitrary status codes,
/// arbitrary bodies, and a record of what was requested.
final class StubServer: @unchecked Sendable {

    struct Reply: Sendable {
        var status: Int = 200
        var body: String = "{}"
        var contentType: String = "application/json"

        static func json(_ body: String, status: Int = 200) -> Reply {
            Reply(status: status, body: body)
        }

        /// A body that is not JSON at all — a proxy's error page, an HTML
        /// index, a truncated response. `ModelCatalog` must report these
        /// rather than pretend the server returned an empty model list.
        static func text(
            _ body: String, contentType: String = "text/plain", status: Int = 200
        ) -> Reply {
            Reply(status: status, body: body, contentType: contentType)
        }
    }

    struct Hit: Sendable {
        var path: String
        var headers: [String: String]

        func header(_ name: String) -> String? {
            headers.first { $0.key.lowercased() == name.lowercased() }?.value
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.model-catalog-stub")
    private let lock = NSLock()

    private var _hits: [Hit] = []

    /// Keyed by path. Anything absent answers 404, which is exactly what a
    /// wrong URL prefix looks like from the client's side.
    var routes: [String: Reply] = [:]

    private(set) var port: UInt16 = 0

    var baseURL: String { "http://127.0.0.1:\(port)" }

    var hits: [Hit] {
        lock.lock(); defer { lock.unlock() }
        return _hits
    }

    var requestedPaths: [String] { hits.map(\.path) }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            throw XCTSkip("stub server did not start")
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, parser: HTTPRequestParser())
    }

    private func receive(_ connection: NWConnection, parser: HTTPRequestParser) {
        var parser = parser
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                parser.consume(data)
                if let request = try? parser.nextRequest() {
                    self.lock.lock()
                    self._hits.append(Hit(path: request.path, headers: request.headers))
                    self.lock.unlock()
                    self.respond(to: request, on: connection)
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, parser: parser)
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        let reply = routes[request.path] ?? Reply.json(#"{"error":"not found"}"#, status: 404)

        let body = Data(reply.body.utf8)
        var head = "HTTP/1.1 \(reply.status) \(reply.status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: \(reply.contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Fetching the model list from a registered backend.
///
/// This file exists because coverage said so: `ModelCatalog` sat at **6% line
/// coverage** — 154 of 164 lines never executed — while being half of the
/// feature the app was asked for ("autofetch supported models from the api
/// which i can select"). It was unreachable from the suite because it needs an
/// HTTP server, and nothing had stood one up for it.
///
/// It is also the code most likely to be *silently* wrong for a user. A wrong
/// envelope guess does not throw; it produces an empty model picker on a server
/// that works fine in every other client, which reads as "this app is broken"
/// with nothing to debug from.
final class ModelCatalogTests: XCTestCase {

    private var server: StubServer!

    override func setUpWithError() throws {
        server = try StubServer()
        try server.start()
    }

    override func tearDownWithError() throws {
        server?.stop()
    }

    private func catalog(timeout: TimeInterval = 5) -> ModelCatalog {
        ModelCatalog(timeout: timeout)
    }

    private func provider(
        _ kind: ProviderKind,
        baseURL: String? = nil,
        apiKey: String? = nil
    ) -> Provider {
        Provider(name: "Test", kind: kind, baseURL: baseURL ?? server.baseURL, apiKey: apiKey)
    }

    // MARK: - The four envelopes

    func testOpenAIEnvelope() async throws {
        // OpenAI, vLLM, LM Studio, llama-server, OpenRouter, Together, and
        // Anthropic's own /v1/models.
        server.routes["/v1/models"] = .json("""
        {"object":"list","data":[
          {"id":"gpt-4o","object":"model"},
          {"id":"gpt-4o-mini","object":"model"}
        ]}
        """)

        let models = try await catalog().fetchModels(from: provider(.openAICompatible))

        XCTAssertEqual(models, ["gpt-4o", "gpt-4o-mini"])
    }

    func testOllamaEnvelope() async throws {
        // Ollama's native API uses `models` and `name`, not `data` and `id`.
        server.routes["/api/tags"] = .json("""
        {"models":[
          {"name":"llama3:8b","size":4700000000},
          {"name":"qwen2.5-coder:7b"}
        ]}
        """)

        let models = try await catalog().fetchModels(from: provider(.ollama))

        XCTAssertEqual(models, ["llama3:8b", "qwen2.5-coder:7b"])
    }

    func testBareArrayOfStrings() async throws {
        // Some minimal self-hosted gateways answer with nothing but a list.
        server.routes["/v1/models"] = .json(#"["alpha","beta"]"#)

        let models = try await catalog().fetchModels(from: provider(.openAICompatible))

        XCTAssertEqual(models, ["alpha", "beta"])
    }

    func testAnUnknownShapeIsHarvestedRatherThanRejected() async throws {
        // The last-resort walk. A server that is otherwise usable should not be
        // declared broken because its envelope is unfamiliar.
        server.routes["/v1/models"] = .json("""
        {"result":{"items":[{"id":"m-one"},{"name":"m-two"}]}}
        """)

        let models = try await catalog().fetchModels(from: provider(.openAICompatible))

        XCTAssertEqual(models, ["m-one", "m-two"])
    }

    func testTheHarvestOnlyTrustsWellKnownKeys() async throws {
        // `items` is not one of the three real envelopes, so this reaches the
        // last-resort walk rather than a decoder. Inside an object the harvest
        // takes `id` in preference to `name`, so a model's own metadata field
        // called `name` must not be mistaken for an identifier — otherwise the
        // picker fills with junk.
        server.routes["/v1/models"] = .json("""
        {"items":[{"id":"real-model","name":"Human Readable Label"}]}
        """)

        let models = try await catalog().fetchModels(from: provider(.openAICompatible))

        XCTAssertEqual(models, ["real-model"], "the label leaked in as a model name")
    }

    // MARK: - Ordering and de-duplication

    func testResultsAreSortedCaseInsensitivelyAndDeduplicated() async throws {
        // Stable order matters: some views keep their selection by index, so a
        // server that shuffles its list would make the selection jump.
        server.routes["/v1/models"] = .json("""
        {"data":[{"id":"zeta"},{"id":"Alpha"},{"id":"zeta"},{"id":"beta"}]}
        """)

        let models = try await catalog().fetchModels(from: provider(.openAICompatible))

        XCTAssertEqual(models, ["Alpha", "beta", "zeta"])
    }

    func testEmptyIdentifiersAreDropped() async throws {
        server.routes["/v1/models"] = .json(#"{"data":[{"id":""},{"id":"real"}]}"#)

        let models = try await catalog().fetchModels(from: provider(.openAICompatible))

        XCTAssertEqual(models, ["real"])
    }

    // MARK: - The root fallback

    func testA404OnThePrimaryPathFallsBackToTheRoot() async throws {
        // This is what makes an older llama-server build work without the user
        // knowing why: the model list is at /models, not /v1/models.
        server.routes["/models"] = .json(#"{"data":[{"id":"local-model"}]}"#)

        let outcome = try await catalog().probe(provider(.localGGUF))

        XCTAssertEqual(outcome.models, ["local-model"])
        XCTAssertEqual(server.requestedPaths, ["/v1/models", "/models"])
        XCTAssertTrue(
            outcome.notes.contains { $0.contains("does not use a /v1 prefix") },
            "the fallback must be visible, notes were: \(outcome.notes)"
        )
    }

    func testTheFallbackIsNotAttemptedForKindsWithoutAnAutomaticPrefix() async throws {
        // Anthropic's paths carry their own /v1, so a 404 there is a real
        // answer rather than a prefix guess, and retrying would be noise.
        server.routes["/models"] = .json(#"{"data":[{"id":"should-not-be-used"}]}"#)

        do {
            _ = try await catalog().fetchModels(from: provider(.anthropic))
            XCTFail("expected the 404 to surface")
        } catch let error as ModelCatalogError {
            guard case .httpStatus(let code, _) = error else {
                return XCTFail("expected httpStatus, got \(error)")
            }
            XCTAssertEqual(code, 404)
        }

        XCTAssertEqual(server.requestedPaths, ["/v1/models"], "the fallback should not have been tried")
    }

    func testAnEmptyRootFallbackDoesNotWin() async throws {
        // A 200 with no models at the root is not an improvement on the 404 it
        // was meant to rescue, so the original failure has to be the one
        // reported.
        server.routes["/models"] = .json(#"{"data":[]}"#)

        do {
            _ = try await catalog().fetchModels(from: provider(.localGGUF))
            XCTFail("expected a failure")
        } catch let error as ModelCatalogError {
            guard case .httpStatus(let code, _) = error else {
                return XCTFail("expected the original 404, got \(error)")
            }
            XCTAssertEqual(code, 404)
        }
    }

    // MARK: - Failures

    func testAServerErrorSurfacesWithItsBody() async throws {
        // The body is where a self-hosted server explains itself, so it has to
        // survive into the message rather than being flattened to a code.
        server.routes["/v1/models"] = .json(
            #"{"error":{"message":"model runner has crashed"}}"#, status: 500
        )

        do {
            _ = try await catalog().fetchModels(from: provider(.openAICompatible))
            XCTFail("expected a failure")
        } catch let error as ModelCatalogError {
            guard case .httpStatus(let code, let body) = error else {
                return XCTFail("expected httpStatus, got \(error)")
            }
            XCTAssertEqual(code, 500)
            XCTAssertTrue(body.contains("model runner has crashed"))
        }
    }

    func testAnEmptyCatalogIsItsOwnError() async throws {
        // Distinct from a decode failure: the server answered correctly and
        // has nothing loaded. The user needs to be told to load a model, not
        // to check their URL.
        server.routes["/v1/models"] = .json(#"{"object":"list","data":[]}"#)

        do {
            _ = try await catalog().fetchModels(from: provider(.openAICompatible))
            XCTFail("expected a failure")
        } catch let error as ModelCatalogError {
            guard case .emptyCatalog(let url) = error else {
                return XCTFail("expected emptyCatalog, got \(error)")
            }
            XCTAssertTrue(url.contains("/v1"), "the message should name the URL tried, got: \(url)")
        }
    }

    func testAnUnparseableBodyIsReportedWithAPreview() async throws {
        server.routes["/v1/models"] = .text("<html>nginx</html>", contentType: "text/html")

        do {
            _ = try await catalog().fetchModels(from: provider(.openAICompatible))
            XCTFail("expected a failure")
        } catch let error as ModelCatalogError {
            guard case .decoding(let preview) = error else {
                return XCTFail("expected decoding, got \(error)")
            }
            XCTAssertTrue(preview.contains("nginx"), "got: \(preview)")
        }
    }

    func testAnEmptyBodyIsReportedAsEmptyRatherThanAsABlankPreview() async throws {
        server.routes["/v1/models"] = .json("")

        do {
            _ = try await catalog().fetchModels(from: provider(.openAICompatible))
            XCTFail("expected a failure")
        } catch let error as ModelCatalogError {
            guard case .decoding(let preview) = error else {
                return XCTFail("expected decoding, got \(error)")
            }
            XCTAssertEqual(preview, "(empty body)")
        }
    }

    func testAConnectionFailureIsATransportErrorNotACrash() async throws {
        // Nothing is listening on this port, which is the everyday case of a
        // local server that is not running yet.
        let dead = Provider(name: "Dead", kind: .localGGUF, baseURL: "http://127.0.0.1:1")

        do {
            _ = try await catalog(timeout: 2).fetchModels(from: dead)
            XCTFail("expected a failure")
        } catch let error as ModelCatalogError {
            guard case .transport = error else {
                return XCTFail("expected transport, got \(error)")
            }
        }
    }

    // MARK: - Auth

    func testAnthropicSendsItsOwnHeaderRatherThanABearerToken() async throws {
        // Anthropic rejects `Authorization: Bearer`, so using the generic path
        // here would make the provider look like it needs a different key.
        server.routes["/v1/models"] = .json(#"{"data":[{"id":"claude-sonnet-4-5"}]}"#)

        _ = try await catalog().fetchModels(
            from: provider(.anthropic, apiKey: "sk-ant-test")
        )

        let hit = try XCTUnwrap(server.hits.first)
        XCTAssertEqual(hit.header("x-api-key"), "sk-ant-test")
        XCTAssertEqual(hit.header("anthropic-version"), "2023-06-01")
        XCTAssertNil(hit.header("Authorization"), "a bearer token must not be sent to Anthropic")
    }

    func testOpenAICompatibleSendsABearerToken() async throws {
        server.routes["/v1/models"] = .json(#"{"data":[{"id":"m"}]}"#)

        _ = try await catalog().fetchModels(
            from: provider(.openAICompatible, apiKey: "sk-test")
        )

        let hit = try XCTUnwrap(server.hits.first)
        XCTAssertEqual(hit.header("Authorization"), "Bearer sk-test")
        XCTAssertNil(hit.header("x-api-key"))
    }

    func testNoKeyMeansNoAuthHeaderAtAll() async throws {
        // A local server often rejects a stray empty Authorization header.
        server.routes["/v1/models"] = .json(#"{"data":[{"id":"m"}]}"#)

        _ = try await catalog().fetchModels(from: provider(.localGGUF))

        let hit = try XCTUnwrap(server.hits.first)
        XCTAssertNil(hit.header("Authorization"))
        XCTAssertNil(hit.header("x-api-key"))
        XCTAssertEqual(hit.header("Accept"), "application/json")
    }

    // MARK: - Notes

    func testANormalisedBaseURLIsReported() async throws {
        // Silently rewriting what the user typed is the kind of helpfulness
        // that makes a wrong URL impossible to debug.
        server.routes["/v1/models"] = .json(#"{"data":[{"id":"m"}]}"#)

        let outcome = try await catalog().probe(
            provider(.openAICompatible, baseURL: server.baseURL)
        )

        XCTAssertTrue(
            outcome.notes.contains { $0.contains("normalised") },
            "notes were: \(outcome.notes)"
        )
    }

    func testABaseURLThatAlreadyEndsInV1IsNotReportedAsNormalised() async throws {
        server.routes["/v1/models"] = .json(#"{"data":[{"id":"m"}]}"#)

        let outcome = try await catalog().probe(
            provider(.openAICompatible, baseURL: server.baseURL + "/v1")
        )

        XCTAssertFalse(
            outcome.notes.contains { $0.contains("normalised") },
            "notes were: \(outcome.notes)"
        )
        XCTAssertEqual(server.requestedPaths, ["/v1/models"], "the prefix must not double")
    }

    func testASuccessfulProbeSaysHowManyModelsAndWhereFrom() async throws {
        server.routes["/v1/models"] = .json(#"{"data":[{"id":"a"},{"id":"b"}]}"#)

        let outcome = try await catalog().probe(provider(.openAICompatible))

        XCTAssertTrue(
            outcome.notes.contains { $0.contains("2 model") && $0.contains("/v1/models") },
            "notes were: \(outcome.notes)"
        )
    }
}

/// The model-name heuristic behind the UI's tool-calling warning.
/// The text of `ModelCatalogError`, which is what a user actually reads when a
/// registered backend does not work.
///
/// None of these strings had ever executed. They are the whole diagnostic
/// experience for requirement 2 — a provider that fails with "HTTP 404" and no
/// hint sends the user hunting for a bug that is a missing `/v1`.
final class ModelCatalogErrorMessageTests: XCTestCase {

    private func message(_ error: ModelCatalogError) -> String {
        error.description
    }

    func testA404ExplainsThePrefixRatherThanJustTheStatus() {
        let text = message(.httpStatus(404, "Not Found"))
        XCTAssertTrue(text.contains("404"), text)
        XCTAssertTrue(
            text.contains("/v1"),
            "a 404 is almost always a prefix mismatch; the message must say so: \(text)"
        )
    }

    func testAuthFailuresPointAtTheKey() {
        for code in [401, 403] {
            let text = message(.httpStatus(code, "unauthorized"))
            XCTAssertTrue(text.contains("\(code)"), text)
            XCTAssertTrue(
                text.lowercased().contains("credential") || text.lowercased().contains("api key"),
                "\(code) should mention credentials: \(text)"
            )
        }
    }

    func testRateLimitingIsNamedAsSuch() {
        XCTAssertTrue(message(.httpStatus(429, "slow down")).lowercased().contains("rate limited"))
    }

    func testAnUnrecognisedStatusStillCarriesTheCodeAndBody() {
        let text = message(.httpStatus(503, "upstream unavailable"))
        XCTAssertTrue(text.contains("503"), text)
        XCTAssertTrue(text.contains("upstream unavailable"), text)
    }

    func testEveryCaseNamesItsCause() {
        let cases: [(ModelCatalogError, [String])] = [
            (.invalidURL("nonsense"), ["invalid URL", "nonsense"]),
            (.transport("connection refused"), ["could not reach", "connection refused"]),
            (.decoding("<html>nginx</html>"), ["not a model list", "<html>nginx</html>"]),
            (.emptyCatalog("http://127.0.0.1:8080"), ["empty model list", "127.0.0.1:8080"]),
        ]
        for (error, fragments) in cases {
            let text = message(error)
            for fragment in fragments {
                XCTAssertTrue(
                    text.contains(fragment),
                    "\(error) → \"\(text)\" does not mention \"\(fragment)\""
                )
            }
        }
    }

    /// A proxy's error page can be megabytes of HTML. Pasting it into a UI
    /// label is how a diagnostic turns into a hang.
    func testALongBodyIsTruncated() {
        let body = String(repeating: "x", count: 5_000)
        let text = message(.httpStatus(500, body))
        XCTAssertLessThan(text.count, 500, "a 5 KB body was pasted into the message wholesale")
    }
}

final class ModelNameHeuristicTests: XCTestCase {

    func testEmbeddingAndUtilityModelsAreFlaggedAsNotToolCapable() {
        // An agent pointed at one of these produces a confusing loop of plain
        // text where tool calls were expected, so the warning is worth having.
        for name in [
            "text-embedding-3-large",
            "bge-rerank-v2",
            "whisper-large-v3",
            "piper-tts",
            "llava-vision-only",
            "llama-2-7b-base",
        ] {
            XCTAssertFalse(Provider.looksToolCapable(name), "\(name) should be flagged")
        }
    }

    func testInstructAndCoderModelsAreNotFlagged() {
        for name in ["qwen2.5-coder:7b", "claude-sonnet-4-5", "gpt-4o-mini", "llama-3.1-8b-instruct"] {
            XCTAssertTrue(Provider.looksToolCapable(name), "\(name) should pass")
        }
    }

    func testTheCheckIsCaseInsensitive() {
        XCTAssertFalse(Provider.looksToolCapable("TEXT-EMBEDDING-3"))
        XCTAssertFalse(Provider.looksToolCapable("Whisper"))
    }
}
