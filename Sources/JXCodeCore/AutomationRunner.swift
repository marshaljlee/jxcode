import Foundation

/// Runs the shared automations.
///
/// An automation is an agent plus a prompt plus a schedule. Running one means
/// starting that agent in a one-shot, non-interactive mode inside the sandbox
/// and recording what happened.
///
/// The per-agent knowledge is the invocation. Every agent spells "run this
/// prompt once and exit" differently, and getting it wrong does not fail
/// loudly — an unrecognised flag usually drops the agent into its interactive
/// TUI, which then blocks forever waiting for input that a scheduled run will
/// never provide. So only the invocations that are documented get an entry, and
/// anything else is reported as unsupported rather than attempted.
public enum AutomationRunner {

    /// What happened to one automation.
    public struct Result: Sendable {
        public var automationID: String
        public var automationName: String
        public var succeeded: Bool
        public var message: String
        public var ranAt: Date

        public var summary: String {
            "\(automationName): \(succeeded ? "ok" : "failed") — \(message)"
        }
    }

    // MARK: - Invocations

    /// The arguments that make an agent run one prompt and exit.
    ///
    /// | Agent | Invocation | Source |
    /// |---|---|---|
    /// | Claude Code | `-p <prompt>` | `--print`, the documented headless mode |
    /// | Codex | `exec <prompt>` | `codex exec`, the documented headless mode |
    /// | Gemini CLI | `-p <prompt>` | `--prompt` |
    /// | opencode | `run <prompt>` | `opencode run` |
    ///
    /// `nil` means JXCode does not know how to drive this agent unattended.
    /// oh-my-pi and Jules are the cases that need a real answer rather than a
    /// guess: Jules dispatches to a cloud VM and returns a session id rather
    /// than a result, so "run and read the output" is not the right shape for
    /// it at all.
    public static func nonInteractiveInvocation(
        agent: AgentDefinition,
        prompt: String
    ) -> [String]? {
        switch agent.id {
        case "claude":   return ["-p", prompt]
        case "codex":    return ["exec", prompt]
        case "gemini":   return ["-p", prompt]
        case "opencode": return ["run", prompt]
        default:         return nil
        }
    }

    /// Why an agent cannot be automated. Used in the failure message.
    static func unsupportedReason(for agent: AgentDefinition) -> String {
        if agent.id == "shell" {
            return "\(agent.name) is a login shell, not an agent — there is nothing to prompt."
        }
        if agent.webURL != nil {
            return "\(agent.name) dispatches work to a cloud service and returns a session id "
                + "rather than a result, so JXCode cannot run it unattended."
        }
        return "JXCode does not know how to run \(agent.name) non-interactively. "
            + "Run it once by hand to check the flag, then add it to "
            + "AutomationRunner.nonInteractiveInvocation."
    }

    // MARK: - Due calculation

    /// The automations that should run now.
    ///
    /// Pure, so the schedule logic can be tested without a clock or a process —
    /// which matters because "it ran at the wrong time" is the failure a user
    /// would actually notice, and it is the one thing a test can pin exactly.
    public static func due(
        automations: [Automation],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [Automation] {
        automations
            .filter(\.enabled)
            .filter { $0.schedule.isDue(last: $0.lastRun, now: now, calendar: calendar) }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Running

    /// Run one automation and record the outcome.
    public static func run(
        _ automation: Automation,
        agents: [AgentDefinition],
        workspaces: [Workspace],
        sandbox: Sandbox,
        store: SharedStore? = nil,
        timeout: TimeInterval = AgentInstaller.defaultTimeout,
        now: Date = Date()
    ) -> Result {
        func finish(_ succeeded: Bool, _ message: String) -> Result {
            // Recorded even on failure. A run that failed and was not written
            // down would be retried on every tick forever, and the schedule
            // would look like it was working while producing nothing.
            try? store?.recordRun(
                id: automation.id,
                at: now,
                result: succeeded ? message : "failed: \(message)"
            )
            return Result(
                automationID: automation.id,
                automationName: automation.name,
                succeeded: succeeded,
                message: message,
                ranAt: now
            )
        }

        guard let agent = agents.first(where: { $0.id == automation.agentID }) else {
            return finish(false, "no agent has the id `\(automation.agentID)`")
        }

        guard let invocation = nonInteractiveInvocation(agent: agent, prompt: automation.prompt) else {
            return finish(false, unsupportedReason(for: agent))
        }

        let workspace = automation.workspaceID.flatMap { id in
            workspaces.first { $0.id == id }
        }

        do {
            let result = try sandbox.run(
                agent.command,
                arguments: invocation,
                workspace: workspace,
                timeout: timeout
            )

            if result.timedOut {
                return finish(false, "\(agent.name) did not finish within "
                    + "\(Int(timeout))s and was stopped")
            }
            if !result.succeeded {
                let tail = result.combined
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .suffix(400)
                return finish(false, "\(agent.name) exited \(result.exitCode)"
                    + (tail.isEmpty ? "" : ": \(tail)"))
            }

            let output = result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = output
                .components(separatedBy: .newlines)
                .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
            return finish(true, firstLine.isEmpty ? "ran, with no output" : String(firstLine.prefix(200)))

        } catch {
            // The usual cause is that the agent is not installed. `SandboxError`
            // already says which, and in words.
            return finish(false, "\(error)")
        }
    }

    /// Run everything due, oldest-scheduled first.
    @discardableResult
    public static func runDue(
        store: SharedStore,
        agents: [AgentDefinition],
        workspaces: [Workspace],
        sandbox: Sandbox,
        now: Date = Date(),
        onProgress: ((String) -> Void)? = nil
    ) -> [Result] {
        let ready = due(automations: store.automations, now: now)
        var results: [Result] = []

        for automation in ready {
            onProgress?("Running \(automation.name)…")
            results.append(run(
                automation,
                agents: agents,
                workspaces: workspaces,
                sandbox: sandbox,
                store: store,
                now: now
            ))
        }

        return results
    }
}
