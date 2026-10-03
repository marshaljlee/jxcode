import XCTest
@testable import JXCodeCore

/// Project folders, and the sandbox location they sit beside.
///
/// Both stores were written once and both failed once, in the same way: they
/// saved correctly and then read back nothing. So the round trip is the first
/// test here rather than an afterthought — a store that cannot read its own
/// output is indistinguishable from a store that has never been used.
final class ProjectFoldersTests: XCTestCase {

    private func makeStore() -> (ProjectFolderStore, SandboxPaths) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-folders-\(UUID().uuidString)", isDirectory: true)
        let paths = SandboxPaths(root: root)
        return (ProjectFolderStore(paths: paths), paths)
    }

    private func cleanUp(_ paths: SandboxPaths) {
        try? FileManager.default.removeItem(at: paths.root)
    }

    // MARK: - Round trip

    /// The test that would have caught the date-decoding bug.
    func testSavedFoldersAreReadable() {
        let (store, paths) = makeStore()
        defer { cleanUp(paths) }

        var folders = ProjectFolders()
        folders.recordVisit(path: "/tmp/one", name: "one", at: Date(timeIntervalSince1970: 1_700_000_000))
        folders.recordVisit(path: "/tmp/two", name: "two", at: Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertTrue(store.save(folders))

        let loaded = store.load()
        XCTAssertEqual(loaded.entries.count, 2, "the list saved but read back empty")
        // `entries` is insertion order — that is the raw list. `recent` is the
        // sorted view the sidebar draws, so that is what the ordering has to be
        // asserted against.
        XCTAssertEqual(loaded.recent.first?.name, "two", "recent order is wrong")
        XCTAssertEqual(
            loaded.recent.first?.lastOpened.timeIntervalSince1970 ?? 0,
            1_700_000_100, accuracy: 1,
            "the timestamp did not survive the round trip"
        )
    }

    func testAnAbsentFileReadsAsEmpty() {
        let (store, paths) = makeStore()
        defer { cleanUp(paths) }
        XCTAssertTrue(store.load().entries.isEmpty)
    }

    // MARK: - Recording

    /// One entry per path, however many times it is opened.
    ///
    /// Appending on every visit would fill the sidebar with copies of the same
    /// folder, and "recent" would become a list of the last three things you
    /// did rather than the last three things you worked on.
    func testRevisitingAFolderUpdatesItRatherThanDuplicating() {
        var folders = ProjectFolders()
        folders.recordVisit(path: "/tmp/one", name: "one", at: Date(timeIntervalSince1970: 100))
        folders.recordVisit(path: "/tmp/one", name: "one", at: Date(timeIntervalSince1970: 200))
        folders.recordVisit(path: "/tmp/one", name: "one", at: Date(timeIntervalSince1970: 300))

        XCTAssertEqual(folders.entries.count, 1)
        XCTAssertEqual(folders.entries[0].visitCount, 3)
        XCTAssertEqual(folders.entries[0].lastOpened.timeIntervalSince1970, 300)
    }

    /// A clock that jumps backwards must not un-sort the folder.
    func testAnEarlierTimestampNeverMovesAFolderBackwards() {
        var folders = ProjectFolders()
        folders.recordVisit(path: "/tmp/one", at: Date(timeIntervalSince1970: 500))
        folders.recordVisit(path: "/tmp/one", at: Date(timeIntervalSince1970: 100))

        XCTAssertEqual(
            folders.entries[0].lastOpened.timeIntervalSince1970, 500,
            "a clock correction sent the folder to the bottom of the recent list"
        )
    }

    /// Two spellings of one directory are one folder.
    ///
    /// macOS volumes are case-insensitive by default, so without this
    /// `/Users/x/Proj` and `/Users/x/proj` become two rows pointing at one
    /// place, and pinning one of them appears to do nothing.
    func testCaseAndDotSegmentsResolveToOneEntry() {
        var folders = ProjectFolders()
        folders.recordVisit(path: "/tmp/Proj")
        folders.recordVisit(path: "/tmp/proj/")
        folders.recordVisit(path: "/tmp/other/../proj")

        XCTAssertEqual(folders.entries.count, 1)
    }

    func testTheNameIsRefreshedFromDiskOnEachVisit() {
        var folders = ProjectFolders()
        folders.recordVisit(path: "/tmp/x", name: "old-name")
        folders.recordVisit(path: "/tmp/x", name: "new-name")

        XCTAssertEqual(folders.entries[0].name, "new-name",
                       "a folder renamed on disk kept its first name")
    }

    // MARK: - Pinning

    func testPinnedFoldersAreNotAlsoRecent() {
        var folders = ProjectFolders()
        folders.recordVisit(path: "/tmp/a", at: Date(timeIntervalSince1970: 100))
        folders.recordVisit(path: "/tmp/b", at: Date(timeIntervalSince1970: 200))
        _ = folders.setPinned(true, path: "/tmp/b")

        XCTAssertEqual(folders.pinned.map(\.path), ["/tmp/b"])
        XCTAssertEqual(folders.recent.map(\.path), ["/tmp/a"],
                       "a pinned folder appeared in both lists")
    }

    /// Pinned folders are never dropped by the recent cap.
    ///
    /// A cap that silently discards a pin is not a pin list — the user made a
    /// decision and it vanished because other folders were busier.
    func testPinnedFoldersSurviveTheRecentCap() {
        var folders = ProjectFolders()
        for index in 0..<(ProjectFolders.recentLimit + 6) {
            folders.recordVisit(
                path: "/tmp/f\(index)",
                at: Date(timeIntervalSince1970: TimeInterval(1000 + index))
            )
        }
        // The oldest folder is pinned, so it is the one a time-sorted list
        // would push furthest down.
        let oldest = "/tmp/f0"
        _ = folders.setPinned(true, path: oldest)

        XCTAssertEqual(folders.pinned.map(\.path), [oldest])
        XCTAssertEqual(
            folders.recent.count, ProjectFolders.recentLimit,
            "the recent list is no longer capped"
        )
    }

    /// Pinning twice is a no-op, so the caller can tell it apart from a change.
    func testPinningIsIdempotent() {
        var folders = ProjectFolders()
        folders.recordVisit(path: "/tmp/a")

        XCTAssertTrue(folders.setPinned(true, path: "/tmp/a"))
        XCTAssertFalse(folders.setPinned(true, path: "/tmp/a"), "reported a change it did not make")
        XCTAssertTrue(folders.setPinned(false, path: "/tmp/a"))
    }

    /// Unpinning keeps the history — that is a different act from forgetting.
    func testUnpinningKeepsTheFolderInRecent() {
        var folders = ProjectFolders()
        folders.recordVisit(path: "/tmp/a", at: Date(timeIntervalSince1970: 100))
        _ = folders.setPinned(true, path: "/tmp/a")
        _ = folders.setPinned(false, path: "/tmp/a")

        XCTAssertEqual(folders.recent.map(\.path), ["/tmp/a"])
    }

    func testForgetRemovesTheEntryEntirely() {
        var folders = ProjectFolders()
        folders.recordVisit(path: "/tmp/a")
        _ = folders.setPinned(true, path: "/tmp/a")

        XCTAssertTrue(folders.remove(path: "/tmp/a"))
        XCTAssertTrue(folders.entries.isEmpty)
        XCTAssertFalse(folders.remove(path: "/tmp/a"), "reported removing something absent")
    }

    /// A pinned folder whose directory is gone is kept and marked, not dropped.
    ///
    /// It may be on an unmounted volume, and silently discarding a pin because
    /// of something that happened on disk would make the pin untrustworthy.
    func testAMissingFolderIsReportedMissingRatherThanDropped() {
        var folders = ProjectFolders()
        folders.recordVisit(path: "/nowhere/at/all/xyz")
        _ = folders.setPinned(true, path: "/nowhere/at/all/xyz")

        XCTAssertEqual(folders.pinned.count, 1, "a pin was dropped because its folder vanished")
        XCTAssertFalse(folders.isPresent(folders.pinned[0]))
    }

    // MARK: - Sandbox location

    /// `JXCODE_ROOT` outranks the saved choice.
    ///
    /// The order is the contract: a leftover preference in Application Support
    /// must never redirect a test run into the user's real sandbox.
    func testTheEnvironmentBeatsTheSavedChoice() {
        let resolved = SandboxLocationStore.resolvedRoot(
            environment: ["JXCODE_ROOT": "/tmp/from-env"]
        )
        XCTAssertEqual(resolved.path, "/tmp/from-env")
    }

    func testWithoutAnOverrideTheBuiltInDefaultIsUsed() {
        let resolved = SandboxLocationStore.resolvedRoot(environment: [:])
        XCTAssertEqual(resolved.path, SandboxLocationStore.builtInRoot.path)
    }

    /// The built-in default must not be computed by asking `defaultRoot`.
    ///
    /// `SandboxPaths.defaultRoot` *is* `resolvedRoot()`, so a cycle between
    /// them recursed until the stack ran out and every command — including
    /// `--help` — segfaulted with no output. This asserts the two are distinct
    /// so the cycle cannot be reintroduced quietly.
    func testTheBuiltInDefaultDoesNotRecurseThroughDefaultRoot() {
        // Calling it twice would be harmless if it were a constant and would
        // blow the stack if it were a cycle.
        _ = SandboxLocationStore.builtInRoot
        _ = SandboxLocationStore.builtInRoot
        XCTAssertEqual(
            SandboxLocationStore.builtInRoot.path,
            SandboxPaths.defaultRoot.path,
            "the built-in default and defaultRoot disagree with no override in force"
        )
    }

    func testTheLocationPointerLivesOutsideTheSandbox() {
        let pointer = SandboxLocation.pointerFile.path
        let root = SandboxLocationStore.builtInRoot.path
        XCTAssertFalse(
            pointer.hasPrefix(root + "/"),
            "the pointer is inside the folder it points at, so the first "
                + "relocation has nowhere to record itself"
        )
    }
}

// MARK: - Adopting the same folder twice

extension ProjectFoldersTests {

    /// Adopting a folder that is already a workspace must not add a second row.
    ///
    /// It did, and it was not a theoretical risk: while the folder list was
    /// being built, `jxcode adopt` was run repeatedly against the same four
    /// directories during testing and the workspace list grew to eleven entries
    /// — four folders shown as eleven rows, none of them distinguishable from
    /// the others in the sidebar.
    func testAdoptingAnAlreadyAdoptedFolderReturnsTheSameWorkspace() throws {
        let paths = SandboxPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-dedupe-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)

        let store = WorkspaceStore(paths: paths)
        let first = try store.adopt(name: "proj", path: "/tmp/proj")
        let second = try store.adopt(name: "proj", path: "/tmp/proj")

        XCTAssertEqual(first.id, second.id, "a second workspace was created for one folder")
        XCTAssertEqual(store.workspaces.count, 1)
    }

    /// Two spellings of one folder are one workspace, not two.
    ///
    /// macOS volumes are case-insensitive by default, so a trailing slash and a
    /// capital letter are the same directory. Without the canonical comparison
    /// the sidebar would show the folder twice for a path typed with a trailing
    /// `/`.
    func testAdoptingIsInsensitiveToTrailingSlashAndCase() throws {
        let paths = SandboxPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-dedupe2-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)

        let store = WorkspaceStore(paths: paths)
        _ = try store.adopt(name: "Proj", path: "/tmp/Proj")
        _ = try store.adopt(name: "Proj", path: "/tmp/proj/")

        XCTAssertEqual(store.workspaces.count, 1, "two spellings of one folder made two workspaces")
    }

    /// Re-adopting still counts as using the folder.
    ///
    /// The dedupe must not swallow the visit, or a folder that is opened
    /// repeatedly would stop moving up the recent list — which is the one thing
    /// the recent list is for.
    func testReAdoptingStillRecordsAVisit() throws {
        let paths = SandboxPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-dedupe3-\(UUID().uuidString)", isDirectory: true))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)

        let store = WorkspaceStore(paths: paths)
        _ = try store.adopt(name: "proj", path: "/tmp/proj")
        let folderStore = ProjectFolderStore(paths: paths)
        let afterFirst = folderStore.load().entries.first?.visitCount ?? 0

        _ = try store.adopt(name: "proj", path: "/tmp/proj")
        let afterSecond = folderStore.load().entries.first?.visitCount ?? 0

        XCTAssertEqual(afterSecond, afterFirst + 1,
                       "re-adopting did not count as another visit, so the folder stopped moving up the recent list")
    }
}
