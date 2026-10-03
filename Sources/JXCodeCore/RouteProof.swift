import Foundation
import Network

// Pillar 02's second half: prove the route, not the reply.
//
// `jxcode prove` spawns processes and checks where they land, because a config
// file that *says* the sandbox is in force proves nothing. The router has the
// same problem in a different shape. `/health` is answered from the router's own
// configuration, and a 200 from `/v1/messages` says only that *something*
// answered — a router that translated when it should have proxied, or proxied
// when it should have translated, produces a perfectly good answer on either
// path. 2.1 exists because that difference is invisible from the client side.
//
// The only place it is visible is the backend's side of the wire. So this file
// puts a recording server where the backend would be, drives real requests
// through a real router at it, and asserts what arrived.

// MARK: - The corpus

/// One request the router has to carry, and the facts about it a check can use.
///
/// The body is written the way Claude Code writes it — an Anthropic Messages
/// request with a model name the backend has never heard of — because that is
/// the shape whose handling is worth proving.
public struct RouteFixture: Sendable, Equatable {
    public let name: String
    public let body: String
    public let streaming: Bool
    /// The tool names this fixture defines. A check looks for them in whichever
    /// vocabulary the target wire uses, so one corpus can judge both routes.
    public let toolNames: [String]
    /// What the client asks for. Must never be what the backend is told, which
    /// is what makes the rewrite observable rather than assumed.
    public let requestedModel: String

    public init(
        name: String,
        body: String,
        streaming: Bool,
        toolNames: [String] = [],
        requestedModel: String
    ) {
        self.name = name
        self.body = body
        self.streaming = streaming
        self.toolNames = toolNames
        self.requestedModel = requestedModel
    }
}

/// The requests both the suite and `jxcode prove route` drive.
///
/// One list, in the core, deliberately. A command with its own private fixtures
/// would be evidence about a different corpus than the one the tests guard, and
/// the two would drift apart at the first change to either.
///
/// The four cases are the four combinations that matter: with and without tools,
/// buffered and streamed. A tool definition is the one thing whose *vocabulary*
/// changes between the wires (`input_schema` ⇄ `parameters`), so it is the only
/// field that can show which route was taken; streaming is the only mode where
/// the two routes emit different event shapes at all.
public enum RouteCorpus {

    public static let requestedModel = "claude-sonnet-4-5-20250929"

    public static let fixtures: [RouteFixture] = [
        RouteFixture(
            name: "plain text, buffered",
            body: """
            {"model":"\(requestedModel)","max_tokens":64,
             "messages":[{"role":"user","content":"say hello"}]}
            """,
            streaming: false,
            requestedModel: requestedModel
        ),
        RouteFixture(
            name: "plain text, streamed",
            body: """
            {"model":"\(requestedModel)","max_tokens":64,"stream":true,
             "messages":[{"role":"user","content":"say hello"}]}
            """,
            streaming: true,
            requestedModel: requestedModel
        ),
        RouteFixture(
            name: "a tool definition, buffered",
            body: """
            {"model":"\(requestedModel)","max_tokens":64,
             "tools":[{"name":"get_weather","description":"Get the weather for a city",
                       "input_schema":{"type":"object","properties":{"city":{"type":"string"}},
                                       "required":["city"]}}],
             "messages":[{"role":"user","content":"what is the weather in Paris?"}]}
            """,
            streaming: false,
            toolNames: ["get_weather"],
            requestedModel: requestedModel
        ),
        RouteFixture(
            name: "a tool definition, streamed",
            body: """
            {"model":"\(requestedModel)","max_tokens":64,"stream":true,
             "tools":[{"name":"get_weather","description":"Get the weather for a city",
                       "input_schema":{"type":"object","properties":{"city":{"type":"string"}},
                                       "required":["city"]}}],
             "messages":[{"role":"user","content":"what is the weather in Paris?"}]}
            """,
            streaming: true,
            toolNames: ["get_weather"],
            requestedModel: requestedModel
        ),
    ]
}

// MARK: - The backend that records

/// A backend that keeps everything it was sent.
///
/// Not a stub of `URLSession`. The router's route decision is a decision about a
/// *path on a socket*, and a fake at the session layer would answer a question
/// about the router's intent rather than about its bytes. This is a real
/// listener on loopback, so a passing check is a statement about HTTP.
///
/// It answers **by path**, exactly as the router itself keys off
/// `ProviderKind.chatPath`: `/v1/messages` gets an Anthropic reply and anything
/// else gets an OpenAI one. That is what lets one spy serve every route, and it
/// is also the point — a router that sent an Anthropic body to
/// `/v1/chat/completions` would get an OpenAI-shaped reply back and fail on the
/// client side, which is precisely the mistake 2.1's route table exists to
/// prevent.
///
/// It emits **CRLF** line endings on the streamed replies, which is legal and
/// which a `String`-based SSE parser silently mis-handles.
public final class SpyUpstream: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "jxcode.route-proof.spy")
    private let lock = NSLock()

    private var _received: [HTTPRequest] = []

    /// The status to answer `/v1/messages` with. 200 unless a caller says
    /// otherwise.
    ///
    /// This is not a testing knob bolted on: a llama-server build that predates
    /// the Anthropic route answers exactly this way, and the router's fallback
    /// to the translating path exists for it. Making the spy able to produce
    /// that answer is what lets the proof be checked *against a failure* — a
    /// suite of checks that has never been seen to fail is a suite nobody can
    /// trust, and 404 is the one fault a correct router reacts to by changing
    /// route, which is the claim under test.
    public var messagesRouteStatus: Int = 200

    public private(set) var port: UInt16 = 0

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: .any
        )
        listener = try NWListener(using: parameters)
    }

    public var baseURL: String { "http://127.0.0.1:\(port)" }

    /// Every request the backend was sent, in arrival order.
    public var received: [HTTPRequest] {
        lock.lock(); defer { lock.unlock() }
        return _received
    }

    public func forget() {
        lock.lock(); defer { lock.unlock() }
        _received = []
    }

    public func start() throws {
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
            throw RouteProofError.spyDidNotStart
        }
        guard let bound = listener.port?.rawValue, bound != 0 else {
            throw RouteProofError.spyDidNotStart
        }
        port = bound
    }

    public func stop() {
        listener.cancel()
    }

    // MARK: Connection handling

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
                    self._received.append(request)
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
        let wantsStream = request.bodyText.contains(#""stream":true"#)

        if request.path.hasSuffix("/v1/messages") {
            guard messagesRouteStatus == 200 else {
                send(connection, status: messagesRouteStatus, json: Self.notFoundBody)
                return
            }
            if wantsStream {
                sendAnthropicStream(on: connection)
            } else {
                send(connection, json: Self.anthropicBody)
            }
            return
        }

        if wantsStream {
            sendOpenAIStream(on: connection)
        } else {
            send(connection, json: Self.openAIBody)
        }
    }

    /// The answer a backend gives to a complete Anthropic request.
    static let anthropicBody = """
    {"id":"msg_spy","type":"message","role":"assistant","model":"spy-model",
     "content":[{"type":"text","text":"spy-ok"}],
     "stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":2}}
    """

    /// What a backend says when the route is not there.
    ///
    /// A status alone would do, but the router records the body it got and the
    /// user reads that in the log — so a spy that answers a bare 404 would make
    /// the router's own error message less like the real thing than it is.
    static let notFoundBody = """
    {"error":{"type":"not_found_error","message":"unknown endpoint"}}
    """

    /// The answer a backend gives to a complete OpenAI request.
    static let openAIBody = """
    {"id":"chatcmpl-spy","object":"chat.completion","model":"spy-model","choices":[
      {"index":0,"message":{"role":"assistant","content":"spy-ok"},"finish_reason":"stop"}
    ],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}
    """

    /// A complete Anthropic stream, with the event names an Anthropic client
    /// expects. Raw frames rather than assembled pieces, because the frame
    /// boundaries are the one thing the router must forward and not re-invent.
    private func sendAnthropicStream(on connection: NWConnection) {
        let frames = [
            #"event: message_start"# + "\r\n"
                + #"data: {"type":"message_start","message":{"id":"msg_spy","type":"message","role":"assistant","model":"spy-model","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":3,"output_tokens":0}}}"#
                + "\r\n\r\n",
            #"event: content_block_start"# + "\r\n"
                + #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#
                + "\r\n\r\n",
            #"event: content_block_delta"# + "\r\n"
                + #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"spy-ok"}}"#
                + "\r\n\r\n",
            #"event: content_block_stop"# + "\r\n"
                + #"data: {"type":"content_block_stop","index":0}"# + "\r\n\r\n",
            #"event: message_delta"# + "\r\n"
                + #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":2}}"#
                + "\r\n\r\n",
            #"event: message_stop"# + "\r\n"
                + #"data: {"type":"message_stop"}"# + "\r\n\r\n",
        ]
        sendStream(frames, on: connection)
    }

    /// A complete OpenAI stream, ending with the usage trailer and `[DONE]`.
    ///
    /// The trailer matters: the router asks for `stream_options.include_usage`
    /// and closes the Anthropic message only after it has seen the counts, so a
    /// spy that omitted it would make the router look like it dropped
    /// `message_delta` when it was never given the data.
    private func sendOpenAIStream(on connection: NWConnection) {
        let frames = [
            #"data: {"id":"chatcmpl-spy","choices":[{"index":0,"delta":{"role":"assistant","content":"spy-"}}]}"#,
            #"data: {"id":"chatcmpl-spy","choices":[{"index":0,"delta":{"content":"ok"}}]}"#,
            #"data: {"id":"chatcmpl-spy","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            #"data: {"id":"chatcmpl-spy","choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2,"total_tokens":5}}"#,
            "data: [DONE]",
        ].map { $0 + "\r\n\r\n" }
        sendStream(frames, on: connection)
    }

    private func sendStream(_ frames: [String], on connection: NWConnection) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Transfer-Encoding: chunked\r\n"
        head += "Connection: close\r\n\r\n"

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

    private func send(_ connection: NWConnection, status: Int = 200, json: String) {
        let body = Data(json.utf8)
        var head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

// MARK: - The report

/// One thing that was checked, and what was found.
public struct RouteProofCheck: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable {
        case pass
        case fail
    }

    /// Which route this check belongs to, as the kind's display name.
    public let route: String
    public let subject: String
    public let title: String
    public let status: Status
    public let detail: String

    public var id: String { "\(route)|\(subject)|\(title)" }

    public init(
        route: String,
        subject: String,
        title: String,
        status: Status,
        detail: String
    ) {
        self.route = route
        self.subject = subject
        self.title = title
        self.status = status
        self.detail = detail
    }
}

/// What one route's proof found.
public struct RouteProofRoute: Sendable, Identifiable {
    public let kind: ProviderKind
    public let routerURL: String
    public let backendURL: String
    /// Every path the backend was asked for, in arrival order.
    ///
    /// Kept beside the checks rather than folded into them because it is the
    /// raw observation: the checks say whether the paths were right, and this
    /// says what they were. A route that sent two requests shows up here as two
    /// entries, which is the shape of a fallback — and a fallback is the one
    /// outcome that must never be mistaken for a pass, because the client sees a
    /// perfectly good answer either way.
    public let backendPaths: [String]
    public let checks: [RouteProofCheck]

    public var id: String { kind.rawValue }

    public var failures: Int { checks.filter { $0.status == .fail }.count }
    public var isPassing: Bool { failures == 0 && !checks.isEmpty }
}

/// The whole proof, across every route it was run against.
public struct RouteProofReport: Sendable {
    public let routes: [RouteProofRoute]

    public init(routes: [RouteProofRoute]) { self.routes = routes }

    public var checks: [RouteProofCheck] { routes.flatMap(\.checks) }
    public var failures: Int { routes.reduce(0) { $0 + $1.failures } }
    public var isPassing: Bool { !routes.isEmpty && routes.allSatisfy(\.isPassing) }

    /// The terminal rendering, in the shape `jxcode prove` already uses.
    ///
    /// Failures by default, everything on request. `jxcode prove` prints all
    /// nine of its checks because nine is a screenful; this one produces 122,
    /// and printing them all buries the four lines that matter under a hundred
    /// and eighteen that say "as expected". The first version did print them all
    /// — it was written before the corpus grew, and the wall of text only became
    /// visible when the command was actually run.
    public func rendered(verbose: Bool = false) -> String {
        var out: [String] = []
        out.append("JXCode route proof")
        out.append(String(repeating: "─", count: 64))

        for route in routes {
            let verdict = route.isPassing ? "  ok  " : " FAIL "
            out.append("[\(verdict)] \(route.kind.displayName)  (\(route.kind.translationSummary))")
            out.append("         router \(route.routerURL) → backend \(route.backendURL)")
            var distinct: [String] = []
            for path in route.backendPaths where !distinct.contains(path) { distinct.append(path) }
            out.append("         asked  \(distinct.isEmpty ? "—" : distinct.joined(separator: ", "))")

            let failures = route.checks.filter { $0.status == .fail }
            if failures.isEmpty {
                out.append("         \(route.checks.count) checks, all passed")
            } else {
                out.append("         \(failures.count) of \(route.checks.count) checks failed:")
                for check in failures {
                    out.append("           ✗ \(check.subject): \(check.title)")
                    out.append("             \(check.detail)")
                }
            }
            if verbose {
                out.append("")
                for check in route.checks where check.status == .pass {
                    out.append("           · \(check.subject): \(check.title)")
                }
            }
            out.append("")
        }

        let total = checks.count
        out.append(String(repeating: "─", count: 64))
        out.append("\(total - failures)/\(total) checks passed across \(routes.count) route(s)")
        out.append(isPassing
            ? "Every route sent the backend what it promised, and returned a well-formed answer."
            : "A route is not doing what it says — see the ✗ entries above.")
        return out.joined(separator: "\n")
    }
}

public enum RouteProofError: Error, CustomStringConvertible {
    case spyDidNotStart
    case routerDidNotStart(String)
    case noBackendRequest(String)

    public var description: String {
        switch self {
        case .spyDidNotStart:
            return "the recording backend could not bind a loopback port"
        case .routerDidNotStart(let detail):
            return "the router did not start: \(detail)"
        case .noBackendRequest(let fixture):
            return "the backend was never reached for '\(fixture)'"
        }
    }
}

// MARK: - The proof

/// Drive the corpus through a real router at a real recording backend, on every
/// route, and judge what arrived.
///
/// Three routes rather than one, because the router has three ways to serve an
/// Anthropic client and they are not variations on a theme — two of them forward
/// the client's own bytes and one of them rewrites the body entirely:
///
///  - `localGGUF` — native, on llama-server's own `/v1/messages`.
///  - `anthropic` — native, on Anthropic's `/v1/messages`, with `x-api-key`
///    rather than a bearer token.
///  - `openAICompatible` — translated, onto `/v1/chat/completions`.
///
/// The same corpus runs against all three, so a fix on the translating side
/// cannot silently break the passthrough one. That is the whole point of 2.6's
/// second bullet, and it is only true if one list feeds both.
public enum RouteProof {

    /// The model the router is configured with.
    ///
    /// Deliberately not the name the corpus asks for. The rewrite is one of the
    /// few things the router does on *every* route, and a fixture whose model
    /// name happened to match would prove nothing about it.
    public static let configuredModel = "proof-model"

    /// A key, so the auth header each kind promises is observable.
    public static let apiKey = "proof-key"

    public static let routes: [ProviderKind] = [.localGGUF, .anthropic, .openAICompatible]

    public static func run(kinds: [ProviderKind] = RouteProof.routes) async -> RouteProofReport {
        var results: [RouteProofRoute] = []
        for kind in kinds {
            results.append(await run(kind: kind))
        }
        return RouteProofReport(routes: results)
    }

    private static func run(kind: ProviderKind) async -> RouteProofRoute {
        let spy: SpyUpstream
        do {
            spy = try SpyUpstream()
            try spy.start()
        } catch {
            return RouteProofRoute(
                kind: kind,
                routerURL: "—",
                backendURL: "—",
                backendPaths: [],
                checks: [RouteProofCheck(
                    route: kind.displayName,
                    subject: "harness",
                    title: "the recording backend binds",
                    status: .fail,
                    detail: "\(error)"
                )]
            )
        }
        defer { spy.stop() }
        return await run(kind: kind, against: spy)
    }

    /// The same proof against a backend the caller already stood up.
    ///
    /// The seam exists so a test can put a *faulty* backend there — one that
    /// refuses the Anthropic route, which is a real llama-server build rather
    /// than a contrived failure — and check that the proof reports it. A proof
    /// that has only ever been run against a working backend is a proof that
    /// might be passing for no reason.
    public static func run(kind: ProviderKind, against spy: SpyUpstream) async -> RouteProofRoute {
        let provider = Provider(
            name: "Proof",
            kind: kind,
            baseURL: spy.baseURL,
            apiKey: apiKey,
            models: [configuredModel]
        )
        let router = ModelRouter(
            state: RouterState(RouterConfiguration(provider: provider, model: configuredModel))
        )
        defer { router.stop() }

        do {
            try router.start(preferredPort: 0)
        } catch {
            return RouteProofRoute(
                kind: kind,
                routerURL: "—",
                backendURL: spy.baseURL,
                backendPaths: [],
                checks: [RouteProofCheck(
                    route: kind.displayName,
                    subject: "harness",
                    title: "the router binds a loopback port",
                    status: .fail,
                    detail: "\(error)"
                )]
            )
        }

        guard await RouterSelfTest.waitUntilListening(routerURL: router.baseURL) else {
            return RouteProofRoute(
                kind: kind,
                routerURL: router.baseURL,
                backendURL: spy.baseURL,
                backendPaths: [],
                checks: [RouteProofCheck(
                    route: kind.displayName,
                    subject: "harness",
                    title: "the router answers /health",
                    status: .fail,
                    detail: "it bound port \(router.port) but did not answer"
                )]
            )
        }

        var checks: [RouteProofCheck] = []
        var paths: [String] = []

        for fixture in RouteCorpus.fixtures {
            spy.forget()
            let reply = await post(fixture.body, to: router.baseURL)
            let seen = spy.received
            paths.append(contentsOf: seen.map(\.path))

            checks.append(contentsOf: judge(
                fixture: fixture,
                kind: kind,
                backendRequests: seen,
                reply: reply
            ))
        }

        return RouteProofRoute(
            kind: kind,
            routerURL: router.baseURL,
            backendURL: spy.baseURL,
            backendPaths: paths,
            checks: checks
        )
    }

    // MARK: One fixture, judged

    private static func judge(
        fixture: RouteFixture,
        kind: ProviderKind,
        backendRequests: [HTTPRequest],
        reply: RouteProof.Reply
    ) -> [RouteProofCheck] {
        var checks: [RouteProofCheck] = []

        func check(_ title: String, _ ok: Bool, _ detail: String) {
            checks.append(RouteProofCheck(
                route: kind.displayName,
                subject: fixture.name,
                title: title,
                status: ok ? .pass : .fail,
                detail: detail
            ))
        }

        // The count first, and as a count. "A request arrived" is satisfied by a
        // router that retried a failing route, and the retry is exactly what the
        // route table is supposed to prevent — 2.1's fallback only fires for a
        // *missing* route, and a spy that answers everything is never missing
        // one. So the number has to be one.
        check(
            "the backend was reached exactly once",
            backendRequests.count == 1,
            backendRequests.isEmpty
                ? "nothing arrived — the router never sent the request"
                : "\(backendRequests.count) requests arrived; a second one means a route was "
                    + "tried and abandoned"
        )

        guard let request = backendRequests.first else { return checks }

        // The route claim itself: the path is the whole observable difference
        // between proxying and translating.
        let expectedPath = kind.messagesPath == nil
            ? "/v1/chat/completions"
            : "/v1/messages"
        check(
            "the backend got the path this route promises",
            request.path.hasSuffix(expectedPath),
            "expected \(expectedPath), got \(request.path)"
        )

        // The auth header the kind promises. Anthropic is `x-api-key`; the rest
        // are bearer. A router that used one everywhere would 401 on half of the
        // kinds it supports, and only ever on the ones nobody tested.
        let promised = kind.authHeaders(apiKey: apiKey)
        let missing = promised.filter { request.header($0.key) != $0.value }
        check(
            "the backend got the auth header this kind promises",
            missing.isEmpty,
            missing.isEmpty
                ? promised.keys.sorted().joined(separator: ", ")
                : "missing or wrong: \(missing.keys.sorted().joined(separator: ", "))"
        )

        // The model rewrite, asserted as an inequality as well as an equality.
        // Equality alone would pass if the router forwarded the client's name
        // *and* the configured one appeared somewhere else in the body.
        let body = request.bodyText
        check(
            "the backend was told the configured model",
            body.contains("\"model\":\"\(configuredModel)\""),
            "no \"model\":\"\(configuredModel)\" in the body it received"
        )
        check(
            "the client's model name did not reach the backend",
            !body.contains(fixture.requestedModel),
            "the backend was told '\(fixture.requestedModel)', which only the client asked for"
        )

        // The tool vocabulary. This is the one field whose *name* changes with
        // the route, so it is the only field that can prove which route ran even
        // if the path check were somehow satisfied twice.
        if !fixture.toolNames.isEmpty {
            let expectedKey = kind.messagesPath == nil ? "\"parameters\"" : "\"input_schema\""
            let forbiddenKey = kind.messagesPath == nil ? "\"input_schema\"" : "\"parameters\""
            check(
                "the tool arrived in the target wire's vocabulary",
                body.contains(expectedKey) && !body.contains(forbiddenKey),
                body.contains(expectedKey)
                    ? "\(expectedKey) present and \(forbiddenKey) absent, as the route requires"
                    : "expected \(expectedKey) and no \(forbiddenKey) in the body the backend got"
            )
            for name in fixture.toolNames {
                check(
                    "the tool '\(name)' reached the backend",
                    body.contains(name),
                    "the definition was dropped on the way through"
                )
            }
        }

        // The translated route has to ask for the usage trailer, or the client
        // never gets real token counts — and the failure is silent, because the
        // answer is otherwise perfect.
        if fixture.streaming, kind.messagesPath == nil {
            check(
                "the translated request asked for the usage trailer",
                body.contains("\"include_usage\":true"),
                "no stream_options.include_usage, so the client's token counts would be estimates"
            )
        }

        // And finally the client's half: whatever the route did upstream, the
        // agent on this end must receive a well-formed Anthropic answer.
        check(
            "the client was answered with HTTP 200",
            reply.status == 200,
            "HTTP \(reply.status): \(reply.body.prefix(300))"
        )
        check(
            "no character was corrupted in transit",
            !reply.body.contains("\u{FFFD}"),
            "the reply carries U+FFFD, which is what a scalar cut in half decodes to"
        )

        if fixture.streaming {
            let names = RouteProof.eventNames(in: reply.body)
            check(
                "the stream is bracketed by message_start and message_stop",
                names.first == "message_start" && names.last == "message_stop",
                names.isEmpty
                    ? "no events at all:\n\(reply.body.prefix(300))"
                    : "first \(names.first ?? "—"), last \(names.last ?? "—")"
            )
            check(
                "the stream carries exactly one message_stop",
                names.filter { $0 == "message_stop" }.count == 1,
                "\(names.filter { $0 == "message_stop" }.count) message_stop events"
            )
            // No ping may be written after the terminal event. A client rejects
            // the frame, and the cause is a race that is invisible when the
            // upstream is fast — which is every run of this proof.
            let afterStop = names.drop(while: { $0 != "message_stop" }).dropFirst()
            check(
                "nothing follows message_stop",
                afterStop.isEmpty,
                "frames after the terminal event: \(afterStop.joined(separator: ", "))"
            )
        } else {
            let decoded = try? JSONDecoder().decode(AnthropicResponse.self, from: Data(reply.body.utf8))
            check(
                "the client got an Anthropic message, not an OpenAI one",
                decoded?.type == "message",
                decoded == nil
                    ? "the body did not decode as an Anthropic message:\n\(reply.body.prefix(300))"
                    : "type was '\(decoded?.type ?? "")'"
            )
        }

        return checks
    }

    // MARK: Transport

    struct Reply: Sendable {
        let status: Int
        let body: String
    }

    private static func post(_ body: String, to baseURL: String) async -> Reply {
        guard let url = URL(string: baseURL + "/v1/messages") else {
            return Reply(status: 0, body: "\(baseURL) is not a usable URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Reply(status: status, body: String(decoding: data, as: UTF8.self))
        } catch {
            return Reply(status: 0, body: "the router could not be reached: \(error)")
        }
    }

    /// The `event:` names in an SSE transcript, in order.
    ///
    /// Read from the raw text rather than through `SSEParser` on purpose: the
    /// parser is the code under test on this path, and using it to judge its own
    /// output would let a framing bug hide behind itself.
    ///
    /// Split on the **byte** `0x0A`, not on the `Character` `"\n"`. This is the
    /// same trap `SSEParser` documents at the top of its own file, and this
    /// function walked straight into it: in a CRLF stream, CR+LF is a single
    /// grapheme cluster, so `split(separator: "\n")` finds nothing to split on
    /// and hands back the *whole transcript* as one line. The first element of
    /// the result was then the entire document, `first` and `last` were the same
    /// string, and "the stream carries exactly one `message_stop`" counted zero.
    /// Every one of those is a check that fails on a correct router — which is
    /// how it was found, on the first run of the proof against the spy, whose
    /// stream is deliberately CRLF.
    ///
    /// The trailing CR has to go with `whitespacesAndNewlines`, not
    /// `whitespaces`: `\r` is not in the latter, so `"message_stop\r"` is not
    /// `"message_stop"` and the count stays zero. That one is worse than the
    /// first, because a stray CR renders as nothing — the failure detail printed
    /// `last message_stop` while the comparison against `"message_stop"` was
    /// false, and the output looked correct.
    static func eventNames(in transcript: String) -> [String] {
        var names: [String] = []
        for line in transcript.utf8.split(separator: 0x0A, omittingEmptySubsequences: false) {
            let text = String(decoding: line, as: UTF8.self)
            guard text.hasPrefix("event: ") else { continue }
            names.append(String(text.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return names
    }
}
