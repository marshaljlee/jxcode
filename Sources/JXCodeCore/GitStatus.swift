import Dispatch
import Foundation

/// A snapshot of a workspace's git state, for the workspace list row.
///
/// Reading git state happens on every refresh and every workspace switch, so
/// the whole type is built around one rule: it must never throw and never
/// block. Every failure mode -- no git, no repository, no commits, a child
/// process that will not exit -- is expressed as a value, because the caller
/// is a UI row that has nowhere useful to put an exception.
public struct GitStatus: Sendable, Equatable, Codable {

    /// False for a plain directory, a missing path, or any read that failed.
    /// Callers use this as the single "should I show a git row at all" check.
    public let isRepository: Bool

    /// Short branch name. `nil` on a detached HEAD -- which is not an error.
    public let branch: String?

    public let isDetached: Bool

    /// Distinct tracked paths that differ from HEAD, staged or not. Porcelain
    /// v2 emits one entry per path, so a file edited and then staged counts
    /// once rather than twice.
    public let changedFiles: Int

    public let untrackedFiles: Int

    public let ahead: Int
    public let behind: Int

    /// Abbreviated HEAD commit. `nil` on an unborn branch.
    public let headShortSHA: String?

    public let lastCommitSubject: String?

    /// Non-nil only when the read itself failed. A directory that is simply
    /// not a repository is a normal state, not an error, and reports `nil`.
    public let error: String?

    /// Untracked files count as dirty: from the user's point of view they are
    /// uncommitted work that would be lost, which is exactly what the
    /// indicator is warning about.
    public var isDirty: Bool {
        isRepository && (changedFiles > 0 || untrackedFiles > 0)
    }

    /// Compact one-liner for a UI row, e.g. "main \u{00B7} 3 changed \u{00B7} 2 ahead".
    public var summary: String {
        if error != nil { return "git error" }
        if !isRepository { return "not a repository" }

        var parts: [String] = []
        if isDetached {
            parts.append(headShortSHA.map { "detached @ \($0)" } ?? "detached")
        } else {
            parts.append(branch ?? "unknown")
        }

        if changedFiles > 0 { parts.append("\(changedFiles) changed") }
        if untrackedFiles > 0 { parts.append("\(untrackedFiles) untracked") }
        if ahead > 0 { parts.append("\(ahead) ahead") }
        if behind > 0 { parts.append("\(behind) behind") }
        // A branch name alone reads like a truncated message, so say the quiet
        // part out loud.
        if parts.count == 1 { parts.append("clean") }

        return parts.joined(separator: " \u{00B7} ")
    }

    public init(
        isRepository: Bool,
        branch: String? = nil,
        isDetached: Bool = false,
        changedFiles: Int = 0,
        untrackedFiles: Int = 0,
        ahead: Int = 0,
        behind: Int = 0,
        headShortSHA: String? = nil,
        lastCommitSubject: String? = nil,
        error: String? = nil
    ) {
        self.isRepository = isRepository
        self.branch = branch
        self.isDetached = isDetached
        self.changedFiles = changedFiles
        self.untrackedFiles = untrackedFiles
        self.ahead = ahead
        self.behind = behind
        self.headShortSHA = headShortSHA
        self.lastCommitSubject = lastCommitSubject
        self.error = error
    }

    public static let notARepository = GitStatus(isRepository: false)

    // MARK: - Reading

    /// Every git call gets the same deadline. A workspace on a network volume
    /// or inside a huge monorepo can make `status` take seconds, and a row
    /// that blocks the main thread forever is worse than one that says
    /// "unknown".
    static let timeout: TimeInterval = 5

    /// Reads git state without ever throwing or hanging.
    ///
    /// - Parameters:
    ///   - path: Directory to inspect. Passed to git as `-C`, so a relative
    ///     path resolves against the current process directory.
    ///   - environment: Environment for the child process. `nil` inherits the
    ///     current process environment. Pass the sandbox environment when the
    ///     workspace is being viewed through an agent, since its rebuilt PATH
    ///     deliberately omits locations like `/opt/homebrew`.
    ///   - gitBinary: Overrides discovery. Useful for tests and for callers
    ///     that already know where their git lives.
    public static func read(
        at path: String,
        environment: [String: String]? = nil,
        gitBinary: URL? = nil
    ) -> GitStatus {
        let environment = environment ?? ProcessInfo.processInfo.environment

        let git: URL
        if let gitBinary {
            guard FileManager.default.isExecutableFile(atPath: gitBinary.path) else {
                return GitStatus(isRepository: false, error: "git is not executable at \(gitBinary.path)")
            }
            git = gitBinary
        } else if let located = locateGit(in: environment) {
            git = located
        } else {
            return GitStatus(isRepository: false, error: "git not found")
        }

        // Checked before launching git so a bad path reports the real problem
        // instead of git's "cannot change to" wrapper.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return GitStatus(isRepository: false, error: "no such directory: \(path)")
        }

        let childEnvironment = hardened(environment)

        // One invocation carries branch, ahead/behind, changed and untracked
        // counts. See `parse(porcelainV2:)` for the grammar.
        let status = run(
            git,
            ["-C", path, "status", "--porcelain=v2", "--branch"],
            environment: childEnvironment
        )

        if let launchFailure = status.launchFailure {
            return GitStatus(isRepository: false, error: "git failed to launch: \(launchFailure)")
        }
        if status.timedOut {
            return GitStatus(isRepository: false, error: "git status timed out after \(Int(timeout))s")
        }
        guard status.exitCode == 0 else {
            let message = firstLine(of: status.stderr)
            // Not being a repository is an ordinary answer to the question we
            // asked, so it does not get flagged as an error.
            if message.contains("not a git repository") { return .notARepository }
            return GitStatus(
                isRepository: false,
                error: message.isEmpty ? "git status failed (exit \(status.exitCode))" : message
            )
        }

        var parsed = parse(porcelainV2: status.stdout)

        // A second call is worth it only for the two fields porcelain v2 omits.
        // An unborn branch has no HEAD to log, and asking would just produce a
        // fatal on stderr, so it is skipped rather than tolerated.
        if let oid = parsed.oid {
            parsed.shortSHA = String(oid.prefix(7))
            if let log = run(
                git,
                ["-C", path, "log", "-1", "--pretty=%h%n%s"],
                environment: childEnvironment
            ).outputIfSuccessful {
                let lines = log.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
                if let sha = lines.first.map({ $0.trimmingCharacters(in: .whitespaces) }), !sha.isEmpty {
                    parsed.shortSHA = sha
                }
                if lines.count > 1 {
                    let subject = lines[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    parsed.subject = subject.isEmpty ? nil : subject
                }
            }
            // A failed log leaves the abbreviated SHA in place and the subject
            // nil: the status data the caller actually asked for is intact, so
            // it would be misleading to report the whole read as failed.
        }

        return GitStatus(
            isRepository: true,
            branch: parsed.branch,
            isDetached: parsed.isDetached,
            changedFiles: parsed.changed,
            untrackedFiles: parsed.untracked,
            ahead: parsed.ahead,
            behind: parsed.behind,
            headShortSHA: parsed.shortSHA,
            lastCommitSubject: parsed.subject,
            error: nil
        )
    }

    // MARK: - Porcelain v2 parsing

    /// Parses `git status --porcelain=v2 --branch`. The format, for reference:
    ///
    ///     # branch.oid <sha>          full HEAD sha, or "(initial)" when the
    ///                                branch has no commits yet
    ///     # branch.head <name>        short branch name, or "(detached)"
    ///     # branch.upstream <ref>     present only with an upstream
    ///     # branch.ab +<ahead> -<behind>   present only with an upstream
    ///     1 <XY> ... <path>          ordinary changed tracked entry
    ///     2 <XY> ... <path>          renamed/copied entry (path field differs)
    ///     u <XY> ... <path>          unmerged entry
    ///     ? <path>                   untracked
    ///     ! <path>                   ignored (only with --ignored)
    ///
    /// Only the leading byte of each entry matters here, so the variadic tail
    /// of the `1`/`2`/`u` forms is deliberately not decoded. Header lines are
    /// always `# `-prefixed, which keeps them from colliding with entries.
    private static func parse(porcelainV2 text: String) -> ParsedStatus {
        var parsed = ParsedStatus()

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            if line.hasPrefix("# branch.head ") {
                let value = String(line.dropFirst("# branch.head ".count))
                if value == "(detached)" {
                    parsed.isDetached = true
                    parsed.branch = nil
                } else if value != "(unknown)" {
                    parsed.branch = value
                }
            } else if line.hasPrefix("# branch.oid ") {
                let value = String(line.dropFirst("# branch.oid ".count))
                // "(initial)" means an unborn branch; there is no commit to
                // name, so HEAD fields stay nil instead of reporting a
                // placeholder as if it were a real sha.
                parsed.oid = value == "(initial)" ? nil : value
            } else if line.hasPrefix("# branch.ab ") {
                for token in line.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if token.hasPrefix("+") { parsed.ahead = Int(token.dropFirst()) ?? 0 }
                    if token.hasPrefix("-") { parsed.behind = Int(token.dropFirst()) ?? 0 }
                }
            } else if let first = line.first {
                switch first {
                case "1", "2", "u": parsed.changed += 1
                case "?": parsed.untracked += 1
                default: break
                }
            }
        }

        return parsed
    }

    private struct ParsedStatus {
        var branch: String?
        var isDetached = false
        var oid: String?
        var shortSHA: String?
        var subject: String?
        var changed = 0
        var untracked = 0
        var ahead = 0
        var behind = 0
    }

    // MARK: - Locating git

    /// Absolute locations tried before PATH, in order.
    ///
    /// The sandbox rebuilds PATH from scratch and intentionally excludes
    /// `/opt/homebrew`, so a workspace opened through an agent would otherwise
    /// look like it has no git at all even though the host has one.
    private static let gitCandidates = [
        "/usr/bin/git",
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
    ]

    private static func locateGit(in environment: [String: String]) -> URL? {
        for candidate in gitCandidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        let searchPath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for directory in searchPath.split(separator: ":") where !directory.isEmpty {
            let candidate = "\(directory)/git"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        return nil
    }

    /// Adds the two git settings that matter for a read that must not hang.
    ///
    /// `GIT_TERMINAL_PROMPT=0` stops a credential prompt from waiting on a
    /// terminal that does not exist, and `GIT_OPTIONAL_LOCKS=0` keeps a status
    /// probe from taking the index lock on a workspace an agent is editing.
    /// Existing caller values win, since the caller knows its environment.
    private static func hardened(_ environment: [String: String]) -> [String: String] {
        var result = environment
        if result["GIT_TERMINAL_PROMPT"] == nil { result["GIT_TERMINAL_PROMPT"] = "0" }
        if result["GIT_OPTIONAL_LOCKS"] == nil { result["GIT_OPTIONAL_LOCKS"] = "0" }
        return result
    }

    private static func firstLine(of text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    // MARK: - Process plumbing

    private struct RunResult {
        var exitCode: Int32 = -1
        var stdout = ""
        var stderr = ""
        var timedOut = false
        var launchFailure: String?

        /// Nil unless the command both exited zero and produced output.
        var outputIfSuccessful: String? {
            guard launchFailure == nil, !timedOut, exitCode == 0 else { return nil }
            return stdout
        }
    }

    /// Runs git under a hard deadline.
    ///
    /// Waits on a semaphore signalled from `terminationHandler` rather than on
    /// `waitUntilExit()`: the latter has no timeout, so a git wedged on a
    /// stalled network mount would pin the calling thread indefinitely.
    private static func run(
        _ git: URL,
        _ arguments: [String],
        environment: [String: String]
    ) -> RunResult {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let box = OutputBox()
        // Drained asynchronously: a pipe that fills while we are blocked
        // waiting for exit would deadlock the child.
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            box.appendStdout(chunk)
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            box.appendStderr(chunk)
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            var result = RunResult()
            result.launchFailure = error.localizedDescription
            return result
        }

        var result = RunResult()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            result.timedOut = true
            process.terminate()
            // SIGTERM can be ignored or, worse, swallowed by a shell wrapper,
            // so escalate rather than leave an orphan holding a pipe.
            if exited.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 1)
            }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        box.appendStdout(outPipe.fileHandleForReading.readDataToEndOfFile())
        box.appendStderr(errPipe.fileHandleForReading.readDataToEndOfFile())

        result.exitCode = process.terminationStatus
        result.stdout = box.stdout
        result.stderr = box.stderr
        return result
    }
}

/// Accumulator for the pipe readers, which run on arbitrary threads.
///
/// `@unchecked` is honest here: every access is behind the same lock, so there
/// is no state a reader could observe torn.
private final class OutputBox: @unchecked Sendable {

    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        stdoutData.append(data)
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        stderrData.append(data)
    }

    var stdout: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stdoutData, as: UTF8.self)
    }

    var stderr: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }
}
