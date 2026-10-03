import Foundation

// MARK: - Model lifecycle, llama-swap style
//
// The limitation this removes is a UX one, not a technical one: today a served
// model is stopped when the pane closes, because an orphaned `llama-server`
// holds gigabytes and a port and the user has to hunt it down. That is the
// problem llama-swap exists to solve, so the model is adopted rather than the
// binary — a supervisor that starts a model when something asks for it, stops
// it when nothing has for a while, and says what it is doing.
//
// Four decisions, each of which could have gone the other way:
//
//   1. **Nothing is loaded until a request needs it.** No "serve" button, and
//      no eager load at startup. A model that is loaded but unused is a model
//      that is holding memory another model could be using, and the app is
//      often used with several models bound to different agents.
//
//   2. **Idle is measured from the last *use*, not the last start.** A long
//      generation would otherwise be unloaded mid-flight, which is a failure
//      that reads as the model crashing.
//
//   3. **A server that cannot be asked whether it is busy is not unloaded.**
//      The two errors are not symmetric: holding memory for another sweep is
//      recoverable in seconds, and killing a generation the user is waiting on
//      is not. So the sweep refuses to act on an unreadable answer — unless the
//      process is already gone, in which case there is nothing to kill.
//
//   4. **The timer is not the only path.** A laptop that sleeps does not fire
//      timers, so `sweep()` is also callable directly — from `jxcode local
//      sweep`, and from the pane. The timer is a convenience, not the
//      mechanism.
//
// The file this type lives in is `ModelSupervisor.swift` and not
// `LlamaServerSupervisor.swift` because the latter already exists and holds
// `LlamaServer` itself — the process, as opposed to the thing that decides
// when to have one.

/// A model that is loaded and answering right now.
public struct RunningModel: Sendable, Equatable {
    public var alias: String
    public var modelPath: String
    public var displayName: String
    public var port: Int
    public var pid: Int32
    public var startedAt: Date
    /// When the last request for this alias arrived. What the idle timer is
    /// measured from — see decision 2 at the top of this file.
    public var lastUsedAt: Date
    /// Seconds of idleness after which this is unloaded. `0` means never.
    public var idleTimeout: TimeInterval
    /// The window the server reports, when it has been asked.
    public var contextLength: Int?
    public var logURL: URL
    /// How many requests this server has answered since it started.
    public var uses: Int

    public init(
        alias: String,
        modelPath: String,
        displayName: String,
        port: Int,
        pid: Int32,
        startedAt: Date,
        lastUsedAt: Date,
        idleTimeout: TimeInterval,
        contextLength: Int? = nil,
        logURL: URL,
        uses: Int = 0
    ) {
        self.alias = alias
        self.modelPath = modelPath
        self.displayName = displayName
        self.port = port
        self.pid = pid
        self.startedAt = startedAt
        self.lastUsedAt = lastUsedAt
        self.idleTimeout = idleTimeout
        self.contextLength = contextLength
        self.logURL = logURL
        self.uses = uses
    }

    public var baseURL: String { "http://127.0.0.1:\(port)" }

    public var filename: String { URL(fileURLWithPath: modelPath).lastPathComponent }

    public func idleFor(now: Date) -> TimeInterval { max(0, now.timeIntervalSince(lastUsedAt)) }

    /// Seconds of idleness still allowed, or `nil` when this never unloads.
    public func idleBudgetRemaining(now: Date) -> TimeInterval? {
        guard idleTimeout > 0 else { return nil }
        return idleTimeout - idleFor(now: now)
    }

    /// Whether the idle timer has expired.
    public var unloadsWhenIdle: Bool { idleTimeout > 0 }

    /// A one-line account for a list row.
    public func summary(now: Date) -> String {
        var parts = ["port \(port)", "pid \(pid)"]
        if let contextLength { parts.append("\(contextLength / 1024)k context") }
        parts.append("\(uses) request\(uses == 1 ? "" : "s")")
        guard let remaining = idleBudgetRemaining(now: now) else {
            parts.append("kept loaded until stopped")
            return parts.joined(separator: " · ")
        }
        if remaining <= 0 {
            parts.append("idle — due to unload")
        } else {
            parts.append("unloads in \(Self.duration(remaining))")
        }
        return parts.joined(separator: " · ")
    }

    /// A duration in the words the panes and the terminal both use.
    ///
    /// Public because it is vocabulary rather than an implementation detail:
    /// "15m 0s" has to read the same in `jxcode local` and in the Models pane,
    /// and a second formatter is a second answer to the same question.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3_600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3_600)h \((total % 3_600) / 60)m"
    }
}

/// What a running server says about itself right now.
///
/// Five cases rather than two, because the four failures need four different
/// responses from whoever is reading this: a server that is still loading is
/// worth waiting for, one that answers badly is worth reading the log for, one
/// that is not listening at all means the process died, and one that never
/// started is a configuration problem.
public enum ServerHealth: Sendable, Equatable {
    case ok
    /// Started, not yet answering. The only case worth retrying.
    case starting
    /// The process is alive and nothing answered on the port.
    case unreachable(String)
    /// The endpoint answered with a status that is not 200.
    case unhealthy(status: Int, detail: String)
    /// The process is gone. Nothing to wait for.
    case gone(String)
    /// `start()` refused, or the server reported a load failure.
    case failed(String)

    public var isHealthy: Bool { self == .ok }

    public var description: String {
        switch self {
        case .ok:                   return "healthy"
        case .starting:             return "starting — the model is still loading"
        case .unreachable(let why): return "not answering: \(why)"
        case .unhealthy(let status, let detail):
            return "answered HTTP \(status): \(detail)"
        case .gone(let why):        return "not running: \(why)"
        case .failed(let why):      return "failed: \(why)"
        }
    }
}

/// A reading of llama-server's Prometheus endpoint.
///
/// Parsed generically rather than against a fixed field list, because the set
/// of metrics is the build's business and not this app's. The accessors below
/// name only the counters verified present in llama.cpp build 10150 on this
/// machine — every one of them observed in a real `/metrics` body, not taken
/// from a document. Notably absent from that body: any KV-cache gauge. The
/// plan's bullet mentions `/metrics` and this is what the endpoint actually
/// carries, so nothing here invents a number the server never reported.
public struct ServerMetrics: Sendable, Equatable {
    /// Every sample, keyed by the metric name with any `prefix:` removed —
    /// this build writes `llamacpp:prompt_tokens_total`, and a future build
    /// that drops the prefix should not silently empty this dictionary.
    public var values: [String: Double]
    public var raw: String

    public init(values: [String: Double], raw: String) {
        self.values = values
        self.raw = raw
    }

    public static func parse(_ text: String) -> ServerMetrics {
        var values: [String: Double] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `# HELP` and `# TYPE` are commentary; only samples have a value.
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2,
                  let value = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { continue }
            let name = parts[0].split(separator: ":").last.map(String.init) ?? String(parts[0])
            values[name] = value
        }
        return ServerMetrics(values: values, raw: text)
    }

    public subscript(name: String) -> Double? { values[name] }

    public var promptTokens: Double? { values["prompt_tokens_total"] }
    public var predictedTokens: Double? { values["tokens_predicted_total"] }
    public var promptTokensPerSecond: Double? { values["prompt_tokens_seconds"] }
    public var predictedTokensPerSecond: Double? { values["predicted_tokens_seconds"] }
    public var requestsProcessing: Double? { values["requests_processing"] }
    public var requestsDeferred: Double? { values["requests_deferred"] }
    public var decodes: Double? { values["n_decode_total"] }

    /// Whether the server has a request in flight.
    ///
    /// This is what stops the idle sweep from unloading a model mid-generation.
    /// A missing counter is read as "not busy" rather than "busy": a build that
    /// does not report it also does not report the flag that would make the
    /// answer meaningful, and `/slots` — which every build serves — is the
    /// check the supervisor actually relies on.
    public var isBusy: Bool { (values["requests_processing"] ?? 0) > 0 }
}

/// The answer to "what does /metrics say", including "it will not say".
public struct ServerMetricsReport: Sendable, Equatable {
    public var metrics: ServerMetrics?
    /// Why there is no reading. The server's own sentence where it has one.
    public var problem: String?

    public init(metrics: ServerMetrics? = nil, problem: String? = nil) {
        self.metrics = metrics
        self.problem = problem
    }

    public var hasMetrics: Bool { metrics != nil }
}

public enum ModelServingError: Error, LocalizedError {
    case unknownAlias(String, profile: String, known: [String])
    case noRuntime(String)
    case missingModel(URL)
    case unreadableModel(URL, String)
    case noFreePort(Int)

    public var errorDescription: String? {
        switch self {
        case .unknownAlias(let name, let profile, let known):
            let suggestion = known.isEmpty
                ? "No alias is bound in profile '\(profile)' at all — see `jxcode local`."
                : "Bound here: \(known.joined(separator: ", "))."
            return "'\(name)' is not an alias in profile '\(profile)'. \(suggestion)"
        case .noRuntime(let hint):
            return "no llama-server found, so no local model can be started. \(hint)"
        case .missingModel(let url):
            return "the alias points at \(url.path), and there is no file there. "
                + "Re-bind it with `jxcode local alias <name> <file.gguf>`."
        case .unreadableModel(let url, let why):
            return "\(url.lastPathComponent) could not be read as a GGUF model: \(why)"
        case .noFreePort(let preferred):
            return "no free port at or above \(preferred)"
        }
    }
}

/// Decides when a local model is loaded, and stops it when nothing is using it.
///
/// Implements `LocalModelServing`, which is the whole reason an agent asking for
/// `coder` can reach a model that was not running when the request arrived.
public final class LlamaServerSupervisor: @unchecked Sendable, LocalModelServing {

    /// The policies an alias inherits when it overrides nothing.
    public struct Defaults: Sendable, Equatable {
        public var memory: MemoryPolicy
        public var cache: CachePolicy
        public var sampling: SamplingPreset
        /// The port range to start looking at.
        public var preferredPort: Int

        public init(
            memory: MemoryPolicy = .safe,
            cache: CachePolicy = .balanced,
            sampling: SamplingPreset = SamplingPreset.default,
            preferredPort: Int = 8_080
        ) {
            self.memory = memory
            self.cache = cache
            self.sampling = sampling
            self.preferredPort = preferredPort
        }
    }

    private let store: ModelLifecycleStore
    private let paths: SandboxPaths
    private let environment: SandboxEnvironment
    private let scanner: ModelScanner
    private let locator: LlamaRuntimeLocator
    private let defaults: Defaults
    private let logs: ModelLogs
    /// The proxy stream, when the caller wants the supervisor's decisions in
    /// the same file as the router's. Optional so a test can run without one.
    private let log: RouterLog?

    /// A loaded server, plus the book it keeps about itself.
    private final class Entry {
        let server: LlamaServer
        var record: RunningModel

        init(server: LlamaServer, record: RunningModel) {
            self.server = server
            self.record = record
        }
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// One in-flight start per alias.
    ///
    /// A `Task` rather than a flag, because the second caller has to *wait* for
    /// the first one rather than be told no: two agents asking for `coder` in
    /// the same second is the ordinary case, not a race to refuse.
    private var starts: [String: Task<RunningModel, Error>] = [:]
    private var sweeper: Task<Void, Never>?

    public init(
        store: ModelLifecycleStore,
        paths: SandboxPaths = .default,
        environment: SandboxEnvironment? = nil,
        scanner: ModelScanner = ModelScanner(),
        locator: LlamaRuntimeLocator? = nil,
        defaults: Defaults = Defaults(),
        log: RouterLog? = nil
    ) {
        self.store = store
        self.paths = paths
        self.environment = environment ?? SandboxEnvironment(paths: paths)
        self.scanner = scanner
        self.locator = locator ?? LlamaRuntimeLocator(paths: paths)
        self.defaults = defaults
        self.logs = ModelLogs(paths: paths)
        self.log = log
    }

    // MARK: - What the router asks

    /// The aliases bound in the active profile.
    public var knownAliases: [String] { store.knownAliases }

    /// The backend that answers for `alias`, starting it if it was not running.
    ///
    /// `nil` — not an error — when the name is not an alias, which is how the
    /// router tells "this is ours" from "this is the configured model". A throw
    /// for a name this supervisor simply does not know would turn every request
    /// for a remote model into a 500.
    public func backend(for alias: String) async throws -> Provider? {
        guard let resolved = store.alias(named: alias) else { return nil }
        // `countingUse: true` — this call *is* a request, so a model it starts
        // has answered one. `start(alias:)` passes `false`, because loading a
        // model in order to look at it is not a request, and counting it would
        // print "1 request" beside a server that has served nothing.
        let record = try await ensureRunning(resolved, countingUse: true)

        return Provider(
            name: "\(record.displayName) (local · \(resolved.name))",
            kind: .localGGUF,
            baseURL: record.baseURL,
            // The name the router hands upstream. A llama-server ignores it and
            // serves what it loaded; the point is that the agent sees a model
            // it asked for rather than a path.
            models: [record.filename],
            contextLength: record.contextLength
        )
    }

    // MARK: - Starting

    /// Load a model now, without waiting for a request.
    @discardableResult
    public func start(alias: String) async throws -> RunningModel {
        guard let resolved = store.alias(named: alias) else {
            throw ModelServingError.unknownAlias(
                alias,
                profile: store.activeProfile.name,
                known: store.knownAliases
            )
        }
        return try await ensureRunning(resolved, countingUse: false)
    }

    private func ensureRunning(_ alias: ModelAlias, countingUse: Bool) async throws -> RunningModel {
        let key = alias.id

        if let existing = touch(key) { return existing }

        let task: Task<RunningModel, Error> = holding {
            if let inFlight = starts[key] { return inFlight }
            let created = Task { try await self.launch(alias, countingUse: countingUse) }
            starts[key] = created
            return created
        }

        do {
            let record = try await task.value
            // `withLock` rather than `lock()`/`unlock()` around a bare pair:
            // this is an async function, and the two-call form is unsafe there
            // — if anything between the calls ever suspends, the lock is held
            // across a suspension point and the cooperative thread pool can
            // deadlock. The scoped form cannot be half-applied.
            lock.withLock { starts[key] = nil }
            return record
        } catch {
            lock.withLock { starts[key] = nil }
            throw error
        }
    }

    /// Bump the idle clock and hand back the record — or `nil` if there is
    /// nothing usable under this key.
    ///
    /// The liveness check is the point. `LlamaServer.state` only changes when
    /// `stop()` is called, so a server that crashed, was killed, or lost its
    /// Metal allocation still reports `.running` forever. `kill(pid, 0)` is the
    /// one signal that says whether the process exists, and a stale entry that
    /// answered `true` here would make every later request fail against a port
    /// nothing is listening on.
    private func touch(_ key: String, at now: Date = Date()) -> RunningModel? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = entries[key] else { return nil }
        guard Self.processExists(entry.record.pid) else {
            entries[key] = nil
            return nil
        }
        entry.record.lastUsedAt = now
        entry.record.uses += 1
        return entry.record
    }

    /// Note that a request has finished with an alias, without starting it.
    ///
    /// Called at the end of a stream as well as the start of one, because a
    /// generation that takes four minutes is four minutes of *use* — and with
    /// the TTL measured from the last use, the difference is whether a long
    /// answer survives its own delivery.
    public func noteUse(alias: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[alias.lowercased()] else { return }
        entry.record.lastUsedAt = Date()
    }

    private func launch(_ alias: ModelAlias, countingUse: Bool) async throws -> RunningModel {
        guard let runtime = locator.locate() else {
            throw ModelServingError.noRuntime(locator.installationHint)
        }

        let model = try localModel(at: alias.modelPath)
        let plan = plan(for: alias, model: model)

        guard let port = PortAllocator.firstFree(from: defaults.preferredPort) else {
            throw ModelServingError.noFreePort(defaults.preferredPort)
        }

        // Every stream this model will write to, created before the process
        // starts: a pane that opens a stream should show an empty file rather
        // than an error about a missing one.
        logs.prepare(.upstream)
        let modelLog = logs.prepare(.model, alias: alias.name)
            ?? paths.logs.appendingPathComponent("llama-server-\(ModelLogs.slug(alias.name)).log")

        let capabilities = LlamaServerCapabilities.cached(binary: runtime.binary)

        // `--metrics` is emitted only when the build defines it, like every
        // other flag here. Unlike the others the failure is not a startup
        // error: llama.cpp 10150 answers `501 not_supported_error` with the
        // sentence "Start it with `--metrics`", verified on this machine. So
        // without this line the Models pane's metrics card would show the
        // server's own complaint about a flag nobody asked it to add.
        var extras: [LlamaArgument] = []
        if capabilities.defines("--metrics") {
            extras.append(LlamaArgument(
                flag: "--metrics",
                reason: "the models pane reads /metrics; without this the server "
                    + "answers 501 and tells you so",
                category: .server
            ))
        }

        let server = LlamaServer(
            configuration: LlamaServerConfiguration(
                binary: runtime.binary,
                plan: plan,
                port: port,
                logURL: modelLog,
                // The same bytes, twice. `modelLog` answers "what did this
                // model say"; `upstream.log` answers "did anything else start
                // while it was still loading", which no single model's log can.
                mirrorLogURL: logs.fileURL(.upstream),
                capabilities: capabilities,
                extraArguments: extras
            ),
            paths: paths,
            environment: environment
        )

        write("loading \(alias.name) → \(model.displayName) on port \(port)")

        do {
            try await server.start()
        } catch {
            write("\(alias.name) failed to load: \(error)")
            throw error
        }

        // Ask the server what it loaded rather than trusting the plan. The
        // window is the number an agent is told about, and only the server
        // knows whether it clamped it.
        let props = await server.props()
        let now = Date()

        let record = RunningModel(
            alias: alias.name,
            modelPath: model.modelPath ?? alias.modelPath,
            displayName: model.displayName,
            port: port,
            pid: server.state.pid ?? 0,
            startedAt: now,
            lastUsedAt: now,
            idleTimeout: alias.idleTimeout ?? store.activeProfile.idleTimeout,
            contextLength: props?.agentContextLength ?? plan.contextLength,
            logURL: modelLog,
            // Zero unless the caller was answering a request. This was a
            // hardcoded `1`, which is right on the router path — the load was
            // caused by a request — and wrong on `start(alias:)`, where it made
            // `jxcode local serve` report "1 request" for a server that had
            // answered none. A count that is correct by accident is one that
            // will be wrong by accident.
            uses: countingUse ? 1 : 0
        )

        // Scoped because this is an async function — see the note on the `starts`
        // cleanup above.
        lock.withLock {
            entries[alias.id] = Entry(server: server, record: record)
        }

        write("\(alias.name) is serving \(model.displayName) on \(record.baseURL)"
            + (record.idleTimeout > 0
                ? ", unloading after \(RunningModel.duration(record.idleTimeout)) idle"
                : ", kept loaded until stopped"))
        return record
    }

    private func plan(for alias: ModelAlias, model: LocalModel) -> OptimizationPlan {
        let optimizer = ModelOptimizer(
            hardware: .current(),
            policy: alias.memory ?? defaults.memory,
            cachePolicy: alias.cache ?? defaults.cache,
            sampling: alias.sampling ?? defaults.sampling,
            capabilities: locator.capabilities()
        )
        // A plan can only fail on a model whose metadata could not be read,
        // and `localModel(at:)` already refused those — so falling back to the
        // same optimizer's *safe* policy keeps this total without inventing a
        // second error path that no caller could act on differently.
        return (try? optimizer.plan(for: model))
            ?? (try! ModelOptimizer(hardware: .current(), policy: .safe).plan(for: model))
    }

    /// The scanned model behind an alias, with its projector paired.
    ///
    /// The scan is of the model's own directory, so a projector sitting beside
    /// the model is found without the user naming it — the same behaviour
    /// `jxcode serve` has, and for the same reason: a vision model served
    /// without its projector answers text-only with no error anywhere.
    private func localModel(at path: String) throws -> LocalModel {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ModelServingError.missingModel(url)
        }

        let directory = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        let scan = scanner.scan(roots: [directory])
        let resolved = url.resolvingSymlinksInPath().path

        if let match = scan.models.first(where: {
            $0.model.url.path == url.path
                || $0.model.resolvedURL?.path == resolved
                || $0.modelPath == resolved
        }) {
            return match
        }

        if isDirectory.boolValue, let first = scan.models.first { return first }

        if let unreadable = scan.unreadable.first(where: { $0.url.path == url.path }) {
            throw ModelServingError.unreadableModel(
                url,
                unreadable.readError ?? (unreadable.isDangling ? "broken symlink" : "unreadable")
            )
        }
        throw ModelServingError.unreadableModel(url, "not a GGUF model")
    }

    // MARK: - Stopping

    /// Unload one alias. `true` when something was actually stopped.
    @discardableResult
    public func stop(alias: String) async -> Bool {
        let key = alias.lowercased()
        let entry: Entry? = holding {
            let entry = entries[key]
            entries[key] = nil
            return entry
        }
        guard let entry else { return false }

        await Self.stopServer(entry.server)
        write("\(entry.record.alias) unloaded (pid \(entry.record.pid))")
        return true
    }

    /// Unload everything. Called on the way out of the app, and by `stopAll`.
    public func stopAll() async {
        let all: [Entry] = holding {
            let all = Array(entries.values)
            entries.removeAll()
            return all
        }
        guard !all.isEmpty else { return }

        for entry in all { await Self.stopServer(entry.server) }
        write("unloaded \(all.count) model\(all.count == 1 ? "" : "s")")
    }

    /// Stop a server off the calling thread.
    ///
    /// `LlamaServer.stop()` waits for the model to unload, which is seconds.
    /// Called from a view that is the frozen window this whole app has been
    /// reviewed for, so it goes to a detached task and is awaited from an
    /// `async` context that is not the main actor.
    private static func stopServer(_ server: LlamaServer) async {
        await Task.detached(priority: .userInitiated) { server.stop() }.value
    }

    /// Stop everything, blocking until each model has unloaded.
    ///
    /// The synchronous twin of `stopAll()`, for one caller: `AppState.shutdown()`.
    /// `applicationWillTerminate` runs once and the process exits the moment it
    /// returns, so a `Task` started there never runs — which is how a served
    /// model comes to outlive the app that served it, holding gigabytes and a
    /// port. Blocking during quit is the right trade; blocking while the window
    /// is on screen is not, which is why the async version is the default.
    public func stopAllBlocking() {
        let all: [Entry] = holding {
            let all = Array(entries.values)
            entries.removeAll()
            return all
        }
        guard !all.isEmpty else { return }

        for entry in all {
            entry.server.stop()
            write("\(entry.record.alias) unloaded (pid \(entry.record.pid))")
        }
    }

    // MARK: - The idle sweep

    /// Unload every model that has been idle past its own timeout.
    ///
    /// Returns the aliases it stopped, so a caller can report something more
    /// useful than "done". Never unloads a server that reports work in flight.
    @discardableResult
    public func sweep(now: Date = Date()) async -> [String] {
        let due: [Entry] = holding {
            entries.values.filter { entry in
                guard entry.record.unloadsWhenIdle else { return false }
                return entry.record.idleFor(now: now) >= entry.record.idleTimeout
            }
        }

        var stopped: [String] = []
        for entry in due {
            // Asked before it is killed, not after. A model producing tokens is
            // not idle however long it has been since the request arrived.
            switch await busy(entry.record) {
            case .some(true):
                noteUse(alias: entry.record.alias)
                continue
            case .some(false):
                break
            case .none:
                // Could not tell. Holding memory for one more sweep is
                // recoverable; killing a live generation is not — unless the
                // process is already gone, in which case there is nothing to
                // kill and the entry is pure bookkeeping.
                if Self.processExists(entry.record.pid) {
                    write("\(entry.record.alias) is idle but did not answer /slots — "
                        + "leaving it loaded rather than risk killing a generation")
                    continue
                }
            }

            let key = entry.record.alias.lowercased()
            let removed: Entry? = holding {
                guard entries[key] === entry else { return nil }
                entries[key] = nil
                return entry
            }
            guard let removed else { continue }

            await Self.stopServer(removed.server)
            stopped.append(removed.record.alias)
            write("\(removed.record.alias) unloaded after "
                + "\(RunningModel.duration(removed.record.idleFor(now: now))) idle")
        }
        return stopped
    }

    /// Whether the server has work in flight. `nil` when it cannot be asked.
    ///
    /// `/slots` rather than `/metrics`: every build serves `/slots` by default
    /// and `/metrics` is off unless `--metrics` was passed. Verified on this
    /// machine against llama-server 10150 — `/slots` answers 200 with
    /// `{"id":0,…,"is_processing":false}` while `/metrics` answers 501 on a
    /// server started without the flag.
    private func busy(_ record: RunningModel) async -> Bool? {
        guard let url = URL(string: "\(record.baseURL)/slots") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }

        guard case .array(let slots) = json else { return nil }
        return slots.contains { slot in
            slot.objectValue?["is_processing"]?.boolValue == true
        }
    }

    /// Start the background sweep.
    ///
    /// A no-op when one is already running, so the app can call it on every
    /// appearance without accumulating timers.
    public func startSweeping(interval: TimeInterval = 30) {
        lock.lock()
        defer { lock.unlock() }
        guard sweeper == nil else { return }

        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
                if Task.isCancelled { return }
                _ = await self?.sweep()
            }
        }
    }

    public func stopSweeping() {
        lock.lock()
        let task = sweeper
        sweeper = nil
        lock.unlock()
        task?.cancel()
    }

    // MARK: - Reading

    /// Every loaded model, with its idle clock already applied.
    public func running(now: Date = Date()) -> [RunningModel] {
        lock.lock()
        defer { lock.unlock() }
        return entries.values
            .map(\.record)
            .filter { Self.processExists($0.pid) }
            .sorted { $0.alias.lowercased() < $1.alias.lowercased() }
    }

    public func record(for alias: String) -> RunningModel? {
        lock.lock()
        defer { lock.unlock() }
        return entries[alias.lowercased()]?.record
    }

    public var loadedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    /// Ask a running server how it is.
    public func health(alias: String) async -> ServerHealth {
        guard let entry = entry(for: alias) else {
            return .gone("no server is running for '\(alias)'")
        }
        if !Self.processExists(entry.record.pid) {
            return .gone("pid \(entry.record.pid) is gone")
        }
        if case .starting = entry.server.state { return .starting }
        if case .failed(let message) = entry.server.state { return .failed(message) }

        guard let url = URL(string: "\(entry.record.baseURL)/health") else {
            return .unreachable("the record has no usable port")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .unreachable("the reply was not HTTP")
            }
            if http.statusCode == 200 { return .ok }
            let detail = String(decoding: data.prefix(300), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .unhealthy(status: http.statusCode, detail: detail)
        } catch {
            return .unreachable(error.localizedDescription)
        }
    }

    /// Read the server's Prometheus endpoint.
    ///
    /// The failure is reported rather than swallowed, because the most likely
    /// one is not a failure at all: a server started without `--metrics`
    /// answers `501 not_supported_error` and its body says exactly what to do.
    /// That sentence is carried through instead of being replaced by one this
    /// app made up.
    public func metrics(alias: String) async -> ServerMetricsReport {
        guard let entry = entry(for: alias) else {
            return ServerMetricsReport(problem: "no server is running for '\(alias)'")
        }
        guard let url = URL(string: "\(entry.record.baseURL)/metrics") else {
            return ServerMetricsReport(problem: "the record has no usable port")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ServerMetricsReport(problem: "the reply was not HTTP")
            }
            let text = String(decoding: data, as: UTF8.self)
            guard http.statusCode == 200 else {
                return ServerMetricsReport(problem: Self.errorMessage(in: text)
                    ?? "HTTP \(http.statusCode)")
            }
            return ServerMetricsReport(metrics: ServerMetrics.parse(text))
        } catch {
            return ServerMetricsReport(problem: error.localizedDescription)
        }
    }

    /// The `error.message` of a JSON error body, when there is one.
    ///
    /// Pulled out so the 501 above reads as the server's own sentence —
    /// "Start it with `--metrics`" — rather than as a status code the user has
    /// to go and look up.
    static func errorMessage(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              let message = root["error"]?.objectValue?["message"]?.stringValue,
              !message.isEmpty else { return nil }
        return message
    }

    /// The tail of one model's own log.
    public func logTail(alias: String, maxBytes: Int = 16_384) -> String {
        guard let entry = entry(for: alias) else { return "" }
        return entry.server.logTail(maxBytes: maxBytes)
    }

    private func entry(for alias: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entries[alias.lowercased()]
    }

    // MARK: - Helpers

    /// Whether a pid is still a live process.
    ///
    /// `kill(pid, 0)` and not `ps`: `/bin/ps` is not runnable from this app's
    /// sandbox, and a check that treats a failed `ps` as "the process is gone"
    /// reports a live server as dead. Signal 0 performs the permission and
    /// existence checks and delivers nothing.
    static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    private func write(_ message: String) {
        log?.write("lifecycle: \(message)")
    }

    /// Run `body` with the lock held.
    ///
    /// A helper rather than four `lock()`/`unlock()` pairs, because the failure
    /// mode of writing them out is an early `return` that skips the unlock —
    /// and a supervisor that deadlocks on its own lock is a window that stops
    /// responding rather than a test that goes red.
    private func holding<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
