import XCTest
@testable import JXCodeCore

/// Ids become directory and file names, and `URL.appendingPathComponent` does
/// not strip `..` — the filesystem resolves it, so an id of `../../../victim`
/// reached straight past the collection directory. Before the gate these tests
/// pin, `jxcode connector-remove ../../../victim` deleted whatever was there,
/// and the id inside a planted `connector.json` did the same from the UI.
final class SharedCollectionPathSafetyTests: XCTestCase {

    private var base: URL!
    private var root: URL!
    /// Sits *beside* the sandbox root, so reaching it proves an escape.
    private var victim: URL!
    private var paths: SandboxPaths!
    private var store: SharedStore!

    /// From `<root>/shared/connectors`, three levels up is `base` — where
    /// `victim` lives.
    private let escaping = "../../../victim"

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-safety-\(UUID().uuidString)")
        root = base.appendingPathComponent("sandbox", isDirectory: true)
        victim = base.appendingPathComponent("victim", isDirectory: true)

        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try "do not delete me".write(
            to: victim.appendingPathComponent("keep.txt"),
            atomically: true,
            encoding: .utf8
        )

        paths = SandboxPaths(root: root)
        try paths.createDirectories()
        store = SharedStore(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func assertVictimSurvives(_ message: String) {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: victim.appendingPathComponent("keep.txt").path),
            message
        )
    }

    /// Generic because the write methods are `@discardableResult`: the
    /// expression yields the value it wrote rather than `Void`.
    private func assertRefused<T>(
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let refused = error as? SharedStoreError,
                  case .unsafeIdentifier = refused else {
                return XCTFail("expected unsafeIdentifier, got \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - The rule

    func testOrdinaryIdsAreAccepted() {
        for id in ["release", "my-skill", "skill-2", "a", "café"] {
            XCTAssertTrue(Identifier.isSafePathComponent(id), "\(id) should be usable")
        }
    }

    func testIdsThatCanEscapeAreRefused() {
        let refused = [
            "..", ".", "", "/", "a/b", "../../../victim",
            "a/../../b", "x\u{0}y", String(repeating: "a", count: 129),
        ]
        for id in refused {
            XCTAssertFalse(Identifier.isSafePathComponent(id), "\(id) must be refused")
        }
    }

    // MARK: - Writes

    func testWriteSkillRefusesAnEscapingId() {
        assertRefused(try store.writeSkill(
            Skill(id: escaping, name: "Evil", summary: "s", body: "# Evil")
        ))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: victim.appendingPathComponent("SKILL.md").path
            ),
            "a skill was written outside the collection"
        )
    }

    func testWriteConnectorRefusesAnEscapingId() {
        assertRefused(try store.writeConnector(
            Connector(id: escaping, name: "Evil", command: "echo")
        ))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: victim.appendingPathComponent("connector.json").path
            ),
            "a connector was written outside the collection"
        )
    }

    func testWriteAutomationRefusesAnEscapingId() {
        assertRefused(try store.writeAutomation(
            Automation(id: escaping, name: "Evil", agentID: "shell", prompt: "go")
        ))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: victim.deletingLastPathComponent()
                    .appendingPathComponent("victim.json").path
            ),
            "an automation was written outside the collection"
        )
    }

    // MARK: - Removes
    //
    // These are the ones that did the damage: the removal was wrapped in `try?`,
    // so the old code deleted an arbitrary directory and reported nothing.

    func testRemoveSkillRefusesAnEscapingId() {
        assertRefused(try store.removeSkill(id: escaping))
        assertVictimSurvives("removeSkill deleted a directory outside the collection")
    }

    func testRemoveConnectorRefusesAnEscapingId() {
        assertRefused(try store.removeConnector(id: escaping))
        assertVictimSurvives("removeConnector deleted a directory outside the collection")
    }

    func testRemoveAutomationRefusesAnEscapingId() {
        assertRefused(try store.removeAutomation(id: escaping))
        assertVictimSurvives("removeAutomation deleted a file outside the collection")
    }

    // MARK: - The id that came from disk
    //
    /// The `--id` flag was not the only way in: the id inside a `connector.json`
    /// is decoded from disk and was never checked against the directory name,
    /// and the UI passes that decoded id straight into a delete.
    func testAnIdReadFromDiskIsRefusedOnWrite() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let directory = paths.sharedConnectors
            .appendingPathComponent("planted", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(Connector(id: escaping, name: "Planted", command: "echo"))
            .write(to: directory.appendingPathComponent("connector.json"))

        // It loads — the store does not reject on read, or the UI could not show
        // the user the row that needs deleting.
        let reloaded = SharedStore(paths: paths)
        XCTAssertEqual(reloaded.connectors.first?.id, escaping)

        // But nothing can be written through it.
        assertRefused(try reloaded.setConnectorEnabled(id: escaping, enabled: false))
        assertVictimSurvives("a planted id reached the filesystem")
    }

    // MARK: - No regression for ordinary ids

    func testAnOrdinaryIdStillRoundTrips() throws {
        try store.writeSkill(Skill(id: "release", name: "Release", summary: "s", body: "# Release"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.sharedSkills.appendingPathComponent("release/SKILL.md").path
            )
        )

        try store.removeSkill(id: "release")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.sharedSkills.appendingPathComponent("release").path
            )
        )
    }

    /// Removing something that is not there is not an error: the caller asked
    /// for the entry to be gone, and it is. Only an *unsafe* id is a refusal.
    func testRemovingAMissingEntryIsStillTolerated() throws {
        XCTAssertNoThrow(try store.removeSkill(id: "never-existed"))
        XCTAssertNoThrow(try store.removeConnector(id: "never-existed"))
        XCTAssertNoThrow(try store.removeAutomation(id: "never-existed"))
    }
}
