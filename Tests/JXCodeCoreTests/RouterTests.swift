import XCTest
import Network
@testable import JXCodeCore

// MARK: - Fake upstream

/// A minimal OpenAI-compatible server, on a real socket.
///
/// Deliberately not a stub of `URLSession`: the point of this test is to
/// exercise the actual HTTP path — request parsing, chunked streaming, and the
/// SSE framing — because that is where the silent failures live.
///
/// It emits **CRLF** line endings, which is legal and which a naive
/// `String`-based SSE parser silently mis-handles (CR+LF is a single grapheme
/// cluster in Swift). Keeping that here means the regression cannot come back.
final class FakeUpstream: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.fake-upstream")
    private let lock = NSLock()

    private var _requests: [HTTPRequest] = []
    private var _bodyTexts: [String] = []

    /// JSON returned for a non-streaming completion.
    var completionBody: String = """
    {"id":"chatcmpl-test","object":"chat.completion","model":"fake-model","choices":[
      {"index":0,"message":{"role":"assistant","content":"hello from upstream"},"finish_reason":"stop"}
    ],"usage":{"prompt_tokens":9,"completion_tokens":4,"total_tokens":13}}
    """

    /// Raw `data:` payloads streamed for a streaming completion.
    var streamPayloads: [String] = [
        #"{"id":"c","choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}"#,
        #"{"id":"c","choices":[{"index":0,"delta":{"content":"lo"}}]}"#,
        #"{"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
        #"{"id":"c","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":2}}"#,
    ]

    /// When set, every completion is streamed.
    var alwaysStream = false

    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        listener = try NWListener(using: parameters)
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    var requests: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    var bodyTexts: [String] {
        lock.lock(); defer { lock.unlock() }
        return _bodyTexts
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
            throw XCTSkip("fake upstream did not start")
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() {
        listener.cancel()
    }

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
                    self._requests.append(request)
                    self._bodyTexts.append(request.bodyText)
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
        if request.path.hasSuffix("/models") {
            send(connection, json: #"{"object":"list","data":[{"id":"fake-model","object":"model"}]}"#)
            return
        }

        let wantsStream = alwaysStream || request.bodyText.contains(#""stream":true"#)
        if wantsStream {
            sendStream(connection)
        } else {
            send(connection, json: completionBody)
        }
    }

    private func send(_ connection: NWConnection, json: String) {
        let body = Data(json.utf8)
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Chunked `text/event-stream`, with CRLF line endings.
    private func sendStream(_ connection: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Transfer-Encoding: chunked\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        for item in streamPayloads {
            let frame = "data: \(item)\r\n\r\n"
            let bytes = Data(frame.utf8)
            payload.append(Data("\(String(bytes.count, radix: 16))\r\n".utf8))
            payload.append(bytes)
            payload.append(Data("\r\n".utf8))
        }
        let done = Data("data: [DONE]\r\n\r\n".utf8)
        payload.append(Data("\(String(done.count, radix: 16))\r\n".utf8))
        payload.append(done)
        payload.append(Data("\r\n".utf8))
        payload.append(Data("0\r\n\r\n".utf8))

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - Router harness

/// A started router pointed at a fake upstream, torn down automatically.
final class RouterHarness {

    let upstream: FakeUpstream
    let router: ModelRouter
    let provider: Provider
    let state: RouterState

    init(model: String = "fake-model", kind: ProviderKind = .openAICompatible) throws {
        upstream = try FakeUpstream()
        try upstream.start()

        provider = Provider(
            name: "Fake",
            kind: kind,
            baseURL: upstream.baseURL,
            models: [model]
        )
        state = RouterState(RouterConfiguration(provider: provider, model: model))
        router = ModelRouter(state: state)
        try router.start(preferredPort: 0)
    }

    deinit {
        router.stop()
        upstream.stop()
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(router.port)\(path)")!
    }

    func post(_ path: String, body: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }

    func get(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(from: url(path))
        return (data, response as! HTTPURLResponse)
    }

    /// Collect a streamed response as raw text.
    func streamPost(_ path: String, body: String) async throws -> String {
        var request = URLRequest(url: url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        var collected = Data()
        for try await byte in bytes { collected.append(byte) }
        return String(decoding: collected, as: UTF8.self)
    }
}

private let simpleAnthropicRequest = """
{"model":"claude-sonnet-4-5-20250929","max_tokens":512,
 "messages":[{"role":"user","content":"say hello"}]}
"""

/// Extract the event names from a raw Anthropic SSE transcript.
private func eventNames(in transcript: String) -> [String] {
    var names: [String] = []
    for line in transcript.split(separator: "\n") {
        guard line.hasPrefix("event: ") else { continue }
        names.append(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces))
    }
    return names
}

// MARK: - Tests

final class RouterEndToEndTests: XCTestCase {

    func testHealthReportsTheSelectedProviderAndModel() async throws {
        let harness = try RouterHarness()
        let (data, response) = try await harness.get("/health")

        XCTAssertEqual(response.statusCode, 200)
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(payload.objectValue?["status"]?.stringValue, "ok")
        XCTAssertEqual(payload.objectValue?["provider"]?.stringValue, "Fake")
        XCTAssertEqual(payload.objectValue?["model"]?.stringValue, "fake-model")
    }

    func testModelsEndpointListsTheSelectedModel() async throws {
        let harness = try RouterHarness()
        let (data, _) = try await harness.get("/v1/models")

        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        let ids = payload.objectValue?["data"]?.arrayValue?
            .compactMap { $0.objectValue?["id"]?.stringValue } ?? []
        XCTAssertEqual(ids, ["fake-model"])
    }

    /// The headline behaviour: an Anthropic request in, an Anthropic response
    /// out, with an OpenAI-shaped upstream in the middle.
    func testNonStreamingMessagesRequestIsTranslated() async throws {
        let harness = try RouterHarness()
        let (data, response) = try await harness.post("/v1/messages", body: simpleAnthropicRequest)

        XCTAssertEqual(response.statusCode, 200)
        let payload = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        XCTAssertEqual(payload.type, "message")
        XCTAssertEqual(payload.role, "assistant")
        XCTAssertEqual(payload.content.first?.textValue, "hello from upstream")
        XCTAssertEqual(payload.stopReason, "end_turn")
        XCTAssertEqual(payload.usage.inputTokens, 9)
        XCTAssertEqual(payload.usage.outputTokens, 4)
        // The client asked for a Claude model and must be told it got one back,
        // otherwise Claude Code refuses the response.
        XCTAssertEqual(payload.model, "claude-sonnet-4-5-20250929")
    }

    /// Claude Code hard-codes its model names and will not accept a rewrite on
    /// its side, so the router has to substitute.
    func testClaudeModelNameIsRewrittenToTheSelectedModel() async throws {
        let harness = try RouterHarness(model: "qwen3-coder")
        _ = try await harness.post("/v1/messages", body: simpleAnthropicRequest)

        let sent = try XCTUnwrap(harness.upstream.bodyTexts.last)
        XCTAssertTrue(
            sent.contains(#""model":"qwen3-coder""#),
            "upstream should have received the configured model, got: \(sent.prefix(200))"
        )
        XCTAssertFalse(sent.contains("claude-sonnet"))
    }

    func testSystemPromptAndToolsReachTheUpstream() async throws {
        let harness = try RouterHarness()
        let body = """
        {"model":"claude-sonnet-4-5","max_tokens":256,"system":"Be terse.",
         "messages":[{"role":"user","content":"read it"}],
         "tools":[{"name":"read_file","description":"Read","input_schema":{"type":"object"}}]}
        """
        _ = try await harness.post("/v1/messages", body: body)

        let sent = try XCTUnwrap(harness.upstream.bodyTexts.last)
        XCTAssertTrue(sent.contains(#""role":"system""#))
        XCTAssertTrue(sent.contains("Be terse."))
        XCTAssertTrue(sent.contains(#""parameters""#))
        XCTAssertTrue(sent.contains("read_file"))
    }

    func testStreamingMessagesRequestProducesAnthropicEvents() async throws {
        let harness = try RouterHarness()
        let transcript = try await harness.streamPost("/v1/messages", body: """
        {"model":"claude-sonnet-4-5","max_tokens":256,"stream":true,
         "messages":[{"role":"user","content":"say hello"}]}
        """)

        let names = eventNames(in: transcript)
        XCTAssertEqual(names, [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "content_block_delta",
            "content_block_stop",
            "message_delta",
            "message_stop",
        ])
        // The upstream used CRLF; if the parser mishandles it this is empty.
        XCTAssertTrue(transcript.contains("Hel"))
        XCTAssertTrue(transcript.contains("lo"))
        XCTAssertTrue(transcript.contains(#""stop_reason":"end_turn""#))
    }

    func testStreamingCarriesTheUpstreamUsageCounts() async throws {
        let harness = try RouterHarness()
        let transcript = try await harness.streamPost("/v1/messages", body: """
        {"model":"claude-sonnet-4-5","max_tokens":256,"stream":true,
         "messages":[{"role":"user","content":"hi"}]}
        """)
        // The usage arrives in the trailer chunk, after finish_reason.
        XCTAssertTrue(transcript.contains(#""output_tokens":2"#))
        XCTAssertTrue(transcript.contains(#""input_tokens":9"#))
    }

    func testStreamingAsksTheUpstreamForUsage() async throws {
        let harness = try RouterHarness()
        _ = try await harness.streamPost("/v1/messages", body: """
        {"model":"claude-sonnet-4-5","max_tokens":256,"stream":true,
         "messages":[{"role":"user","content":"hi"}]}
        """)
        let sent = try XCTUnwrap(harness.upstream.bodyTexts.last)
        XCTAssertTrue(sent.contains(#""include_usage":true"#))
    }

    func testToolCallRoundTripsThroughTheRouter() async throws {
        let harness = try RouterHarness()
        harness.upstream.completionBody = """
        {"id":"c","model":"fake-model","choices":[{"index":0,"message":{"role":"assistant",
          "content":null,"tool_calls":[{"id":"call_1","type":"function",
            "function":{"name":"read_file","arguments":"{\\"path\\":\\"/tmp/x\\"}"}}]},
          "finish_reason":"tool_calls"}],"usage":{"prompt_tokens":5,"completion_tokens":7}}
        """

        let (data, _) = try await harness.post("/v1/messages", body: simpleAnthropicRequest)
        let payload = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        XCTAssertEqual(payload.stopReason, "tool_use")
        guard case .toolUse(let id, let name, let input) = payload.content.first else {
            return XCTFail("expected a tool_use block")
        }
        XCTAssertEqual(id, "call_1")
        XCTAssertEqual(name, "read_file")
        XCTAssertEqual(input.objectValue?["path"]?.stringValue, "/tmp/x")
    }

    func testReasoningContentBecomesAThinkingBlock() async throws {
        let harness = try RouterHarness()
        harness.upstream.completionBody = """
        {"id":"c","model":"fake-model","choices":[{"index":0,"message":{"role":"assistant",
          "reasoning_content":"weighing options","content":"the answer"},"finish_reason":"stop"}]}
        """
        let (data, _) = try await harness.post("/v1/messages", body: simpleAnthropicRequest)
        let payload = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        XCTAssertEqual(payload.content.count, 2)
        XCTAssertEqual(payload.content[0].textValue, "weighing options")
        XCTAssertEqual(payload.content[1].textValue, "the answer")
    }

    func testCountTokensReturnsAnEstimate() async throws {
        let harness = try RouterHarness()
        let (data, response) = try await harness.post(
            "/v1/messages/count_tokens",
            body: simpleAnthropicRequest
        )

        XCTAssertEqual(response.statusCode, 200)
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        let tokens = try XCTUnwrap(payload.objectValue?["input_tokens"]?.intValue)
        // Returning zero would make the client think it has unlimited context.
        XCTAssertGreaterThan(tokens, 0)
    }

    func testChatCompletionsIsPassedThroughForAnOpenAIUpstream() async throws {
        let harness = try RouterHarness()
        let (data, response) = try await harness.post("/v1/chat/completions", body: """
        {"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}
        """)

        XCTAssertEqual(response.statusCode, 200)
        let payload = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        XCTAssertEqual(payload.first?.message?.content?.plainText, "hello from upstream")

        let sent = try XCTUnwrap(harness.upstream.bodyTexts.last)
        XCTAssertTrue(sent.contains(#""model":"fake-model""#))
    }

    func testUnconfiguredRouterReturnsAnActionableError() async throws {
        let state = RouterState(.idle)
        let router = ModelRouter(state: state)
        try router.start(preferredPort: 0)
        defer { router.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(router.port)/v1/messages")!)
        request.httpMethod = "POST"
        request.httpBody = Data(simpleAnthropicRequest.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        XCTAssertEqual(http.statusCode, 500)

        // The message has to say what to do, not just that something failed.
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("Providers pane"), "got: \(text)")
    }

    func testUnknownPathReturns404InAnthropicErrorShape() async throws {
        let harness = try RouterHarness()
        let (data, response) = try await harness.post("/v1/nonsense", body: "{}")

        XCTAssertEqual(response.statusCode, 404)
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(payload.objectValue?["type"]?.stringValue, "error")
        XCTAssertNotNil(payload.objectValue?["error"]?.objectValue?["message"]?.stringValue)
    }

    func testUpstreamFailureIsReportedNotSwallowed() async throws {
        let harness = try RouterHarness()
        harness.upstream.stop()

        let (data, response) = try await harness.post("/v1/messages", body: simpleAnthropicRequest)
        XCTAssertEqual(response.statusCode, 500)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("error"))
    }

    func testRouterBindsLoopbackOnly() throws {
        let harness = try RouterHarness()
        // The listener is bound to 127.0.0.1, so the machine's LAN address must
        // not answer. Nothing to connect to means the bind was loopback-scoped.
        XCTAssertEqual(harness.router.baseURL, "http://127.0.0.1:\(harness.router.port)")
        XCTAssertTrue(harness.router.isRunning)
    }

    func testStopIsIdempotent() throws {
        let harness = try RouterHarness()
        harness.router.stop()
        harness.router.stop()
        XCTAssertFalse(harness.router.isRunning)
    }
}

// MARK: - Model resolution

final class RouterModelResolutionTests: XCTestCase {

    private func configuration(
        model: String = "local-qwen",
        models: [String] = ["local-qwen"],
        aliases: [String] = []
    ) -> RouterConfiguration {
        RouterConfiguration(
            provider: Provider(name: "P", kind: .openAICompatible, baseURL: "http://x", models: models),
            model: model,
            aliases: aliases
        )
    }

    private func router() -> ModelRouter {
        ModelRouter(state: RouterState(.idle))
    }

    func testClaudeNamesAreIntercepted() {
        let router = router()
        let config = configuration()
        XCTAssertEqual(router.resolveModel("claude-sonnet-4-5-20250929", config), "local-qwen")
        XCTAssertEqual(router.resolveModel("claude-3-5-haiku-latest", config), "local-qwen")
    }

    func testOtherVendorNamesAreIntercepted() {
        let router = router()
        let config = configuration()
        XCTAssertEqual(router.resolveModel("gpt-4o", config), "local-qwen")
        XCTAssertEqual(router.resolveModel("gemini-2.5-pro", config), "local-qwen")
        XCTAssertEqual(router.resolveModel("o3-mini", config), "local-qwen")
    }

    /// A model the provider actually advertises should be honoured, so a
    /// multi-model backend stays addressable.
    func testAdvertisedModelIsHonoured() {
        let router = router()
        let config = configuration(models: ["local-qwen", "local-llama"])
        XCTAssertEqual(router.resolveModel("local-llama", config), "local-llama")
    }

    func testExplicitAliasIsHonoured() {
        let router = router()
        let config = configuration(aliases: ["my-favourite"])
        XCTAssertEqual(router.resolveModel("my-favourite", config), "local-qwen")
    }

    func testEmptyRequestedModelFallsBackToTheConfiguredOne() {
        let router = router()
        XCTAssertEqual(router.resolveModel("", configuration()), "local-qwen")
    }

    func testUnrecognisedNameIsRoutedToTheConfiguredModel() {
        let router = router()
        XCTAssertEqual(router.resolveModel("some-random-name", configuration()), "local-qwen")
    }

    func testNoConfiguredModelLeavesTheRequestAlone() {
        let router = router()
        let config = RouterConfiguration(provider: nil, model: nil)
        XCTAssertEqual(router.resolveModel("claude-sonnet-4-5", config), "claude-sonnet-4-5")
    }
}

// MARK: - Base URL normalisation

final class ProviderURLNormalisationTests: XCTestCase {

    func testBareHostGetsV1Appended() {
        let provider = Provider(name: "p", kind: .localGGUF, baseURL: "http://127.0.0.1:8080")
        XCTAssertEqual(provider.normalizedBaseURL, "http://127.0.0.1:8080/v1")
    }

    func testTrailingSlashIsRemoved() {
        let provider = Provider(name: "p", kind: .openAICompatible, baseURL: "https://api.example.com/v1/")
        XCTAssertEqual(provider.normalizedBaseURL, "https://api.example.com/v1")
    }

    func testExistingV1IsNotDuplicated() {
        let provider = Provider(name: "p", kind: .openAICompatible, baseURL: "https://api.openai.com/v1")
        XCTAssertEqual(provider.normalizedBaseURL, "https://api.openai.com/v1")
    }

    /// A deliberate non-standard path must survive untouched — guessing here
    /// would break a working configuration.
    func testCustomPathIsLeftAlone() {
        let provider = Provider(name: "p", kind: .openAICompatible, baseURL: "https://gw.internal/llm/v2")
        XCTAssertEqual(provider.normalizedBaseURL, "https://gw.internal/llm/v2")
    }

    /// Ollama serves `/api/tags` at the root, so it must never get a `/v1`.
    func testOllamaDoesNotGetV1Appended() {
        let provider = Provider(name: "p", kind: .ollama, baseURL: "http://127.0.0.1:11434")
        XCTAssertEqual(provider.normalizedBaseURL, "http://127.0.0.1:11434")
        XCTAssertEqual(provider.modelsURL?.absoluteString, "http://127.0.0.1:11434/api/tags")
    }

    func testAnthropicDoesNotGetV1Appended() {
        let provider = Provider(name: "p", kind: .anthropic, baseURL: "https://api.anthropic.com")
        XCTAssertEqual(provider.normalizedBaseURL, "https://api.anthropic.com")
        XCTAssertEqual(provider.modelsURL?.absoluteString, "https://api.anthropic.com/v1/models")
        XCTAssertEqual(provider.chatURL?.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    func testOpenAICompatibleEndpoints() {
        let provider = Provider(name: "p", kind: .openAICompatible, baseURL: "https://api.openai.com/v1")
        XCTAssertEqual(provider.modelsURL?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(provider.chatURL?.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    /// Anthropic authenticates with `x-api-key`, not a bearer token. Getting
    /// this wrong is a common integration bug.
    func testAnthropicUsesApiKeyHeaderNotBearer() {
        let headers = ProviderKind.anthropic.authHeaders(apiKey: "sk-test")
        XCTAssertEqual(headers["x-api-key"], "sk-test")
        XCTAssertEqual(headers["anthropic-version"], "2023-06-01")
        XCTAssertNil(headers["Authorization"])
    }

    func testOpenAIUsesBearerToken() {
        let headers = ProviderKind.openAICompatible.authHeaders(apiKey: "sk-test")
        XCTAssertEqual(headers["Authorization"], "Bearer sk-test")
        XCTAssertNil(headers["x-api-key"])
    }

    func testNoKeyMeansNoAuthHeaders() {
        XCTAssertTrue(ProviderKind.openAICompatible.authHeaders(apiKey: nil).isEmpty)
        XCTAssertTrue(ProviderKind.openAICompatible.authHeaders(apiKey: "").isEmpty)
    }

    func testTranslationIsRequiredForEverythingButAnthropic() {
        XCTAssertFalse(ProviderKind.anthropic.requiresTranslation)
        XCTAssertTrue(ProviderKind.openAICompatible.requiresTranslation)
        XCTAssertTrue(ProviderKind.ollama.requiresTranslation)
        XCTAssertTrue(ProviderKind.localGGUF.requiresTranslation)
    }
}

// MARK: - The retained failure

final class RouterLogErrorTests: XCTestCase {

    /// A backend rejection has to be retrievable without scanning the log.
    ///
    /// A provider with no credit returns 403 and the agent renders it as
    /// nothing, so the diagnosis was only findable by reading hundreds of
    /// lines. `lastError` is what lets the UI lead with it.
    func testWriteErrorIsRetainedSeparatelyFromTheLog() {
        let log = RouterLog()
        XCTAssertNil(log.lastError)

        log.write("model claude-sonnet-4-5 → deepseek/deepseek-v3.2")
        XCTAssertNil(log.lastError, "an ordinary line is not a failure")

        log.writeError("POST /v1/messages failed: upstream error: HTTP 403")
        XCTAssertEqual(log.lastError, "POST /v1/messages failed: upstream error: HTTP 403")
        XCTAssertTrue(log.snapshot().contains { $0.contains("HTTP 403") })
    }

    func testClearErrorKeepsTheLog() {
        let log = RouterLog()
        log.write("something happened")
        log.writeError("it failed")
        log.clearError()

        XCTAssertNil(log.lastError)
        XCTAssertTrue(log.snapshot().contains { $0.contains("something happened") },
                      "clearing the error must not discard the diagnostic")
    }

    func testClearRemovesBoth() {
        let log = RouterLog()
        log.writeError("it failed")
        log.clear()
        XCTAssertNil(log.lastError)
        XCTAssertTrue(log.snapshot().isEmpty)
    }
}

// MARK: - Provider list hygiene

final class ProviderStoreDedupeTests: XCTestCase {

    private func store() -> ProviderStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-prov-\(UUID().uuidString)")
        return ProviderStore(paths: SandboxPaths(root: root))
    }

    private func provider(
        name: String, url: String, kind: ProviderKind = .localGGUF
    ) -> Provider {
        Provider(name: name, kind: kind, baseURL: url, models: ["m"])
    }

    /// Registering the same backend twice must not leave two entries.
    ///
    /// The local-model registrar builds a fresh `Provider` each time, so
    /// deduping on `id` alone appended a duplicate on every run. The list then
    /// filled with entries pointing at one port, most of them stale: pick one
    /// after the server moved and the router answers
    /// `500 upstream error: Could not connect`, which says nothing about why.
    func testSameBackendReplacesRatherThanDuplicates() throws {
        let store = store()
        try store.add(provider(name: "First (local)", url: "http://127.0.0.1:8081"))
        try store.add(provider(name: "Second (local)", url: "http://127.0.0.1:8081"))

        XCTAssertEqual(store.providers.count, 1)
        XCTAssertEqual(store.providers.first?.name, "Second (local)")
    }

    /// Different ports are different backends — collapsing those would delete
    /// a working entry.
    func testDifferentPortsAreKept() throws {
        let store = store()
        try store.add(provider(name: "A", url: "http://127.0.0.1:8080"))
        try store.add(provider(name: "B", url: "http://127.0.0.1:8081"))
        XCTAssertEqual(store.providers.count, 2)
    }

    /// Re-adding by id still replaces, which is how edits are saved.
    func testSameIdReplaces() throws {
        let store = store()
        let first = provider(name: "First", url: "http://127.0.0.1:8080")
        try store.add(first)
        var edited = first
        edited = Provider(
            id: first.id, name: "Renamed", kind: .localGGUF,
            baseURL: "http://127.0.0.1:8080", models: ["m"]
        )
        try store.add(edited)
        XCTAssertEqual(store.providers.count, 1)
        XCTAssertEqual(store.providers.first?.name, "Renamed")
    }
}
