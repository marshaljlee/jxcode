/// What `jxcode shared-bind` could not do.
///
/// The bind printed its failures and then exited 0 whatever it had printed, so
/// `jxcode shared-bind && jxcode run …` carried on against a half-bound sandbox
/// with no signal that anything had gone wrong. Printing a failure is not the
/// same as reporting one.
///
/// Deciding what counts as a failure belongs with the types that produced the
/// outcome rather than in the command that prints it, which is also what puts
/// it somewhere a test can reach.
public enum SharedBind {

    /// One thing a bind did not achieve.
    public struct Failure: Sendable, Equatable {
        /// What was being bound: an agent, or a connector's install.
        public let subject: String
        /// Why it did not take.
        public let reason: String

        public var line: String { "\(subject): \(reason)" }
    }

    /// The failures in a bind.
    ///
    /// A connector whose install did not succeed, and an agent whose MCP config
    /// was refused, are both a collection that is not fully bound.
    ///
    /// An agent with no instruction file or no MCP config at all is *not* one.
    /// That is `.notApplicable`, and it is the honest answer for an agent
    /// JXCode has nowhere to write to — reporting it would make every bind of
    /// every collection fail on any machine that has Codex but not Gemini.
    public static func failures(
        installs: [AgentInstaller.Outcome],
        connectors: [ConnectorBinder.Report]
    ) -> [Failure] {
        var failures: [Failure] = []

        for outcome in installs where !outcome.succeeded {
            failures.append(Failure(
                subject: outcome.agentName,
                reason: outcome.failureMessage ?? "the install did not succeed"
            ))
        }

        for report in connectors where report.action == .refused {
            let detail = report.notes.joined(separator: "; ")
            failures.append(Failure(
                subject: report.agentName,
                reason: detail.isEmpty ? "its MCP config was left untouched" : detail
            ))
        }

        return failures
    }
}
