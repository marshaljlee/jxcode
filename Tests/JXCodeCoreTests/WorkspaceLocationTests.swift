import XCTest
@testable import JXCodeCore

/// Creating a workspace in a folder the user chose.
///
/// The default base is the sandbox's own `workspaces/`; a custom base is how a
/// workspace lands somewhere the user picked. The isolation story is about the
/// toolchain, so the only thing to prove here is that the directory is created
/// where it was asked for and that the slug/suffix rules still apply there.
final class WorkspaceLocationTests: XCTestCase {
    private var root: URL!
    private var paths: SandboxPaths!
    private var customBase: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-wsloc-\(UUID().uuidString)")
        paths = SandboxPaths(root: root)
        customBase = root.appendingPathComponent("My Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: customBase, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testCustomBaseReceivesTheWorkspaceFolder() throws {
        let store = WorkspaceStore(paths: paths)
        let workspace = try store.create(name: "Side Quest", in: customBase)

        XCTAssertTrue(workspace.path.hasPrefix(customBase.path),
                      "\(workspace.path) should live under \(customBase.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.path))
        XCTAssertFalse(workspace.path.hasPrefix(paths.workspaces.path),
                       "the default workspaces/ directory must stay out of it")
    }

    func testCustomBaseStillSuffixesCollisions() throws {
        let store = WorkspaceStore(paths: paths)
        let first = try store.create(name: "demo", in: customBase)
        let second = try store.create(name: "demo", in: customBase)
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertTrue(second.path.hasSuffix("demo-2"))
    }

    func testDefaultBaseIsUnchangedWhenNoBaseIsPassed() throws {
        let store = WorkspaceStore(paths: paths)
        let workspace = try store.create(name: "plain")
        XCTAssertTrue(workspace.path.hasPrefix(paths.workspaces.path))
    }
}
