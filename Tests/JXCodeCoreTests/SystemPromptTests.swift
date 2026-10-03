import XCTest
@testable import JXCodeCore

final class SystemPromptTests: XCTestCase {
    private var root: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-sysprompt-\(UUID().uuidString)")
        paths = SandboxPaths(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Store round trip

    func testMissingFileLoadsAsEmptyAndDisabled() {
        let prompt = SystemPromptStore(paths: paths).load()
        XCTAssertEqual(prompt.body, "")
        XCTAssertFalse(prompt.enabled)
    }

    func testSaveRoundTripsThroughTheFile() throws {
        let store = SystemPromptStore(paths: paths)
        let saved = try store.save(SystemPrompt(body: "  Be terse.  \n", enabled: true))

        XCTAssertEqual(saved.body, "Be terse.", "leading/trailing blank matter is not content")

        // The file is the source of truth — read it back through a fresh store.
        let reloaded = SystemPromptStore(paths: paths).load()
        XCTAssertEqual(reloaded.body, "Be terse.")
        XCTAssertTrue(reloaded.enabled)
    }

    func testRenderedBlockCarriesTheSystemPromptMarkers() throws {
        let prompt = try SystemPromptStore(paths: paths)
            .save(SystemPrompt(body: "Always run the tests.", enabled: true))
        let rendered = prompt.rendered()
        XCTAssertTrue(rendered.contains(ManagedBlock.Markers.markdownSystemPrompt.start))
        XCTAssertTrue(rendered.contains("Always run the tests."))
    }

    // MARK: Binding

    private func agent(_ id: String) -> AgentDefinition {
        AgentDefinition(id: id, name: id, command: id)
    }

    func testBindWritesTheBlockIntoEveryInstructionFile() throws {
        try SystemPromptStore(paths: paths).save(SystemPrompt(body: "Stay terse.", enabled: true))
        let prompt = SystemPromptStore(paths: paths).load()

        let reports = try SystemPromptStore.bind(
            prompt: prompt, agents: [agent("claude"), agent("codex")],
            paths: paths
        )

        XCTAssertEqual(reports.count, 2)
        let claude = try String(contentsOf: paths.claudeMemory, encoding: .utf8)
        XCTAssertTrue(claude.contains(ManagedBlock.Markers.markdownSystemPrompt.start))
        XCTAssertTrue(claude.contains("Stay terse."))
    }

    func testBindPreservesTheUsersOwnText() throws {
        try FileManager.default.createDirectory(
            at: paths.claudeMemory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = "# My notes\n\nKeep the workspace tidy.\n"
        try original.write(to: paths.claudeMemory, atomically: true, encoding: .utf8)

        let prompt = SystemPrompt(body: "Be brief.", enabled: true)
        _ = try SystemPromptStore.bind(prompt: prompt, agents: [agent("claude")], paths: paths)

        let bound = try String(contentsOf: paths.claudeMemory, encoding: .utf8)
        XCTAssertTrue(bound.contains("# My notes"))
        XCTAssertTrue(bound.contains("Keep the workspace tidy."))
        XCTAssertTrue(bound.contains("Be brief."))
        // The user's text comes *after* the block — blocks go in at the top.
        let blockEnd = try XCTUnwrap(bound.range(of: ManagedBlock.Markers.markdownSystemPrompt.end))
        let notesStart = try XCTUnwrap(bound.range(of: "# My notes"))
        XCTAssertTrue(blockEnd.upperBound < notesStart.lowerBound)

        // Unbind restores the user's file byte for byte (with the shape-kept
        // blank line), and the backup records the pre-bind state.
        _ = try SystemPromptStore.unbind(agents: [agent("claude")], paths: paths)
        let restored = try String(contentsOf: paths.claudeMemory, encoding: .utf8)
        XCTAssertFalse(restored.contains("jxcode system prompt"))
        XCTAssertTrue(restored.contains("# My notes"))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: paths.claudeMemory.appendingPathExtension("jxcode-backup").path))
    }

    func testDisabledBindClearsAnExistingBlock() throws {
        try FileManager.default.createDirectory(
            at: paths.claudeMemory.deletingLastPathComponent(), withIntermediateDirectories: true)
        let seeded = ManagedBlock.inserting(
            SystemPrompt(body: "old", enabled: true).rendered(),
            into: "# own\n", markers: .markdownSystemPrompt)
        try seeded.write(to: paths.claudeMemory, atomically: true, encoding: .utf8)

        let reports = try SystemPromptStore.bind(
            prompt: SystemPrompt(body: "", enabled: false),
            agents: [agent("claude")], paths: paths
        )
        XCTAssertEqual(reports.first?.action, .cleared)
        let after = try String(contentsOf: paths.claudeMemory, encoding: .utf8)
        XCTAssertFalse(after.contains("jxcode system prompt"))
        XCTAssertTrue(after.contains("# own"))
    }

    // MARK: YOLO

    func testYOLOFlagsExistForTheGatedAgents() {
        XCTAssertNotNil(YOLOMode.flags(for: "claude"))
        XCTAssertNotNil(YOLOMode.flags(for: "codex"))
        XCTAssertNotNil(YOLOMode.flags(for: "gemini"))
        XCTAssertNotNil(YOLOMode.flags(for: "opencode"))
        XCTAssertNotNil(YOLOMode.flags(for: "omp"))
        // No local gates to skip.
        XCTAssertNil(YOLOMode.flags(for: "jules"))
        // A custom agent is never guessed at.
        XCTAssertNil(YOLOMode.flags(for: "my-custom-thing"))
    }

    func testClaudeYOLOFlagIsTheDocumentedOne() {
        let flags = YOLOMode.flags(for: "claude")
        XCTAssertEqual(flags?.arguments, ["--dangerously-skip-permissions"])
    }
}
