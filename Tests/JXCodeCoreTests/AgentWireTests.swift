import XCTest
@testable import JXCodeCore

/// Track 2.5 — the wire an agent speaks, chosen per agent.
///
/// The defect this pins: `writeCodexConfig` hardcoded `wire_api = "chat"`.
/// OpenAI deprecated `chat/completions` for Codex on 2025-12-09 and removed it
/// in early February 2026, at which point that value became a **startup error**
/// rather than a warning — so the writer was producing a config Codex refuses
/// to load, and the test that should have caught it was asserting the broken
/// value instead.
///
/// A test on *presence* cannot catch a duplicate or a fallback. So the
/// load-bearing assertions here are **counts** (`wire_api` appears exactly
/// once, asserted on the whole array), **differences** (`chat` requested ⇒ the
/// deprecation note present), and **absences** (`messages` requested ⇒
/// `wire_api = "messages"` never reaches the file).
final class AgentWireTests: XCTestCase {

    // MARK: - The wire itself

    func testEveryWireNamesItselfDistinctly() {
        XCTAssertEqual(
            Set(AgentWire.allCases.map(\.displayName)).count,
            AgentWire.allCases.count,
            "two wires share a display name, so a picker cannot tell them apart"
        )
        for wire in AgentWire.allCases {
            XCTAssertFalse(wire.displayName.isEmpty)
        }
    }

    /// `codexWireAPI` is the capability *and* the route: `nil` exactly where
    /// Codex has no such wire. A test on presence would pass for a wire that
    /// returned a made-up string, so this asserts the partition instead.
    func testCodexHasBothOpenAIWiresAndNoMessagesWire() {
        XCTAssertEqual(AgentWire.responses.codexWireAPI, "responses")
        XCTAssertEqual(AgentWire.chat.codexWireAPI, "chat")
        XCTAssertNil(AgentWire.messages.codexWireAPI)

        XCTAssertEqual(
            AgentWire.allCases.filter { $0.codexWireAPI == nil },
            [.messages],
            "a wire gained or lost a Codex spelling without this test being told"
        )
    }

    /// The default is the whole point of the track. The old default was `chat`.
    func testTheCodexDefaultIsTheOnlyWireACurrentCodexAccepts() {
        XCTAssertEqual(AgentWire.codexDefault, .responses)
        XCTAssertTrue(AgentWire.codexDefault.isUsableByCurrentCodex)
        XCTAssertNotEqual(AgentWire.codexDefault, .chat, "the defect, restated")
    }

    func testOnlyResponsesIsUsableByACurrentCodex() {
        XCTAssertEqual(
            AgentWire.allCases.filter(\.isUsableByCurrentCodex),
            [.responses]
        )
    }

    // MARK: - Parsing

    func testEveryCanonicalSpellingParsesBackToItsCase() {
        for wire in AgentWire.allCases {
            XCTAssertEqual(AgentWire.parse(wire.rawValue), wire)
        }
    }

    func testAliasesResolveToTheOneWireTheyName() {
        XCTAssertEqual(AgentWire.parse("response"), .responses)
        XCTAssertEqual(AgentWire.parse("anthropic"), .messages)
        XCTAssertEqual(AgentWire.parse("message"), .messages)
        XCTAssertEqual(AgentWire.parse("chat_completions"), .chat)
        XCTAssertEqual(AgentWire.parse("chat-completions"), .chat)
        XCTAssertEqual(AgentWire.parse("ChatCompletions"), .chat)
        XCTAssertEqual(AgentWire.parse("  MESSAGES \n"), .messages)
    }

    func testGarbageIsRejectedRatherThanDefaulted() {
        XCTAssertNil(AgentWire.parse(""))
        XCTAssertNil(AgentWire.parse("   "))
        XCTAssertNil(AgentWire.parse("responses-api"))
        XCTAssertNil(AgentWire.parse("anthropic-messages"))
        XCTAssertNil(AgentWire.parse("complete"))
    }

    /// The error message lists exactly the spellings that parse — no more (a
    /// suggestion that does not work) and no fewer (a wire the user cannot name).
    func testTheAcceptedSpellingsAreTheOnesThatParse() {
        let accepted = AgentWire.acceptedSpellings
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        XCTAssertEqual(Set(accepted), Set(AgentWire.allCases.map(\.rawValue)))
        for spelling in accepted {
            XCTAssertNotNil(AgentWire.parse(spelling))
        }
    }
}

/// The same choice, seen through the writer: does the wire the user asked for
/// reach `config.toml`, and is a request that cannot be honoured reported?
final class AgentWireBindingTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-wire-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var routerURL: String { "http://127.0.0.1:5255" }

    private func codexConfig() throws -> String {
        try String(
            contentsOf: paths.codexHome.appendingPathComponent("config.toml"),
            encoding: .utf8
        )
    }

    @discardableResult
    private func bind(wires: [String: AgentWire] = [:]) throws -> [AgentConfigWriter.Report] {
        try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "qwen3-coder",
            wires: wires
        )
    }

    private func report(
        _ id: String,
        in reports: [AgentConfigWriter.Report]
    ) throws -> AgentConfigWriter.Report {
        try XCTUnwrap(reports.first { $0.agentID == id }, "no report for `\(id)`")
    }

    /// Every `wire_api` declaration in the file, trimmed.
    ///
    /// The assertions below compare the whole array rather than calling
    /// `contains`, so a **second** declaration cannot hide behind the first —
    /// which is exactly the shape a fallback bug would take.
    private func wireDeclarations(in config: String) -> [String] {
        config
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("wire_api") }
    }

    // MARK: - The default

    func testWithNoOverrideCodexIsGivenTheWireItCanStartWith() throws {
        try bind()

        XCTAssertEqual(
            wireDeclarations(in: try codexConfig()),
            [#"wire_api = "responses""#]
        )
    }

    // MARK: - The override reaching the file

    func testAWireOverrideReachesTheWrittenConfig() throws {
        try bind(wires: ["codex": .chat])

        XCTAssertEqual(
            wireDeclarations(in: try codexConfig()),
            [#"wire_api = "chat""#],
            "the override was accepted and then ignored"
        )
    }

    /// A wire Codex cannot load is still written when asked for — an older
    /// Codex needs it — but never silently. The note is the whole reason it is
    /// safe to honour the request.
    func testAnUnusableWireIsWrittenWithTheReasonItWillFail() throws {
        let reports = try bind(wires: ["codex": .chat])
        let report = try report("codex", in: reports)

        XCTAssertEqual(wireDeclarations(in: try codexConfig()), [#"wire_api = "chat""#])

        XCTAssertTrue(
            report.notes.contains { $0.contains("February 2026") },
            "the note dropped the date that makes it a fact rather than a warning"
        )
        XCTAssertTrue(
            report.notes.contains { $0.contains("startup error") },
            "the note did not say the value is fatal on a current Codex"
        )
    }

    // MARK: - The request that cannot be honoured

    func testAMessagesWireIsRefusedRatherThanWritten() throws {
        let reports = try bind(wires: ["codex": .messages])
        let config = try codexConfig()

        XCTAssertFalse(
            config.contains(#"wire_api = "messages""#),
            "a wire Codex has no route for was written into its config"
        )
        XCTAssertEqual(
            wireDeclarations(in: config),
            [#"wire_api = "responses""#],
            "the refusal did not fall back to the one wire that starts"
        )

        let report = try report("codex", in: reports)
        XCTAssertTrue(
            report.notes.contains { $0.contains("messages") && $0.contains("no such wire") },
            "the request was dropped without saying so: \(report.notes)"
        )
    }

    /// Only a Codex config carries a `wire_api`, so a wire named for any other
    /// agent is reported rather than silently accepted — otherwise a user would
    /// believe they had moved it onto another wire when nothing changed.
    func testAWireForAnAgentWithNoWireToChooseIsReported() throws {
        let reports = try bind(wires: ["claude": .chat])
        let report = try report("claude", in: reports)

        XCTAssertTrue(
            report.notes.contains {
                $0.contains("wire override") && $0.contains("only a Codex config carries one")
            },
            "the override for a non-Codex agent vanished: \(report.notes)"
        )
    }

    func testAWireForAnUnknownAgentGetsItsOwnReport() throws {
        let reports = try bind(wires: ["codexx": .chat])
        let orphan = try XCTUnwrap(reports.first { $0.agentID == "codexx" })

        XCTAssertEqual(orphan.action, .notApplicable)
        XCTAssertFalse(orphan.isRouted)
        XCTAssertTrue(
            orphan.notes.contains { $0.contains("no agent has the id") },
            "a typo'd agent id was accepted in silence: \(orphan.notes)"
        )
    }

    // MARK: - Independence

    /// A wire chosen for one agent must not appear against another. Without
    /// this, a bug that applied every wire to every agent would still pass the
    /// tests above, because each one looks at `codex` alone.
    func testAWireChosenForCodexIsNotReportedAgainstAnotherAgent() throws {
        let reports = try bind(wires: ["codex": .chat])
        let claude = try report("claude", in: reports)

        XCTAssertFalse(
            claude.notes.contains { $0.contains("ignored the wire override") },
            "codex's wire was reported against claude: \(claude.notes)"
        )
    }

    // MARK: - The note on the exit that rewrites nothing

    /// The early return for an unchanged file must still carry the wire note.
    /// It is seeded before the render for exactly this reason; a refactor that
    /// moved it after the comparison would silently drop the one note that says
    /// which wire the file now names.
    func testTheWireNoteSurvivesARebindThatChangesNothing() throws {
        try bind(wires: ["codex": .chat])
        let second = try bind(wires: ["codex": .chat])
        let report = try report("codex", in: second)

        XCTAssertEqual(report.action, .unchanged)
        XCTAssertTrue(
            report.notes.contains { $0.contains("February 2026") },
            "the unchanged exit dropped the wire note: \(report.notes)"
        )
    }

    /// And the refusal note survives it too, since it is the other half of the
    /// same seeding.
    func testTheRefusalNoteSurvivesARebindThatChangesNothing() throws {
        try bind(wires: ["codex": .messages])
        let second = try bind(wires: ["codex": .messages])
        let report = try report("codex", in: second)

        XCTAssertEqual(report.action, .unchanged)
        XCTAssertTrue(
            report.notes.contains { $0.contains("no such wire") },
            "the unchanged exit dropped the refusal note: \(report.notes)"
        )
    }
}
