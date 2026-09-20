import Foundation

// MARK: - Supervising llama-server
//
// A served local model is a child process that has to be started, waited for,
// watched, and — the part that is easy to get wrong — reliably stopped. The
// failure mode of getting that wrong is not a crash, it is a `llama-server`
// still holding gigabytes of memory and a port after the app that started it is
// gone, which the user then has to hunt down and kill by hand.
//
// Two decisions follow from that:
//
//   1. **The child runs inside the sandbox environment.** It inherits the
//      private `$HOME` and `TMPDIR`, so a runtime that writes a cache or a
//      config writes it inside the sandbox. The same isolation that keeps Claude
//      Code out of `~/.claude` keeps llama.cpp out of `~/.cache`.
//
//   2. **Startup is confirmed by asking the server, not by watching the
//      process.** A `llama-server` that fails to load a model stays alive and
//      prints an error; a process-exit check would call that success. The health
//      endpoint is the only honest signal, so `start()` polls it and fails with
//      the log tail if the server never becomes healthy.

public enum LlamaServerError: Error, CustomStringConvertible {
    case binaryMissing(URL)
    case launchFailed(String)
    case noFreePort(preferred: Int)
    case didNotBecomeHealthy(seconds: Double, logTail: String)
    case exited(code: Int32, logTail: String)

    public var description: String {
        switch self {
        case .binaryMissing(let url):
            return "llama-server was not found at \(url.path)"
        case .launchFailed(let detail):
            return "could not start llama-server: \(detail)"
        case .noFreePort(let preferred):
            return "no free port at or above \(preferred)"
        case .didNotBecomeHealthy(let seconds, let tail):
            return "llama-server did not become healthy within \(Int(seconds))s.\n\(tail)"
        case .exited(let code, let tail):
            return "llama-server exited with status \(code) before becoming healthy.\n\(tail)"
        }
    }
}

public struct LlamaServerConfiguration: Sendable {
    public var binary: URL
    public var plan: OptimizationPlan
    public var host: String
    public var port: Int
    public var logURL: URL
    public var capabilities: LlamaServerCapabilities
    /// How long to wait for the health endpoint before giving up. Loading a
    /// multi-gigabyte model from disk takes a while; a short timeout here would
    /// report failure for a server that was about to work.
    public var startupTimeout: TimeInterval

    public init(
        binary: URL,
        plan: OptimizationPlan,
        host: String = "127.0.0.1",
        port: Int = 8_080,
        logURL: URL,
        capabilities: LlamaServerCapabilities = .assumedModern,
        startupTimeout: TimeInterval = 180
    ) {
        self.binary = binary
        self.plan = plan
        self.host = host
        self.port = port
        self.logURL = logURL
        self.capabilities = capabilities
        self.startupTimeout = startupTimeout
    }

    /// The URL agents and the router should talk to.
    public var baseURL: String {
        "http://\(host):\(port)"
    }

    /// The full argument list, with the server-level flags added to the model
    /// flags the optimiser produced.
    public var arguments: [String] { arguments(using: capabilities) }

    /// The same list built against capabilities read from a specific binary.
    ///
    /// Separate from `arguments` so `LlamaServer.start()` can build argv from
    /// what the binary actually reports instead of what this value assumed —
    /// no caller has to remember to pass capabilities in.
    public func arguments(using capabilities: LlamaServerCapabilities) -> [String] {
        var arguments = capabilities.adapt(plan.arguments)
        arguments.append(LlamaArgument(
            flag: "--host",
            value: host,
            reason: "loopback only — the server is not reachable from the network",
            category: .server
        ))
        arguments.append(LlamaArgument(
            flag: "--port",
            value: String(port),
            reason: "the port the router will forward to",
            category: .server
        ))

        var argv: [String] = []
        for argument in arguments {
            argv.append(argument.flag)
            if let value = argument.value { argv.append(value) }
        }
        return argv
    }
}

/// A running (or failed) llama-server.
public final class LlamaServer: @unchecked Sendable {

    public enum State: Equatable {
        case stopped
        case starting
        case running(port: Int, pid: Int32)
        case failed(String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        public var description: String {
            switch self {
            case .stopped:  return "stopped"
            case .starting: return "starting"
            case .running(let port, let pid): return "running on port \(port) (pid \(pid))"
            case .failed(let message): return "failed: \(message)"
            }
        }
    }

    public let configuration: LlamaServerConfiguration
    private let paths: SandboxPaths
    private let environment: SandboxEnvironment

    private var process: Process?
    private var logHandle: FileHandle?

    /// All mutable state is touched only from this queue, which is what makes
    /// the `@unchecked Sendable` above sound.
    private let queue = DispatchQueue(label: "app.jxcode.llama-server")

    public private(set) var state: State = .stopped

    public init(
        configuration: LlamaServerConfiguration,
        paths: SandboxPaths = .default,
        environment: SandboxEnvironment? = nil
    ) {
        self.configuration = configuration
        self.paths = paths
        self.environment = environment ?? SandboxEnvironment(paths: paths)
    }

    /// The URL agents and the router should talk to.
    public var baseURL: String { configuration.baseURL }

    /// What the binary reported it accepts, once `start()` has asked.
    ///
    /// `nil` before the first start. Useful when a load fails: the assumed set
    /// and the real set are the first thing to compare.
    public private(set) var resolvedCapabilities: LlamaServerCapabilities?

    // MARK: Starting

    /// Launch the server and wait until it answers its health endpoint.
    public func start() async throws {
        guard FileManager.default.isExecutableFile(atPath: configuration.binary.path) else {
            throw LlamaServerError.binaryMissing(configuration.binary)
        }

        // Ask the binary what it accepts instead of trusting the configured
        // guess. Assuming cost nothing in a test and everything on a real
        // machine: a wrong `-fa` spelling makes llama.cpp swallow the next
        // argument and exit before it loads a model.
        let resolved = await LlamaServerCapabilities.probe(binary: configuration.binary)
            ?? configuration.capabilities
        resolvedCapabilities = resolved

        let process = Process()
        process.executableURL = configuration.binary
        process.arguments = configuration.arguments(using: resolved)
        // The child inherits the sandbox, so anything it writes stays inside it.
        process.environment = environment.build()

        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: configuration.logURL.path) {
            FileManager.default.createFile(atPath: configuration.logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: configuration.logURL) else {
            throw LlamaServerError.launchFailed("could not open the log at \(configuration.logURL.path)")
        }
        // Append rather than truncate: a restart should not erase the previous
        // run's output, which is usually the one that explains the failure.
        _ = try? handle.seekToEnd()
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice

        self.logHandle = handle
        self.process = process
        state = .starting

        do {
            try process.run()
        } catch {
            state = .failed("\(error)")
            try? handle.close()
            throw LlamaServerError.launchFailed("\(error)")
        }

        let pid = process.processIdentifier

        do {
            try await waitUntilHealthy(process: process)
        } catch {
            // A server that never became healthy is of no use, and leaving it
            // running would hold its memory until the app exits.
            stop()
            state = .failed("\(error)")
            throw error
        }

        state = .running(port: configuration.port, pid: pid)
    }

    private func waitUntilHealthy(process: Process) async throws {
        let deadline = Date().addingTimeInterval(configuration.startupTimeout)
        let health = URL(string: "http://\(configuration.host):\(configuration.port)/health")

        while Date() < deadline {
            // A process that has already exited will never become healthy, so
            // fail immediately with its output rather than waiting out the
            // whole timeout — the log says what went wrong and the user wants
            // to see it now.
            if !process.isRunning {
                let code = process.terminationStatus
                throw LlamaServerError.exited(code: code, logTail: logTail())
            }

            if let health, await Self.isHealthy(health) {
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        throw LlamaServerError.didNotBecomeHealthy(
            seconds: configuration.startupTimeout,
            logTail: logTail()
        )
    }

    static func isHealthy(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        // Health is about reachability, not freshness.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: Stopping

    /// Stop the server, escalating from SIGTERM to SIGKILL.
    ///
    /// llama-server unloads a multi-gigabyte model on SIGTERM, which takes a
    /// moment. Killing it outright would work but risks leaving the Metal
    /// allocation in a state the next launch has to clean up, so it is given a
    /// chance to exit on its own first.
    public func stop(timeout: TimeInterval = 10) {
        // The process is captured under the queue and waited on outside it.
        // The wait runs for as long as the model takes to unload — seconds —
        // and holding the lock across it would stall every other reader,
        // `isProcessAlive` most of all, which is what has to observe the exit.
        let running = queue.sync { () -> Process? in
            guard let process = self.process, process.isRunning else { return nil }
            return process
        }

        guard let process = running else {
            queue.sync {
                cleanup()
                state = .stopped
            }
            return
        }

        process.terminate()   // SIGTERM

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(100_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            // Reaping is asynchronous; give the kernel a moment so the pid is
            // not still allocated when this returns.
            usleep(200_000)
        }

        queue.sync {
            cleanup()
            state = .stopped
        }
    }

    private func cleanup() {
        try? logHandle?.close()
        logHandle = nil
        process = nil
    }

    // MARK: Log

    /// The last few kilobytes of the server's output.
    ///
    /// Read from the end rather than the whole file: llama-server logs a line
    /// per token in verbose mode, and a long session's log is not something to
    /// load into memory to show the last twenty lines.
    public func logTail(maxBytes: Int = 16_384) -> String {
        guard let handle = try? FileHandle(forReadingFrom: configuration.logURL) else { return "" }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd(), end > 0 else { return "" }
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return "" }

        var text = String(decoding: data, as: UTF8.self)
        // A tail that begins mid-line begins with a fragment; drop it.
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }

    // MARK: What the server actually loaded

    /// Ask the running server what it loaded, rather than assuming.
    ///
    /// The plan is a *prediction* derived from a GGUF header; this is the
    /// server's own account, and the only thing that can contradict it. The
    /// difference matters most for the chat template: a template that resolves
    /// but cannot express a tool call produces an agent that answers in prose,
    /// with no error anywhere.
    ///
    /// Returns `nil` when the server does not answer, which is not the same as
    /// a server that reports nothing useful — callers should fall back to the
    /// plan rather than reporting a failure.
    ///
    /// `/props` is served at the server root. `/v1/props` is a 404 on this
    /// build, so it is not tried.
    public func props() async -> ServerProps? {
        guard let url = URL(string: "\(baseURL)/props") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200 else { return nil }

        return ServerProps(data: data)
    }

    /// Compare what the server loaded against what the plan asked for.
    ///
    /// Convenience so callers do not have to remember which plan fields the
    /// comparison needs. An unreachable server yields an empty array: a missing
    /// answer is not a disagreement.
    public func disagreementsWithPlan() async -> [String] {
        guard let props = await props() else { return [] }
        return props.disagreements(
            expectedVision: configuration.plan.mmprojPath != nil,
            requestedContext: configuration.plan.contextLength,
            expectedSlots: 1
        )
    }

    /// Whether the server answers its health endpoint *right now*.
    ///
    /// `start()` proves the server was healthy once, and says nothing about the
    /// hours after. A server that exhausts memory, or is killed from outside,
    /// leaves every caller still believing the model is loaded. This is the
    /// check to poll.
    public func checkHealth() async -> Bool {
        guard let url = URL(string: "\(baseURL)/health") else { return false }
        return await Self.isHealthy(url)
    }

    /// Whether the underlying process is still alive.
    ///
    /// Deliberately separate from health. A running process that does not
    /// answer is a transient problem worth retrying; a process that has exited
    /// can never answer again, and the caller needs to say so rather than
    /// showing a spinner forever.
    public var isProcessAlive: Bool {
        queue.sync { state.isRunning }
    }

    deinit {
        // Last line of defence against an orphaned server holding memory. The
        // app also stops servers explicitly; this covers the paths where it
        // does not get the chance.
        if let process, process.isRunning {
            process.terminate()
        }
        try? logHandle?.close()
    }
}

// MARK: - Ports

public enum PortAllocator {

    /// Whether a loopback TCP port could be bound by a server right now.
    ///
    /// `SO_REUSEADDR` is set before the probe, and that detail is the whole
    /// point. Without it, a port that a just-stopped server left with
    /// connections in `TIME_WAIT` reports as occupied — the probe would be
    /// stricter than any real server, which is the opposite of useful. With it,
    /// the answer matches what actually matters: could llama-server bind here?
    ///
    /// A port with a *live listener* still reports as taken, because
    /// `SO_REUSEADDR` does not permit two active TCP listeners on one address.
    /// So this correctly distinguishes "still running" from "recently stopped".
    public static func isFree(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var reuse: Int32 = 1
        setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuse,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    /// The first free port at or above `preferred`.
    ///
    /// Scanning upward rather than asking for an arbitrary port keeps the
    /// chosen port predictable, which matters because it is written into agent
    /// config files that a person may read.
    public static func firstFree(from preferred: Int, attempts: Int = 32) -> Int? {
        for offset in 0..<attempts {
            let port = preferred + offset
            guard port > 0, port < 65_536 else { break }
            if isFree(port) { return port }
        }
        return nil
    }
}
