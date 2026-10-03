import XCTest
@testable import JXCodeCore

// MARK: - Installing an agent
//
// The install used to be "open a shell and type the command", which meant no
// exit status was ever read and nothing was ever retried. These tests cover the
// three decisions that replace it: when a failure is worth retrying, what a
// user is told when it is not, and the refusal to call an install successful
// just because the command exited 0.

final class AgentInstallerTests: XCTestCase {

    // MARK: - Retry policy

    /// A missing package cannot appear because a second attempt was made.
    /// Retrying it wastes a minute of the user's time and teaches them the
    /// retry loop does not mean anything.
    func testUnchangeableFailuresAreNotRetried() {
        let fatal = [
            "npm error 404 Not Found - GET https://registry.npmjs.org/@jx/nope",
            "npm ERR! code E404",
            "npm error notarget No matching version found for foo@99",
            "npm error code EACCES",
            "zsh:1: command not found: npm",
            "npm error ENOSPC: no space left on device",
        ]
        for output in fatal {
            XCTAssertEqual(
                AgentInstaller.classify(exitCode: 1, output: output), .fatal,
                "should not have retried: \(output)"
            )
        }
    }

    /// Everything else is retried. The bias is deliberate: one extra `npm i -g`
    /// costs seconds, while not retrying turns a dropped DNS lookup into a
    /// permanent first-click failure.
    func testTransientFailuresAreRetried() {
        let transient = [
            "npm error code EAI_AGAIN",
            "npm error code ENOTFOUND registry.npmjs.org",
            "npm error code ETIMEDOUT",
            "npm error code ECONNRESET",
            "npm error 429 Too Many Requests",
            "npm error code ERR_SOCKET_TIMEOUT",
            "something nobody has seen before",
            "",
        ]
        for output in transient {
            XCTAssertEqual(
                AgentInstaller.classify(exitCode: 1, output: output), .retry,
                "should have retried: \(output)"
            )
        }
    }

    /// Fatal markers are checked first, so a message containing both is not
    /// retried on the strength of the transient half.
    func testAFatalMarkerWinsOverATransientOne() {
        let output = "npm error code E404 while fetching after ECONNRESET"
        XCTAssertEqual(AgentInstaller.classify(exitCode: 1, output: output), .fatal)
    }

    /// Three attempts, with a gap that grows but stays short enough that a user
    /// waiting on a click does not give up.
    func testBackoffGrowsThenStopsGrowing() {
        XCTAssertEqual(AgentInstaller.backoff(afterFailure: 1), 2)
        XCTAssertEqual(AgentInstaller.backoff(afterFailure: 2), 6)
        XCTAssertEqual(AgentInstaller.backoff(afterFailure: 9), 6)
        XCTAssertEqual(AgentInstaller.backoff(afterFailure: 0), 2)
    }

    // MARK: - Explaining a failure

    /// Each class of failure gets a different sentence. One generic "could not
    /// install" is what sent users to a terminal to find out what happened.
    func testEachKnownFailureGetsItsOwnExplanation() throws {
        let cases: [(String, String)] = [
            ("npm error code EAI_AGAIN", "resolved"),
            ("npm error code ETIMEDOUT", "stopped responding"),
            ("npm error 429 Too Many Requests", "rate-limiting"),
            ("npm error code EACCES", "not writable"),
            ("npm error 404 Not Found", "no package by that name"),
            ("zsh:1: command not found: npm", "jx-where"),
        ]
        var seen = Set<String>()
        for (output, expected) in cases {
            let hint = try XCTUnwrap(
                AgentInstaller.hint(for: output),
                "no hint for: \(output)"
            )
            XCTAssertTrue(
                hint.contains(expected),
                "hint for \(output) does not mention \(expected): \(hint)"
            )
            seen.insert(hint)
        }
        XCTAssertEqual(seen.count, cases.count, "two different failures produced the same explanation")
    }

    func testAnUnknownFailureGetsNoInventedExplanation() {
        XCTAssertNil(AgentInstaller.hint(for: "npm error code WEIRD_THING"))
    }

    /// The message ends with the real output. Without it the user has to go
    /// looking for the reason, which is the behaviour being replaced.
    func testTheMessageCarriesTheAttemptCountAndTheOutputTail() {
        let agent = AgentRegistry.builtIns.first { $0.id == "claude" }!
        let log = [
            AgentInstaller.Attempt(index: 1, exitCode: 1, timedOut: false, output: "first"),
            AgentInstaller.Attempt(index: 2, exitCode: 1, timedOut: false, output: "npm error code EAI_AGAIN"),
        ]

        let message = AgentInstaller.message(for: agent, log: log)
        XCTAssertTrue(message.contains("after 2 attempts"), message)
        XCTAssertTrue(message.contains("EAI_AGAIN"), "the real output is missing:\n\(message)")
        XCTAssertTrue(message.contains("Claude Code"), message)
    }

    func testASingleAttemptIsNotDescribedAsSeveral() {
        let agent = AgentRegistry.builtIns.first { $0.id == "codex" }!
        let log = [AgentInstaller.Attempt(index: 1, exitCode: 1, timedOut: false, output: "boom")]
        let message = AgentInstaller.message(for: agent, log: log)
        XCTAssertFalse(message.contains("attempts"), message)
    }

    func testATimedOutInstallSaysSo() {
        let agent = AgentRegistry.builtIns.first { $0.id == "gemini" }!
        let log = [AgentInstaller.Attempt(index: 1, exitCode: 15, timedOut: true, output: "")]
        let message = AgentInstaller.message(for: agent, log: log)
        XCTAssertTrue(message.contains("timed out"), message)
    }

    // MARK: - Installing

    /// An agent with no install command is a toolchain problem, not a download
    /// problem — there is nothing to download.
    func testAnAgentWithoutAnInstallCommandFailsBeforeRunningAnything() throws {
        let paths = SandboxPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-installer-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let agent = AgentDefinition(id: "nothing", name: "Nothing", command: "nothing")
        let outcome = AgentInstaller.install(
            agent: agent,
            sandbox: Sandbox(paths: paths),
            maxAttempts: 1
        )

        guard case .failed(let stage, let message) = outcome.status else {
            return XCTFail("expected a failure, got \(outcome.status)")
        }
        XCTAssertEqual(stage, .toolchain)
        XCTAssertTrue(message.contains("no install command"), message)
        XCTAssertTrue(outcome.attempts.isEmpty, "nothing should have been run")
    }

    /// Progress is reported so the card can say what is happening. An install
    /// that reports nothing is indistinguishable from one that has hung.
    func testProgressIsReportedBeforeAnythingRuns() throws {
        let paths = SandboxPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-installer-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: paths.root) }

        let agent = AgentDefinition(
            id: "nothing", name: "Nothing", command: "nothing", installCommand: "true"
        )
        var reported: [String] = []
        _ = AgentInstaller.install(
            agent: agent,
            sandbox: Sandbox(paths: paths),
            maxAttempts: 1,
            onProgress: { reported.append($0) }
        )

        XCTAssertTrue(
            reported.contains { $0.contains("Node toolchain") },
            "the toolchain step is the one that used to be missing: \(reported)"
        )
    }
}
