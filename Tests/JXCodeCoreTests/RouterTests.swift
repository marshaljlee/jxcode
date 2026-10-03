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

    /// JSON returned for a non-streaming **Anthropic** messages request.
    ///
    /// The router's Anthropic-upstream path posts to `/v1/messages` and decodes
    /// an `AnthropicResponse`, so the fake has to answer in Anthropic's shape.
    /// The path is the one thing that distinguishes the two, and it is the same
    /// distinction the router itself keys off (`ProviderKind.chatPath`).
    var anthropicCompletionBody: String = """
    {"id":"msg_test","type":"message","role":"assistant","model":"fake-model",
     "content":[{"type":"text","text":"hello from upstream"}],
     "stop_reason":"end_turn","usage":{"input_tokens":9,"output_tokens":4}}
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

    /// Complete SSE frames, emitted verbatim.
    ///
    /// `streamPayloads` wraps each entry as an OpenAI `data:` line, which cannot
    /// express an Anthropic event — those need an `event:` line as well. Native
    /// Anthropic passthrough is a real route, so the fake has to be able to
    /// speak it.
    var rawStreamFrames: [String]?

    /// When set, the streamed body is written as these raw pieces, one HTTP
    /// chunk each, with `dripDelay` between them.
    ///
    /// `rawStreamFrames` and `streamPayloads` both hand the router whole frames,
    /// which is the easy case. A real server is free to cut anywhere — inside a
    /// JSON string, inside a multi-byte scalar, between a frame's `data:` line
    /// and the blank line that ends it — and every one of those cuts is a
    /// reassembly trap the whole-frame fakes cannot reach.
    var streamPieces: [Data]?

    /// Seconds to wait between `streamPieces`. Zero writes them back to back.
    ///
    /// A non-zero delay is what makes a *slow* stream distinguishable from a
    /// silent one: pieces arriving slower than the router's keep-alive interval
    /// must still count as activity, because bytes are arriving. That is the
    /// difference between a ping that means "still waiting" and one injected
    /// into the middle of a frame.
    var dripDelay: TimeInterval = 0

    /// The status this fake answers `/v1/messages` with.
    ///
    /// 200 by default, so every existing test keeps the behaviour it was written
    /// against. Set to 404 or 405 to model a llama-server build that predates the
    /// Anthropic route, which is the case the router's fallback exists for; set to
    /// 400 to model a backend that understood the request and refused it, which
    /// the router must *not* answer with a second request in another shape.
    var messagesRouteStatus: Int = 200

    /// The status this fake answers `/v1/messages/count_tokens` with.
    ///
    /// 200 by default, so a test that is about something else is unaffected.
    /// Set to 404 to model a backend that serves the Anthropic wire but not the
    /// counting endpoint beside it — the case the router's negative memory
    /// exists for, and the only way to observe that it remembers.
    var countTokensRouteStatus: Int = 200

    /// The count this fake reports when its counting route answers.
    ///
    /// A number no estimate could plausibly produce for the request bodies the
    /// tests use, so "the answer came from the backend" is distinguishable from
    /// "the answer came from `TokenEstimator`" by the value alone.
    var countTokensValue: Int = 4242

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

        // The counting endpoint sits under the messages path, so it is matched
        // before it. `/v1/messages/count_tokens` does not itself end in
        // `/v1/messages`, but the more specific route is the one that should
        // win regardless of how the paths are later spelled.
        if request.path.hasSuffix("/count_tokens") {
            guard countTokensRouteStatus == 200 else {
                send(
                    connection,
                    status: countTokensRouteStatus,
                    json: #"{"error":{"type":"not_found_error","message":"File Not Found"}}"#
                )
                return
            }
            send(connection, json: #"{"input_tokens":\#(countTokensValue)}"#)
            return
        }

        // A native Anthropic upstream answers in Anthropic's shape. Keyed off the
        // path because that is exactly what the router keys off.
        if request.path.hasSuffix("/v1/messages") {
            guard messagesRouteStatus == 200 else {
                send(
                    connection,
                    status: messagesRouteStatus,
                    json: #"{"error":{"type":"not_found_error","message":"unknown endpoint"}}"#
                )
                return
            }
            if alwaysStream || rawStreamFrames != nil {
                sendStream(connection)
            } else {
                send(connection, json: anthropicCompletionBody)
            }
            return
        }

        let wantsStream = alwaysStream || request.bodyText.contains(#""stream":true"#)
        if wantsStream {
            sendStream(connection)
        } else {
            send(connection, json: completionBody)
        }
    }

    /// A reason phrase for the statuses the fakes need to be able to produce.
    ///
    /// The router reads the code, not this, but a fake that answers `404 OK`
    /// is a fake that lies about the wire it is imitating.
    private func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default:  return "Status \(status)"
        }
    }

    private func send(_ connection: NWConnection, status: Int = 200, json: String) {
        let body = Data(json.utf8)
        var head = "HTTP/1.1 \(status) \(reasonPhrase(status))\r\n"
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

        // `[DONE]` is OpenAI's terminator. An Anthropic stream ends with
        // `message_stop`, so raw frames are emitted exactly as given and bring
        // their own ending.
        let frames: [String]
        if let raw = rawStreamFrames {
            frames = raw
        } else {
            frames = streamPayloads.map { "data: \($0)\r\n\r\n" } + ["data: [DONE]\r\n\r\n"]
        }

        // `streamPieces` bypasses the frame assembly entirely: the caller has
        // decided where the chunk boundaries go, so each piece becomes one HTTP
        // chunk. That is the only way to put a boundary *inside* a frame, which
        // is where the reassembly traps live.
        if let pieces = streamPieces {
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            writePieces(pieces, to: connection)
            return
        }

        var payload = Data(head.utf8)
        for frame in frames {
            let bytes = Data(frame.utf8)
            payload.append(Data("\(String(bytes.count, radix: 16))\r\n".utf8))
            payload.append(bytes)
            payload.append(Data("\r\n".utf8))
        }
        payload.append(Data("0\r\n\r\n".utf8))

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Write each piece as its own HTTP chunk, optionally spaced out in time.
    ///
    /// Always hops back onto the connection's queue between pieces rather than
    /// recursing on the send completion: the completion handler runs on that
    /// queue, and a long run of pieces would otherwise be a deep call stack
    /// rather than a sequence of writes.
    private func writePieces(_ pieces: [Data], to connection: NWConnection) {
        var remaining = pieces
        func next() {
            guard let piece = remaining.first else {
                connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            remaining.removeFirst()
            var frame = Data("\(String(piece.count, radix: 16))\r\n".utf8)
            frame.append(piece)
            frame.append(Data("\r\n".utf8))
            connection.send(content: frame, completion: .contentProcessed { _ in
                self.queue.async {
                    if self.dripDelay > 0 {
                        self.queue.asyncAfter(deadline: .now() + self.dripDelay) { next() }
                    } else {
                        next()
                    }
                }
            })
        }
        next()
    }
}

// MARK: - Router harness

/// A started router pointed at a fake upstream, torn down automatically.
final class RouterHarness {

    let upstream: FakeUpstream
    let router: ModelRouter
    let provider: Provider
    let state: RouterState

    /// `keepAliveInterval` is a parameter because the production value is 15
    /// seconds and the behaviour it guards is about *ordering* — a ping must
    /// never land inside a frame or after `message_stop`. A test that waited 15
    /// seconds to observe that would be a test nobody runs.
    init(
        model: String = "fake-model",
        kind: ProviderKind = .openAICompatible,
        keepAliveInterval: TimeInterval = ModelRouter.defaultKeepAliveInterval
    ) throws {
        upstream = try FakeUpstream()
        try upstream.start()

        provider = Provider(
            name: "Fake",
            kind: kind,
            baseURL: upstream.baseURL,
            models: [model]
        )
        state = RouterState(RouterConfiguration(provider: provider, model: model))
        router = ModelRouter(state: state, keepAliveInterval: keepAliveInterval)
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

/// Extract the `data:` payloads from a raw OpenAI SSE transcript.
///
/// The OpenAI envelope has no `event:` line, so the payload is the only thing
/// there is to read.
private func dataPayloads(in transcript: String) -> [String] {
    var payloads: [String] = []
    for line in transcript.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { continue }
        payloads.append(String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces))
    }
    return payloads
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

    /// A flush driven by a byte *count* rather than by a newline can cut a
    /// multi-byte scalar in half, and `String(decoding:as: UTF8.self)` turns
    /// each half into U+FFFD. `translateOpenAIStream` flushes at 1024 bytes, so
    /// the payload is built to place a four-byte emoji across that offset on
    /// the wire: three of its bytes land in the flushed chunk, one in the next.
    func testAMultiByteScalarStraddlingTheFlushBoundarySurvives() async throws {
        let harness = try RouterHarness()

        // `data: ` plus the JSON up to the content value — exactly what the
        // fake puts on the wire before the content begins.
        let wirePrefix = #"data: {"id":"c","choices":[{"index":0,"delta":{"content":""#
        let emojiStart = 1021
        let padding = String(repeating: "a", count: emojiStart - wirePrefix.utf8.count)
        let content = padding + "🙂" + " done"

        harness.upstream.streamPayloads = [
            #"{"id":"c","choices":[{"index":0,"delta":{"content":"\#(content)"}}]}"#,
            #"{"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
        ]

        let transcript = try await harness.streamPost("/v1/messages", body: """
        {"model":"claude-sonnet-4-5","max_tokens":256,"stream":true,
         "messages":[{"role":"user","content":"say hello"}]}
        """)

        XCTAssertFalse(transcript.contains("\u{FFFD}"), "a scalar was cut in half")
        XCTAssertTrue(transcript.contains("🙂"), "the character did not arrive")
    }

    /// The same hazard on the raw passthrough route (`/v1/chat/completions`
    /// against an OpenAI-compatible upstream), which flushes at 8192 bytes.
    func testAMultiByteScalarStraddlingTheRawPassthroughBoundarySurvives() async throws {
        let harness = try RouterHarness()

        let wirePrefix = #"data: {"id":"c","choices":[{"index":0,"delta":{"content":""#
        let emojiStart = 8189          // flush fires at 8192, three bytes in
        let padding = String(repeating: "a", count: emojiStart - wirePrefix.utf8.count)
        let content = padding + "\u{1F642}" + " done"

        harness.upstream.streamPayloads = [
            #"{"id":"c","choices":[{"index":0,"delta":{"content":"\#(content)"}}]}"#,
        ]

        let transcript = try await harness.streamPost("/v1/chat/completions", body: """
        {"model":"fake-model","max_tokens":256,"stream":true,
         "messages":[{"role":"user","content":"say hello"}]}
        """)

        XCTAssertFalse(transcript.contains("\u{FFFD}"), "a scalar was cut in half")
        XCTAssertTrue(transcript.contains("\u{1F642}"), "the character did not arrive")
    }

    /// And on Anthropic passthrough — a native Anthropic upstream, where the
    /// frames carry an `event:` line and the volume threshold is also 8192.
    func testAMultiByteScalarStraddlingTheAnthropicPassthroughBoundarySurvives() async throws {
        let harness = try RouterHarness(kind: .anthropic)

        let wirePrefix = "event: content_block_delta\n"
            + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":""#
        let emojiStart = 8189
        let padding = String(repeating: "a", count: emojiStart - wirePrefix.utf8.count)
        let content = padding + "\u{1F642}" + " done"

        harness.upstream.rawStreamFrames = [
            wirePrefix + content + "\"}}\n\n",
        ]

        let transcript = try await harness.streamPost("/v1/messages", body: """
        {"model":"claude-sonnet-4-5","max_tokens":256,"stream":true,
         "messages":[{"role":"user","content":"say hello"}]}
        """)

        XCTAssertFalse(transcript.contains("\u{FFFD}"), "a scalar was cut in half")
        XCTAssertTrue(transcript.contains("\u{1F642}"), "the character did not arrive")
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

    /// A block the translation cannot carry is named in the log the pane shows.
    ///
    /// The notes were built by every call site and read by none: a request whose
    /// server-tool block was dropped reported nothing at all, so "the agent
    /// never sees the search result" had no explanation anywhere.
    func testABlockTheTranslationCannotCarryIsReported() async throws {
        let harness = try RouterHarness()
        let body = """
        {"model":"claude-sonnet-4-5","max_tokens":256,"messages":[
          {"role":"user","content":"search"},
          {"role":"assistant","content":[
            {"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{"q":"x"}},
            {"type":"text","text":"done"}]},
          {"role":"user","content":"thanks"}]}
        """
        _ = try await harness.post("/v1/messages", body: body)

        let notes = harness.router.log.lastTranslation
        XCTAssertEqual(notes.count, 1, "expected one drop note, got: \(notes)")
        let note = try XCTUnwrap(notes.first)
        XCTAssertTrue(note.contains("server_tool_use"), note)
        XCTAssertTrue(
            harness.router.log.snapshot().contains { $0.contains("translation (anthropic→openai)") },
            "the note has to be in the log the pane shows, not only in memory"
        )
    }

    /// A request that carries everything clears the previous request's notes.
    ///
    /// The card shows the *last* translation, so leaving the old list up would
    /// describe a request that has since been superseded — and the user would go
    /// on chasing a loss that is no longer happening.
    func testACleanRequestClearsThePreviousNotes() async throws {
        let harness = try RouterHarness()
        _ = try await harness.post("/v1/messages", body: """
        {"model":"claude-sonnet-4-5","max_tokens":256,"messages":[
          {"role":"user","content":"search"},
          {"role":"assistant","content":[
            {"type":"server_tool_use","id":"s","name":"web_search","input":{}},
            {"type":"text","text":"x"}]},
          {"role":"user","content":"hi"}]}
        """)
        XCTAssertFalse(
            harness.router.log.lastTranslation.isEmpty,
            "the first request was supposed to leave a note"
        )

        _ = try await harness.post("/v1/messages", body: simpleAnthropicRequest)
        XCTAssertTrue(
            harness.router.log.lastTranslation.isEmpty,
            "the superseded request's losses were still on show: "
            + "\(harness.router.log.lastTranslation)"
        )
    }

    /// A failure the backend reports *inside* the stream reaches the client as
    /// an Anthropic `error` event, not as a successful empty answer.
    ///
    /// An OpenAI-compatible server signals a mid-stream failure with a chunk
    /// carrying `error` and no `choices`. That chunk cannot decode as a
    /// response, so it was skipped by the same `try?` that tolerates a bad token
    /// delta: the stream then ended normally and `message_stop` told the client
    /// the (empty) answer was complete. Verified here as a *sequence* claim —
    /// `error` present, `message_stop` absent — because either one alone passes
    /// on a transcript that has both.
    func testAnUpstreamErrorInsideTheStreamBecomesAnAnthropicErrorEvent() async throws {
        let harness = try RouterHarness()
        harness.upstream.streamPayloads = [
            #"{"id":"c","choices":[{"index":0,"delta":{"role":"assistant","content":"par"}}]}"#,
            #"{"error":{"type":"server_error","message":"CUDA out of memory"}}"#,
            #"{"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
        ]

        let transcript = try await harness.streamPost("/v1/messages", body: """
        {"model":"claude-sonnet-4-5","max_tokens":256,"stream":true,
         "messages":[{"role":"user","content":"say hello"}]}
        """)

        let names = eventNames(in: transcript)
        XCTAssertTrue(names.contains("error"), "the failure was not reported:\n\(transcript)")
        XCTAssertFalse(
            names.contains("message_stop"),
            "a message_stop after an error tells the client the answer is complete:\n\(transcript)"
        )
        XCTAssertTrue(transcript.contains("CUDA out of memory"), transcript)
        XCTAssertEqual(
            harness.router.log.lastError?.contains("CUDA out of memory"), true,
            "the retained error is what the pane leads with"
        )
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

    // MARK: An OpenAI caller against an Anthropic upstream
    //
    // The reverse of the usual direction, and the one that was broken: the
    // caller asked for `stream: true`, the router passed that through to
    // Anthropic, and then tried to decode an event stream as a single JSON
    // message. Every such request 500'd — after the upstream had been paid for
    // the turn — which is why the first assertion here is simply "this is SSE at
    // all".

    func testStreamingChatCompletionsAgainstAnAnthropicUpstreamIsFramedAsOpenAIChunks() async throws {
        let harness = try RouterHarness(kind: .anthropic)
        let transcript = try await harness.streamPost("/v1/chat/completions", body: """
        {"model":"fake-model","stream":true,"messages":[{"role":"user","content":"say hello"}]}
        """)

        XCTAssertTrue(transcript.contains("data: "), "expected SSE, got: \(transcript)")

        let payloads = dataPayloads(in: transcript)
        XCTAssertEqual(payloads.last, "[DONE]", "the stream has to terminate or the client hangs")

        // `[DONE]` is not JSON, so it drops out here: three chunks and a sentinel.
        let chunks = payloads.dropLast().compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        XCTAssertEqual(chunks.count, 3, "content, finish_reason, usage")

        let first = try XCTUnwrap(chunks.first)
        XCTAssertEqual(first["object"] as? String, "chat.completion.chunk")
        let delta = try XCTUnwrap(
            (first["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any]
        )
        XCTAssertEqual(delta["role"] as? String, "assistant")
        XCTAssertEqual(delta["content"] as? String, "hello from upstream")

        let finish = try XCTUnwrap(
            (chunks[1]["choices"] as? [[String: Any]])?.first?["finish_reason"] as? String
        )
        XCTAssertEqual(finish, "stop")

        let trailer = try XCTUnwrap(chunks[2]["choices"] as? [Any])
        XCTAssertTrue(trailer.isEmpty, "the usage chunk carries no choices")
        let usage = try XCTUnwrap(chunks[2]["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 9)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 4)
    }

    /// The outbound request must not ask for a stream. That single field is what
    /// broke this path, so it is asserted on the wire rather than inferred from
    /// the reply.
    func testStreamingAgainstAnAnthropicUpstreamAsksForACompleteAnswer() async throws {
        let harness = try RouterHarness(kind: .anthropic)
        _ = try await harness.streamPost("/v1/chat/completions", body: """
        {"model":"fake-model","stream":true,"messages":[{"role":"user","content":"hi"}]}
        """)

        let sent = try XCTUnwrap(harness.upstream.bodyTexts.last)
        XCTAssertTrue(sent.contains(#""stream":false"#), "upstream body was: \(sent)")
        // And it has to be an Anthropic request, not an OpenAI one.
        XCTAssertTrue(sent.contains(#""max_tokens""#), sent)
    }

    /// The non-streaming half of the same path, which had no test at all.
    func testChatCompletionsAgainstAnAnthropicUpstreamIsTranslated() async throws {
        let harness = try RouterHarness(kind: .anthropic)
        let (data, response) = try await harness.post("/v1/chat/completions", body: """
        {"model":"fake-model","messages":[{"role":"user","content":"hi"}]}
        """)

        XCTAssertEqual(response.statusCode, 200)
        let payload = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        XCTAssertEqual(payload.first?.message?.content?.plainText, "hello from upstream")
        XCTAssertEqual(payload.first?.finishReason, "stop")
        XCTAssertEqual(payload.usage?.promptTokens, 9)
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

    /// The claim this used to make — that only Anthropic needs no translation —
    /// stopped being true when llama-server grew a native `/v1/messages`. What
    /// is left is the rule that actually holds: a backend is translated for
    /// exactly when it has no Anthropic route of its own.
    func testTranslationIsRequiredOnlyWhereThereIsNoAnthropicRoute() {
        XCTAssertFalse(ProviderKind.anthropic.requiresTranslation)
        XCTAssertFalse(
            ProviderKind.localGGUF.requiresTranslation,
            "llama-server serves /v1/messages itself, so translating for it is work with no purpose"
        )
        XCTAssertTrue(ProviderKind.openAICompatible.requiresTranslation)
        XCTAssertTrue(ProviderKind.ollama.requiresTranslation)

        // The invariant behind the two: the flag is derived from the path, so
        // there is no state in which a backend has a route and is still
        // described as needing a translation.
        for kind in ProviderKind.allCases {
            XCTAssertEqual(kind.requiresTranslation, kind.messagesPath == nil, "\(kind)")
        }
    }

    /// A backend that serves the Anthropic wire is not automatically one that
    /// can be fallen back *to*. The fallback posts a translated body, so it
    /// needs an OpenAI route, and Anthropic has none.
    func testOnlyTheKindsWithAnOpenAIRouteCanBeTranslatedFor() {
        XCTAssertFalse(ProviderKind.anthropic.speaksOpenAI)
        XCTAssertTrue(ProviderKind.openAICompatible.speaksOpenAI)
        XCTAssertTrue(ProviderKind.ollama.speaksOpenAI)
        XCTAssertTrue(ProviderKind.localGGUF.speaksOpenAI)
    }

    func testTheMessagesRouteIsSeparateFromTheChatRoute() {
        // The trap: for a llama-server the base URL is normalised to carry
        // `/v1`, so a messages path that repeated the prefix would resolve to
        // `/v1/v1/messages`. Anthropic refuses the automatic prefix, so its path
        // must carry its own.
        XCTAssertEqual(ProviderKind.localGGUF.messagesPath, "{base}/messages")
        XCTAssertEqual(ProviderKind.anthropic.messagesPath, "{base}/v1/messages")
        XCTAssertNil(ProviderKind.openAICompatible.messagesPath)
        XCTAssertNil(ProviderKind.ollama.messagesPath)

        let local = Provider(name: "Local", kind: .localGGUF, baseURL: "http://127.0.0.1:8080")
        XCTAssertEqual(local.messagesURL?.absoluteString, "http://127.0.0.1:8080/v1/messages")
        XCTAssertNotEqual(
            local.messagesURL,
            local.chatURL,
            "an Anthropic body posted to the chat path is the bug this guards"
        )

        let anthropic = Provider(name: "A", kind: .anthropic, baseURL: "https://api.anthropic.com")
        XCTAssertEqual(anthropic.messagesURL?.absoluteString, "https://api.anthropic.com/v1/messages")
    }

    /// The sentence `jxcode router` prints, which is where a user finds out what
    /// the router will do to their traffic.
    func testTheTranslationSummaryMatchesTheRouteTable() {
        for kind in ProviderKind.allCases {
            let summary = kind.translationSummary
            XCTAssertFalse(summary.isEmpty, "\(kind)")
            if kind.requiresTranslation {
                XCTAssertEqual(summary, "Anthropic ⇄ OpenAI", "\(kind)")
            } else {
                XCTAssertTrue(summary.hasPrefix("none"), "\(kind) — \(summary)")
            }
        }
        XCTAssertTrue(ProviderKind.localGGUF.translationSummary.contains("llama-server"))
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
