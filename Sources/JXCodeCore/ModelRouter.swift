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

/// Something that can turn an alias into a backend, starting one if needed.
///
/// The router asks this before it decides where a request goes, which is what
/// makes `coder` mean a *model* rather than a name to rewrite. `LlamaServerSupervisor`
/// is the implementation; the protocol exists so the router can be tested
/// against a stub without a llama-server on the machine, and so the core does
/// not have to depend on the supervisor's construction.
///
/// `nil` — not an error — is the answer for a name this does not know. Every
/// request for a remote model goes through this hook too, and a throw there
/// would turn an ordinary Claude turn into a 500.
public protocol LocalModelServing: Sendable {
    /// The aliases that resolve right now, whether or not they are loaded.
    var knownAliases: [String] { get }

    /// The backend answering for `alias`, started if it was not running.
    func backend(for alias: String) async throws -> Provider?
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
    /// The local-model supervisor, when one is attached.
    ///
    /// A third slot, and separate from `configuration` for the same reason the
    /// auth is: `RouterConfiguration` is compared with `==` to decide whether a
    /// running listener still matches what the UI shows, and a live supervisor
    /// is an object with no stable value. Folding it in would make every
    /// attach and detach read as "the configuration changed", which is the
    /// check that decides whether the router needs restarting.
    ///
    /// Read once per request. Attaching or detaching one therefore takes effect
    /// on the next request rather than needing a restart, exactly like
    /// switching model or rotating the token.
    private var localModels: (any LocalModelServing)?

    public init(
        _ configuration: RouterConfiguration = .idle,
        auth: RouterAuth = RouterAuth(),
        serving: (any LocalModelServing)? = nil
    ) {
        self.configuration = configuration
        self.storedAuth = auth
        self.localModels = serving
    }

    /// The attached supervisor, if any.
    public var serving: (any LocalModelServing)? {
        lock.lock()
        defer { lock.unlock() }
        return localModels
    }

    /// Attach or detach the supervisor without disturbing anything else.
    public func update(serving: (any LocalModelServing)?) {
        lock.lock()
        localModels = serving
        lock.unlock()
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
        translation = []
        lock.unlock()
    }

    // MARK: - What the last translation could not carry

    /// The notes from the most recent translation, kept separately from the
    /// scrolling log for the same reason `lastError` is.
    ///
    /// A dropped block is not a failure — the request still succeeds — so it
    /// belongs nowhere near the error banner. It is also not nothing: "why did
    /// my model stop using tools" and "why does the agent not see the search
    /// result" are both this list. The pane shows the latest set without the
    /// user having to pattern-match hundreds of log lines.
    ///
    /// Before this existed the notes were built and then discarded on the floor
    /// at every call site, which made the router's own honesty unreachable.
    public var lastTranslation: [String] {
        lock.lock()
        defer { lock.unlock() }
        return translation
    }

    private var translation: [String] = []

    /// Record what a translation could not carry.
    ///
    /// An empty set clears the previous one, deliberately: the last request's
    /// notes are what is shown, so a translation that carried everything is how
    /// the user finds out the earlier problem is gone. Retaining the old list
    /// would leave a card describing a request that has since been superseded.
    public func writeTranslation(_ notes: [String], route: String) {
        lock.lock()
        translation = notes
        lock.unlock()
        for note in notes { write("translation (\(route)): \(note)") }
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

/// The backend answered, and the route asked for is not there.
///
/// Its own type rather than a message, because it is the only upstream failure
/// the router can route around: an older llama-server build has no
/// `/v1/messages`, and the same request translated onto the OpenAI wire is
/// answered perfectly. Collapsing it into `RouterError.upstream` would make that
/// indistinguishable from a 400 or a 429, both of which mean the backend *did*
/// understand the request — retrying those in another shape is how one error
/// becomes two.
struct MissingRoute: Error, Sendable, CustomStringConvertible {
    let status: Int
    let path: String
    let detail: String

    /// The sentence this failure would have been before it became a type.
    ///
    /// Not cosmetic. When there is no wire to fall back to, this error is written
    /// into the SSE `error` frame the client reads, and `String(describing:)` on
    /// a struct is a reflection dump — `MissingRoute(status: 404, path:
    /// "/v1/messages", …)`. Raising a type instead of a message must not change a
    /// byte of what the user is told.
    var description: String {
        "upstream error: HTTP \(status): \(detail)"
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

    /// How long a token count may take before the estimate stands in.
    ///
    /// Short on purpose, and short for a reason that is about *where* this
    /// number is asked for rather than how hard it is to compute. Claude Code
    /// asks for a count on the way into every turn, to decide whether it must
    /// compact first — so this sits on the critical path of a turn, and a
    /// backend that has gone away must not be able to hold the turn open while
    /// the router waits for it. Three seconds is generous for a tokenizer that
    /// is running and answers in single-digit milliseconds, and short enough
    /// that a wrong endpoint costs the user a beat rather than a stall.
    public static let countingTimeout: TimeInterval = 3

    private let listenerQueue = DispatchQueue(label: "app.jxcode.router.listener")
    private let session: URLSession

    /// A second session, for the token-count probe only.
    ///
    /// `session` below is deliberately generous — 600 seconds — because a local
    /// model producing a long answer takes minutes and a premature timeout
    /// looks like the model crashing. That same 600 seconds is exactly wrong for
    /// a count, which is asked for on the way into every turn: a backend that
    /// has gone away would hold the turn for ten minutes before the estimate
    /// could stand in for it. The count is a measurement on a critical path, so
    /// it gets a budget that says so.
    ///
    /// Separate rather than shared because the two want opposite things and
    /// neither value is a compromise the other can live with.
    private let countingSession: URLSession

    /// Which backends have already said they cannot count.
    private let tokenCountCapability = TokenCountCapability()

    /// One lock around all three lifecycle fields, not one lock each.
    ///
    /// They describe a single state — either the router is listening on a known
    /// port, or it is not listening at all — so guarding them separately would
    /// let a reader take a port from one generation and a listener from the
    /// next. They used to be plain `var`s on an `@unchecked Sendable` class,
    /// written by `start`/`stop` on whatever thread called them and read from
    /// connection tasks (`/health` reports the port) and from the UI
    /// (`baseURL`). On a non-atomic type that is undefined behaviour, not
    /// merely a stale read.
    private let lifecycleLock = NSLock()
    private var _listener: NWListener?
    private var _port: UInt16 = 0
    private var _isRunning = false

    /// A start that has claimed the router but not yet bound.
    ///
    /// Separate from `_isRunning` so that `isRunning` keeps its meaning —
    /// listening, right now — and a bind that is still in flight does not read
    /// as running. It is what serialises two concurrent `start()` calls; a
    /// `guard` on `_isRunning` alone would let both past, because neither sets
    /// it until its bind completes.
    private var _claiming = false

    /// The port the listener is bound to, or 0 before the first successful
    /// `start()`.
    public var port: UInt16 {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return _port
    }

    public var isRunning: Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return _isRunning
    }

    /// The access log, when one is attached.
    ///
    /// A second sink rather than a second *kind* of line in `log`, because the
    /// two answer different questions and interleaving them destroys both. The
    /// decision log is read to find out what the router did with a request; the
    /// access log is read to find out whether the request arrived at all — and
    /// "the agent sent nothing" and "the agent sent something the router
    /// refused" are the same shape in a decision log and opposite diagnoses.
    ///
    /// Separate instances also mean the access log can be truncated on its own,
    /// which matters because it grows one line per request and the decision log
    /// grows only when something happens.
    private let httpLog: RouterLog?

    public init(
        state: RouterState,
        log: RouterLog = RouterLog(),
        httpLog: RouterLog? = nil,
        catalog: ModelCatalog = ModelCatalog(),
        keepAliveInterval: TimeInterval = ModelRouter.defaultKeepAliveInterval
    ) {
        self.state = state
        self.log = log
        self.httpLog = httpLog
        self.catalog = catalog
        self.keepAliveInterval = keepAliveInterval

        let configuration = URLSessionConfiguration.ephemeral
        // Generous: a local model producing a long answer can easily take
        // minutes, and a premature timeout looks like the model crashing.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: configuration)

        let counting = URLSessionConfiguration.ephemeral
        counting.timeoutIntervalForRequest = ModelRouter.countingTimeout
        counting.timeoutIntervalForResource = ModelRouter.countingTimeout
        self.countingSession = URLSession(configuration: counting)
    }

    // MARK: Lifecycle

    /// Bind and start accepting connections.
    ///
    /// Binds to loopback only. The router holds API keys, so exposing it on the
    /// LAN would hand those to anyone on the network. Loopback is not a trust
    /// boundary by itself — every other process running as this user can reach
    /// it — which is what `RouterAuth` is for.
    public func start(preferredPort: UInt16 = RouterConfiguration.defaultPort) throws {
        // Claimed before the bind rather than after it, so a second concurrent
        // `start()` is refused instead of binding a port it will then have to
        // give back. Released by `abandonStart()` if the bind does not
        // complete, which is the path a failed start takes.
        try claimStart()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: preferredPort) ?? .any
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            abandonStart()
            throw error
        }

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
            abandonStart()
            throw RouterError.upstream("listener did not become ready within 5s")
        }
        if let startError {
            listener.cancel()
            abandonStart()
            throw RouterError.upstream("\(startError)")
        }

        let bound = listener.port?.rawValue ?? preferredPort
        commitStart(port: bound, listener: listener)
        log.write("router listening on http://127.0.0.1:\(bound)")
    }

    public func stop() {
        // Cancelled with no lock held: `cancel()` completes asynchronously, and
        // calling it under the lock would leave `port` and `isRunning`
        // unreachable for however long Network.framework takes to get round to
        // it — the shape of bug this whole type was reviewed for.
        detachListener()?.cancel()
        log.write("router stopped")
    }

    // MARK: Lifecycle state

    /// Take the router for a start, or throw if a start already holds it.
    private func claimStart() throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        guard !_claiming, !_isRunning else { throw RouterError.alreadyRunning(_port) }
        _claiming = true
    }

    /// Record a bind that succeeded.
    private func commitStart(port: UInt16, listener: NWListener) {
        lifecycleLock.lock()
        _port = port
        _listener = listener
        _isRunning = true
        _claiming = false
        lifecycleLock.unlock()
    }

    /// Give back a claim whose bind did not complete.
    ///
    /// Without this a start that failed would hold the router forever: the
    /// claim is what refuses the next `start()`, so one failed bind would make
    /// the router unstartable for the life of the process.
    private func abandonStart() {
        lifecycleLock.lock()
        _claiming = false
        _listener = nil
        lifecycleLock.unlock()
    }

    /// Mark the router stopped and hand the listener back, so the caller can
    /// cancel it outside the lock.
    private func detachListener() -> NWListener? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        _isRunning = false
        let current = _listener
        _listener = nil
        return current
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
                    // A parse failure carries the status the peer should see;
                    // an oversized body is 413, not 400, so the client can tell
                    // "too big" from "not understood".
                    let status = (error as? HTTPParseError)?.statusCode ?? 400
                    self.send(
                        .apiError("\(error)", status: status, anthropicStyle: false),
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

        // First line of the access log, ahead of every gate — including the
        // origin check, which is precisely the one whose refusals are worth
        // seeing. It records that a request arrived and how big it was, and
        // decides nothing: whether a token was present is recorded, its value
        // never is. This is the file to read when the question is "did the
        // agent send anything at all", which a decision log cannot answer.
        // Whether a token was presented is decided *before* the literal, not
        // inside an interpolation in it. `request.header("x-api-key")` puts a
        // string literal inside an interpolation inside a literal, which the
        // Swift parser cannot see past — it reports the outer string as
        // unterminated and points at the wrong line.
        let presentedToken = request.header("x-api-key")?.isEmpty == false
            || request.header("authorization")?.isEmpty == false
        httpLog?.write(
            "\(request.method) \(request.path) \(request.body.count) bytes "
            + "token=\(presentedToken ? "yes" : "no")"
        )

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
            return try await handleCountTokens(request, configuration)

        case ("POST", "/v1/responses"), ("POST", "/responses"):
            return try await handleResponses(request, configuration)

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

    /// The client's own request bytes, with only the model name rewritten.
    ///
    /// This route exists so that nothing between the client and the model has an
    /// opinion about the request. Re-encoding `AnthropicRequest` would give it
    /// one, because that struct is deliberately a *partial* model: it declares
    /// the fields the router has to understand, and drops everything else on the
    /// way back out.
    ///
    ///   - `cache_control`, on a system block or a tool definition. Prompt
    ///     caching stops working, which is a cost the user pays with no message
    ///     to explain it.
    ///   - The `signature` on a `thinking` block. Anthropic requires it back on
    ///     the next turn, so a thinking conversation breaks on turn two.
    ///   - The payload of any block type the struct does not model:
    ///     `redacted_thinking` carries its content in `data`, and `.unknown`
    ///     re-encodes as a bare `{"type": ...}`.
    ///   - Every top-level field added after the struct was written.
    ///
    /// A lossy passthrough would be strictly worse than the translation it
    /// replaced — the same losses, plus a promise that there are none — so the
    /// body is parsed as a generic JSON tree, one key is replaced, and it is
    /// re-serialised with the unknown fields intact. When the model name does
    /// not change the caller forwards the original bytes and even this is
    /// skipped, which is the common case: an agent bound to this router already
    /// asks for the model it is going to get.
    /// Replace the top-level `model` in a request body, touching nothing else.
    ///
    /// Named for the operation rather than for a wire, because it never was
    /// Anthropic-specific: it parses a generic JSON tree, replaces one key, and
    /// re-serialises with every unknown field intact. The Anthropic passthrough
    /// and the Responses passthrough both need exactly this, and for the same
    /// reason — both wires carry more than this router models, so re-encoding
    /// through a decoded struct would drop the parts the client needs.
    private func passthroughBody(_ raw: Data, model: String) throws -> Data {
        guard case .object(var fields)? = try? JSONDecoder().decode(JSONValue.self, from: raw) else {
            throw RouterError.badRequest("body is not a JSON object")
        }
        fields["model"] = .string(model)
        return Data(JSONValue.object(fields).jsonString().utf8)
    }

    /// Read one top-level field out of a request body without decoding the rest.
    ///
    /// The Responses body is deliberately not modelled as a struct: it carries
    /// `reasoning` items, `encrypted_content`, hosted tools and
    /// `previous_response_id`, none of which this router has any business
    /// rewriting. The two fields it does need — the model, and whether the
    /// caller wants a stream — are read straight off the JSON tree.
    private func topLevelField(_ raw: Data, _ key: String) -> JSONValue? {
        guard case .object(let fields)? = try? JSONDecoder().decode(JSONValue.self, from: raw) else {
            return nil
        }
        return fields[key]
    }

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

        // What goes upstream on the native path: the client's bytes, with the
        // model name rewritten and nothing else touched. Built once here because
        // both the streaming and the buffered routes need it, and a second
        // construction site is a second chance to re-encode the decoded model by
        // accident — which is the mistake this replaced.
        let nativeBody = requested == anthropic.model
            ? data
            : try passthroughBody(data, model: anthropic.model)

        // Whether this backend serves the Anthropic wire is the provider's
        // answer, not a test restated here. `nil` means the router must
        // translate; a URL means the body goes out as it arrived.
        let messagesURL = provider.messagesURL
        // A translation is only reachable when the backend speaks OpenAI too.
        // Anthropic is the one kind that does not, so a 404 from it means the
        // user's endpoint is wrong and must be reported rather than routed
        // around — translating would post an OpenAI body to `/v1/messages`,
        // which is the same mistake in the other direction.
        let canTranslate = provider.kind.speaksOpenAI
        if requested != anthropic.model {
            log.write("model \(requested) → \(anthropic.model)")
        }
        log.write(
            "POST /v1/messages stream=\(streaming) kind=\(provider.kind.rawValue) "
            + "wire=\(messagesURL == nil ? "translated" : "native")"
        )

        if streaming {
            let inputTokens = TokenEstimator.estimate(anthropic)
            // Bound as a `let` so the streaming closure captures a value rather
            // than a mutable local, which Swift 6 rejects.
            let outbound = anthropic
            let head = HTTPResponse.stream(status: 200, headers: Self.sseHeaders)
            let plan: @Sendable (StreamSink) async -> Void = { [weak self] sink in
                guard let self else { return }
                do {
                    if let messagesURL {
                        do {
                            try await self.forwardAnthropicStream(
                                nativeBody,
                                provider: provider,
                                url: messagesURL,
                                sink: sink
                            )
                            return
                        } catch let missing as MissingRoute where canTranslate {
                            // The response head has already gone out, but
                            // nothing has been written into the body yet — the
                            // passthrough checks the upstream's status before it
                            // forwards a byte, which is exactly what makes this
                            // fallback invisible to the client. Doing it after
                            // the first frame would splice a translated stream
                            // onto the tail of a native one.
                            self.log.write(
                                "\(provider.name) does not serve \(missing.path) "
                                + "(HTTP \(missing.status)) — translating this request "
                                + "instead: \(missing.detail.prefix(160))"
                            )
                        }
                    }
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
                } catch {
                    self.log.writeError("stream failed: \(error)")
                    sink.send(AnthropicSSE.error("\(error)"))
                }
            }
            return .stream(head, plan)
        }

        if let messagesURL {
            let (responseData, status) = try await post(
                provider: provider,
                url: messagesURL,
                body: nativeBody
            )
            // Every status is passed through verbatim — including the failures —
            // except the one that means "this route is not here", and only when
            // there is a wire to fall back to. A 400 from a backend that does
            // speak the Anthropic wire names the offending field, and
            // re-framing it through a translation would trade a precise error
            // for a vague one.
            if !(Self.routeIsAbsent(status) && canTranslate) {
                return .respond(.buffered(
                    status: status,
                    headers: ["Content-Type": "application/json"],
                    body: responseData
                ))
            }
            log.write(
                "\(provider.name) does not serve \(messagesURL.path) (HTTP \(status)) "
                + "— translating this request instead"
            )
        }

        let translatedRequest = Translation.request(anthropic)
        // The notes were built by every call site and read by none. A drop the
        // user is never told about is indistinguishable from a bug in the
        // model, which is the whole reason the translation records them.
        log.writeTranslation(translatedRequest.notes, route: "anthropic→openai")
        var openAI = translatedRequest.request
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

    /// Answer a token count, measured wherever the backend can measure it.
    ///
    /// This route used to estimate unconditionally, on the reasoning that most
    /// OpenAI-compatible servers have no counting endpoint and that an error or
    /// a zero is worse than an approximation. The first half of that is still
    /// true and the conclusion no longer follows: llama-server serves
    /// `/v1/messages/count_tokens` itself, in Anthropic's own shape, so for the
    /// one backend this app actually supervises the approximation can be
    /// replaced by a measurement — and the approximation kept as the fallback
    /// for the backends that still cannot answer.
    ///
    /// Measured, that endpoint returns `{"input_tokens":18}` for
    /// `"Hello, how are you today?"`, where the estimate says 11, and 213 for a
    /// one-line request carrying a system prompt and a tool schema, where the
    /// estimate says 70. The gap is the chat template: the estimate counts the
    /// characters it can see and the backend counts the characters it will
    /// actually be fed, plus every role marker the template wraps them in. On a
    /// tool-bearing request — which is every real Claude Code turn — the schema
    /// dominates and the estimate is low by a factor of three, in the one
    /// direction the estimate's own comment calls dangerous.
    ///
    /// The reply is `input_tokens` and nothing else, whichever path produced
    /// it. Provenance goes to the log rather than into the body: this is
    /// Anthropic's endpoint, a client is entitled to Anthropic's shape, and an
    /// extra key is the kind of thing a strict client rejects.
    private func handleCountTokens(
        _ request: HTTPRequest,
        _ configuration: RouterConfiguration
    ) async throws -> RouteOutcome {
        guard let data = request.body.isEmpty ? nil : request.body,
              let anthropic = try? JSONDecoder().decode(AnthropicRequest.self, from: data) else {
            throw RouterError.badRequest("body is not an Anthropic messages request")
        }

        let count = await measuredTokenCount(body: data, configuration: configuration)
            ?? TokenCount(tokens: TokenEstimator.estimate(anthropic), source: .estimated)

        log.write(
            "POST /v1/messages/count_tokens → \(count.tokens) tokens (\(count.source.rawValue))"
        )
        return .respond(.json(.object(["input_tokens": .number(Double(count.tokens))])))
    }

    /// Ask the backend to count, when there is one that can.
    ///
    /// `nil` on every failure — no provider selected, no endpoint for this
    /// kind, a 404, a timeout, an unreadable reply — because all of them mean
    /// the same thing to this route: it still has to answer, and the estimate
    /// is the answer it has always given. Nothing is reported as measured
    /// unless the backend measured it, which is what keeps the provenance
    /// honest rather than merely present.
    ///
    /// A 404 or 405 is remembered, because it is the one failure that is a
    /// fact about the backend rather than about this request. Everything else
    /// is left to be retried: a timeout means the server was busy, not that it
    /// cannot count.
    private func measuredTokenCount(
        body: Data,
        configuration: RouterConfiguration
    ) async -> TokenCount? {
        guard let provider = configuration.provider,
              let url = provider.countTokensURL,
              tokenCountCapability.supports(provider)
        else { return nil }

        do {
            let (data, status) = try await post(
                provider: provider,
                url: url,
                body: body,
                session: countingSession
            )
            guard (200..<300).contains(status) else {
                if Self.routeIsAbsent(status) {
                    tokenCountCapability.markUnsupported(provider)
                    log.write(
                        "count_tokens: \(provider.kind.rawValue) at "
                        + "\(provider.normalizedBaseURL) has no counting endpoint "
                        + "(HTTP \(status)) — estimating from here on"
                    )
                }
                return nil
            }
            guard let tokens = TokenCountReply.decode(data) else { return nil }
            return TokenCount(tokens: tokens, source: .measured)
        } catch {
            // Deliberately not logged. A backend that is simply not running
            // fails here on every turn, and the estimate covers it silently —
            // the same silence a completion failure would not get, because a
            // completion has no fallback to fall back to.
            return nil
        }
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
        //
        // `stream` is forced off outbound, and that is the whole fix for a
        // guaranteed 500. `Translation.anthropicRequest` copies the caller's
        // `stream` straight through, Anthropic answers a streaming request with
        // `text/event-stream`, and the code below decodes a single
        // `AnthropicResponse` from it — so every `stream: true` call from Codex
        // or Gemini CLI against an Anthropic provider failed, after the upstream
        // had already been paid for the turn.
        //
        // Forwarding the event stream instead is not an option: the caller parses
        // OpenAI chunks and would not understand `content_block_delta`. So the
        // answer is fetched whole and re-framed as OpenAI chunks below.
        let translatedRequest = Translation.anthropicRequest(from: openAI)
        log.writeTranslation(translatedRequest.notes, route: "openai→anthropic")
        var anthropic = translatedRequest.request
        anthropic.stream = false

        if streaming {
            // Bound as a `let` so the streaming closure captures a value rather
            // than a mutable local, which Swift 6 rejects.
            let outbound = anthropic
            let head = HTTPResponse.stream(status: 200, headers: Self.sseHeaders)
            let plan: @Sendable (StreamSink) async -> Void = { [weak self] sink in
                guard let self else { return }
                await self.pipeTranslatedAnthropic(
                    provider: provider,
                    body: outbound,
                    sink: sink
                )
            }
            return .stream(head, plan)
        }

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
        let reply = Translation.openAIResponse(from: decoded)
        log.writeTranslation(reply.notes, route: "anthropic→openai")
        return .respond(.buffered(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: try JSONEncoder().encode(reply.response)
        ))
    }

    // MARK: /v1/responses

    /// Serve OpenAI's Responses wire, forwarded rather than translated.
    ///
    /// Not optional and not a nice-to-have. OpenAI deprecated `chat/completions`
    /// for Codex on 2025-12-09 and removed it in early February 2026; from that
    /// point Codex speaks `/v1/responses` and nothing else, and a config
    /// carrying `wire_api = "chat"` is a hard startup error. The deprecation
    /// notice addresses gateway operators directly — "ensure your proxy
    /// supports the `responses` API" — and for a local model this router *is*
    /// that proxy.
    ///
    /// The body goes out with the model name rewritten and nothing else touched,
    /// for the reason the Anthropic passthrough exists: the Responses shape is
    /// richer than this router models. It carries `reasoning` items,
    /// `encrypted_content`, hosted tools and `previous_response_id`, and
    /// re-encoding through a decoded struct would drop precisely the parts a
    /// reasoning client needs. Verified live against llama-server, whose reply
    /// carries a `reasoning` item with `encrypted_content` — the thing 2.2
    /// recorded as unachievable on the OpenAI *chat* wire, and achievable here
    /// only because the backend produces it rather than a translator inventing
    /// it.
    ///
    /// No translation is offered for a backend without the route. Responses ⇄
    /// Messages is the large, lossy job 2.2 already declined, and a confident
    /// half-translation is worse than a 404 that says which backend is missing
    /// what.
    private func handleResponses(
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
        guard let url = provider.responsesURL else {
            // A kind with no Responses route at all. Naming the kind is the
            // point: the user's next question is "why", and the answer is a
            // property of the backend kind, not of the URL they typed.
            throw RouterError.badRequest(
                "a \(provider.kind.rawValue) backend has no Responses API, so there "
                + "is nowhere to send /v1/responses. Codex requires this wire — point "
                + "the agent at a backend that serves it (llama-server and OpenAI both "
                + "do), or pin that agent to a Codex old enough to still accept "
                + "wire_api = \"chat\"."
            )
        }

        let raw = request.body
        let requested = topLevelField(raw, "model")?.stringValue ?? ""
        let model = resolveModel(requested, configuration)
        // Skipped entirely when the name does not change, which is the common
        // case: an agent bound to this router already asks for the model it is
        // going to get, and a byte-identical forward is the safest one.
        let body = requested == model ? raw : try passthroughBody(raw, model: model)
        let streaming = topLevelField(raw, "stream")?.boolValue == true

        log.write("POST /v1/responses stream=\(streaming) kind=\(provider.kind.rawValue)")

        if streaming {
            let head = HTTPResponse.stream(status: 200, headers: Self.sseHeaders)
            let plan: @Sendable (StreamSink) async -> Void = { [weak self] sink in
                guard let self else { return }
                await self.pipeRawResponses(provider: provider, url: url, body: body, sink: sink)
            }
            return .stream(head, plan)
        }

        let (data, status) = try await post(provider: provider, url: url, body: body)
        guard (200..<300).contains(status) else {
            // A backend in this kind that does not actually serve the route.
            // Reported as the backend's own verdict with the endpoint named,
            // rather than retried in another shape: there is no other shape
            // that a Responses client would accept.
            throw RouterError.upstream(
                "\(provider.normalizedBaseURL) answered HTTP \(status) for "
                + "/v1/responses: \(String(decoding: data.prefix(300), as: UTF8.self))"
            )
        }
        return .respond(.buffered(
            status: 200,
            headers: ["Content-Type": "application/json"],
            body: data
        ))
    }

    /// Pass a Responses SSE stream through untouched.
    ///
    /// The same shape as `pipeRawUpstream`, which is deliberate: both hand the
    /// client's own bytes back and neither parses an event. The Responses stream
    /// is a different event vocabulary (`response.output_text.delta`,
    /// `response.reasoning_summary_text.delta`, `response.completed`), so a
    /// parser here would be a second place to be wrong about it.
    private func pipeRawResponses(
        provider: Provider,
        url: URL,
        body: Data,
        sink: StreamSink
    ) async {
        do {
            let request = try makeUpstreamRequest(provider: provider, url: url, body: body)
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
                if pending.suffix(2) == Data("\n\n".utf8) {
                    sink.send(String(decoding: pending, as: UTF8.self))
                    pending.removeAll(keepingCapacity: true)
                } else if pending.count >= 8192 {
                    // A count, not a boundary, so it has to land between scalars.
                    let safe = pending.utf8ScalarPrefixLength
                    guard safe > 0 else { continue }
                    sink.send(String(decoding: pending.prefix(safe), as: UTF8.self))
                    pending.removeFirst(safe)
                }
            }
            if !pending.isEmpty { sink.send(String(decoding: pending, as: UTF8.self)) }
        } catch {
            log.writeError("responses passthrough failed: \(error)")
            sink.send(Self.openAIErrorFrame(error))
        }
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
    /// reads the same way whichever route found it down. `session` is a
    /// parameter for the same reason: the token-count probe wants a short
    /// budget rather than the 600 seconds a completion needs, and a second copy
    /// of this method would be a second place for the unreachable-backend
    /// message to drift out of date.
    private func performUpstreamRequest(
        _ request: URLRequest,
        provider: Provider,
        session: URLSession? = nil
    ) async throws -> (Data, Int) {
        do {
            let (data, response) = try await (session ?? self.session).data(for: request)
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

    /// A status that means "this backend does not serve that route", as opposed
    /// to "this backend read the request and refused it".
    ///
    /// Only the first is safe to answer with a second request in a different
    /// shape. 405 is included with 404 because a server that knows the path but
    /// not the method is telling the router the same thing — this endpoint is
    /// not what you think it is — and a proxy or a static file handler in front
    /// of the backend answers one or the other depending on its own routing.
    private static func routeIsAbsent(_ status: Int) -> Bool {
        status == 404 || status == 405
    }

    private func post(
        provider: Provider,
        url: URL?,
        body: Data,
        session: URLSession? = nil
    ) async throws -> (Data, Int) {
        try await performUpstreamRequest(
            makeUpstreamRequest(provider: provider, url: url, body: body),
            provider: provider,
            session: session
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
    /// Used when the backend serves the Anthropic wire itself: Anthropic, and
    /// llama-server, which accepts `/v1/messages` and converts it internally.
    /// Translating and translating back would only lose `cache_control`,
    /// thinking signatures and tool-use ids.
    ///
    /// `url` is the backend's messages endpoint and is passed in rather than
    /// derived, because `chatURL` is *not* it for a llama-server: that would be
    /// `/chat/completions`, and posting an Anthropic body there is the specific
    /// mistake this route exists to avoid.
    private func forwardAnthropicStream(
        _ body: Data,
        provider: Provider,
        url: URL,
        sink: StreamSink
    ) async throws {
        // Started before the upstream is contacted, for the same reason as the
        // translated path: the wait for the first token is the longest silence
        // and the one the client's watchdog is most likely to see.
        let keepAlive = StreamKeepAlive(interval: keepAliveInterval, sink: sink)
        keepAlive.start()

        do {
            let request = try makeUpstreamRequest(provider: provider, url: url, body: body)
            let (bytes, response) = try await session.bytes(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw RouterError.upstream("response was not HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                var data = Data()
                for try await byte in bytes { data.append(byte) }
                let detail = String(decoding: data.prefix(400), as: UTF8.self)
                // A route that is not there is the one upstream failure the
                // router can route around, so it is raised as its own type
                // rather than as a message. Every other status — 400, 401, 429,
                // 500 — is the backend's verdict on a request it did
                // understand, and answering it with a second request in a
                // different shape would only produce a second error.
                if Self.routeIsAbsent(http.statusCode) {
                    throw MissingRoute(
                        status: http.statusCode,
                        path: url.path,
                        detail: detail
                    )
                }
                throw RouterError.upstream("HTTP \(http.statusCode): \(detail)")
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
                    // Volume flush, for an upstream that never sends the blank
                    // line. The cut has to land between scalars: decoding a
                    // severed one yields U+FFFD now, and again for the bytes
                    // that would have completed it, by which point they are
                    // gone. See `utf8ScalarPrefixLength`.
                    let safe = pending.utf8ScalarPrefixLength
                    guard safe > 0 else { continue }
                    sink.send(String(decoding: pending.prefix(safe), as: UTF8.self))
                    pending.removeFirst(safe)
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
        let translatedRequest = Translation.request(anthropic)
        log.writeTranslation(translatedRequest.notes, route: "anthropic→openai")
        var upstream = translatedRequest.request
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

        /// The upstream's own failure, when it reports one inside the stream.
        ///
        /// Once set, the byte loop stops feeding the translator. The reason is
        /// the whole point of this: the terminal events that follow an upstream
        /// error would otherwise close the message normally, and a client that
        /// asked a question would be handed a successful empty answer instead of
        /// being told the backend failed.
        var upstreamError: String?

        func ingest(_ event: SSEEvent) {
            guard upstreamError == nil, !event.isDone, !event.data.isEmpty else { return }
            guard let data = event.data.data(using: .utf8) else { return }

            // Checked *before* the decode, because an error chunk carries no
            // `choices` and so cannot decode as a response at all — it was
            // swallowed by the same `try?` that exists to tolerate a malformed
            // token delta.
            if let message = Translation.streamError(inChunk: data) {
                upstreamError = message
                return
            }
            guard let chunk = try? decoder.decode(OpenAIChatResponse.self, from: data) else {
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
                // A newline is always a safe cut — every byte of a multi-byte
                // scalar is 0x80 or greater, and 0x0A is not — but a cut at a
                // byte *count* is not, so that one takes whole scalars only.
                if byte == 0x0A {
                    let text = String(decoding: pending, as: UTF8.self)
                    pending.removeAll(keepingCapacity: true)
                    for event in parser.feed(text) { ingest(event) }
                } else if pending.count >= 1024 {
                    let safe = pending.utf8ScalarPrefixLength
                    guard safe > 0 else { continue }
                    let text = String(decoding: pending.prefix(safe), as: UTF8.self)
                    pending.removeFirst(safe)
                    for event in parser.feed(text) { ingest(event) }
                }
                // Nothing after an upstream failure is worth reading. Breaking
                // here rather than draining the socket also means a server that
                // holds the connection open after its error cannot stall the
                // client.
                if upstreamError != nil { break }
            }
            if upstreamError == nil {
                if !pending.isEmpty {
                    for event in parser.feed(String(decoding: pending, as: UTF8.self)) { ingest(event) }
                }
                for event in parser.flush() { ingest(event) }
            }
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

        if let upstreamError {
            // The failure is reported *instead of* a normal close, not before
            // one. `finalize()` would write `message_delta` and `message_stop`,
            // and a client that reads those has been told the answer is
            // complete — which turns a backend failure into a confident empty
            // reply. Anthropic's own stream ends at `error` with no
            // `message_stop`, so that is what this sends.
            log.writeError("upstream failed mid-stream: \(upstreamError)")
            sink.send(AnthropicSSE.error(upstreamError))
            return
        }

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
                if pending.suffix(2) == Data("\n\n".utf8) {
                    sink.send(String(decoding: pending, as: UTF8.self))
                    pending.removeAll(keepingCapacity: true)
                } else if pending.count >= 8192 {
                    // The blank line above is a safe cut; this one is a count,
                    // so it has to land between scalars.
                    let safe = pending.utf8ScalarPrefixLength
                    guard safe > 0 else { continue }
                    sink.send(String(decoding: pending.prefix(safe), as: UTF8.self))
                    pending.removeFirst(safe)
                }
            }
            if !pending.isEmpty { sink.send(String(decoding: pending, as: UTF8.self)) }
        } catch {
            log.writeError("raw passthrough failed: \(error)")
            sink.send(Self.openAIErrorFrame(error))
        }
    }

    /// Fetch a complete answer from an Anthropic upstream and re-frame it as an
    /// OpenAI SSE stream.
    ///
    /// Reached when the caller speaks OpenAI, asked for `stream: true`, and the
    /// selected provider is natively Anthropic. The request handed in already has
    /// `stream` forced off — see the call site — because the alternative was a
    /// guaranteed 500: Anthropic answers a streaming request with
    /// `text/event-stream`, and no single `AnthropicResponse` can be decoded from
    /// that.
    ///
    /// Deliberately not incremental. Translating Anthropic events into OpenAI
    /// chunks as they arrive would be the better answer and is a larger job; this
    /// is the honest version of "correct, whole answer, one burst".
    private func pipeTranslatedAnthropic(
        provider: Provider,
        body: AnthropicRequest,
        sink: StreamSink
    ) async {
        do {
            let request = try makeUpstreamRequest(
                provider: provider,
                url: provider.chatURL,
                body: try JSONEncoder().encode(body)
            )
            let (data, response) = try await session.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw RouterError.upstream("response was not HTTP")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw RouterError.upstream(
                    "HTTP \(http.statusCode): \(String(decoding: data.prefix(400), as: UTF8.self))"
                )
            }
            guard let decoded = try? JSONDecoder().decode(AnthropicResponse.self, from: data) else {
                throw RouterError.upstream("reply was not an Anthropic message")
            }

            let reply = Translation.openAIResponse(from: decoded)
            log.writeTranslation(reply.notes, route: "anthropic→openai")
            for frame in Translation.openAISSEFrames(from: reply.response) {
                sink.send(frame)
            }
        } catch {
            log.writeError("anthropic→openai stream failed: \(error)")
            sink.send(Self.openAIErrorFrame(error))
        }
    }

    /// An error, framed the way an OpenAI streaming client expects.
    ///
    /// Built through `JSONValue` rather than by interpolation. The message
    /// routinely carries an upstream body verbatim — quotes, backslashes and all
    /// — and splicing that into a JSON string produced a frame no client could
    /// parse, which turns a reportable upstream error into a silent protocol
    /// failure. The Anthropic side has always encoded its error frames through
    /// `JSONValue`; this is the OpenAI half catching up.
    private static func openAIErrorFrame(_ error: Error) -> String {
        SSEWriter.frame(data: JSONValue.object([
            "error": .object([
                "type": .string("api_error"),
                "message": .string("\(error)"),
            ])
        ]).jsonString())
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

    /// Where this request actually goes, after aliases.
    ///
    /// Two questions in one place, in this order:
    ///
    ///   1. **Is the requested name an alias?** If so the supervisor is asked
    ///      for the backend behind it, and asking is what *starts* the model —
    ///      this call is the whole of "on-demand load", which is why no "serve"
    ///      button is needed anywhere.
    ///   2. Otherwise the configured pair, with `resolveModel`'s usual rewrite.
    ///
    /// An alias is checked **first**, and that ordering is load-bearing. The
    /// configured model is a catch-all for names this router has not heard of,
    /// so consulting it first would swallow every alias the moment a provider
    /// happened to advertise a model with the same name — the alias would
    /// resolve, or not, depending on what some backend's `/v1/models` said.
    ///
    /// A failure to *start* an alias propagates rather than falling back to the
    /// configured model. Falling back would answer a request for `coder` with a
    /// different model and no indication that anything went wrong, which is
    /// worse than an error naming the model that would not load.
    private func target(
        for requested: String,
        provider configured: Provider,
        model configuredModel: String
    ) async throws -> (provider: Provider, model: String) {
        guard let serving = state.serving, !requested.isEmpty else {
            return (configured, resolveModel(requested, configuredModel: configuredModel, configuration: nil))
        }

        let isAlias = serving.knownAliases.contains {
            $0.caseInsensitiveCompare(requested) == .orderedSame
        }
        guard isAlias, let resolved = try await serving.backend(for: requested) else {
            return (configured, resolveModel(requested, configuredModel: configuredModel, configuration: nil))
        }

        log.write(
            "alias \(requested) → \(resolved.models.first ?? configuredModel) "
            + "on \(resolved.normalizedBaseURL)"
        )
        return (resolved, resolved.models.first ?? configuredModel)
    }

    /// `resolveModel`, for the alias path where there is no configuration to
    /// consult — only the configured model name to fall back to.
    private func resolveModel(
        _ requested: String,
        configuredModel: String,
        configuration: RouterConfiguration?
    ) -> String {
        guard let configuration else {
            return requested.isEmpty ? configuredModel : requested
        }
        return resolveModel(requested, configuration)
    }
}
