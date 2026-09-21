import Foundation

public struct CommandResult: Sendable {
    public let executable: String
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    /// True when the command was killed for running past its timeout rather
    /// than exiting on its own.
    ///
    /// Worth carrying separately because the two are indistinguishable from the
    /// status alone — a terminated process reports 15, which reads as an
    /// ordinary failure — and the difference decides whether retrying is
    /// sensible.
    public let timedOut: Bool

    public init(
        executable: String,
        exitCode: Int32,
        stdout: String,
        stderr: String,
        timedOut: Bool = false
    ) {
        self.executable = executable
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var succeeded: Bool { exitCode == 0 }

    /// Combined output with trailing whitespace removed. Convenient for
    /// assertions and for `jxcode run`.
    public var combined: String {
        (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum CommandError: Error, CustomStringConvertible {
    case executableNotFound(String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .executableNotFound(let path): return "not executable: \(path)"
        case .launchFailed(let message): return "launch failed: \(message)"
        }
    }
}

/// Runs a short-lived, non-interactive command inside the sandbox and captures
/// its output.
///
/// Interactive tabs use `PTYSession`; this is for one-shot commands (probes,
/// `npm i -g`, version checks) where clean pipes beat terminal emulation.
public enum CommandRunner {

    public static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String],
        workingDirectory: String,
        timeout: TimeInterval = 300
    ) throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw CommandError.executableNotFound(executable)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        /// One reader, one handle, read once to the end.
        ///
        /// Touched by its own queue and by nobody else until the group has
        /// completed, which is the happens-before that lets `data` be read
        /// afterwards without a lock.
        final class Reader: @unchecked Sendable {
            let handle: FileHandle
            private(set) var data = Data()

            init(_ handle: FileHandle) { self.handle = handle }

            func read() { data.append(handle.readDataToEndOfFile()) }
        }

        let outReader = Reader(outPipe.fileHandleForReading)
        let errReader = Reader(errPipe.fileHandleForReading)

        do {
            try process.run()
        } catch {
            throw CommandError.launchFailed(error.localizedDescription)
        }

        // Read both pipes concurrently, each on a queue of its own. Draining
        // them while we wait is the point: a pipe buffer that fills while we
        // block on the process would deadlock the child.
        //
        // Deliberately not `readabilityHandler`. Tearing one down cannot be
        // synchronised with an invocation already in flight — setting it to nil
        // does not stop a handler that is between `availableData` and the append
        // that follows it — so a `readDataToEndOfFile` afterwards reads the same
        // handle from another thread, and the late chunk is appended *after* the
        // rest rather than before it. Two readers that each own one handle have
        // nothing to tear down.
        //
        // Started after a successful launch so a failed one leaves no reader
        // waiting on a pipe nobody will ever close.
        let group = DispatchGroup()
        DispatchQueue(label: "jxcode.command-runner.stdout")
            .async(group: group) { outReader.read() }
        DispatchQueue(label: "jxcode.command-runner.stderr")
            .async(group: group) { errReader.read() }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            usleep(200_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        group.wait()
        // Both pipes reached EOF, so the process has already exited; reaping it
        // is what makes `terminationStatus` meaningful.
        process.waitUntilExit()

        return CommandResult(
            executable: executable,
            exitCode: process.terminationStatus,
            stdout: String(decoding: outReader.data, as: UTF8.self),
            stderr: String(decoding: errReader.data, as: UTF8.self),
            timedOut: timedOut
        )
    }
}

/// Resolves a bare command name against a sandbox `PATH`.
///
/// Deliberately does not consult the host `PATH`, so a name that only exists on
/// the host resolves to `nil` rather than silently escaping the sandbox.
public enum ExecutableResolver {

    public static func resolve(_ name: String, environment: [String: String]) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        let searchPath = environment["PATH"] ?? "/usr/bin:/bin"
        for directory in searchPath.split(separator: ":") {
            let candidate = "\(directory)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
