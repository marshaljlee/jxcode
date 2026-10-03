import XCTest
@testable import JXCodeCore

/// The primary record, and the charter built from it.
///
/// Both halves are tested together because the charter is only as trustworthy as
/// the record behind it: a charter that says "no subagents" while the record
/// says four is worse than no charter, because the primary will act on it.
final class PrimaryAgentTests: XCTestCase {

    private func makeStore() -> (PrimaryAgentStore, SandboxPaths) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-primary-\(UUID().uuidString)", isDirectory: true)
        let paths = SandboxPaths(root: root)
        return (PrimaryAgentStore(paths: paths), paths)
    }

    private func cleanUp(_ paths: SandboxPaths) {
        try? FileManager.default.removeItem(at: paths.root)
    }

    // MARK: - Round trip

    func testSavesAndReadsBack() {
        let (store, paths) = makeStore()
        defer { cleanUp(paths) }

        let record = PrimaryAgent(
            agentID: "claude",
            agentName: "Claude Code",
            maxSubagents: 3,
            canInstallTools: false
        )
        XCTAssertTrue(store.save(record))

        let loaded = store.load()
        XCTAssertEqual(loaded?.agentID, "claude")
        XCTAssertEqual(loaded?.maxSubagents, 3)
        XCTAssertEqual(loaded?.canInstallTools, false, "install rights must survive the round trip")
    }

    func testNoRecordReadsAsNil() {
        let (store, paths) = makeStore()
        defer { cleanUp(paths) }

        XCTAssertNil(store.load())
    }

    /// A hand-mangled file must not stop the app from launching anything.
    ///
    /// This is the one place a decode failure is deliberately swallowed. The
    /// alternative — refusing to run — turns a typo in a four-line JSON file
    /// into a brick, and there is nothing in the record worth protecting that the
    /// user cannot simply retype.
    func testAMalformedRecordReadsAsNoPrimary() {
        let (store, paths) = makeStore()
        defer { cleanUp(paths) }
        try? FileManager.default.createDirectory(at: paths.state, withIntermediateDirectories: true)
        try? "{ not json".write(to: store.fileURL, atomically: true, encoding: .utf8)

        XCTAssertNil(store.load())
    }

    func testClearRemovesTheRecord() {
        let (store, paths) = makeStore()
        defer { cleanUp(paths) }

        _ = store.save(PrimaryAgent(agentID: "claude", agentName: "Claude Code"))
        XCTAssertTrue(store.clear())
        XCTAssertNil(store.load())
    }

    /// Clearing when there is nothing to clear is success, not an error.
    ///
    /// The GUI calls this on an empty state and a "Remove primary" that throws
    /// because there was never a primary reads as a bug in the button.
    func testClearOnAnAbsentRecordSucceeds() {
        let (store, paths) = makeStore()
        defer { cleanUp(paths) }

        XCTAssertTrue(store.clear())
    }

    func testIsPrimaryMatchesTheRecord() {
        let (store, paths) = makeStore()
        defer { cleanUp(paths) }
        _ = store.save(PrimaryAgent(agentID: "codex", agentName: "Codex CLI"))

        XCTAssertTrue(store.isPrimary("codex"))
        XCTAssertFalse(store.isPrimary("claude"))
    }

    // MARK: - Charter

    /// The charter must name the limit that was actually recorded.
    ///
    /// The two failure modes are both silent: a charter promising four
    /// subagents when the record says none has the primary opening tabs it was
    /// told it could not, and the reverse has it stall while four tabs sit idle.
    func testCharterStatesTheRecordedSubagentLimit() {
        let charter = PrimaryCharter()

        let three = charter.charter(
            primary: PrimaryAgent(agentID: "claude", agentName: "Claude Code", maxSubagents: 3),
            subagents: [],
            environment: [:]
        )
        XCTAssertTrue(three.contains("up to 3 subagents"))

        let one = charter.charter(
            primary: PrimaryAgent(agentID: "claude", agentName: "Claude Code", maxSubagents: 1),
            subagents: [],
            environment: [:]
        )
        XCTAssertTrue(one.contains("up to 1 subagent at the same time"), "singular reads wrong at one")
        XCTAssertFalse(one.contains("1 subagents"), "the plural suffix leaked through at one")

        let none = charter.charter(
            primary: PrimaryAgent(agentID: "claude", agentName: "Claude Code", maxSubagents: 0),
            subagents: [],
            environment: [:]
        )
        XCTAssertTrue(none.contains("may not open subagents"))
    }

    func testCharterReflectsInstallRights() {
        let charter = PrimaryCharter()

        let allowed = charter.charter(
            primary: PrimaryAgent(agentID: "claude", agentName: "C", canInstallTools: true),
            subagents: [],
            environment: [:]
        )
        XCTAssertTrue(allowed.contains("may install a tool"))
        XCTAssertTrue(allowed.contains("Never install anything that needs a payment method"))

        let denied = charter.charter(
            primary: PrimaryAgent(agentID: "claude", agentName: "C", canInstallTools: false),
            subagents: [],
            environment: [:]
        )
        XCTAssertTrue(denied.contains("may NOT install anything"))
    }

    /// A primary told it may install must still be told the money rule.
    ///
    /// Install rights are the one power here that reaches the network, so the
    /// charter that grants it carries the prohibition with it. Dropping the
    /// sentence would leave "may install" as the whole of the instruction.
    func testTheMoneyRuleIsPresentWhicheverWayInstallGoes() {
        let charter = PrimaryCharter()
        for allowed in [true, false] {
            let text = charter.charter(
                primary: PrimaryAgent(agentID: "claude", agentName: "C", canInstallTools: allowed),
                subagents: [],
                environment: [:]
            )
            XCTAssertTrue(
                text.contains("costs money") || text.contains("payment method"),
                "the no-payment rule went missing with canInstallTools=\(allowed)"
            )
        }
    }

    /// The primary must never be offered as its own subagent.
    func testThePrimaryIsNotListedAmongItsSubagents() {
        let paths = SandboxPaths(root: URL(fileURLWithPath: NSTemporaryDirectory()))
        let registry = AgentRegistry(paths: paths)
        let primary = PrimaryAgent(agentID: "claude", agentName: "Claude Code")

        // Nothing resolves on an empty PATH, so the roster is empty — which is
        // the point: the filter must not depend on install state to exclude the
        // primary, only the id comparison.
        let text = PrimaryCharter().charter(
            primary: primary,
            subagents: registry.agents,
            environment: [:]
        )
        XCTAssertTrue(text.contains("no other agent is installed"))
        XCTAssertFalse(text.contains("- Claude Code —"))
    }

    /// With no launchable subagents the charter says so, rather than showing an
    /// empty list that reads as a rendering failure.
    func testAnEmptyRosterIsStatedInWords() {
        let text = PrimaryCharter().charter(
            primary: PrimaryAgent(agentID: "claude", agentName: "Claude Code"),
            subagents: [],
            environment: [:]
        )
        XCTAssertTrue(text.contains("(no other agent is installed in the sandbox right now)"))
    }

    // MARK: - Flags

    func testIntValueReadsANumber() {
        XCTAssertEqual(parseFlags(["--subagents", "5"]).intValue("--subagents"), 5)
        XCTAssertEqual(parseFlags(["--subagents=7"]).intValue("--subagents"), 7)
    }

    /// Nonsense is `nil`, not zero — so a caller can tell "not given" from
    /// "given something unusable" and reject the second.
    func testIntValueRejectsNonsenseRatherThanReadingItAsZero() {
        XCTAssertNil(parseFlags(["--subagents", "many"]).intValue("--subagents"))
        XCTAssertNil(parseFlags(["--subagents", ""]).intValue("--subagents"))
        XCTAssertNil(parseFlags([]).intValue("--subagents"))
    }

    /// `--subagents N` must take its value. Registered as a valued option, so the
    /// number is not left sitting in `positional` where it would become an agent
    /// id and produce "no agent with id 4".
    func testSubagentsTakesItsValueAndDoesNotBecomeAPositional() {
        let flags = parseFlags(["primary", "claude", "--subagents", "4"])

        XCTAssertEqual(flags.intValue("--subagents"), 4)
        XCTAssertEqual(flags.positional, ["primary", "claude"])
    }
}
