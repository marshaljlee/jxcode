import XCTest
@testable import JXCodeCore

// MARK: - The toolchain that was missing
//
// These tests exist because of a specific bug: every npm-based agent failed to
// install with `zsh: command not found: npm`, and nothing in the app could have
// noticed. What they protect is the mechanism that fixed it — the shims in
// `PATH[0]` — and, just as importantly, the answer given when there is no Node
// on the machine at all.

final class NodeToolchainTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-toolchain-\(UUID().uuidString)")
        paths = SandboxPaths(root: root)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// A directory shaped like a Node install: `bin/node`, `bin/npm` as a
    /// symlink to a `.js` entry point, exactly as Homebrew lays it out.
    private func makeNodeInstall(in directory: URL) throws -> URL {
        let fm = FileManager.default
        let bin = directory.appendingPathComponent("bin")
        let modules = directory.appendingPathComponent("lib/node_modules/npm/bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        try fm.createDirectory(at: modules, withIntermediateDirectories: true)

        let node = bin.appendingPathComponent("node")
        try "#!/bin/sh\nexit 0\n".write(to: node, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)

        let cli = modules.appendingPathComponent("npm-cli.js")
        try "// npm\n".write(to: cli, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let npm = bin.appendingPathComponent("npm")
        try fm.createSymbolicLink(atPath: npm.path, withDestinationPath: cli.path)
        return node
    }

    // MARK: - Discovery

    /// The real Homebrew layout: `bin/npm` is a symlink straight at npm's JS
    /// entry point, so following it is the answer. Handing the launcher to
    /// `node` instead would execute a symlink to a `.js` file.
    func testNpmLauncherIsFollowedToItsScript() throws {
        let install = root.appendingPathComponent("host-node")
        _ = try makeNodeInstall(in: install)

        let candidate = try XCTUnwrap(NodeToolchain.discover(in: [install.appendingPathComponent("bin")]))
        XCTAssertEqual(candidate.npmCLI?.pathExtension, "js")
        XCTAssertEqual(candidate.npmCLI?.lastPathComponent, "npm-cli.js")
    }

    func testDiscoverySkipsDirectoriesWithoutANode() throws {
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertNil(NodeToolchain.discover(in: [empty]))
        XCTAssertNil(NodeToolchain.discover(in: []))
    }

    /// A `node` that is not executable is not a Node. Checking the mode rather
    /// than mere existence is what keeps a half-finished download from being
    /// adopted as the runtime.
    func testDiscoveryIgnoresANonExecutableNode() throws {
        let directory = root.appendingPathComponent("not-executable")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let node = directory.appendingPathComponent("node")
        try "not a program".write(to: node, atomically: true, encoding: .utf8)

        XCTAssertNil(NodeToolchain.discover(in: [directory]))
    }

    /// The first directory that has one wins, so the list is a priority order.
    func testDiscoveryTakesTheFirstDirectoryThatHasANode() throws {
        let first = root.appendingPathComponent("first")
        let second = root.appendingPathComponent("second")
        _ = try makeNodeInstall(in: first)
        _ = try makeNodeInstall(in: second)

        let candidate = try XCTUnwrap(NodeToolchain.discover(in: [first.appendingPathComponent("bin"), second.appendingPathComponent("bin")]))
        XCTAssertTrue(candidate.node.path.hasPrefix(first.path))
    }

    // MARK: - Where it looks

    /// The GUI app inherits launchd's `PATH`, which is not the user's `PATH` and
    /// never contains Homebrew. Probing `PATH` would therefore find nothing on
    /// most machines, which is why the search is a fixed directory list.
    func testTheSearchListNamesThePlacesNodeActuallyInstalls() {
        let directories = NodeToolchain.hostSearchDirectories(environment: [:], home: "/tmp/home")
            .map(\.path)
        XCTAssertTrue(directories.contains("/opt/homebrew/bin"))
        XCTAssertTrue(directories.contains("/usr/local/bin"))
    }

    /// A developer machine often has Node *only* under a version manager, and
    /// none of those live in a Homebrew prefix.
    func testVersionManagedInstallsAreIncludedAndNewestFirst() throws {
        let home = root.appendingPathComponent("home")
        for version in ["v18.20.0", "v22.9.0", "v20.11.0"] {
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent(".nvm/versions/node/\(version)/bin"),
                withIntermediateDirectories: true
            )
        }

        let directories = NodeToolchain.versionManagedDirectories(home: home.path)
        let nvm = directories.filter { $0.contains(".nvm/versions/node") }
        XCTAssertEqual(nvm.count, 3)
        XCTAssertTrue(nvm[0].contains("v22.9.0"), "the newest version should be tried first: \(nvm)")
        XCTAssertTrue(directories.contains { $0.hasSuffix(".volta/bin") })
    }

    func testAnExplicitOverrideIsTriedBeforeTheGuesses() {
        let directories = NodeToolchain.hostSearchDirectories(
            environment: ["JXCODE_NODE": "/custom/node/bin"],
            home: "/tmp/home"
        ).map(\.path)
        XCTAssertEqual(directories.first, "/custom/node/bin")
    }

    // MARK: - Shims

    func testShimsAreWrittenForNodeNpmAndNpx() throws {
        let install = root.appendingPathComponent("host-node")
        let node = try makeNodeInstall(in: install)
        let candidate = try XCTUnwrap(NodeToolchain.discover(in: [install.appendingPathComponent("bin")]))

        try NodeToolchain.installShims(paths: paths, candidate: candidate)

        for name in NodeToolchain.shimNames {
            let shim = paths.bin.appendingPathComponent(name)
            XCTAssertTrue(
                FileManager.default.isExecutableFile(atPath: shim.path),
                "\(name) was not written as an executable"
            )
            XCTAssertTrue(NodeToolchain.isShim(shim), "\(name) is not marked as a shim")
        }

        // The point of the shim: it points at the runtime that exists, so the
        // sandbox has a Node without a copy of one.
        let contents = try String(contentsOf: paths.bin.appendingPathComponent("node"), encoding: .utf8)
        XCTAssertTrue(contents.contains(node.path))
    }

    /// A shim that could not be recognised as one would be mistaken for a real
    /// sandbox-local Node, which is the thing the marker prevents.
    func testARealBinaryIsNotMistakenForAShim() throws {
        let binary = root.appendingPathComponent("real-node")
        try "\u{7F}ELF not really".write(to: binary, atomically: true, encoding: .utf8)
        XCTAssertFalse(NodeToolchain.isShim(binary))
        XCTAssertNil(NodeToolchain.readShimMetadata(binary))
    }

    /// `installed(paths:)` is on the hot path — `Sandbox.prepare()` runs it on
    /// every tab launch — so it reads the header rather than executing anything.
    func testInstalledRoundTripsTheRecordedTargets() throws {
        let install = root.appendingPathComponent("host-node")
        _ = try makeNodeInstall(in: install)
        let candidate = try XCTUnwrap(NodeToolchain.discover(in: [install.appendingPathComponent("bin")]))

        XCTAssertNil(NodeToolchain.installed(paths: paths), "nothing is installed yet")
        try NodeToolchain.installShims(paths: paths, candidate: candidate)

        let located = try XCTUnwrap(NodeToolchain.installed(paths: paths))
        XCTAssertEqual(located.node, candidate.node)
        XCTAssertEqual(located.npmCLI, candidate.npmCLI)
    }

    /// If the borrowed runtime is uninstalled or upgraded away, the shims are
    /// dead and must not be reported as a working toolchain.
    func testStaleShimsAreNotReportedAsInstalled() throws {
        let install = root.appendingPathComponent("host-node")
        let node = try makeNodeInstall(in: install)
        let candidate = try XCTUnwrap(NodeToolchain.discover(in: [install.appendingPathComponent("bin")]))
        try NodeToolchain.installShims(paths: paths, candidate: candidate)
        XCTAssertNotNil(NodeToolchain.installed(paths: paths))

        try FileManager.default.removeItem(at: node)
        XCTAssertNil(NodeToolchain.installed(paths: paths), "a shim pointing at nothing is not a toolchain")
    }

    /// A path under `Application Support` is one space away from needing this,
    /// and an apostrophe is one character away from breaking it.
    func testShimTargetsAreShellQuoted() {
        XCTAssertEqual(NodeToolchain.shellQuoted("/a b/node"), "'/a b/node'")
        XCTAssertEqual(NodeToolchain.shellQuoted("/it's/node"), "'/it'\\''s/node'")
    }

    // MARK: - The answer when there is no Node

    /// The failure that started all of this was a bare `command not found`
    /// printed into a terminal. The replacement has to name what was searched,
    /// or the user is back to guessing.
    func testAMissingRuntimeIsExplainedWithThePlacesSearched() {
        let empty = root.appendingPathComponent("nowhere")
        let outcome = NodeToolchain.ensure(
            paths: paths,
            environment: [:],
            home: root.path,
            directories: [empty]
        )

        guard case .failure(let error) = outcome else {
            return XCTFail("a directory with no node should not produce a toolchain")
        }
        guard case .nodeNotFound(let searched) = error else {
            return XCTFail("expected nodeNotFound, got \(error)")
        }
        XCTAssertEqual(searched, [empty.path])

        let message = error.description
        XCTAssertTrue(message.contains(empty.path), "the message must list what was searched:\n\(message)")
        XCTAssertTrue(message.contains("npm"), "the message should say why npm matters:\n\(message)")
    }

    func testEnsureWritesShimsAndReportsTheBorrowedRuntime() throws {
        let install = root.appendingPathComponent("host-node")
        let node = try makeNodeInstall(in: install)

        let located = try NodeToolchain.ensure(
            paths: paths,
            environment: [:],
            home: root.path,
            directories: [install.appendingPathComponent("bin")]
        ).get()

        XCTAssertEqual(located.node, node.resolvingSymlinksInPath())
        XCTAssertTrue(NodeToolchain.installed(paths: paths) != nil)
    }

    /// A Node with no npm beside it cannot install anything, and saying so beats
    /// writing shims that fail later with a confusing message.
    func testANodeWithoutNpmIsRejectedBeforeAnythingIsWritten() throws {
        let directory = root.appendingPathComponent("node-only/bin")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let node = directory.appendingPathComponent("node")
        try "#!/bin/sh\n".write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)

        let outcome = NodeToolchain.ensure(
            paths: paths,
            environment: [:],
            home: root.path,
            directories: [directory]
        )

        guard case .failure(.npmNotFound) = outcome else {
            return XCTFail("expected npmNotFound, got \(outcome)")
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.bin.appendingPathComponent("node").path),
            "a rejected toolchain must not leave shims behind"
        )
    }
}
