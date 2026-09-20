import XCTest
@testable import JXCodeCore

/// The tool catalog, the locator and the linker.
///
/// The locator is the interesting one: it deliberately consults *two different
/// sources* — the sandbox `PATH`, and a fixed list of host directories — and the
/// tests below pin both, because collapsing them into one lookup is the obvious
/// simplification and it would be wrong in both directions. A sandbox-only
/// lookup reports "not installed" for a tool the user runs every day; a
/// host-only lookup would launch the host's copy, which is the exact leak this
/// app exists to prevent.
final class ToolCatalogTests: XCTestCase {

    private var base: URL!
    private var root: URL!
    private var hostHome: URL!
    private var paths: SandboxPaths!

    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("jxcode-tools-\(UUID().uuidString)")
        root = base.appendingPathComponent("root")
        hostHome = base.appendingPathComponent("host")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: hostHome.appendingPathComponent(".local/bin"),
                               withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - Fixtures

    private func tool(_ id: String) -> ToolDefinition {
        ToolDefinition(id: id, name: id, binary: id, tagline: "a test tool")
    }

    /// A stand-in for a real executable. Every check below only asks "is this a
    /// runnable path", so an executable shell stub is enough — and it keeps the
    /// tests off the real binaries on the machine.
    @discardableResult
    private func makeExecutable(at url: URL) throws -> String {
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// A non-executable file — a plain data file that happens to share the name.
    @discardableResult
    private func makePlainFile(at url: URL) throws -> String {
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try Data("not executable".utf8).write(to: url)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        return url.path
    }

    /// An environment whose `PATH` is exactly these directories.
    private func environment(_ directories: [String]) -> [String: String] {
        ["PATH": directories.joined(separator: ":")]
    }

    private var sandboxEnvironment: [String: String] {
        environment([paths.sharedBin.path])
    }

    // MARK: - The catalog

    func testTheCatalogCarriesTheToolsThatWereAskedFor() {
        XCTAssertEqual(ToolCatalog.builtIns.map(\.id), ["herdr", "jcode"])
        for tool in ToolCatalog.builtIns {
            XCTAssertFalse(tool.binary.isEmpty, "\(tool.id) has no binary to look for")
            XCTAssertFalse(tool.tagline.isEmpty, "\(tool.id) has no tagline for its card")
        }
    }

    /// A binary containing a slash is resolved as a *path* by
    /// `ExecutableResolver`, which would quietly bypass the sandbox `PATH` search
    /// the whole lookup is built on.
    func testEveryBuiltInBinaryIsABareNameNotAPath() {
        for tool in ToolCatalog.builtIns {
            XCTAssertFalse(tool.binary.contains("/"),
                           "\(tool.id) should name a binary, not a location")
        }
    }

    // MARK: - Where the host is searched

    func testTheHostSearchStartsAtTheUsersLocalBin() {
        let directories = ToolLocator.hostSearchDirectories(home: hostHome).map(\.path)
        XCTAssertEqual(
            directories.first,
            hostHome.appendingPathComponent(".local/bin").path,
            "~/.local/bin is where a self-installed CLI tool lives"
        )
        XCTAssertTrue(directories.contains("/opt/homebrew/bin"))
        XCTAssertTrue(directories.contains("/usr/local/bin"))
    }

    // MARK: - Locating

    func testAToolOnTheSandboxPathIsFoundInTheSandbox() throws {
        let path = try makeExecutable(at: paths.sharedBin.appendingPathComponent("herdr"))

        let found = ToolLocator.locate(tool("herdr"),
                                       environment: sandboxEnvironment,
                                       hostHome: hostHome)

        XCTAssertEqual(found, .sandbox(path))
        XCTAssertEqual(found?.isInSandbox, true)
    }

    func testAToolOnlyOnTheMacIsReportedAsAHostInstall() throws {
        let path = try makeExecutable(at: hostHome.appendingPathComponent(".local/bin/herdr"))

        let found = ToolLocator.locate(tool("herdr"),
                                       environment: sandboxEnvironment,
                                       hostHome: hostHome)

        XCTAssertEqual(found, .host(path))
        XCTAssertEqual(found?.isInSandbox, false,
                       "a host install is not something an agent can run")
    }

    func testTheSandboxCopyWinsWhenBothExist() throws {
        try makeExecutable(at: paths.sharedBin.appendingPathComponent("herdr"))
        try makeExecutable(at: hostHome.appendingPathComponent(".local/bin/herdr"))

        let found = ToolLocator.locate(tool("herdr"),
                                       environment: sandboxEnvironment,
                                       hostHome: hostHome)

        XCTAssertEqual(found?.isInSandbox, true,
                       "the sandbox copy is the one an agent would actually run")
    }

    func testAToolThatIsNowhereIsNil() {
        XCTAssertNil(ToolLocator.locate(tool("herdr"),
                                        environment: sandboxEnvironment,
                                        hostHome: hostHome))
    }

    func testAHostFileThatIsNotExecutableDoesNotCount() throws {
        try makePlainFile(at: hostHome.appendingPathComponent(".local/bin/herdr"))

        XCTAssertNil(ToolLocator.locate(tool("herdr"),
                                        environment: sandboxEnvironment,
                                        hostHome: hostHome),
                     "a file that cannot be run is not an install")
    }

    // MARK: - Linking

    func testLinkingMakesAHostToolReachableInTheSandbox() throws {
        let source = try makeExecutable(at: hostHome.appendingPathComponent(".local/bin/herdr"))

        let link = try ToolLinker.link(tool: tool("herdr"), from: source, paths: paths)

        XCTAssertEqual(link, paths.sharedBin.appendingPathComponent("herdr").path)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link), source)
        XCTAssertTrue(ToolLinker.isLinked(tool: tool("herdr"), paths: paths))
    }

    func testLinkingIsIdempotent() throws {
        let source = try makeExecutable(at: hostHome.appendingPathComponent(".local/bin/herdr"))

        let first = try ToolLinker.link(tool: tool("herdr"), from: source, paths: paths)
        let second = try ToolLinker.link(tool: tool("herdr"), from: source, paths: paths)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: second), source)
    }

    /// A tool that has moved — a reinstall, a different prefix — must be
    /// followed rather than left pointing at where it used to be.
    func testRelinkingFollowsTheToolWhenItMoves() throws {
        let old = try makeExecutable(at: hostHome.appendingPathComponent(".local/bin/herdr"))
        let new = try makeExecutable(at: hostHome.appendingPathComponent("bin/herdr"))

        try ToolLinker.link(tool: tool("herdr"), from: old, paths: paths)
        let link = try ToolLinker.link(tool: tool("herdr"), from: new, paths: paths)

        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link), new)
    }

    /// The rule this project keeps having to relearn: a writer must not destroy
    /// something it did not create. `removeItem` does not care what it is
    /// deleting, so an unconditional replace would silently eat a real file that
    /// happened to share the name.
    func testLinkingRefusesToClobberAFileItDidNotMake() throws {
        let occupied = try makeExecutable(at: paths.sharedBin.appendingPathComponent("herdr"))
        let source = try makeExecutable(at: hostHome.appendingPathComponent(".local/bin/herdr"))

        XCTAssertThrowsError(
            try ToolLinker.link(tool: tool("herdr"), from: source, paths: paths)
        ) { error in
            XCTAssertEqual(error as? ToolError, .destinationOccupied(occupied))
        }

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: occupied)),
                       Data("#!/bin/sh\n".utf8),
                       "the file that was already there must be untouched")
    }

    // MARK: - Unlinking

    func testUnlinkingRemovesTheLinkButNotTheTool() throws {
        let source = try makeExecutable(at: hostHome.appendingPathComponent(".local/bin/herdr"))
        try ToolLinker.link(tool: tool("herdr"), from: source, paths: paths)

        try ToolLinker.unlink(tool: tool("herdr"), paths: paths)

        XCTAssertFalse(fm.fileExists(atPath: paths.sharedBin.appendingPathComponent("herdr").path))
        XCTAssertTrue(fm.fileExists(atPath: source), "the tool itself must survive")
        XCTAssertFalse(ToolLinker.isLinked(tool: tool("herdr"), paths: paths))
    }

    func testUnlinkingIsANoOpWhenThereIsNothingThere() {
        XCTAssertNoThrow(try ToolLinker.unlink(tool: tool("herdr"), paths: paths))
    }

    /// The other half of the same rule, and the reason `unlink` reads the link
    /// first instead of just removing whatever is at the path: it must not be
    /// able to delete an install the user made themselves.
    func testUnlinkingLeavesARealInstallAlone() throws {
        let installed = try makeExecutable(at: paths.sharedBin.appendingPathComponent("herdr"))

        try ToolLinker.unlink(tool: tool("herdr"), paths: paths)

        XCTAssertTrue(fm.fileExists(atPath: installed),
                      "unlinking is only ever allowed to remove a link JXCode made")
    }

    // MARK: - The round trip

    /// Link and unlink are inverse operations, and the check is that the tool
    /// ends up *exactly* where it started: host-only before, host-only after.
    func testLinkingThenUnlinkingReturnsToTheHostOnlyState() throws {
        let source = try makeExecutable(at: hostHome.appendingPathComponent(".local/bin/herdr"))

        XCTAssertEqual(locate(tool("herdr"))?.isInSandbox, false)

        try ToolLinker.link(tool: tool("herdr"), from: source, paths: paths)
        XCTAssertEqual(locate(tool("herdr"))?.isInSandbox, true)

        try ToolLinker.unlink(tool: tool("herdr"), paths: paths)
        XCTAssertEqual(locate(tool("herdr"))?.isInSandbox, false,
                       "unlinking must return the tool to exactly where it was")
    }

    private func locate(_ tool: ToolDefinition) -> ToolLocator.Location? {
        ToolLocator.locate(tool, environment: sandboxEnvironment, hostHome: hostHome)
    }
}
