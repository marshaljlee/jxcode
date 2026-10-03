import Foundation

/// Other `llama-server` processes already running on this machine.
///
/// Apple Silicon shares memory between CPU and GPU, so a second model alongside
/// llama.app or Ollama usually fails with a Metal allocation error that reads
/// like a bug in this app. The reference implementations terminate those
/// processes outright; killing another application's process on the user's
/// behalf is hostile, so this reports them instead and lets the user decide.
///
/// This lives in the core rather than in the view layer because it spawns a
/// subprocess. Spawning one while a view was being evaluated meant blocking
/// whatever thread the view was on — the main thread, whenever the pane was
/// open — which is how a background check came to freeze the window.
public enum RunningServers {

    /// One line of `pgrep -fl` output.
    public struct Entry: Sendable, Equatable {
        public let pid: Int32
        public let command: String

        public init(pid: Int32, command: String) {
            self.pid = pid
            self.command = command
        }
    }

    /// Where `pgrep` lives.
    ///
    /// Absolute, and outside the sandbox on purpose: the processes being listed
    /// belong to other applications on the host, and a sandboxed `pgrep` cannot
    /// see them at all.
    private static let pgrepPath = "/usr/bin/pgrep"

    /// Processes whose full command line matches `pattern`.
    ///
    /// Async, and never blocking. `Process.waitUntilExit()` parks the calling
    /// thread until the child exits, which from the main actor freezes the
    /// window for the duration; the termination handler resumes a continuation
    /// instead, so the thread is released while the child runs.
    public static func list(matching pattern: String = "llama-server") async -> [Entry] {
        guard FileManager.default.isExecutableFile(atPath: pgrepPath) else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pgrepPath)
        process.arguments = ["-fl", pattern]
        process.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        // Drained while the child runs. A pipe buffer that fills with nobody
        // reading it blocks the child on write, so it never exits, so the
        // continuation below never resumes — a hang, not an error.
        let output = Collector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Installed before `run()`, not after: a process that exits between
            // the two calls would never fire a handler installed late, and the
            // continuation would wait forever for a child that is already gone.
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume()
            }
        }

        pipe.fileHandleForReading.readabilityHandler = nil
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())

        guard let text = String(data: output.snapshot(), encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// Turn `pgrep -fl` output into entries.
    ///
    /// `pgrep -fl` prints `pid command`, and with `-f` the command is the full
    /// path — which can itself begin with digits. The split is therefore
    /// bounded to one and the pid is taken from the first field only, rather
    /// than from whatever digit happens to appear first in the line.
    ///
    /// Separate from `list` so it can be tested without spawning anything.
    public static func parse(_ output: String) -> [Entry] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard let first = parts.first, let pid = Int32(first) else { return nil }
            return Entry(pid: pid, command: parts.count > 1 ? String(parts[1]) : "")
        }
    }

    /// Accumulates pipe output across the reader thread and this function.
    ///
    /// A class with its own lock rather than a captured `var`: the handler runs
    /// concurrently with the code that declared it, and mutating a captured
    /// local from it is a race the Swift 6 language mode rejects outright.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }
}
