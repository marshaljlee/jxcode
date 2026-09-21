import XCTest
@testable import JXCodeCore

/// `jxcode shared-bind` used to print its failures and exit 0, so a scripted
/// bind that bound nothing still looked like it had worked.
///
/// What is being decided here is which outcomes are failures at all. Getting it
/// wrong in the other direction is just as bad: an agent with nowhere to write
/// is not a failure, and calling it one would fail every bind on any machine
/// that does not have every agent installed.
final class SharedBindTests: XCTestCase {

    private func outcome(
        _ name: String,
        status: AgentInstaller.Outcome.Status
    ) -> AgentInstaller.Outcome {
        AgentInstaller.Outcome(
            agentID: name.lowercased(), agentName: name, attempts: [], status: status
        )
    }

    private func report(
        _ name: String,
        action: ConnectorBinder.Report.Action,
        notes: [String] = []
    ) -> ConnectorBinder.Report {
        ConnectorBinder.Report(
            agentID: name.lowercased(), agentName: name,
            action: action, path: nil, notes: notes
        )
    }

    // MARK: - Installs

    func testAConnectorWhoseInstallFailedIsAFailure() {
        let failures = SharedBind.failures(
            installs: [
                outcome("Filesystem", status: .failed(stage: .download, message: "npm exited 1"))
            ],
            connectors: []
        )

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.subject, "Filesystem")
        XCTAssertEqual(failures.first?.reason, "npm exited 1")
    }

    func testAConnectorThatInstalledIsNotAFailure() {
        XCTAssertTrue(
            SharedBind.failures(
                installs: [outcome("Filesystem", status: .installed(path: "/bin/fs"))],
                connectors: []
            ).isEmpty
        )
    }

    // MARK: - Connector binding

    func testAnAgentWhoseConfigWeRefusedToTouchIsAFailure() {
        let failures = SharedBind.failures(
            installs: [],
            connectors: [
                report(
                    "Claude", action: .refused,
                    notes: ["settings.json is not a JSON object — left untouched"]
                )
            ]
        )

        XCTAssertEqual(
            failures.map(\.line),
            ["Claude: settings.json is not a JSON object — left untouched"]
        )
    }

    /// The reason lives in the notes, and a refused report is not guaranteed to
    /// carry one. The line still has to say something.
    func testARefusalWithNoNoteStillSaysSomething() {
        let failures = SharedBind.failures(
            installs: [], connectors: [report("Claude", action: .refused)]
        )

        XCTAssertEqual(failures.map(\.line), ["Claude: its MCP config was left untouched"])
    }

    /// An agent JXCode has nowhere to write to is not a failure. Nor is one
    /// that bound, or that already said the right thing, or that was cleared.
    func testNoneOfTheOtherActionsIsAFailure() {
        XCTAssertTrue(
            SharedBind.failures(
                installs: [],
                connectors: [
                    report("Codex", action: .notApplicable),
                    report("Gemini", action: .bound),
                    report("Claude", action: .unchanged),
                    report("OpenCode", action: .cleared),
                ]
            ).isEmpty
        )
    }

    // MARK: - Together

    func testFailuresFromBothSourcesAccumulateInOrder() {
        let failures = SharedBind.failures(
            installs: [
                outcome("Filesystem", status: .failed(stage: .download, message: "boom")),
                outcome("GitHub", status: .installed(path: "/bin/gh")),
                outcome("Brave", status: .failed(stage: .verify, message: "nothing on PATH")),
            ],
            connectors: [
                report("Claude", action: .bound),
                report("Codex", action: .refused, notes: ["nope"]),
            ]
        )

        XCTAssertEqual(failures.map(\.subject), ["Filesystem", "Brave", "Codex"])
    }

    func testNothingToBindIsNotAFailure() {
        XCTAssertTrue(SharedBind.failures(installs: [], connectors: []).isEmpty)
    }
}
