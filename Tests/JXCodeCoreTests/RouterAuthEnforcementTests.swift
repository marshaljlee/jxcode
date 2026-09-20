import XCTest
import Network
@testable import JXCodeCore

// MARK: - Paced upstream

/// An OpenAI- or Anthropic-shaped SSE server that dribbles its frames out on a
/// caller-controlled schedule.
///
/// The keep-alive exists because a real upstream can go quiet for minutes, so
/// testing it against a server that answers in one burst would prove nothing.
/// The pauses here are tens of milliseconds against an equally short ping
/// interval, which drives the same code path without a real wait.
///
/// Frames are paced on their own queue rather than the connection's: the
/// connection queue also delivers send completions, and sleeping on it would
/// stall the very I/O the test is trying to observe.
final class PacedUpstream: @unchecked Sendable {

    private let listener: NWListener
    private let connectionQueue = DispatchQueue(label: "test.paced-upstream")
    private let paceQueue = DispatchQueue(label: "test.paced-upstream.pace")

    /// Raw SSE text, one chunked frame per entry, sent verbatim.
    var frames: [String] = [
        PacedUpstream.openAIFrame(
            #"{"id":"c","choices":[{"index":0,"delta":{"role":"assistant","content":"first"}}]}"#
        ),
        PacedUpstream.openAIFrame(
            #"{"id":"c","choices":[{"index":0,"delta":{"content":"second"}}]}"#
        ),
        PacedUpstream.openAIFrame(
            #"{"id":"c","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#
        ),
        PacedUpstream.openAIFrame(
            #"{"id":"c","choices":[],"usage":{"prompt_tokens":9,"completion_tokens":2}}"#
        ),
        "data: [DONE]\n\n",
    ]

    /// Pause before the first frame. Models the longest silence of all: a local
    /// model loading a long context before it can say anything.
    var delayBeforeFirstFrame: TimeInterval = 0
    /// Pause before every frame after the first. Models a model thinking
    /// mid-answer.
    var gapBetweenFrames: TimeInterval = 0
    /// Pause after the last frame, before closing. Models an upstream that
    /// holds the connection open after it has finished the message, which is
    /// the window in which a stray ping would land after `message_stop`.
    var holdOpenAfterFrames: TimeInterval = 0

    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    var baseURL: String { "http://127.0.0.1:\(port)" }

    static func openAIFrame(_ payload: String) -> String { "data: \(payload)\n\n" }

    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: connectionQueue)

        guard ready.wait(timeout: .now() + 5) == .success else {
            throw XCTSkip("paced upstream did not start")
        }
        port = listener.port?.rawValue ?? 0
    }

    func stop() { listener.cancel() }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: connectionQueue)
        receive(connection, parser: HTTPRequestParser())
    }

    private func receive(_ connection: NWConnection, parser: HTTPRequestParser) {
        var parser = parser
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                parser.consume(data)
                if (try? parser.nextRequest()) != nil {
                    self.respond(on: connection)
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

    private func respond(on connection: NWConnection) {
        paceQueue.async { [weak self] in
            guard let self else { return }

            var head = "HTTP/1.1 200 OK\r\n"
            head += "Content-Type: text/event-stream\r\n"
            head += "Transfer-Encoding: chunked\r\n"
            head += "Connection: close\r\n\r\n"
            // The head goes out immediately, so the router's read loop starts
            // waiting straight away and the first pause is real silence.
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

            for (index, frame) in self.frames.enumerated() {
                let pause = index == 0 ? self.delayBeforeFirstFrame : self.gapBetweenFrames
                if pause > 0 { Thread.sleep(forTimeInterval: pause) }
                self.sendFrame(frame, on: connection)
            }

            if self.holdOpenAfterFrames > 0 {
                Thread.sleep(forTimeInterval: self.holdOpenAfterFrames)
            }

            connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private func sendFrame(_ text: String, on connection: NWConnection) {
        let bytes = Data(text.utf8)
        var frame = Data("\(String(bytes.count, radix: 16))\r\n".utf8)
        frame.append(bytes)
        frame.append(Data("\r\n".utf8))
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }
}

// MARK: - Harnesses

/// A started router pointed at a `PacedUpstream`, with a ping interval short
/// enough for a test to observe.
final class PacedHarness {

    let upstream: PacedUpstream
    let router: ModelRouter
    let state: RouterState

    init(kind: ProviderKind = .openAICompatible, pingInterval: TimeInterval = 0.12) throws {
        upstream = try PacedUpstream()
        try upstream.start()

        let provider = Provider(
            name: "Paced",
            kind: kind,
            baseURL: upstream.baseURL,
            models: ["paced-model"]
        )
        state = RouterState(RouterConfiguration(provider: provider, model: "paced-model"))
        router = ModelRouter(state: state, keepAliveInterval: pingInterval)
        try router.start(preferredPort: 0)
    }

    deinit {
        router.stop()
        upstream.stop()
    }

    func url(_ path: String) -> URL {
        URL(string: "http://127.0.0.1:\(router.port)\(path)")!
    }

    /// Collect a streamed response as raw text, exactly as the client sees it.
    func streamMessages(_ body: String) async throws -> String {
        var request = URLRequest(url: url("/v1/messages"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        let (bytes, _) = try await URLSession.shared.bytes(for: request)
        var collected = Data()
        for try await byte in bytes { collected.append(byte) }
        return String(decoding: collected, as: UTF8.self)
    }
}

/// Extra request shapes on top of the harness in `RouterTests.swift`, which
/// cannot carry custom headers.
extension RouterHarness {

    func send(
        _ path: String,
        method: String = "POST",
        body: String? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = Data(body.utf8) }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, response as! HTTPURLResponse)
    }
}

// MARK: - Shared fixtures

private let routerToken = "9tKq2Xb7Vm4Pz1Lc8Rd5Nh3Gy6Jw0Sa"

private let streamingAnthropicRequest = """
{"model":"claude-sonnet-4-5","max_tokens":256,"stream":true,
 "messages":[{"role":"user","content":"say hello"}]}
"""

private let nonStreamingAnthropicRequest = """
{"model":"claude-sonnet-4-5-20250929","max_tokens":512,
 "messages":[{"role":"user","content":"say hello"}]}
"""

/// The exact bytes an Anthropic keep-alive must be.
private let pingFrame = "event: ping\ndata: {\"type\":\"ping\"}\n\n"

/// The names of the events in a raw Anthropic SSE transcript, in order.
private func sseEventNames(in transcript: String) -> [String] {
    var names: [String] = []
    for line in transcript.split(separator: "\n") {
        guard line.hasPrefix("event: ") else { continue }
        names.append(String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces))
    }
    return names
}

private let openAITranslatedSequence = [
    "message_start",
    "content_block_start",
    "content_block_delta",
    "content_block_delta",
    "content_block_stop",
    "message_delta",
    "message_stop",
]

// MARK: - Authentication

final class RouterAuthEnforcementTests: XCTestCase {

    private func securedHarness() throws -> RouterHarness {
        let harness = try RouterHarness()
        harness.state.update(auth: RouterAuth(isEnabled: true, token: routerToken))
        return harness
    }

    /// The gap this closes: before auth, any process on the machine could POST
    /// to the loopback router and spend the user's API credits.
    func testRequestWithoutAuthHeaderIsRejected() async throws {
        let harness = try securedHarness()
        let (data, response) = try await harness.send(
            "/v1/messages",
            body: nonStreamingAnthropicRequest
        )

        XCTAssertEqual(response.statusCode, 401)
        // Claude Code reads `error.type` to decide whether to retry, so the
        // envelope has to be the Anthropic one.
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(payload.objectValue?["type"]?.stringValue, "error")
        XCTAssertEqual(
            payload.objectValue?["error"]?.objectValue?["type"]?.stringValue,
            "authentication_error"
        )
        // A rejected request must not have reached the provider.
        XCTAssertTrue(harness.upstream.requests.isEmpty)
    }

    func testCorrectAPIKeyHeaderIsAccepted() async throws {
        let harness = try securedHarness()
        let (_, response) = try await harness.send(
            "/v1/messages",
            body: nonStreamingAnthropicRequest,
            headers: ["x-api-key": routerToken]
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(harness.upstream.requests.count, 1)
    }

    func testCorrectBearerTokenIsAccepted() async throws {
        let harness = try securedHarness()
        let (_, response) = try await harness.send(
            "/v1/messages",
            body: nonStreamingAnthropicRequest,
            headers: ["Authorization": "Bearer \(routerToken)"]
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(harness.upstream.requests.count, 1)
    }

    func testWrongTokenIsRejected() async throws {
        let harness = try securedHarness()
        let (apiKey, apiKeyResponse) = try await harness.send(
            "/v1/messages",
            body: nonStreamingAnthropicRequest,
            headers: ["x-api-key": "not-the-token"]
        )
        let (bearer, bearerResponse) = try await harness.send(
            "/v1/messages",
            body: nonStreamingAnthropicRequest,
            headers: ["Authorization": "Bearer not-the-token"]
        )

        XCTAssertEqual(apiKeyResponse.statusCode, 401)
        XCTAssertEqual(bearerResponse.statusCode, 401)
        XCTAssertTrue(harness.upstream.requests.isEmpty)

        // The token itself must never be echoed back, or the error becomes a
        // way to confirm a guess.
        XCTAssertFalse(String(decoding: apiKey, as: UTF8.self).contains(routerToken))
        XCTAssertFalse(String(decoding: bearer, as: UTF8.self).contains(routerToken))
    }

    /// The deliberate exception. The app polls this to decide whether the router
    /// is alive, and a liveness probe that needs a credential reports a healthy
    /// router as dead.
    func testHealthStaysOpenWhenAuthIsEnabled() async throws {
        let harness = try securedHarness()
        let (_, health) = try await harness.send("/health", method: "GET")
        let (_, v1Health) = try await harness.send("/v1/health", method: "GET")

        XCTAssertEqual(health.statusCode, 200)
        XCTAssertEqual(v1Health.statusCode, 200)
    }

    /// The gate is read per request, so turning auth on takes effect without a
    /// restart.
    func testEnablingAuthAfterStartTakesEffectOnTheNextRequest() async throws {
        let harness = try RouterHarness()

        let (_, before) = try await harness.send(
            "/v1/messages",
            body: nonStreamingAnthropicRequest
        )
        XCTAssertEqual(before.statusCode, 200)

        harness.state.update(auth: RouterAuth(isEnabled: true, token: routerToken))
        let (_, after) = try await harness.send(
            "/v1/messages",
            body: nonStreamingAnthropicRequest
        )
        XCTAssertEqual(after.statusCode, 401)
    }

    func testAuthDisabledLeavesTheRouterOpen() async throws {
        let harness = try RouterHarness()
        let (_, response) = try await harness.send(
            "/v1/messages",
            body: nonStreamingAnthropicRequest
        )
        XCTAssertEqual(response.statusCode, 200)
    }
}

// MARK: - /props

final class RouterPropsTests: XCTestCase {

    private let propsBody = #"{"n_ctx":4096,"total_slots":1,"chat_template":"{{ .Prompt }}"}"#

    func testPropsForwardsTheUpstreamBodyVerbatim() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        harness.upstream.completionBody = propsBody

        let (data, response) = try await harness.get("/props")

        XCTAssertEqual(response.statusCode, 200)
        // Verbatim: an agent reading `n_ctx` out of this must be handed the
        // upstream's own answer, not a translation of it.
        XCTAssertEqual(String(decoding: data, as: UTF8.self), propsBody)

        let sent = try XCTUnwrap(harness.upstream.requests.last)
        XCTAssertEqual(sent.method, "GET")
        // llama-server serves /props at the root, not under the /v1 that a bare
        // host:port gets normalised to.
        XCTAssertEqual(sent.path, "/props")
    }

    func testPropsIsAlsoReachableUnderV1() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        harness.upstream.completionBody = propsBody

        let (data, response) = try await harness.get("/v1/props")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), propsBody)
        XCTAssertEqual(harness.upstream.requests.last?.path, "/props")
    }

    func testPropsIsRefusedForANonLocalProvider() async throws {
        let harness = try RouterHarness(kind: .openAICompatible)
        let (data, response) = try await harness.get("/props")

        XCTAssertEqual(response.statusCode, 400)
        let text = String(decoding: data, as: UTF8.self)
        // A clear refusal, not the upstream's 404 — which reads as a router bug
        // and sends the user looking in the wrong place.
        XCTAssertTrue(text.contains("llama-server"), text)
        XCTAssertTrue(text.contains("openAICompatible"), text)
        XCTAssertTrue(harness.upstream.requests.isEmpty)
    }

    func testPropsReportsAnUnreachableUpstream() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        harness.upstream.stop()

        let (data, response) = try await harness.get("/props")

        XCTAssertEqual(response.statusCode, 500)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("reachable"), text)
    }
}

// MARK: - Keep-alive pings

final class RouterKeepAliveTests: XCTestCase {

    /// The headline behaviour: a slow upstream must not look like a hang.
    ///
    /// The upstream is silent for 0.4s before its first frame, which is the
    /// shape of a local model loading a long context. A ping is allowed to land
    /// *before* `message_start` here, and should: the wait for the first token
    /// is the longest silence of all, and feeding the client's byte-counting
    /// watchdog through it is the whole point. `ping` is a no-op for every
    /// client, and Anthropic documents it as valid at any point in the stream.
    func testPingIsEmittedWhileTheUpstreamIsSilent() async throws {
        let harness = try PacedHarness(pingInterval: 0.12)
        harness.upstream.delayBeforeFirstFrame = 0.4

        let transcript = try await harness.streamMessages(streamingAnthropicRequest)
        let names = sseEventNames(in: transcript)

        XCTAssertGreaterThanOrEqual(
            names.filter { $0 == "ping" }.count,
            1,
            "no ping during 0.4s of silence with a 0.12s interval"
        )
        // The exact wire bytes, including the blank line that terminates the
        // event. A missing blank line makes the client buffer indefinitely.
        XCTAssertTrue(transcript.contains(pingFrame), "transcript: \(transcript.prefix(600))")
        // The `event: ping` form rather than the SSE comment form, which would
        // not carry the documented event name. Matched as a whole line, since
        // "event: ping" itself contains ": ping".
        XCTAssertFalse(transcript.contains("\n: ping\n"))
        // Wherever it interleaves, a ping never lands after the message is
        // finished.
        let messageStop = try XCTUnwrap(names.firstIndex(of: "message_stop"))
        XCTAssertFalse(names.dropFirst(messageStop + 1).contains("ping"))
        // And the events a client acts on are exactly the ones it expects.
        XCTAssertEqual(names.filter { $0 != "ping" }, openAITranslatedSequence)
    }

    /// Pings are driven by upstream silence, not a wall clock, so an upstream
    /// that answers promptly must produce none at all.
    func testNoPingWhenTheUpstreamIsNotSlow() async throws {
        let harness = try PacedHarness(pingInterval: 0.5)
        let transcript = try await harness.streamMessages(streamingAnthropicRequest)

        XCTAssertFalse(transcript.contains("event: ping"), "transcript: \(transcript.prefix(600))")
    }

    /// Pings may be interleaved anywhere, but stripping them must leave the
    /// sequence a client expects.
    func testPingsDoNotDisturbTheEventSequence() async throws {
        let harness = try PacedHarness(pingInterval: 0.12)
        harness.upstream.delayBeforeFirstFrame = 0.4
        harness.upstream.gapBetweenFrames = 0.25

        let transcript = try await harness.streamMessages(streamingAnthropicRequest)
        let names = sseEventNames(in: transcript)

        XCTAssertTrue(names.contains("ping"), "expected the interleaved case")
        XCTAssertEqual(names.filter { $0 != "ping" }, openAITranslatedSequence)
    }

    func testNoPingAfterMessageStop() async throws {
        let harness = try PacedHarness(pingInterval: 0.1)
        harness.upstream.gapBetweenFrames = 0.15

        let transcript = try await harness.streamMessages(streamingAnthropicRequest)
        let names = sseEventNames(in: transcript)

        let messageStop = try XCTUnwrap(names.firstIndex(of: "message_stop"))
        XCTAssertEqual(names.last, "message_stop")
        XCTAssertFalse(names.dropFirst(messageStop + 1).contains("ping"))
        XCTAssertTrue(transcript.hasSuffix("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"))
    }

    /// The Anthropic passthrough path, which is where a stray ping is easiest to
    /// get wrong: `message_stop` arrives mid-stream from the upstream, and the
    /// upstream is then free to hold the connection open for as long as it
    /// likes. A keep-alive that is only stopped when the socket closes would
    /// ping into that window.
    func testPassthroughDoesNotPingAfterTheUpstreamsMessageStop() async throws {
        let harness = try PacedHarness(kind: .anthropic, pingInterval: 0.1)
        harness.upstream.frames = [
            "event: message_start\ndata: {\"type\":\"message_start\"}\n\n",
            "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0}\n\n",
            "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"index\":0}\n\n",
            "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n",
        ]
        // Each gap is longer than the ping interval, so a working keep-alive
        // must ping during them; the trailing hold is longer still, so a broken
        // one would ping after `message_stop`.
        harness.upstream.gapBetweenFrames = 0.25
        harness.upstream.holdOpenAfterFrames = 0.35

        let transcript = try await harness.streamMessages(streamingAnthropicRequest)
        let names = sseEventNames(in: transcript)

        XCTAssertTrue(names.contains("ping"), "expected pings between the upstream's events")
        XCTAssertEqual(names.last, "message_stop")
        XCTAssertFalse(names.dropFirst(try XCTUnwrap(names.firstIndex(of: "message_stop")) + 1)
            .contains("ping"))
        XCTAssertEqual(names.filter { $0 != "ping" }, [
            "message_start",
            "content_block_start",
            "content_block_delta",
            "message_stop",
        ])
    }

    /// A zero interval disables pinging, which is the escape hatch for a caller
    /// that wants the pre-keep-alive behaviour.
    func testZeroIntervalDisablesPinging() async throws {
        let harness = try PacedHarness(pingInterval: 0)
        harness.upstream.delayBeforeFirstFrame = 0.3

        let transcript = try await harness.streamMessages(streamingAnthropicRequest)

        XCTAssertFalse(transcript.contains("event: ping"))
        XCTAssertEqual(sseEventNames(in: transcript), openAITranslatedSequence)
    }
}
