import XCTest
@testable import JXCodeCore

/// Per-agent model overrides: one agent on a stronger model, the rest on the
/// local default, and a loud report when the caller names something that does
/// not exist.
final class AgentModelOverrideTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-override-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var routerURL: String { "http://127.0.0.1:5255" }

    private func claudeEnvironment() throws -> [String: String] {
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        let data = try Data(contentsOf: file)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(root["env"] as? [String: String])
    }

    private func codexConfig() throws -> String {
        let file = paths.codexHome.appendingPathComponent("config.toml")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// Every note on every report, so a test can ask whether anything was
    /// refused without caring which agent the refusal was filed against.
    private func allNotes(_ reports: [AgentConfigWriter.Report]) -> [String] {
        reports.flatMap(\.notes)
    }

    // MARK: - Overrides that apply

    func testAnOverrideChangesOnlyTheNamedAgentsModel() throws {
        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "local-default",
            overrides: ["codex": "gpt-oss"]
        )

        // Codex was named, so it moves.
        XCTAssertTrue(try codexConfig().contains(#"model = "gpt-oss""#))
        // Claude Code was not, so it keeps the shared default.
        XCTAssertEqual(try claudeEnvironment()["ANTHROPIC_MODEL"], AgentConfigWriter.claudeVisibleModel("local-default"))
        XCTAssertEqual(try claudeEnvironment()["ANTHROPIC_SMALL_FAST_MODEL"], AgentConfigWriter.claudeVisibleModel("local-default"))

        XCTAssertEqual(reports.count, AgentRegistry.builtIns.count)
        XCTAssertFalse(
            allNotes(reports).contains { $0.contains("ignored") },
            "a valid override must not be reported as a problem"
        )
    }

    /// The point of the feature: two agents, two models, at the same time.
    func testTwoAgentsCanUseTwoDifferentModelsAtOnce() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "local-default",
            overrides: ["claude": "claude-sonnet", "codex": "gpt-oss"]
        )

        let environment = try claudeEnvironment()
        XCTAssertEqual(environment["ANTHROPIC_MODEL"], "claude-sonnet")
        // The small/fast model follows the agent's override too — leaving it on
        // the shared default would send background calls to the wrong backend.
        XCTAssertEqual(environment["ANTHROPIC_SMALL_FAST_MODEL"], "claude-sonnet")

        let config = try codexConfig()
        XCTAssertTrue(config.contains(#"model = "gpt-oss""#))
        // Codex gets the real model name; only the Claude env is rewritten.
        XCTAssertFalse(config.contains("local-default"))
    }

    /// Surrounding whitespace is a paste artefact, not a model name.
    func testAnOverrideIsTrimmedBeforeItReachesTheConfig() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "local-default",
            overrides: ["claude": "  claude-sonnet\n"]
        )

        XCTAssertEqual(try claudeEnvironment()["ANTHROPIC_MODEL"], "claude-sonnet")
    }

    // MARK: - Overrides that are refused

    /// A typo'd agent id that quietly does nothing is the bug this reporting
    /// exists to prevent, so it has to appear in the returned reports.
    func testAnOverrideForAnUnknownAgentIsReportedAndChangesNothing() throws {
        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "local-default",
            overrides: ["claud": "claude-sonnet"]
        )

        let stray = try XCTUnwrap(reports.first { $0.agentID == "claud" })
        XCTAssertEqual(stray.action, .notApplicable)
        XCTAssertTrue(
            stray.notes.contains { $0.contains("claud") && $0.contains("ignored") },
            "the report must name the id that matched nothing"
        )

        // Nothing was routed to the mistyped name, and the real agent is intact.
        XCTAssertEqual(try claudeEnvironment()["ANTHROPIC_MODEL"], AgentConfigWriter.claudeVisibleModel("local-default"))
        XCTAssertFalse(try codexConfig().contains("claude-sonnet"))
        XCTAssertEqual(reports.count, AgentRegistry.builtIns.count + 1)
    }

    /// Writing an empty model would produce a config the agent cannot start
    /// from, which is worse than keeping the default and saying so.
    func testAnEmptyOverrideIsIgnoredAndReported() throws {
        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "local-default",
            overrides: ["claude": ""]
        )

        let report = try XCTUnwrap(reports.first { $0.agentID == "claude" })
        XCTAssertTrue(report.notes.contains { $0.contains("ignored the override") })

        let environment = try claudeEnvironment()
        XCTAssertEqual(environment["ANTHROPIC_MODEL"], AgentConfigWriter.claudeVisibleModel("local-default"))
        XCTAssertEqual(environment["ANTHROPIC_SMALL_FAST_MODEL"], AgentConfigWriter.claudeVisibleModel("local-default"))
        // An untouched agent is unaffected by someone else's bad override.
        // Codex gets the real model name; only the Claude env is rewritten.
        XCTAssertTrue(try codexConfig().contains("model = \"local-default\""))
    }

    /// Whitespace-only is empty in every way that matters: no backend has a
    /// model by that name.
    func testAWhitespaceOnlyOverrideIsAlsoRefused() throws {
        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "local-default",
            overrides: ["codex": "   "]
        )

        XCTAssertTrue(
            reports.first { $0.agentID == "codex" }?
                .notes.contains { $0.contains("ignored the override") } == true
        )
        // Codex gets the real model name; only the Claude env is rewritten.
        XCTAssertTrue(try codexConfig().contains("model = \"local-default\""))
    }

    /// A refusal for an agent that exists belongs on that agent's report, not
    /// on a stray entry that would put a second row with the same id in the UI.
    func testARefusalDoesNotAddAnExtraReportEntry() throws {
        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "local-default",
            overrides: ["claude": ""]
        )

        XCTAssertEqual(reports.count, AgentRegistry.builtIns.count)
        XCTAssertEqual(reports.filter { $0.agentID == "claude" }.count, 1)
    }

    // MARK: - Backwards compatibility

    /// The existing call sites pass no overrides at all. That must produce the
    /// same files as passing an empty map, byte for byte.
    func testEmptyOverridesReproduceTheDefaultBehaviour() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "m"
        )

        let otherRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-override-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let otherPaths = SandboxPaths(root: otherRoot)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: otherPaths,
            routerURL: routerURL,
            model: "m",
            overrides: [:]
        )

        for (left, right) in [
            (paths.claudeConfig.appendingPathComponent("settings.json"),
             otherPaths.claudeConfig.appendingPathComponent("settings.json")),
            (paths.codexHome.appendingPathComponent("config.toml"),
             otherPaths.codexHome.appendingPathComponent("config.toml")),
        ] {
            XCTAssertEqual(
                try String(contentsOf: left, encoding: .utf8),
                try String(contentsOf: right, encoding: .utf8),
                "\(left.lastPathComponent) changed when an empty overrides map was passed"
            )
        }
    }

    /// Overrides do not relax the sandbox rule: a model name is still only ever
    /// written to a path derived from `SandboxPaths`.
    func testOverridesStillWriteOnlyInsideTheSandbox() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "local-default",
            overrides: ["claude": "a", "codex": "b", "ghost": "c"]
        )

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var checked = 0
        while let item = enumerator?.nextObject() as? URL {
            XCTAssertTrue(paths.contains(item), "\(item.path) escapes the sandbox root")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "expected at least one file to have been written")
    }
}
