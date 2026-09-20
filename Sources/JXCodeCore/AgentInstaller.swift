import Foundation

// MARK: - Installing an agent
//
// The launcher's promise is that clicking an agent installs it. What used to
// happen instead: `AppState.openTab` opened a *shell* tab and typed the install
// command into it 0.7 seconds later. Three things were wrong with that, and only
// the first was the reason it never worked.
//
//  1. `npm` is not on the sandbox `PATH`, so the command died with
//     `zsh: command not found: npm`. Nothing provided a JavaScript runtime —
//     see `NodeToolchain`.
//  2. Nothing read the exit status. The command could fail, or half-run, and
//     the app would not know: the user got a terminal with an error in it and
//     no agent. The tab that was supposed to be Claude Code was a shell.
//  3. Nothing retried. A dropped DNS lookup or a 429 from the registry failed
//     the click permanently, even though a second attempt would have worked.
//
// This type fixes all three. It runs the install as a one-shot command with
// captured output, retries the failures that can change, and then *verifies*
// the binary is on the sandbox `PATH` before reporting success — because npm
// exiting 0 is not the same thing as the agent existing.

public enum AgentInstaller {

    // MARK: - Results

    /// Which phase a failure belongs to, so the message can say something
    /// useful rather than "installation failed".
    public enum Stage: String, Sendable {
        /// No install command, or no JavaScript runtime to run it with.
        case toolchain
        /// The command ran and did not succeed.
        case download
        /// The command succeeded but produced nothing on the sandbox `PATH`.
        case verify
    }

    public struct Attempt: Sendable {
        public let index: Int
        public let exitCode: Int32
        public let timedOut: Bool
        public let output: String
    }

    public struct Outcome: Sendable {
        public enum Status: Sendable {
            case installed(path: String)
            case failed(stage: Stage, message: String)
        }

        public let agentID: String
        public let agentName: String
        public let attempts: [Attempt]
        public let status: Status

        public var succeeded: Bool {
            if case .installed = status { return true }
            return false
        }

        /// The message to show in a banner, or `nil` on success.
        public var failureMessage: String? {
            if case .failed(_, let message) = status { return message }
            return nil
        }

        /// Where the binary landed, or `nil`.
        public var installedPath: String? {
            if case .installed(let path) = status { return path }
            return nil
        }
    }

    // MARK: - Policy

    /// Three attempts. One failure is usually the network; three is enough to
    /// ride out a registry hiccup without leaving a user staring at a spinner.
    public static let defaultAttempts = 3

    /// Generous, because a cold `npm i -g` of Claude Code is tens of megabytes
    /// over a slow link and npm's own fetch timeout is already 300s.
    public static let defaultTimeout: TimeInterval = 900

    /// npm environment for a non-interactive, global install.
    ///
    /// The audit and fund calls are extra round trips to the registry that add
    /// nothing to `npm i -g` and are a common source of the transient failures
    /// the retry loop exists for. The fetch settings are npm's own retries,
    /// which are cheaper than ours because they resume rather than restart.
    public static let installEnvironment: [String: String] = [
        "NPM_CONFIG_AUDIT": "false",
        "NPM_CONFIG_FUND": "false",
        "NPM_CONFIG_UPDATE_NOTIFIER": "false",
        "NPM_CONFIG_PROGRESS": "false",
        "NPM_CONFIG_LOGLEVEL": "error",
        "NPM_CONFIG_FETCH_RETRIES": "3",
        "NPM_CONFIG_FETCH_RETRY_MINTIMEOUT": "20000",
        "NPM_CONFIG_FETCH_RETRY_MAXTIMEOUT": "120000",
        "NPM_CONFIG_FETCH_TIMEOUT": "300000",
        "CI": "1",
    ]

    // MARK: - Retry policy

    public enum Disposition: Equatable, Sendable {
        case retry
        case fatal
    }

    /// Output that means "trying again cannot help".
    ///
    /// Deliberately a short list, and deliberately checked before anything
    /// suggests retrying. Everything else is retried: the cost of one extra
    /// `npm i -g` is a few seconds, and the cost of *not* retrying is a
    /// first-click failure on a flaky network, which is the bug being fixed.
    static let fatalMarkers = [
        "code e404",
        "404 not found",
        "is not in this registry",
        "no matching version found",
        "eacces",
        "eperm",
        "enospc",
        "unknown command",
        "command not found",
    ]

    /// Whether another attempt could plausibly succeed.
    ///
    /// `exitCode` is accepted but not currently decisive — the interesting
    /// signal is in the text, and a bare status code cannot distinguish a DNS
    /// failure from a missing package. It stays in the signature because the
    /// caller has it and a future rule may need it.
    public static func classify(exitCode: Int32, output: String) -> Disposition {
        let haystack = output.lowercased()
        for marker in fatalMarkers where haystack.contains(marker) {
            return .fatal
        }
        return .retry
    }

    /// 2s, then 6s. Short enough that a user waiting on a click does not give
    /// up, long enough to clear a DNS hiccup or a rate-limit window.
    public static func backoff(afterFailure failure: Int) -> TimeInterval {
        let schedule: [TimeInterval] = [2, 6]
        return schedule[min(max(failure, 1), schedule.count) - 1]
    }

    // MARK: - Installing

    /// Install `agent` inside the sandbox, retrying what is worth retrying.
    ///
    /// Blocking by design: the caller runs it off the main actor. It reports
    /// progress through `onProgress` so the card can say what is happening
    /// instead of showing an unexplained spinner.
    public static func install(
        agent: AgentDefinition,
        sandbox: Sandbox,
        workspace: Workspace? = nil,
        maxAttempts: Int = AgentInstaller.defaultAttempts,
        timeout: TimeInterval = AgentInstaller.defaultTimeout,
        onProgress: ((String) -> Void)? = nil
    ) -> Outcome {
        let attempts = max(1, maxAttempts)

        func failure(_ stage: Stage, _ message: String, _ log: [Attempt] = []) -> Outcome {
            Outcome(agentID: agent.id, agentName: agent.name, attempts: log,
                    status: .failed(stage: stage, message: message))
        }

        guard let command = agent.installCommand,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return failure(.toolchain, "\(agent.name) has no install command, so there is nothing "
                + "to run. Add one with “Add an agent…”.")
        }

        // Stage 1 — the toolchain. This is the step that was missing entirely.
        onProgress?("Preparing the Node toolchain…")
        switch NodeToolchain.ensure(paths: sandbox.paths) {
        case .failure(let error):
            return failure(.toolchain, error.description)
        case .success:
            break
        }

        var log: [Attempt] = []

        for index in 1...attempts {
            if index > 1 {
                let delay = backoff(afterFailure: index - 1)
                onProgress?("Retrying in \(Int(delay))s…")
                Thread.sleep(forTimeInterval: delay)
            }
            onProgress?(attempts == 1
                ? "Installing \(agent.name)…"
                : "Installing \(agent.name) — attempt \(index) of \(attempts)…")

            let result: CommandResult
            do {
                result = try sandbox.run(
                    "/bin/zsh",
                    arguments: ["-lc", command],
                    workspace: workspace,
                    extraEnvironment: installEnvironment,
                    timeout: timeout
                )
            } catch {
                // The command could not even be started. Nothing about that is
                // improved by a different package, but it may be a transient
                // fork failure, so it is retried like anything else.
                log.append(Attempt(index: index, exitCode: -1, timedOut: false,
                                   output: "\(error)"))
                continue
            }

            let output = result.combined
            log.append(Attempt(index: index, exitCode: result.exitCode,
                               timedOut: result.timedOut, output: output))

            if result.succeeded {
                // Stage 3 — the exit code is not the answer.
                //
                // npm returns 0 for an install that left no bin link behind more
                // often than one would like, and "succeeded but nothing is
                // there" is exactly the silent failure this replaces. So the
                // binary has to be found on the sandbox PATH before this counts.
                let environment = sandbox.env(workspace: workspace)
                if let resolved = ExecutableResolver.resolve(agent.command, environment: environment) {
                    onProgress?("\(agent.name) installed.")
                    return Outcome(agentID: agent.id, agentName: agent.name, attempts: log,
                                   status: .installed(path: resolved))
                }
                onProgress?("\(agent.name) reported success but produced no \(agent.command) "
                    + "binary. Retrying…")
                continue
            }

            if classify(exitCode: result.exitCode, output: output) == .fatal { break }
        }

        let last = log.last
        let stage: Stage = (last?.exitCode == 0) ? .verify : .download
        return failure(stage, message(for: agent, log: log), log)
    }

    // MARK: - Explaining a failure

    /// The message a user reads when the click did not work.
    ///
    /// It ends with the tail of the real output, because the alternative — a
    /// generic "installation failed" — sends the user to a terminal to find out
    /// what happened, which is what the previous implementation made them do.
    static func message(for agent: AgentDefinition, log: [Attempt]) -> String {
        guard let last = log.last else {
            return "\(agent.name) could not be installed."
        }

        var message = "\(agent.name) could not be installed"
        message += log.count > 1 ? " after \(log.count) attempts." : "."

        if last.timedOut {
            message += " The install timed out after \(Int(defaultTimeout))s."
        }
        if let hint = hint(for: last.output) {
            message += " " + hint
        }

        let tail = last.output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(6)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            message += "\n\n" + tail
        }
        return message
    }

    /// A plain-language reading of the failure, when there is one worth giving.
    static func hint(for output: String) -> String? {
        let text = output.lowercased()

        if text.contains("command not found") {
            return "The install command needs a program that is not in the sandbox. "
                + "Open a tab and run `jx-where npm node` to see what resolves."
        }
        if text.contains("eai_again") || text.contains("enotfound") || text.contains("getaddrinfo") {
            return "The package registry could not be resolved. Check the network and try again."
        }
        if text.contains("etimedout") || text.contains("err_socket_timeout") {
            return "The registry stopped responding. Try again — npm resumes a partial download."
        }
        if text.contains("e429") || text.contains("429") || text.contains("too many requests") {
            return "The registry is rate-limiting this machine. Waiting a minute usually clears it."
        }
        if text.contains("eacces") || text.contains("eperm") {
            return "The sandbox prefix is not writable. `jxcode doctor` reports the details."
        }
        if text.contains("404") || text.contains("not in this registry") {
            return "The registry has no package by that name, so retrying will not help."
        }
        return nil
    }
}
