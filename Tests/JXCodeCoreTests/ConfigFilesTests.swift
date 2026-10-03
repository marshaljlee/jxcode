import XCTest
@testable import JXCodeCore

/// The ownership record, for directories as well as files.
///
/// The file rule — remove what we created rather than leave it — stopped at
/// directories for exactly as long as the record was only written for files, and
/// four directories survived a full bind-and-unbind cycle because of it. These
/// tests pin the two halves that make the extension safe: a directory is
/// recorded only when a bind actually made it, and a recorded directory is
/// removed only when it is empty.
///
/// The marker is the interesting part. It has to be a *sibling* of the
/// directory rather than something inside it, or the "is it empty" guard could
/// never hold and a failed removal would take the evidence with it — so the
/// first test here is about where the record lives, not about what it says.
final class ConfigFilesTests: XCTestCase {

    private var boundary: URL!
    private var home: URL!

    private var manager: FileManager { FileManager.default }

    override func setUpWithError() throws {
        boundary = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-configfiles-\(UUID().uuidString)")
        home = boundary.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: boundary)
    }

    // MARK: - Helpers

    private func exists(_ url: URL) -> Bool {
        manager.fileExists(atPath: url.path)
    }

    private func contents(of directory: URL) -> [String] {
        ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    private func directory(_ name: String) -> URL {
        home.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Creating

    /// `createDirectory(withIntermediateDirectories: true)` makes an unknown
    /// number of ancestors and reports none of them. The record has to name each
    /// one, or an unbind can only ever take back the deepest.
    func testCreatingADirectoryRecordsEveryAncestorItMade() throws {
        let target = home.appendingPathComponent(".agents/skills", isDirectory: true)

        let made = try ConfigFiles.createDirectory(at: target, upTo: home)

        XCTAssertEqual(made.map(\.lastPathComponent), ["skills", ".agents"],
                       "the record must name every directory the call created, deepest first")
        for path in made {
            XCTAssertTrue(exists(ConfigFiles.createdURL(of: path)),
                          "no record was written for \(path.path)")
        }
    }

    /// The other half of the same rule: a directory the user already had is not
    /// ours, and recording it would make an unbind delete it.
    func testADirectoryThatAlreadyExistedIsNotRecorded() throws {
        let target = directory("skills")
        try manager.createDirectory(at: target, withIntermediateDirectories: true)

        let made = try ConfigFiles.createDirectory(at: target, upTo: home)

        XCTAssertTrue(made.isEmpty)
        XCTAssertFalse(exists(ConfigFiles.createdURL(of: target)))
    }

    /// The walk stops at the boundary, so the sandbox home can never be claimed
    /// — nor anything above it.
    func testTheBoundaryIsNeverClaimedEvenWhenAskedForItDirectly() throws {
        XCTAssertTrue(try ConfigFiles.createDirectory(at: home, upTo: home).isEmpty)
        XCTAssertFalse(exists(ConfigFiles.createdURL(of: home)))
    }

    // MARK: - The marker's shape

    /// A marker inside the directory would make it non-empty by construction, so
    /// the "is it empty" guard could never hold and nothing would ever be
    /// removed. It lives beside the directory, like the file rule's.
    func testTheRecordIsASiblingSoItNeverMakesTheDirectoryNonEmpty() throws {
        let target = directory("skills")

        _ = try ConfigFiles.createDirectory(at: target, upTo: home)

        XCTAssertTrue(contents(of: target).isEmpty,
                      "the record must not live inside the directory it describes")
        XCTAssertTrue(exists(ConfigFiles.createdURL(of: target)))
        XCTAssertEqual(ConfigFiles.createdURL(of: target).lastPathComponent, "skills.jxcode-created")
    }

    // MARK: - Removing

    func testAMarkedEmptyDirectoryIsRemovedAndItsRecordWithIt() throws {
        let target = directory("skills")
        _ = try ConfigFiles.createDirectory(at: target, upTo: home)

        let messages = ConfigFiles.removeCreatedDirectories([target], upTo: home)

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].contains("an empty directory the bind created"),
                      "the message has to say what was removed and why — got \(messages[0])")
        XCTAssertFalse(exists(target))
        XCTAssertFalse(exists(ConfigFiles.createdURL(of: target)),
                       "the record has to go with the directory, or the next directory at that "
                           + "path inherits a claim nobody made")
    }

    func testAnUnmarkedDirectoryIsNeverRemoved() throws {
        let target = directory("skills")
        try manager.createDirectory(at: target, withIntermediateDirectories: true)

        XCTAssertTrue(ConfigFiles.removeCreatedDirectories([target], upTo: home).isEmpty)
        XCTAssertTrue(exists(target))
    }

    /// Removing only the deepest directory would leave its parent behind — the
    /// same defect one level up, and the one that kept `~/.agents/` on disk.
    func testTheRemovalWalkTakesTheAncestorsItMadeWithIt() throws {
        let target = home.appendingPathComponent(".agents/skills", isDirectory: true)
        _ = try ConfigFiles.createDirectory(at: target, upTo: home)

        let messages = ConfigFiles.removeCreatedDirectories([target], upTo: home)

        XCTAssertEqual(messages.count, 2, "both directories were ours — got \(messages)")
        XCTAssertFalse(exists(directory(".agents")))
    }

    func testTheRemovalWalkStopsAtADirectoryThatIsNotOurs() throws {
        let parent = directory(".agents")
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        let target = parent.appendingPathComponent("skills", isDirectory: true)
        _ = try ConfigFiles.createDirectory(at: target, upTo: home)

        let messages = ConfigFiles.removeCreatedDirectories([target], upTo: home)

        XCTAssertEqual(messages.count, 1, "the walk must not climb past a directory it did not make")
        XCTAssertFalse(exists(target))
        XCTAssertTrue(exists(parent))
    }

    /// "Ours" and "empty" are two questions, and a directory can be the first
    /// without being the second. The marker authorises removing the container we
    /// made — not anything the user has since put in it.
    func testAMarkedDirectoryWithContentSurvives() throws {
        let target = directory("skills")
        _ = try ConfigFiles.createDirectory(at: target, upTo: home)
        let theirs = target.appendingPathComponent("my-own-skill")
        try "theirs".write(to: theirs, atomically: true, encoding: .utf8)

        XCTAssertTrue(ConfigFiles.removeCreatedDirectories([target], upTo: home).isEmpty)

        XCTAssertEqual(contents(of: target), ["my-own-skill"])
        XCTAssertTrue(exists(ConfigFiles.createdURL(of: target)),
                      "the record stays too: the directory is still ours, and still not removable")
    }

    func testTheBoundaryIsNeverRemovedEvenWhenItCarriesARecord() throws {
        ConfigFiles.markCreated(home)

        XCTAssertTrue(ConfigFiles.removeCreatedDirectories([home], upTo: home).isEmpty)
        XCTAssertTrue(exists(home))
    }

    /// Clearing the record is what stops a claim outliving its directory. A
    /// marker left behind would make the *user's* next directory at that path
    /// removable.
    func testADirectoryRecreatedAfterARemovalIsNotOurs() throws {
        let target = directory("skills")
        _ = try ConfigFiles.createDirectory(at: target, upTo: home)
        _ = ConfigFiles.removeCreatedDirectories([target], upTo: home)

        try manager.createDirectory(at: target, withIntermediateDirectories: true)

        XCTAssertTrue(ConfigFiles.removeCreatedDirectories([target], upTo: home).isEmpty)
        XCTAssertTrue(exists(target), "a stale record made the user's own directory removable")
    }
}
