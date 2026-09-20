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

        let lock = NSLock()
        var outData = Data()
        var errData = Data()

        // Read concurrently. A pipe buffer that fills while we block on
        // waitUntilExit would deadlock the child.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); outData.append(chunk); lock.unlock()
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock(); errData.append(chunk); lock.unlock()
        }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw CommandError.launchFailed(error.localizedDescription)
        }

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

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let outRest = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errRest = errPipe.fileHandleForReading.readDataToEndOfFile()
        lock.lock()
        outData.append(outRest)
        errData.append(errRest)
        lock.unlock()

        return CommandResult(
            executable: executable,
            exitCode: process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self),
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
