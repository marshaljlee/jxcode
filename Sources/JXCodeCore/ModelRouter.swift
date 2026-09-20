import Foundation
import Network

// MARK: - Configuration

/// What the router is currently pointed at.
///
/// Held separately from `ProviderStore` because this changes far more often —
/// the user switching model in the UI should take effect on the very next
/// request, without restarting the listener.
public struct RouterConfiguration: Sendable, Equatable {
    public var provider: Provider?
    /// The model every agent request is routed to.
    public var model: String?
    /// Extra model names to intercept. Anything starting with `claude`, `gpt-`,
    /// `o1`/`o3`/`o4`, or `gemini` is intercepted regardless.
    public var aliases: [String]
    public var port: UInt16

    public init(
        provider: Provider? = nil,
        model: String? = nil,
        aliases: [String] = [],
        port: UInt16 = RouterConfiguration.defaultPort
    ) {
        self.provider = provider
        self.model = model
        self.aliases = aliases
        self.port = port
    }

    /// A port unlikely to collide with anything else the user runs.
    public static let defaultPort: UInt16 = 5255

    public static let idle = RouterConfiguration()

    public var isReady: Bool { provider != nil && model != nil }
}

/// Thread-safe holder for the live configuration.
public final class RouterState: @unchecked Sendable {

    private let lock = NSLock()
    private var configuration: RouterConfiguration
    private var storedAuth: RouterAuth

    /// The auth lives in a second slot on `RouterState` rather than as a field
    /// of `RouterConfiguration`, and follows the same `current`/`update`
    /// pattern as the rest of this type.
    ///
    /// Two reasons for the separate slot. `RouterConfiguration` is compared
    /// with `==` to decide whether a running listener still matches what the UI
    /// shows, and folding a rotating secret into it would make every token
    /// change read as "the configuration changed". And a defaulted parameter
    /// keeps every existing `RouterState(...)` call site compiling, with auth
    /// off — the same opt-in default `RouterAuth` itself uses.
    ///
    /// Read once per request by the router, so enabling auth takes effect on
    /// the next request rather than needing a restart, exactly like switching
    /// model does.
    public init(
        _ configuration: RouterConfiguration = .idle,
        auth: RouterAuth = RouterAuth()
    ) {
        self.configuration = configuration
        self.storedAuth = auth
    }

    public var current: RouterConfiguration {
        lock.lock()
        defer { lock.unlock() }
        return configuration
    }

    /// The live auth. Never logged and never echoed into a response body.
    public var auth: RouterAuth {
        lock.lock()
        defer { lock.unlock() }
        return storedAuth
    }

    public func update(_ configuration: RouterConfiguration) {
        lock.lock()
        self.configuration = configuration
        lock.unlock()
    }

    /// Swap the auth without disturbing the provider or model.
    public func update(auth: RouterAuth) {
        lock.lock()
        storedAuth = auth
        lock.unlock()
    }

    /// Point at a different model without disturbing the provider.
    public func selectModel(_ model: String?) {
        lock.lock()
        configuration.model = model
        lock.unlock()
    }
}

// MARK: - Log

/// Recent router activity, for the app's log pane and for debugging.
public final class RouterLog: @unchecked Sendable {

    private let lock = NSLock()
    private var recent: [String] = []
    private let limit: Int
    private let fileURL: URL?

    public init(fileURL: URL? = nil, limit: Int = 400) {
        self.fileURL = fileURL
        self.limit = limit
    }

    public func write(_ message: String) {
        let stamp = Self.formatter.string(from: Date())
        let line = "[\(stamp)] \(message)"

        lock.lock()
        recent.append(line)
        if recent.count > limit {
            recent.removeFirst(recent.count - limit)
        }
        lock.unlock()

        guard let fileURL else { return }
        appendToFile(line + "\n", at: fileURL)
    }

    public func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return recent
    }

    public func clear() {
        lock.lock()
        recent.removeAll()
        error = nil
        lock.unlock()
    }

    // MARK: - The failure that matters

    /// The most recent failure, kept separately from the scrolling log.
    ///
    /// A backend that rejects a request — no credit, a missing model, an
    /// expired key — currently reaches the agent as an empty or truncated
    /// response. The user sees "nothing happened" and has to go hunting
    /// through hundreds of log lines to learn their provider has ＄0 credit.
    /// This is the single line that explains it, so the UI can lead with it.
    public var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }

    private var error: String?

    /// Forget the retained failure, once routing is healthy again.
    ///
    /// Kept separate from `clear()` so a restart does not throw away the
    /// diagnostic with the rest of the log.
    public func clearError() {
        lock.lock()
        error = nil
        lock.unlock()
    }

    /// Record a failure: written to the log as usual, and retained as
    /// `lastError` so the UI can surface it without pattern-matching text.
    public func writeError(_ message: String) {
        lock.lock()
        error = message
        lock.unlock()
        write(message)
    }

    private func appendToFile(_ text: String, at url: URL) {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}

// MARK: - Errors

public enum RouterError: Error, CustomStringConvertible {
    case notConfigured
    case badRequest(String)
    case upstream(String)
    case alreadyRunning(UInt16)

    public var description: String {
        switch self {
        case .notConfigured:
            return "no provider and model selected — pick one in the Providers pane"
        case .badRequest(let detail):
            return "bad request: \(detail)"
        case .upstream(let detail):
            return "upstream error: \(detail)"
        case .alreadyRunning(let port):
            return "router is already listening on port \(port)"
        }
    }
}

// MARK: - Sink

/// Where streamed frames go. Abstracted so the streaming logic can be tested
/// without a real socket.
public protocol StreamSink: AnyObject, Sendable {
    func send(_ text: String)
    func finish()
}

// MARK: - Router

/// A loopback HTTP server that presents every registered backend in whichever
/// API shape the calling agent expects.
///
/// The whole point is that an agent is configured once — point `ANTHROPIC_BASE_URL`
/// or `OPENAI_BASE_URL` at this server — and never needs to know whether the
/// model behind it is Claude, a vLLM box, or a GGUF file. Switching provider is
/// a change to `RouterState` and nothing else.
public final class ModelRouter: @unchecked Sendable {

    private let state: RouterState
    public let log: RouterLog
    private let catalog: ModelCatalog

    /// How long the upstream may be silent before a keep-alive ping is written.
    ///
    /// Immutable and injected rather than a mutable property: the streaming path
    /// reads it from a different task than the one that would write it, and an
    /// interval that changes mid-stream is not a thing anyone needs. The default
    /// is the production value; tests pass something in the tens of
    /// milliseconds so they do not have to wait a real quarter-minute.
    public let keepAliveInterval: TimeInterval

    /// 15 seconds, against Claude Code's 300 second silence watchdog.
    ///
    /// Twenty times more headroom than the watchdog needs, which is deliberate:
    /// the ping only costs bytes on the wire when the upstream is genuinely
    /// stalled, and a shorter interval would risk firing during a normal
    /// long-thinking turn.
    public static let defaultKeepAliveInterval: TimeInterval = 15

    private let listenerQueue = DispatchQueue(label: "app.jxcode.router.listener")
    private let session: URLSession
    private var listener: NWListener?

    public private(set) var port: UInt16 = 0
    public private(set) var isRunning = false

    public init(
        state: RouterState,
        log: RouterLog = RouterLog(),
        catalog: ModelCatalog = ModelCatalog(),
        keepAliveInterval: TimeInterval = ModelRouter.defaultKeepAliveInterval
    ) {
        self.state = state
        self.log = log
        self.catalog = catalog
        self.keepAliveInterval = keepAliveInterval

        let configuration = URLSessionConfiguration.ephemeral
        // Generous: a local model producing a long answer can easily take
        // minutes, and a premature timeout looks like the model crashing.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: configuration)
    }

    // MARK: Lifecycle

    /// Bind and start accepting connections.
    ///
    /// Binds to loopback only. The router holds API keys, so exposing it on the
    /// LAN would hand those to anyone on the network. Loopback is not a trust
    /// boundary by itself — every other process running as this user can reach
    /// it — which is what `RouterAuth` is for.
    public func start(preferredPort: UInt16 = RouterConfiguration.defaultPort) throws {
        guard !isRunning else { throw RouterError.alreadyRunning(port) }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: preferredPort) ?? .any
        )

        let listener = try NWListener(using: parameters)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        let ready = DispatchSemaphore(value: 0)
        var startError: Error?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            case .cancelled:
                ready.signal()
            default:
                break
            }
        }

        listener.start(queue: listenerQueue)

        // Waiting is what makes `start()` usable synchronously: callers need a
        // bound port before they can write it into an agent's environment.
        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            self.listener = nil
            throw RouterError.upstream("listener did not become ready within 5s")
        }
        if let startError {
            listener.cancel()
            self.listener = nil
            throw RouterError.upstream("\(startError)")
        }

        port = listener.port?.rawValue ?? preferredPort
        isRunning = true
        log.write("router listening on http://127.0.0.1:\(port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        log.write("router stopped")
    }

    public var baseURL: String { "http://127.0.0.1:\(port)" }

    // MARK: Accepting

    private final class ConnectionContext: @unchecked Sendable {
        let connection: NWConnection
        var parser = HTTPRequestParser()
        var dispatched = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
        let context = ConnectionContext(connection)
        connection.stateUpdateHandler = { state in
            if case .failed = state { connection.cancel() }
        }
        connection.start(queue: listenerQueue)
        receive(context)
    }

    private func receive(_ context: ConnectionContext) {
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                context.parser.consume(data)
                do {
                    if let request = try context.parser.nextRequest(), !context.dispatched {
                        context.dispatched = true
                        self.dispatch(request, on: context.connection)
                        // Keep receiving only to notice the client going away,
                        // which is what lets a long generation be abandoned
                        // instead of running to completion for nobody.
                        self.watchForDisconnect(context)
                        return
                    }
                } catch {
                    self.send(
                        .apiError("\(error)", status: 400, anthropicStyle: false),
                        on: context.connection
                    )
                    return
                }
            }

            if isComplete || error != nil {
                context.connection.cancel()
                return
            }
            self.receive(context)
        }
    }

    private func watchForDisconnect(_ context: ConnectionContext) {
        context.connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            _, _, isComplete, error in
            if isComplete || error != nil {
                context.connection.cancel()
            }
        }
    }

    // MARK: Sending

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        var payload = response.serializedHead()
        if case .buffered(_, _, let body) = response {
            payload.append(body)
        }
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func sendHead(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serializedHead(), completion: .contentProcessed { _ in })
    }

    /// Writes chunked frames to a live connection.
    private final class ConnectionSink: StreamSink, @unchecked Sendable {
        private let connection: NWConnection
        private let lock = NSLock()
        private var closed = false

        init(_ connection: NWConnection) { self.connection = connection }

        /// The lock serialises writes, rather than merely guarding `closed`.
        ///
        /// Two tasks write to this connection: the streaming task forwards
        /// deltas while the keep-alive task writes pings. Taking the lock only
        /// to read `closed` would let two frames be enqueued concurrently, and
        /// the order they reach the wire would then be the networking stack's
        /// business — which is exactly how a ping ends up after `message_stop`.
        /// Holding it across the enqueue makes wire order the order the lock was
        /// taken, which is what lets `StreamKeepAlive.stop()` act as a barrier.
        func send(_ text: String) {
            guard !text.isEmpty else { return }
            let frame = HTTPResponse.chunk(text)
            guard !frame.isEmpty else { return }

            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            connection.send(content: frame, completion: .contentProcessed { _ in })
        }

        func finish() {
            lock.lock()
            defer { lock.unlock() }
            guard !closed else { return }
            closed = true
            connection.send(content: HTTPResponse.chunkTerminator, completion: .contentProcessed { _ in
                self.connection.cancel()
            })
        }
    }

    // MARK: Keep-alive

    /// Writes Anthropic `ping` events while the upstream is silent.
    ///
    /// Claude Code aborts a stream after 300 seconds with no bytes received, and
    /// its watchdog counts ping frames as bytes. A local model loading a long
    /// context, or a reasoning model thinking for minutes, sends nothing at all
    /// for far longer than that, so without this the user sees a hang where
    /// there is only a slow answer.
    ///
    /// Three decisions worth recording:
    ///
    ///  - `event: ping`, not an SSE comment. `SSEWriter.comment` was written for
    ///    this and both forms are counted by the watchdog, but `ping` is the
    ///    documented Anthropic event and the one clients already special-case; a
    ///    comment is only specified to be *ignored*. `comment` is left in place,
    ///    unused, because it is still the right tool for a non-Anthropic stream.
    ///
    ///  - Pings are driven by upstream *silence*, not a wall clock. Every byte
    ///    that arrives pushes the deadline out, so an active stream carries no
    ///    ping frames at all and a ping means "still waiting" — which is the
    ///    only reading under which it is a useful liveness signal.
    ///
    ///  - Elapsed time is read from the monotonic clock. A wall-clock jump
    ///    backwards would otherwise push the deadline out indefinitely, and the
    ///    thing being defended against is an elapsed-time watchdog.
    ///
    /// Ordering is the part that is easy to get wrong. A ping is written from
    /// this task while the reader task is writing deltas, so `stop()` is a
    /// barrier: it waits for the in-flight ping to land, and only then does the
    /// reader emit `message_stop`. "A ping can never appear after
    /// `message_stop`" is therefore a structural property rather than a race
    /// that is usually won.
    private final class StreamKeepAlive: @unchecked Sendable {

        private let intervalNanos: UInt64
        private let sink: StreamSink
        /// Guards `nextPingAt`, `stopped` and `task` — the three pieces of state
        /// the streaming task and the pinger task both touch.
        private let lock = NSLock()
        private var nextPingAt: UInt64
        private var stopped = false
        private var task: Task<Void, Never>?

        /// An `interval` of zero or less disables pinging entirely.
        init(interval: TimeInterval, sink: StreamSink) {
            let nanos = interval > 0 ? UInt64(interval * 1_000_000_000) : 0
            self.intervalNanos = nanos
            self.sink = sink
            self.nextPingAt = Self.now + nanos
        }

        private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

        /// The upstream produced bytes, so the next ping is a full interval away.
        ///
        /// Called once per byte read. That is an uncontended lock and a clock
        /// read per byte, which is the same order as the per-byte buffer append
        /// the read loop already does, and it is what keeps the deadline honest
        /// for an upstream that trickles without newlines.
        func noteActivity() {
            lock.lock()
            nextPingAt = Self.now + intervalNanos
            lock.unlock()
        }

        func start() {
            guard intervalNanos > 0 else { return }

            // Read the interval out here rather than inside the task: it is
            // immutable, and reaching for a property from inside the closure
            // would require `self` before the weak capture has been unwrapped.
            // Tick finer than the interval so a ping is not a whole interval
            // late, but not so finely that an idle stream becomes a spin.
            let tick = max(intervalNanos / 4, 20_000_000)

            // The check and the store happen under the same lock the pinger
            // takes, so a second caller cannot start a second pinger. Creating
            // the task while holding it is safe: the body only ever blocks on
            // this lock for as long as it takes to release it.
            lock.lock()
            defer { lock.unlock() }
            guard task == nil else { return }

            task = Task { [weak self] in
                while true {
                    do {
                        try await Task.sleep(nanoseconds: tick)
                    } catch {
                        return // cancelled by stop()
                    }
                    guard let self else { return }
                    self.pingIfDue()
                }
            }
        }

        private func pingIfDue() {
            lock.lock()
            defer { lock.unlock() }
            let now = Self.now
            guard !stopped, now >= nextPingAt else { return }
            // Reset from now rather than from the missed deadline, so a long
            // stall does not produce a burst of catch-up pings.
            nextPingAt = now + intervalNanos
            sink.send(AnthropicSSE.ping())
        }

        /// Claim the pinger task and mark the stream finished.
        ///
        /// Synchronous on purpose: `stop()` is async, and taking an `NSLock`
        /// directly from an async context is what Swift 6 warns about, because
        /// the lock is held across a potential suspension point. Here the lock
        /// is taken and released without suspending, and the awaiting happens
        /// afterwards on the task that was handed back.
        private func takePinger() -> Task<Void, Never>? {
            lock.lock()
            defer { lock.unlock() }
            stopped = true
            let running = task
            task = nil
            return running
        }

        /// Stop pinging, waiting for any in-flight ping to land first.
        ///
        /// Idempotent: the passthrough path stops this as soon as it forwards
        /// the upstream's own `message_stop`, and again on the way out.
        func stop() async {
            let running = takePinger()
            running?.cancel()
            // The ping write is synchronous, so once the task body has returned
            // no further frame can be written. Awaiting it is what makes the
            // barrier real: a ping already past its `stopped` check is enqueued
            // before this returns, and therefore before `message_stop`.
            await running?.value
        }
    }

    // MARK: Routing

    private enum RouteOutcome {
        case respond(HTTPResponse)
        case stream(HTTPResponse, @Sendable (StreamSink) async -> Void)
    }

    private func dispatch(_ request: HTTPRequest, on connection: NWConnection) {
        Task { [weak self] in
            guard let self else { return }
            do {
                switch try await self.route(request) {
                case .respond(let response):
                    self.send(response, on: connection)

                case .stream(let head, let produce):
                    self.sendHead(head, on: connection)
                    let sink = ConnectionSink(connection)
                    await produce(sink)
                    sink.finish()
                }
            } catch {
                self.log.writeError("\(request.method) \(request.path) failed: \(error)")
                self.send(
                    .apiError("\(error)", status: 500, anthropicStyle: request.path.contains("messages")),
                    on: connection
                )
            }
        }
    }

    /// Why this request cannot have come from a local client, or `nil` if it can.
    ///
    /// The listener is bound to 127.0.0.1, which stops a remote host reaching it
    /// but does nothing about a page the user already has open. A browser will
    /// POST to `http://127.0.0.1:5255` from any origin it likes, and because a
    /// `no-cors` fetch is a *simple* request it is sent with no preflight — so
    /// the router sees a well-formed request and spends the user's credits. The
    /// attacker cannot read the reply that way, but DNS rebinding removes even
    /// that limit, and once a name has been rebound the `Host` header is the
    /// only thing left that distinguishes it from `localhost`.
    ///
    /// So both are checked. No local client sets an `Origin`, which makes its
    /// presence on its own sufficient grounds for refusal; and `Host` must name
    /// the loopback interface or this machine.
    private func nonLocalRequestRejection(_ request: HTTPRequest) -> String? {
        if let origin = request.header("origin"), !origin.isEmpty {
            return "cross-origin request rejected"
        }

        guard let host = request.header("host")?.trimmingCharacters(in: .whitespaces),
              !host.isEmpty else {
            return "request rejected: missing Host header"
        }

        // Strip the port, and the brackets around an IPv6 literal.
        var name = host
        if name.hasPrefix("[") {
            guard let close = name.firstIndex(of: "]") else {
                return "request rejected: malformed Host"
            }
            name = String(name[name.index(after: name.startIndex)..<close])
        } else if let colon = name.lastIndex(of: ":") {
            name = String(name[name.startIndex..<colon])
        }
        name = name.lowercased()

        // This machine's own names are legitimate — an agent pointed at
        // `http://<host>.local:5255` still resolves to the loopback listener.
        // A rebinding attacker's domain matches none of these.
        let machine = ProcessInfo.processInfo.hostName.lowercased()
        let allowed: Set<String> = [
            "127.0.0.1", "localhost", "::1", machine,
            machine.hasSuffix(".local") ? machine : machine + ".local",
        ]
        guard allowed.contains(name) else {
            return "request rejected: Host \(host) is not loopback"
        }
        return nil
    }

    private func route(_ request: HTTPRequest) async throws -> RouteOutcome {
        let configuration = state.current

        // Ahead of everything, including the liveness probes below. Those are
        // unauthenticated by design, so the origin check is the only thing
        // standing in front of them, and it costs nothing to do it first.
        if let rejection = nonLocalRequestRejection(request) {
            log.write("403 \(request.method) \(request.path) — \(rejection)")
            return .respond(.apiError(rejection, status: 403, anthropicStyle: true))
        }

        switch (request.method, request.path) {
        // Deliberately unauthenticated, and deliberately first: the app polls
        // these to decide whether the router is alive, and a liveness probe that
        // needs a credential reports a healthy router as dead the moment the
        // credential is wrong, missing, or not yet loaded. Neither endpoint
        // touches a provider, a key, or the model list, so there is nothing here
        // worth protecting.
        case ("GET", "/health"), ("GET", "/v1/health"):
            return .respond(.json(healthPayload(configuration)))

        default:
            break
        }

        // Everything past this point can spend the user's API credits, so it is
        // gated. Read per request, not cached, so enabling or rotating the token
        // takes effect immediately without restarting the listener.
        let auth = state.auth
        guard auth.accepts(headers: request.headers) else {
            // Log the rejection but never the presented value: a rejected
            // request is the one case where the caller might have sent the real
            // token by mistake, and the log file is not a secret store.
            log.write("401 \(request.method) \(request.path) — missing or invalid router token")
            // Anthropic-shaped regardless of the path. Claude Code decides
            // whether to retry from `error.type` and is the client this feature
            // exists for; the OpenAI shape nests the same fields one level
            // differently but carries the same `error.message`, so an
            // OpenAI-shaped caller still gets a readable message.
            return .respond(.apiError(
                "authentication required: send the router token in the x-api-key "
                + "or Authorization: Bearer header",
                status: 401,
                anthropicStyle: true
            ))
        }

        switch (request.method, request.path) {
        case ("GET", "/v1/models"), ("GET", "/models"):
            return .respond(.json(modelsPayload(configuration)))

        case ("GET", "/props"), ("GET", "/v1/props"):
            return try await handleProps(configuration)

        case ("POST", "/v1/messages"):
            return try await handleAnthropicMessages(request, configuration)

        case ("POST", "/v1/messages/count_tokens"):
            return try handleCountTokens(request)

        case ("POST", "/v1/chat/completions"), ("POST", "/chat/completions"):
            return try await handleChatCompletions(request, configuration)

        default:
            log.write("404 \(request.method) \(request.path)")
            return .respond(.apiError(
                "no route for \(request.method) \(request.path)",
                status: 404,
                anthropicStyle: true
            ))
        }
    }

    // MARK: Introspection endpoints

    private func healthPayload(_ configuration: RouterConfiguration) -> JSONValue {
        // The provider and model are reported on purpose — the field set is
        // pinned by `RouterEndToEndTests.testHealthReportsTheSelectedProviderAndModel`,
        // so trimming it would be a silent behaviour change, not a fix.
        //
        // It is only safe to report them because `nonLocalRequestRejection`
        // runs first. This endpoint is unauthenticated by design, so the app can
        // poll it before a token is loaded; without the origin gate,
        // "unauthenticated" also meant "reachable from any page the user has
        // open", which is what made this worth reviewing. A local process can
        // still read it, but a local process can read the config files directly.
        var object: [String: JSONValue] = [
            "status": .string(configuration.isReady ? "ok" : "unconfigured"),
            "port": .number(Double(port)),
        ]
        if let provider = configuration.provider {
            object["provider"] = .string(provider.name)
            object["kind"] = .string(provider.kind.rawValue)
            object["base_url"] = .string(provider.normalizedBaseURL)
        }
        if let model = configuration.model {
            object["model"] = .string(model)
        }
        return .object(object)
    }

    /// The model list agents see.
    ///
    /// Reports the selected model first, then whatever the provider advertised,
    /// so a model picker in an agent shows something sensible instead of an
    /// empty list when the upstream could not be reached.
    private func modelsPayload(_ configuration: RouterConfiguration) -> JSONValue {
        var ids: [String] = []
        if let model = configuration.model { ids.append(model) }
        if let provider = configuration.provider { ids.append(contentsOf: provider.models) }

        var seen = Set<String>()
        let entries: [JSONValue] = ids
            .filter { seen.insert($0).inserted }
            .map { .object(["id": .string($0), "object": .string("model")]) }

        return .object([
            "object": .string("list"),
            "data": .array(entries),
        ])
    }

    // MARK: /props

    /// Forward llama-server's `/props` verbatim.
    ///
    /// Reports the loaded model's real configuration, chat template included,
    /// which is how a user finds out what context window they actually have
    /// rather than what the model card claims. Nothing is reshaped on the way
    /// through: the entire value of the endpoint is that it is the upstream's own
    /// view of itself, and an agent reading `n_ctx` from it must not be handed a
    /// translation.
    private func handleProps(_ configuration: RouterConfiguration) async throws -> RouteOutcome {
        guard let provider = configuration.provider else {
            throw RouterError.notConfigured
        }

        // Only llama-server serves this. Answering with a clear refusal beats
        // forwarding to an upstream that has no such route and returning its
        // 404, which reads as a router bug and sends the user looking in the
        // wrong place.
        guard provider.kind == .localGGUF else {
            return .respond(.apiError(
                "/props is only available when the upstream is a llama-server "
                + "(provider kind \"localGGUF\"). The selected provider is "
                + "\"\(provider.kind.rawValue)\", which has no /props endpoint.",
                status: 400,
                anthropicStyle: true
            ))
        }

        guard let url = propsURL(for: provider) else {
            throw RouterError.badRequest("provider has no usable base URL")
        }

        let (data, status) = try await get(provider: provider, url: url)
        guard (200..<300).contains(status) else {
            throw RouterError.upstream(
                "GET \(url.absoluteString) returned HTTP \(status): "
                + String(decoding: data.prefix(300), as: UTF8.self)
            )
        }

        return .respond(.buffered(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: data
        ))
    }

    /// llama-server serves `/props` at the server root, not under `/v1`.
    ///
    /// `normalizedBaseURL` appends `/v1` to a bare `host:port`, so the suffix is
    /// taken back off here rather than assuming `/v1/props` is routed. Some
    /// llama.cpp builds alias it and some do not, and a 404 from the guess looks
    /// like the model failed to load.
    private func propsURL(for provider: Provider) -> URL? {
        var base = provider.normalizedBaseURL
        if base.hasSuffix("/v1") { base.removeLast("/v1".count) }
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + "/props")
    }

    // MARK: /v1/messages

    private func handleAnthropicMessages(
        _ request: HTTPRequest,
        _ configuration: RouterConfiguration
    ) async throws -> RouteOutcome {
        guard let provider = configuration.provider,
              configuration.model != nil else {
            throw RouterError.notConfigured
        }
        guard let data = request.body.isEmpty ? nil : request.body else {
            throw RouterError.badRequest("empty body")
        }

        let decoder = JSONDecoder()
        guard var anthropic = try? decoder.decode(AnthropicRequest.self, from: data) else {
            throw RouterError.badRequest("body is not an Anthropic messages request")
        }

        let requested = anthropic.model
        anthropic.model = resolveModel(requested, configuration)
        let streaming = anthropic.stream == true

        let passthrough = provider.kind == .anthropic
        if requested != anthropic.model {
            log.write("model \(requested) → \(anthropic.model)")
        }
        log.write("POST /v1/messages stream=\(streaming) kind=\(provider.kind.rawValue)")

        if streaming {
            let inputTokens = TokenEstimator.estimate(anthropic)
            // Bound as a `let` so the streaming closure captures a value rather
            // than a mutable local, which Swift 6 rejects.
            let outbound = anthropic
            let head = HTTPResponse.stream(status: 200, headers: Self.sseHeaders)
            let plan: @Sendable (StreamSink) async -> Void = { [weak self] sink in
                guard let self else { return }
                do {
                    if passthrough {
                        try await self.forwardAnthropicStream(outbound, provider: provider, sink: sink)
                    } else {
                        try await self.translateOpenAIStream(
                            outbound,
                            provider: provider,
                            // Report the name the client asked for. It keys its
                            // context-window and capability tables off this, and
                            // an unrecognised name can make it misjudge its own
                            // limits. The substitution is logged instead.
                            reportedModel: requested,
                            inputTokens: inputTokens,
                            sink: sink
                        )
                    }
                } catch {
                    self.log.writeError("stream failed: \(error)")
                    sink.send(AnthropicSSE.frame(event: "error", payload: .object([
                        "type": .string("error"),
                        "error": .object([
                            "type": .string("api_error"),
                            "message": .string("\(error)"),
                        ]),
                    ])))
                }
            }
            return .stream(head, plan)
        }

        if passthrough {
            let body = try JSONEncoder().encode(anthropic)
            let (responseData, status) = try await post(
                provider: provider,
                url: provider.chatURL,
                body: body
            )
            guard (200..<300).contains(status) else {
                return .respond(.buffered(
                    status: status,
                    headers: ["Content-Type": "application/json"],
                    body: responseData
                ))
            }
            return .respond(.buffered(
                status: 200,
                headers: ["Content-Type": "application/json"],
                body: responseData
            ))
        }

        var openAI = Translation.request(anthropic).request
        openAI.model = anthropic.model
        let (responseData, status) = try await post(
            provider: provider,
            url: provider.chatURL,
            body: try JSONEncoder().encode(openAI)
        )
        guard (200..<300).contains(status) else {
            throw RouterError.upstream(
                "HTTP \(status): \(String(decoding: responseData.prefix(400), as: UTF8.self))"
            )
        }
        guard let decoded = try? decoder.decode(OpenAIChatResponse.self, from: responseData) else {
            throw RouterError.upstream(
                "reply was not a chat completion: \(String(decoding: responseData.prefix(200), as: UTF8.self))"
            )
        }

        let translated = Translation.response(
            decoded,
            // Echo the client's own model name, as the alias substitution is an
            // implementation detail of the router. See the streaming path.
            requestedModel: requested,
            inputTokens: TokenEstimator.estimate(anthropic)
        )
        return .respond(.buffered(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(translated)
        ))
    }

    private func handleCountTokens(_ request: HTTPRequest) throws -> RouteOutcome {
        guard let data = request.body.isEmpty ? nil : request.body,
              let anthropic = try? JSONDecoder().decode(AnthropicRequest.self, from: data) else {
            throw RouterError.badRequest("body is not an Anthropic messages request")
        }
        // Estimated locally rather than proxied: most OpenAI-compatible servers
        // have no counting endpoint, and returning an error here makes Claude
        // Code misjudge its context and stop compacting.
        let tokens = TokenEstimator.estimate(anthropic)
        return .respond(.json(.object(["input_tokens": .number(Double(tokens))])))
    }

    // MARK: /v1/chat/completions

    private func handleChatCompletions(
        _ request: HTTPRequest,
        _ configuration: RouterConfiguration
    ) async throws -> RouteOutcome {
        guard let provider = configuration.provider,
              configuration.model != nil else {
            throw RouterError.notConfigured
        }
        guard !request.body.isEmpty else {
            throw RouterError.badRequest("empty body")
        }

        let decoder = JSONDecoder()
        guard var openAI = try? decoder.decode(OpenAIChatRequest.self, from: request.body) else {
            throw RouterError.badRequest("body is not a chat completion request")
        }
        openAI.model = resolveModel(openAI.model, configuration)
        let streaming = openAI.stream == true
        log.write("POST /v1/chat/completions stream=\(streaming) kind=\(provider.kind.rawValue)")

        guard provider.kind == .anthropic else {
            // Streaming has to be handed off before anything is posted, since
            // the buffered path would consume the whole stream into memory and
            // then have to fake it back out.
            if streaming {
                let outbound = openAI
                let head = HTTPResponse.stream(status: 200, headers: Self.sseHeaders)
                let plan: @Sendable (StreamSink) async -> Void = { [weak self] sink in
                    guard let self else { return }
                    await self.pipeRawUpstream(provider: provider, body: outbound, sink: sink)
                }
                return .stream(head, plan)
            }

            let (data, status) = try await post(
                provider: provider,
                url: provider.chatURL,
                body: try JSONEncoder().encode(openAI)
            )
            return .respond(.buffered(
                status: status,
                headers: ["Content-Type": "application/json"],
                body: data
            ))
        }

        // Upstream is Anthropic but the caller speaks OpenAI.
        let anthropic = Translation.anthropicRequest(from: openAI)
        let (data, status) = try await post(
            provider: provider,
            url: provider.chatURL,
            body: try JSONEncoder().encode(anthropic)
        )
        guard (200..<300).contains(status) else {
            throw RouterError.upstream(
                "HTTP \(status): \(String(decoding: data.prefix(400), as: UTF8.self))"
            )
        }
        guard let decoded = try? decoder.decode(AnthropicResponse.self, from: data) else {
            throw RouterError.upstream("reply was not an Anthropic message")
        }
        let translated = Translation.openAIResponse(from: decoded)
        return .respond(.buffered(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(translated)
        ))
    }

    // MARK: Upstream

    private static let sseHeaders: [String: String] = [
        "Content-Type": "text/event-stream; charset=utf-8",
        "Cache-Control": "no-cache, no-store",
        // Tells nginx-style intermediaries not to buffer. Loopback needs it
        // least, but a user running this behind a local proxy benefits.
        "X-Accel-Buffering": "no",
    ]

    private func makeUpstreamRequest(
        provider: Provider,
        url: URL?,
        body: Data?,
        method: String = "POST"
    ) throws -> URLRequest {
        guard let url else { throw RouterError.badRequest("provider has no usable endpoint URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in provider.kind.authHeaders(apiKey: provider.apiKey) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.httpBody = body
        return request
    }

    /// Send a prepared upstream request, mapping transport failures onto a
    /// message that names the endpoint.
    ///
    /// Shared by every upstream call so a server that is simply not running
    /// reads the same way whichever route found it down.
    private func performUpstreamRequest(
        _ request: URLRequest,
        provider: Provider
    ) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw RouterError.upstream("response was not HTTP")
            }
            return (data, http.statusCode)
        } catch let error as RouterError {
            throw error
        } catch {
            throw unreachable(provider, error)
        }
    }

    /// A transport failure, phrased so the user knows where to look.
    ///
    /// A local backend has no third party to blame: if nothing answers, the
    /// model simply is not being served. Without that sentence, "Could not
    /// connect to the server" reads as a router fault and sends the user
    /// hunting through router settings for a port that just has no server on
    /// it — which is what happened with a stale `127.0.0.1:8081` entry.
    private func unreachable(_ provider: Provider, _ error: Error) -> RouterError {
        var message =
            "\(error.localizedDescription) — is \(provider.normalizedBaseURL) reachable?"
        if provider.kind == .localGGUF {
            message +=
                " No llama-server is answering there: serve a model in the local "
                + "model pane first, or select a backend that is already running."
        }
        return RouterError.upstream(message)
    }

    private func post(provider: Provider, url: URL?, body: Data) async throws -> (Data, Int) {
        try await performUpstreamRequest(
            makeUpstreamRequest(provider: provider, url: url, body: body),
            provider: provider
        )
    }

    private func get(provider: Provider, url: URL?) async throws -> (Data, Int) {
        try await performUpstreamRequest(
            makeUpstreamRequest(provider: provider, url: url, body: nil, method: "GET"),
            provider: provider
        )
    }

    /// Proxy an already-Anthropic stream straight through, rewriting nothing.
    ///
    /// Used when the upstream really is Anthropic: translating and translating
    /// back would only lose `cache_control` and thinking signatures.
    private func forwardAnthropicStream(
        _ anthropic: AnthropicRequest,
        provider: Provider,
        sink: StreamSink
    ) async throws {
        // Started before the upstream is contacted, for the same reason as the
        // translated path: the wait for the first token is the longest silence
        // and the one the client's watchdog is most likely to see.
        let keepAlive = StreamKeepAlive(interval: keepAliveInterval, sink: sink)
        keepAlive.start()

        do {
            let body = try JSONEncoder().encode(anthropic)
            let request = try makeUpstreamRequest(provider: provider, url: provider.chatURL, body: body)
            let (bytes, response) = try await session.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw RouterError.upstream("response was not HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                throw RouterError.upstream(
                    "HTTP \(http.statusCode): \(String(decoding: data.prefix(400), as: UTF8.self))"
                )
            }

            var pending = Data()
            for try await byte in bytes {
                keepAlive.noteActivity()
                pending.append(byte)
                // Forward on event boundaries so the client sees whole events.
                if pending.suffix(2) == Data("\n\n".utf8) {
                    let text = String(decoding: pending, as: UTF8.self)
                    sink.send(text)
                    pending.removeAll(keepingCapacity: true)
                    // An upstream is free to hold the connection open after it
                    // has finished the message. Pinging then would put a frame
                    // after `message_stop`, which the client rejects, so the
                    // keep-alive is switched off the moment the terminal event
                    // goes past rather than when the socket closes.
                    if text.contains("event: message_stop") {
                        await keepAlive.stop()
                    }
                } else if pending.count >= 8192 {
                    sink.send(String(decoding: pending, as: UTF8.self))
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if !pending.isEmpty {
                sink.send(String(decoding: pending, as: UTF8.self))
            }
        } catch {
            // Stop before the error escapes. The caller writes an `error` event
            // after this returns, and a ping arriving after that is as invalid
            // as one after `message_stop`.
            await keepAlive.stop()
            throw error
        }
        await keepAlive.stop()
    }

    /// Translate an OpenAI-compatible SSE stream into Anthropic events.
    ///
    /// `anthropic.model` is the resolved model sent upstream; `reportedModel` is
    /// the name echoed back to the client, which is the one it asked for.
    private func translateOpenAIStream(
        _ anthropic: AnthropicRequest,
        provider: Provider,
        reportedModel: String,
        inputTokens: Int,
        sink: StreamSink
    ) async throws {
        var upstream = Translation.request(anthropic).request
        upstream.model = anthropic.model
        upstream.stream = true
        upstream.streamOptions = OpenAIStreamOptions(includeUsage: true)

        // Started before the upstream is even contacted. The longest silence a
        // slow local model produces is the wait for the first token — loading
        // the context, then prefill — and that is precisely the window in which
        // the client's watchdog would otherwise fire. Starting this after the
        // response head arrives would miss all of it.
        let keepAlive = StreamKeepAlive(interval: keepAliveInterval, sink: sink)
        keepAlive.start()

        var translator = Translation.StreamTranslator(
            model: reportedModel,
            inputTokens: inputTokens
        )
        var parser = SSEParser()
        var pending = Data()
        let decoder = JSONDecoder()

        func ingest(_ event: SSEEvent) {
            guard !event.isDone, !event.data.isEmpty else { return }
            guard let data = event.data.data(using: .utf8),
                  let chunk = try? decoder.decode(OpenAIChatResponse.self, from: data) else {
                // A single malformed chunk is not worth killing the stream over;
                // the next one usually still carries the rest of the answer.
                return
            }
            for frame in translator.consume(chunk) { sink.send(frame) }
        }

        do {
            let request = try makeUpstreamRequest(
                provider: provider,
                url: provider.chatURL,
                body: try JSONEncoder().encode(upstream)
            )
            let (bytes, response) = try await session.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw RouterError.upstream("response was not HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                throw RouterError.upstream(
                    "HTTP \(http.statusCode): \(String(decoding: data.prefix(400), as: UTF8.self))"
                )
            }

            for try await byte in bytes {
                keepAlive.noteActivity()
                pending.append(byte)
                // Feed on newlines for latency, and on volume so a server that
                // never sends a newline cannot stall the buffer indefinitely.
                if byte == 0x0A || pending.count >= 1024 {
                    let text = String(decoding: pending, as: UTF8.self)
                    pending.removeAll(keepingCapacity: true)
                    for event in parser.feed(text) { ingest(event) }
                }
            }
            if !pending.isEmpty {
                for event in parser.feed(String(decoding: pending, as: UTF8.self)) { ingest(event) }
            }
            for event in parser.flush() { ingest(event) }
        } catch {
            // Stop before the error escapes: the caller writes an `error` event
            // after this returns, and a ping arriving after that is as invalid
            // as one after `message_stop`.
            await keepAlive.stop()
            throw error
        }

        // Barrier: no ping can be written after this returns, so the closing
        // events below are the last thing the client sees. `finalize()` is where
        // `message_stop` comes from, so stopping first is what keeps the
        // sequence valid.
        await keepAlive.stop()
        for frame in translator.finalize() { sink.send(frame) }
    }

    /// Pass an OpenAI-compatible SSE stream through untouched.
    private func pipeRawUpstream(provider: Provider, body: OpenAIChatRequest, sink: StreamSink) async {
        do {
            var streaming = body
            streaming.stream = true
            streaming.streamOptions = OpenAIStreamOptions(includeUsage: true)
            let request = try makeUpstreamRequest(
                provider: provider,
                url: provider.chatURL,
                body: try JSONEncoder().encode(streaming)
            )
            let (bytes, response) = try await session.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw RouterError.upstream("response was not HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                throw RouterError.upstream(
                    "HTTP \(http.statusCode): \(String(decoding: data.prefix(400), as: UTF8.self))"
                )
            }

            var pending = Data()
            for try await byte in bytes {
                pending.append(byte)
                if pending.suffix(2) == Data("\n\n".utf8) || pending.count >= 8192 {
                    sink.send(String(decoding: pending, as: UTF8.self))
                    pending.removeAll(keepingCapacity: true)
                }
            }
            if !pending.isEmpty { sink.send(String(decoding: pending, as: UTF8.self)) }
        } catch {
            log.writeError("raw passthrough failed: \(error)")
            sink.send(SSEWriter.frame(data: "{\"error\":{\"message\":\"\(error)\"}}"))
        }
    }

    // MARK: Model resolution

    /// Map whatever model name the agent asked for onto the configured one.
    ///
    /// Agents hard-code their own model names — Claude Code sends
    /// `claude-sonnet-4-5-20250929` and will not accept a rewrite on its side.
    /// Substituting here is what makes a local GGUF usable from it at all.
    ///
    /// A request for a model the provider actually advertises is honoured, so a
    /// multi-model backend can still be addressed deliberately.
    func resolveModel(_ requested: String, _ configuration: RouterConfiguration) -> String {
        guard let configured = configuration.model else { return requested }

        if requested.isEmpty { return configured }
        if requested == configured { return requested }

        if configuration.aliases.contains(where: {
            $0.caseInsensitiveCompare(requested) == .orderedSame
        }) {
            return configured
        }

        if let provider = configuration.provider,
           provider.models.contains(where: { $0 == requested }) {
            return requested
        }

        let lowered = requested.lowercased()
        let intercepted = ["claude", "gpt-", "o1", "o3", "o4", "gemini", "text-", "davinci"]
        if intercepted.contains(where: { lowered.hasPrefix($0) }) {
            return configured
        }

        // Anything else is a name this router has never heard of. Routing it to
        // the selected model is more useful than forwarding a guaranteed 404.
        return configured
    }
}
