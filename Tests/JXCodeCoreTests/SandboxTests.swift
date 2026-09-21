import XCTest
import Darwin
@testable import JXCodeCore

// MARK: - Paths

final class SandboxPathsTests: XCTestCase {

    func testContainmentAcceptsDescendants() {
        let paths = SandboxPaths(root: URL(fileURLWithPath: "/tmp/jx"))
        XCTAssertTrue(paths.contains(URL(fileURLWithPath: "/tmp/jx/env/home")))
        XCTAssertTrue(paths.contains(URL(fileURLWithPath: "/tmp/jx")))
    }

    /// The classic prefix bug: a sibling directory whose name merely starts with
    /// the sandbox path must not be treated as inside it.
    func testContainmentRejectsSiblingWithSharedPrefix() {
        let paths = SandboxPaths(root: URL(fileURLWithPath: "/tmp/jx"))
        XCTAssertFalse(paths.contains(URL(fileURLWithPath: "/tmp/jx-evil")))
        XCTAssertFalse(paths.contains(URL(fileURLWithPath: "/tmp/jxcode/home")))
        XCTAssertFalse(paths.contains(URL(fileURLWithPath: "/Users/someone")))
    }

    func testRequiredDirectoriesAllLiveInsideRoot() {
        let paths = SandboxPaths(root: URL(fileURLWithPath: "/tmp/jx"))
        for directory in paths.requiredDirectories {
            XCTAssertTrue(
                paths.contains(directory),
                "\(directory.path) escapes the sandbox root"
            )
        }
    }

    func testDisplayShortensSandboxPaths() {
        let paths = SandboxPaths(root: URL(fileURLWithPath: "/tmp/jx"))
        XCTAssertEqual(paths.display(paths.npmPrefix), "~sandbox/env/npm")
    }
}

// MARK: - Environment

final class SandboxEnvironmentTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!
    private var environment: SandboxEnvironment!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-tests-\(UUID().uuidString)")
        paths = SandboxPaths(root: root)
        environment = SandboxEnvironment(paths: paths)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - report()

    /// The inspector's output is the only place a user can see what the sandbox
    /// actually did to their environment. Coverage found the whole function
    /// unexecuted, which matters more here than elsewhere: every other check in
    /// this suite is a claim that the sandbox holds, and this is the surface
    /// that lets someone disagree with it.
    func testTheReportNamesTheRootAndEveryGroup() {
        let report = environment.report()

        XCTAssertTrue(
            report.hasPrefix("sandbox root   \(root.path)"),
            "the report does not start with the root it describes:\n\(report)"
        )
        for group in ["identity:", "xdg:", "packages:", "homebrew:", "agents:", "session:", "path:"] {
            XCTAssertTrue(
                report.contains(group),
                "the report does not mention the \(group) group:\n\(report)"
            )
        }
    }

    /// A value inside the sandbox must be shown as `~sandbox/…`, never as the
    /// raw path. A bare `/Users/...` line in the inspector is indistinguishable
    /// from a leak, and the reader has no way to tell which one they are
    /// looking at.
    func testSandboxedValuesAreShownRelativeToTheRoot() {
        let report = environment.report()
        let env = environment.build()

        for key in ["HOME", "TMPDIR", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR", "npm_config_prefix"] {
            guard let value = env[key] else {
                XCTFail("\(key) is not set")
                continue
            }
            XCTAssertTrue(value.hasPrefix(root.path), "\(key) is not in the sandbox: \(value)")
            XCTAssertFalse(
                report.contains(value),
                "\(key) is printed as the raw sandbox path (\(value)) instead of `~sandbox/…`"
            )
        }
        XCTAssertTrue(report.contains("~sandbox"), "nothing was rendered sandbox-relative")
    }

    /// PATH is deliberately mixed — sandbox prefixes first, then the system's
    /// own tools — so each entry is labelled. The labels are the whole point:
    /// without them a mixed PATH reads as a containment failure.
    func testPathEntriesAreLabelledAndTheLabelMatchesThePath() throws {
        let report = environment.report()
        let marker = try XCTUnwrap(report.range(of: "path:"))
        let body = String(report[marker.lowerBound...])

        XCTAssertTrue(body.contains("[sandbox]"), "no PATH entry was labelled sandbox:\n\(body)")
        XCTAssertTrue(body.contains("[host   ]"), "no PATH entry was labelled host:\n\(body)")

        for line in body.split(separator: "\n").dropFirst() {
            let text = String(line)
            guard text.contains("] ") else { continue }
            XCTAssertEqual(
                text.contains("[sandbox]"), text.contains("~sandbox"),
                "the label disagrees with the path it labels: \(text)"
            )
        }
    }

    func testHomePointsInsideSandbox() {
        let env = environment.build()
        XCTAssertEqual(env["HOME"], paths.home.path)
        XCTAssertTrue(paths.contains(URL(fileURLWithPath: env["HOME"]!)))
    }

    func testTmpAndXDGPointInsideSandbox() {
        let env = environment.build()
        for key in ["TMPDIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "ZDOTDIR"] {
            let value = try? XCTUnwrap(env[key])
            XCTAssertNotNil(value, "\(key) should be set")
            XCTAssertTrue(
                paths.contains(URL(fileURLWithPath: env[key]!)),
                "\(key) points outside the sandbox: \(env[key]!)"
            )
        }
    }

    /// These are the variables that decide whether an agent writes to the
    /// sandbox or to the user's real home.
    func testAgentConfigRootsAreContained() {
        let env = environment.build()
        for key in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GEMINI_CONFIG_DIR"] {
            guard let value = env[key] else {
                XCTFail("\(key) is not set — the agent would fall back to a home lookup")
                continue
            }
            XCTAssertTrue(paths.contains(URL(fileURLWithPath: value)), "\(key) leaks: \(value)")
        }
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], paths.claudeConfig.path)
    }

    /// oh-my-pi and Jules have no config-directory override, so they are only
    /// isolated because $HOME is. Assert the directories they will derive.
    func testHomeOnlyToolsResolveInsideSandbox() {
        let env = environment.build()
        let home = URL(fileURLWithPath: env["HOME"]!)
        for relative in [".omp", ".jules", ".bun"] {
            let derived = home.appendingPathComponent(relative)
            XCTAssertTrue(paths.contains(derived), "\(relative) would land at \(derived.path)")
        }
    }

    func testPackageManagerPrefixesAreContained() {
        let env = environment.build()
        for key in ["npm_config_prefix", "NPM_CONFIG_PREFIX", "CARGO_HOME", "GOPATH", "GEM_HOME", "BUN_INSTALL"] {
            guard let value = env[key] else {
                XCTFail("\(key) is not set")
                continue
            }
            XCTAssertTrue(paths.contains(URL(fileURLWithPath: value)), "\(key) leaks: \(value)")
        }
        for key in ["HOMEBREW_PREFIX", "HOMEBREW_CELLAR", "HOMEBREW_REPOSITORY"] {
            XCTAssertTrue(paths.contains(URL(fileURLWithPath: env[key]!)), "\(key) leaks")
        }
    }

    /// The host PATH must not be inherited — one entry is enough to escape.
    func testPathExcludesHostToolDirectories() {
        let entries = environment.buildPath()
        XCTAssertFalse(entries.contains("/usr/local/bin"), "/usr/local/bin is a host tool directory")
        XCTAssertFalse(entries.contains("/opt/homebrew/bin"))
        XCTAssertTrue(entries.allSatisfy { !$0.hasPrefix("/opt/homebrew") })

        // Sandbox entries must come first, before the system ones.
        let sandboxIndex = entries.firstIndex(of: paths.bin.path)
        let systemIndex = entries.firstIndex(of: "/usr/bin")
        XCTAssertNotNil(sandboxIndex)
        XCTAssertNotNil(systemIndex)
        XCTAssertLessThan(sandboxIndex!, systemIndex!)
    }

    func testIncludeHostLocalBinIsOptIn() {
        let permissive = SandboxEnvironment(
            paths: paths,
            options: SandboxOptions(includeHostLocalBin: true)
        )
        XCTAssertTrue(permissive.buildPath().contains("/usr/local/bin"))
        XCTAssertFalse(environment.buildPath().contains("/usr/local/bin"))
    }

    func testPathIsDeduplicated() {
        let entries = environment.buildPath()
        XCTAssertEqual(entries.count, Set(entries).count)
    }

    func testEnvironmentArrayIsSortedAndComplete() {
        let array = environment.environmentArray()
        XCTAssertEqual(array, array.sorted())
        XCTAssertTrue(array.contains { $0.hasPrefix("HOME=") })
    }

    func testRouterInjectionIsOffByDefaultAndOnWhenConfigured() {
        XCTAssertNil(environment.build()["ANTHROPIC_BASE_URL"])

        let routed = SandboxEnvironment(
            paths: paths,
            options: SandboxOptions(routerURL: "http://127.0.0.1:8787")
        )
        let env = routed.build()
        XCTAssertEqual(env["ANTHROPIC_BASE_URL"], "http://127.0.0.1:8787")
        XCTAssertEqual(env["OPENAI_BASE_URL"], "http://127.0.0.1:8787")
    }

    func testWorkspaceContextIsExposed() {
        let workspace = Workspace(name: "demo", path: paths.home.path)
        let env = environment.build(workspace: workspace)
        XCTAssertEqual(env["JXCODE_WORKSPACE"], "demo")
        XCTAssertEqual(env["JXCODE_WORKSPACE_DIR"], paths.home.path)
        XCTAssertEqual(env["JXCODE_SANDBOX"], "1")
    }

    func testExtraEnvOverridesWin() {
        let custom = SandboxEnvironment(
            paths: paths,
            options: SandboxOptions(extraEnv: ["CLAUDE_CONFIG_DIR": "/tmp/override"])
        )
        XCTAssertEqual(custom.build()["CLAUDE_CONFIG_DIR"], "/tmp/override")
    }
}

// MARK: - Shell init

final class ShellInitTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-shell-\(UUID().uuidString)")
        paths = SandboxPaths(root: root)
        try ShellInit.install(paths: paths, realHome: "/Users/example")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testGeneratesAllInitFiles() {
        for name in [".zshenv", ".zprofile", ".zshrc"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: paths.zshDir.appendingPathComponent(name).path),
                "\(name) was not generated"
            )
        }
    }

    func testZshenvPinsHomeAndPaths() throws {
        let contents = try String(
            contentsOf: paths.zshDir.appendingPathComponent(".zshenv"),
            encoding: .utf8
        )
        XCTAssertTrue(contents.contains("export HOME=\"$JXCODE_HOME\""))
        XCTAssertTrue(contents.contains(paths.home.path))
        XCTAssertTrue(contents.contains(paths.bin.path))
        XCTAssertTrue(contents.contains("_jx_assert_path"))
    }

    /// path_helper runs from /etc/zprofile, so the re-assert has to happen in
    /// .zprofile and .zshrc as well — .zshenv alone would be overwritten.
    func testPathIsReassertedAfterSystemProfile() throws {
        for name in [".zprofile", ".zshrc"] {
            let contents = try String(
                contentsOf: paths.zshDir.appendingPathComponent(name),
                encoding: .utf8
            )
            XCTAssertTrue(contents.contains("_jx_assert_path"), "\(name) does not re-assert PATH")
        }
    }

    func testGlobalClaudeMemoryIsSeededInsideSandbox() throws {
        let memory = paths.claudeConfig.appendingPathComponent("CLAUDE.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: memory.path))

        let contents = try String(contentsOf: memory, encoding: .utf8)
        XCTAssertTrue(contents.contains(paths.claudeConfig.path))
        // It must be explicit that this is not the host file.
        XCTAssertTrue(contents.contains("/Users/example/.claude/CLAUDE.md"))
    }

    func testGitConfigIncludesHostReadOnly() throws {
        let contents = try String(contentsOf: paths.gitConfig, encoding: .utf8)
        XCTAssertTrue(contents.contains("/Users/example/.gitconfig"))
    }
}

// MARK: - Import

final class ImportServiceTests: XCTestCase {

    private var root: URL!
    private var host: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
        root = base.appendingPathComponent("jxcode-import-\(UUID().uuidString)")
        host = base.appendingPathComponent("jxcode-host-\(UUID().uuidString)")
        paths = SandboxPaths(root: root)
        try paths.createDirectories()
        try FileManager.default.createDirectory(
            at: host.appendingPathComponent(".claude"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: host)
    }

    private func type(at url: URL) throws -> FileAttributeType? {
        (try FileManager.default.attributesOfItem(atPath: url.path))[.type] as? FileAttributeType
    }

    private func text(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    /// The real-world case: `~/.claude/skills` is often a symlink into iCloud or
    /// a shared repo. Recreating that link inside the sandbox hands the sandbox
    /// a live path to the host, so it is copied as content instead — and a write
    /// inside the sandbox must stay inside it.
    func testALinkOutOfTheSandboxIsCopiedNotRecreated() throws {
        let fm = FileManager.default
        let claude = host.appendingPathComponent(".claude")

        let shared = host.appendingPathComponent("shared-skills")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try "skill body".write(
            to: shared.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )
        try fm.createSymbolicLink(
            atPath: claude.appendingPathComponent("skills").path,
            withDestinationPath: shared.path
        )

        let plan = ImportService.plan(paths: paths, realHome: host.path)
        let entry = try XCTUnwrap(plan.entries.first { $0.source.lastPathComponent == "skills" })
        XCTAssertEqual(entry.kind, .symlink)
        XCTAssertTrue(entry.escapesSandbox, "a link out of the sandbox should be flagged")

        try ImportService.apply(plan)

        let destination = paths.claudeConfig.appendingPathComponent("skills")
        XCTAssertEqual(
            try type(at: destination), .typeDirectory,
            "the link was recreated, so the sandbox holds a path back to the host"
        )
        XCTAssertFalse(
            destination.resolvingSymlinksInPath().path.hasPrefix(host.path),
            "the import resolved to the host directory"
        )
        XCTAssertEqual(try text(at: destination.appendingPathComponent("SKILL.md")), "skill body")

        // The harm the copy prevents: editing inside the sandbox must not edit
        // the host.
        try "edited in the sandbox".write(
            to: destination.appendingPathComponent("SKILL.md"),
            atomically: true, encoding: .utf8
        )
        XCTAssertEqual(
            try text(at: shared.appendingPathComponent("SKILL.md")), "skill body",
            "a write inside the sandbox reached the host"
        )
    }

    /// A link is still a link when recreating it is safe: it resolves inside the
    /// sandbox and to something that is actually there.
    func testALinkThatResolvesInsideTheSandboxIsRecreated() throws {
        let fm = FileManager.default
        let claude = host.appendingPathComponent(".claude")

        // The host side, needed for the link to be readable at all.
        try fm.createDirectory(
            at: host.appendingPathComponent("shared-skills"), withIntermediateDirectories: true
        )
        try "on host".write(
            to: host.appendingPathComponent("shared-skills/SKILL.md"),
            atomically: true, encoding: .utf8
        )
        try fm.createSymbolicLink(
            atPath: claude.appendingPathComponent("skills").path,
            withDestinationPath: "../shared-skills"
        )

        // The same relative target inside the sandbox, where the link will land.
        try fm.createDirectory(
            at: paths.home.appendingPathComponent("shared-skills"), withIntermediateDirectories: true
        )
        try "in sandbox".write(
            to: paths.home.appendingPathComponent("shared-skills/SKILL.md"),
            atomically: true, encoding: .utf8
        )

        let plan = ImportService.plan(paths: paths, realHome: host.path)
        let entry = try XCTUnwrap(plan.entries.first { $0.source.lastPathComponent == "skills" })
        XCTAssertFalse(entry.escapesSandbox, "a link that stays inside is not an escape")

        try ImportService.apply(plan)

        let destination = paths.claudeConfig.appendingPathComponent("skills")
        XCTAssertEqual(try type(at: destination), .typeSymbolicLink)
        XCTAssertEqual(
            try text(at: destination.appendingPathComponent("SKILL.md")), "in sandbox",
            "the recreated link resolved to the host, not to the sandbox"
        )
    }

    /// `copyItem` reproduces a symlink as a symlink, so a link one level down in
    /// a copied tree would survive the copy and escape anyway.
    func testALinkInsideACopiedTreeIsNotRecreated() throws {
        let fm = FileManager.default
        let skills = host.appendingPathComponent(".claude/skills")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try "top level".write(
            to: skills.appendingPathComponent("TOP.md"), atomically: true, encoding: .utf8
        )

        let elsewhere = host.appendingPathComponent("elsewhere")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try "elsewhere body".write(
            to: elsewhere.appendingPathComponent("E.md"), atomically: true, encoding: .utf8
        )
        try fm.createSymbolicLink(
            atPath: skills.appendingPathComponent("nested").path,
            withDestinationPath: elsewhere.path
        )

        try ImportService.apply(ImportService.plan(paths: paths, realHome: host.path))

        let nested = paths.claudeConfig.appendingPathComponent("skills/nested")
        XCTAssertEqual(
            try type(at: nested), .typeDirectory,
            "a link inside the copied tree was recreated, escaping the sandbox"
        )
        XCTAssertEqual(try text(at: nested.appendingPathComponent("E.md")), "elsewhere body")
        XCTAssertEqual(
            try text(at: paths.claudeConfig.appendingPathComponent("skills/TOP.md")), "top level",
            "the rest of the tree should survive the link being replaced"
        )
    }

    /// A link to a directory containing itself is a loop. `replaceLinks` must
    /// terminate rather than copy until the disk fills.
    func testALinkLoopTerminates() throws {
        let fm = FileManager.default
        let skills = host.appendingPathComponent(".claude/skills")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try "top level".write(
            to: skills.appendingPathComponent("TOP.md"), atomically: true, encoding: .utf8
        )
        try fm.createSymbolicLink(
            atPath: skills.appendingPathComponent("loop").path,
            withDestinationPath: skills.path
        )
        try fm.createSymbolicLink(
            atPath: skills.appendingPathComponent("self").path,
            withDestinationPath: "."
        )

        try ImportService.apply(ImportService.plan(paths: paths, realHome: host.path))

        let destination = paths.claudeConfig.appendingPathComponent("skills")
        XCTAssertEqual(try type(at: destination), .typeDirectory)
        XCTAssertEqual(try text(at: destination.appendingPathComponent("TOP.md")), "top level")
        XCTAssertNil(
            try? type(at: destination.appendingPathComponent("self")),
            "a link to its own directory was followed instead of dropped"
        )
    }

    /// Two directories that link to each other. Neither link contains its own
    /// target, so only the record of what has already been copied stops the
    /// tree being duplicated once per level.
    func testMutuallyRecursiveLinksTerminate() throws {
        let fm = FileManager.default
        let skills = host.appendingPathComponent(".claude/skills")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try "top level".write(
            to: skills.appendingPathComponent("TOP.md"), atomically: true, encoding: .utf8
        )
        let other = host.appendingPathComponent("other")
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try "other body".write(
            to: other.appendingPathComponent("O.md"), atomically: true, encoding: .utf8
        )
        try fm.createSymbolicLink(
            atPath: skills.appendingPathComponent("other").path,
            withDestinationPath: other.path
        )
        try fm.createSymbolicLink(
            atPath: other.appendingPathComponent("back").path,
            withDestinationPath: skills.path
        )

        try ImportService.apply(ImportService.plan(paths: paths, realHome: host.path))

        let destination = paths.claudeConfig.appendingPathComponent("skills")
        XCTAssertEqual(try text(at: destination.appendingPathComponent("TOP.md")), "top level")
        XCTAssertEqual(
            try text(at: destination.appendingPathComponent("other/O.md")), "other body"
        )
        XCTAssertNil(
            try? type(at: destination.appendingPathComponent("other/back")),
            "a link back to a directory already copied was duplicated instead of dropped"
        )
    }

    /// A broken link is still an entry at the destination. Without an overwrite
    /// it must be left alone, not silently replaced.
    func testADanglingDestinationIsKeptWhenNotOverwriting() throws {
        let fm = FileManager.default
        try "# host memory\n".write(
            to: host.appendingPathComponent(".claude/CLAUDE.md"),
            atomically: true, encoding: .utf8
        )
        let destination = paths.claudeConfig.appendingPathComponent("CLAUDE.md")
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fm.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: host.appendingPathComponent("gone.md").path
        )

        let messages = try ImportService.apply(
            ImportService.plan(paths: paths, realHome: host.path)
        )
        XCTAssertTrue(
            messages.contains { $0.contains("kept existing") },
            "a broken link at the destination was not recognised as existing: \(messages)"
        )
        XCTAssertEqual(try type(at: destination), .typeSymbolicLink)
    }

    /// The finding: `removeItem` then `copyItem` leaves nothing behind if the
    /// copy fails. The existing destination must survive a failed import.
    func testAFailedImportLeavesTheExistingDestinationIntact() throws {
        let fm = FileManager.default
        let skills = host.appendingPathComponent(".claude/skills")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try "host version".write(
            to: skills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        // Unreadable, so the copy fails part way through the tree.
        let locked = skills.appendingPathComponent("locked.md")
        try "secret".write(to: locked, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let destination = paths.claudeConfig.appendingPathComponent("skills")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try "existing".write(
            to: destination.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        let plan = ImportService.plan(paths: paths, realHome: host.path)
        XCTAssertThrowsError(
            try ImportService.apply(plan, overwrite: true),
            "the unreadable file should make the copy fail"
        )
        XCTAssertEqual(
            try text(at: destination.appendingPathComponent("SKILL.md")), "existing",
            "the destination was destroyed before its replacement existed"
        )
    }

    /// Overwrite replaces the whole item: content is swapped in, and nothing
    /// that was only at the old destination survives.
    func testOverwriteReplacesADirectoryAndLeavesNothingBehind() throws {
        let fm = FileManager.default
        let skills = host.appendingPathComponent(".claude/skills")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try "new".write(
            to: skills.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )

        let destination = paths.claudeConfig.appendingPathComponent("skills")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try "old".write(
            to: destination.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8
        )
        try "only in the old one".write(
            to: destination.appendingPathComponent("STALE.md"), atomically: true, encoding: .utf8
        )

        try ImportService.apply(
            ImportService.plan(paths: paths, realHome: host.path), overwrite: true
        )

        XCTAssertEqual(try text(at: destination.appendingPathComponent("SKILL.md")), "new")
        XCTAssertNil(
            try? type(at: destination.appendingPathComponent("STALE.md")),
            "the replace merged into the old directory instead of replacing it"
        )
        let leftovers = try fm.contentsOfDirectory(
            at: paths.claudeConfig, includingPropertiesForKeys: nil
        )
        XCTAssertEqual(
            leftovers.filter { $0.lastPathComponent.hasPrefix(".skills") }, [],
            "a staging item was left behind: \(leftovers.map(\.lastPathComponent))"
        )
    }

    /// A destination that is a symlink — the state a previous, buggy import left
    /// behind. `FileManager.replaceItemAt` refuses these outright, and writing
    /// through the link would reach the host.
    func testOverwriteReplacesASymlinkDestinationWithoutWritingThroughIt() throws {
        let fm = FileManager.default
        let outside = host.appendingPathComponent("outside.md")
        try "host original".write(to: outside, atomically: true, encoding: .utf8)

        try "# host memory\n".write(
            to: host.appendingPathComponent(".claude/CLAUDE.md"),
            atomically: true, encoding: .utf8
        )

        let destination = paths.claudeConfig.appendingPathComponent("CLAUDE.md")
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fm.createSymbolicLink(atPath: destination.path, withDestinationPath: outside.path)

        try ImportService.apply(
            ImportService.plan(paths: paths, realHome: host.path), overwrite: true
        )

        XCTAssertEqual(
            try type(at: destination), .typeRegular,
            "the symlink destination was not replaced"
        )
        XCTAssertEqual(try text(at: destination), "# host memory\n")
        XCTAssertEqual(
            try text(at: outside), "host original",
            "the import wrote through the link and onto the host"
        )
    }

    /// A broken link at the destination reads as absent to `fileExists`, so the
    /// write used to fail with "file exists" and the entry was lost.
    func testADanglingDestinationIsReplaced() throws {
        let fm = FileManager.default
        try "# host memory\n".write(
            to: host.appendingPathComponent(".claude/CLAUDE.md"),
            atomically: true, encoding: .utf8
        )

        let destination = paths.claudeConfig.appendingPathComponent("CLAUDE.md")
        try fm.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try fm.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: host.appendingPathComponent("gone.md").path
        )

        try ImportService.apply(
            ImportService.plan(paths: paths, realHome: host.path), overwrite: true
        )

        XCTAssertEqual(try type(at: destination), .typeRegular)
        XCTAssertEqual(try text(at: destination), "# host memory\n")
    }

    func testRegularFilesAreCopiedWithContent() throws {
        let claude = host.appendingPathComponent(".claude")
        try "# host memory\n".write(
            to: claude.appendingPathComponent("CLAUDE.md"),
            atomically: true, encoding: .utf8
        )

        let plan = ImportService.plan(paths: paths, realHome: host.path)
        try ImportService.apply(plan)

        // ShellInit seeds a CLAUDE.md; import must not clobber it by default.
        let memory = try String(
            contentsOf: paths.claudeConfig.appendingPathComponent("CLAUDE.md"),
            encoding: .utf8
        )
        XCTAssertFalse(memory.isEmpty)
    }

    func testSessionStateIsSkipped() throws {
        let claude = host.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(
            at: claude.appendingPathComponent("projects"),
            withIntermediateDirectories: true
        )

        let plan = ImportService.plan(paths: paths, realHome: host.path)
        XCTAssertTrue(
            plan.skipped.contains { $0.path == ".claude/projects" },
            "session history should be listed as skipped, not silently ignored"
        )
        XCTAssertFalse(plan.entries.contains { $0.source.path.contains("/projects") })
    }

    func testMissingHostConfigProducesEmptyPlan() {
        let emptyHost = host.appendingPathComponent("nonexistent")
        let plan = ImportService.plan(paths: paths, realHome: emptyHost.path)
        XCTAssertTrue(plan.entries.isEmpty)
    }
}

// MARK: - Workspaces

final class WorkspaceStoreTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-ws-\(UUID().uuidString)")
        paths = SandboxPaths(root: root)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSlugIsFilesystemSafe() {
        XCTAssertEqual(Workspace.slug("My Project"), "my-project")
        XCTAssertEqual(Workspace.slug("a/b:c*d"), "abcd")
        XCTAssertEqual(Workspace.slug("   "), "workspace")
    }

    func testCreatePersistsAndReloads() throws {
        let store = WorkspaceStore(paths: paths)
        let created = try store.create(name: "demo")
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path))

        let reloaded = WorkspaceStore(paths: paths)
        XCTAssertEqual(reloaded.workspaces.count, 1)
        XCTAssertEqual(reloaded.workspaces.first?.name, "demo")
    }

    func testNameCollisionsGetSuffixed() throws {
        let store = WorkspaceStore(paths: paths)
        let first = try store.create(name: "demo")
        let second = try store.create(name: "demo")
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertTrue(second.path.hasSuffix("demo-2"))
    }

    /// Forgetting a workspace must not delete the user's directory.
    func testRemoveLeavesDirectoryOnDisk() throws {
        let store = WorkspaceStore(paths: paths)
        let created = try store.create(name: "demo")
        try store.remove(id: created.id)

        XCTAssertTrue(store.workspaces.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: created.path),
            "the workspace directory was deleted — it should only be forgotten"
        )
    }
}

// MARK: - Agents

final class AgentRegistryTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!
    private var registry: AgentRegistry!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-agents-\(UUID().uuidString)")
        paths = SandboxPaths(root: root)
        try paths.createDirectories()
        registry = AgentRegistry(paths: paths)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBuiltInAgentsArePresent() {
        let ids = Set(registry.agents.map(\.id))
        for expected in ["claude", "codex", "gemini", "opencode", "omp", "jules", "shell"] {
            XCTAssertTrue(ids.contains(expected), "\(expected) is missing from the agent list")
        }
    }

    func testOmpUsesNpmInstallSoItLandsInTheSandbox() throws {
        let omp = try XCTUnwrap(registry.agent(id: "omp"))
        XCTAssertEqual(omp.command, "omp")
        // npm honours npm_config_prefix; omp.sh's curl installer does not.
        XCTAssertEqual(omp.installCommand, "npm i -g @oh-my-pi/pi-coding-agent")
    }

    func testJulesHasBothTerminalAndWebSurfaces() throws {
        let jules = try XCTUnwrap(registry.agent(id: "jules"))
        XCTAssertEqual(jules.command, "jules")
        XCTAssertEqual(jules.installCommand, "npm i -g @google/jules")
        // Jules is async: the CLI dispatches, the dashboard is web.
        XCTAssertEqual(jules.webURL, "https://jules.google.com")
    }

    /// A registered agent must survive a restart.
    ///
    /// `add()` used to store the caller's `isBuiltIn` unchanged, and the
    /// `AgentDefinition` initialiser defaults it to `true`. `saveCustom()`
    /// persists only non-built-in entries, so `add()` reported success, put the
    /// agent in the in-memory list, and wrote `[]` to disk. The agent was gone
    /// on the next launch — and `jxcode install <id>`, which runs in a fresh
    /// process, could not find it even immediately afterwards.
    func testACustomAgentSurvivesAReload() throws {
        try registry.add(AgentDefinition(
            id: "mine",
            name: "My agent",
            command: "mine",
            installCommand: "npm i -g mine"
        ))

        let reloaded = AgentRegistry(paths: paths)
        let found = try XCTUnwrap(
            reloaded.agent(id: "mine"),
            "the agent did not survive a reload — agents.json held "
                + ((try? String(contentsOf: paths.agentsFile, encoding: .utf8)) ?? "<unreadable>")
        )

        XCTAssertEqual(found.name, "My agent")
        XCTAssertEqual(found.installCommand, "npm i -g mine")
        XCTAssertFalse(found.isBuiltIn, "anything added at runtime is custom")
    }

    /// The built-ins must not be swept up by the same rule.
    func testBuiltInsAreNotMarkedCustom() throws {
        try registry.add(AgentDefinition(id: "mine", name: "My agent", command: "mine"))

        XCTAssertFalse(try XCTUnwrap(registry.agent(id: "mine")).isBuiltIn)
        XCTAssertTrue(
            try XCTUnwrap(registry.agent(id: "claude")).isBuiltIn,
            "adding a custom agent must not reclassify the built-ins"
        )
    }

    /// The plain shell deliberately uses the system `/bin/zsh`, so base system
    /// paths are fine. What must never happen is an agent resolving to a *host
    /// package-manager* location, because that binary would write to the host
    /// home regardless of the environment we set.
    func testNoAgentResolvesToAHostToolDirectory() {
        let env = SandboxEnvironment(paths: paths).build()
        let hostToolPrefixes = ["/usr/local", "/opt/homebrew"]

        for agent in registry.agents {
            guard let resolved = registry.resolvedPath(for: agent, environment: env) else { continue }
            let offender = hostToolPrefixes.first { resolved.hasPrefix($0) }
            XCTAssertNil(
                offender,
                "\(agent.name) resolves to a host tool directory: \(resolved)"
            )
        }
    }
}

// MARK: - Providers (phase 02 seam)

final class ProviderTests: XCTestCase {

    func testEndpointMappingPerKind() {
        let openAI = Provider(name: "vLLM", kind: .openAICompatible, baseURL: "http://box:8000/v1")
        XCTAssertEqual(openAI.modelsURL?.absoluteString, "http://box:8000/v1/models")
        XCTAssertEqual(openAI.chatURL?.absoluteString, "http://box:8000/v1/chat/completions")

        let anthropic = Provider(name: "Anthropic", kind: .anthropic, baseURL: "https://api.anthropic.com")
        XCTAssertEqual(anthropic.chatURL?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertFalse(anthropic.kind.requiresTranslation)

        let ollama = Provider(name: "Ollama", kind: .ollama, baseURL: "http://127.0.0.1:11434")
        XCTAssertEqual(ollama.modelsURL?.absoluteString, "http://127.0.0.1:11434/api/tags")
        XCTAssertEqual(ollama.chatURL?.absoluteString, "http://127.0.0.1:11434/api/chat")
    }

    /// Anthropic authenticates with x-api-key, not a bearer token. Getting this
    /// wrong is a common integration bug, so it is pinned here.
    func testAnthropicUsesApiKeyHeaderNotBearer() {
        let headers = ProviderKind.anthropic.authHeaders(apiKey: "sk-test")
        XCTAssertEqual(headers["x-api-key"], "sk-test")
        XCTAssertEqual(headers["anthropic-version"], "2023-06-01")
        XCTAssertNil(headers["Authorization"])

        let openAIHeaders = ProviderKind.openAICompatible.authHeaders(apiKey: "sk-test")
        XCTAssertEqual(openAIHeaders["Authorization"], "Bearer sk-test")
    }

    func testLocalGGUFIsOpenAICompatibleAndNeedsTranslation() {
        XCTAssertEqual(ProviderKind.localGGUF.chatPath, "{base}/chat/completions")
        XCTAssertTrue(ProviderKind.localGGUF.requiresTranslation)
        XCTAssertEqual(ProviderKind.localGGUF.defaultBaseURL, "http://127.0.0.1:8080")
    }

    /// The resolved URL, not the template, is what a request actually goes to.
    ///
    /// Asserting the path *template* is what let a real bug through: a local
    /// llama-server was registered with paths that already contained `/v1`
    /// while `normalizedBaseURL` was also appending one, so every chat request
    /// went to `/v1/v1/chat/completions` and 404'd. Both halves looked right in
    /// isolation. Only resolving them together shows it.
    func testLocalGgufResolvesToASingleV1Prefix() {
        // A bare host:port — the common case, and the one that broke.
        let bare = Provider(name: "Local", kind: .localGGUF, baseURL: "http://127.0.0.1:8080")
        XCTAssertEqual(bare.normalizedBaseURL, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(bare.chatURL?.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
        XCTAssertEqual(bare.modelsURL?.absoluteString, "http://127.0.0.1:8080/v1/models")

        // A base URL that already carries the prefix must not gain a second one.
        let explicit = Provider(name: "Local", kind: .localGGUF, baseURL: "http://127.0.0.1:8080/v1")
        XCTAssertEqual(explicit.normalizedBaseURL, "http://127.0.0.1:8080/v1")
        XCTAssertEqual(explicit.chatURL?.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")

        // A trailing slash must not produce `//chat/completions`.
        let slashed = Provider(name: "Local", kind: .localGGUF, baseURL: "http://127.0.0.1:8080/")
        XCTAssertEqual(slashed.chatURL?.absoluteString, "http://127.0.0.1:8080/v1/chat/completions")
    }

    func testEveryProviderKindResolvesWithoutADoubledPrefix() {
        // A local backend is not special; the same mistake could be made for
        // any kind, so check them all for the shape of the failure.
        let kinds: [ProviderKind] = [.openAICompatible, .anthropic, .ollama, .localGGUF]

        for kind in kinds {
            for base in ["http://127.0.0.1:8080", "http://127.0.0.1:8080/", "http://127.0.0.1:8080/v1"] {
                let provider = Provider(name: "p", kind: kind, baseURL: base)
                guard let chat = provider.chatURL?.absoluteString,
                      let models = provider.modelsURL?.absoluteString else {
                    XCTFail("\(kind) with base \(base) produced no URL")
                    continue
                }
                XCTAssertFalse(chat.contains("/v1/v1/"), "\(kind) \(base) -> \(chat)")
                XCTAssertFalse(models.contains("/v1/v1/"), "\(kind) \(base) -> \(models)")
                XCTAssertFalse(chat.contains("//chat"), "\(kind) \(base) -> \(chat)")
                XCTAssertFalse(chat.contains("//models"), "\(kind) \(base) -> \(chat)")
            }
        }
    }

    /// Pasting the `/v1` that appears in most Anthropic examples must not break
    /// the endpoint. This is the same defect as the local-GGUF one, in the kind
    /// whose paths carry their own prefix.
    func testAnthropicToleratesABaseUrlThatAlreadyEndsInV1() {
        for base in ["https://api.anthropic.com", "https://api.anthropic.com/", "https://api.anthropic.com/v1"] {
            let provider = Provider(name: "Anthropic", kind: .anthropic, baseURL: base)
            XCTAssertEqual(
                provider.chatURL?.absoluteString, "https://api.anthropic.com/v1/messages",
                "base \(base)"
            )
            XCTAssertEqual(
                provider.modelsURL?.absoluteString, "https://api.anthropic.com/v1/models",
                "base \(base)"
            )
        }
    }

    /// Ollama serves its native API at the root, so a pasted `/v1` has to come
    /// back off rather than turn `/api/tags` into `/v1/api/tags`.
    func testOllamaToleratesABaseUrlThatAlreadyEndsInV1() {
        for base in ["http://127.0.0.1:11434", "http://127.0.0.1:11434/", "http://127.0.0.1:11434/v1"] {
            let provider = Provider(name: "Ollama", kind: .ollama, baseURL: base)
            XCTAssertEqual(
                provider.chatURL?.absoluteString, "http://127.0.0.1:11434/api/chat",
                "base \(base)"
            )
            XCTAssertEqual(
                provider.modelsURL?.absoluteString, "http://127.0.0.1:11434/api/tags",
                "base \(base)"
            )
        }
    }

    /// A path that is not the standard prefix must be left alone — guessing
    /// would break a gateway mounted somewhere unusual.
    func testANonStandardPathIsNotRewritten() {
        let gateway = Provider(
            name: "Gateway",
            kind: .openAICompatible,
            baseURL: "https://gateway.internal/llm/v2"
        )
        XCTAssertEqual(gateway.normalizedBaseURL, "https://gateway.internal/llm/v2")
        XCTAssertEqual(gateway.chatURL?.absoluteString, "https://gateway.internal/llm/v2/chat/completions")
    }

    func testProviderStoreRoundTrips() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-providers-\(UUID().uuidString)")
        let paths = SandboxPaths(root: root)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProviderStore(paths: paths)
        try store.add(Provider(name: "local", kind: .localGGUF))
        try store.add(Provider(name: "box", kind: .openAICompatible, baseURL: "http://box:8000/v1"))

        let reloaded = ProviderStore(paths: paths)
        XCTAssertEqual(reloaded.providers.count, 2)
        XCTAssertEqual(reloaded.providers.map(\.name).sorted(), ["box", "local"])
    }

    /// Removing a provider is the other half of "register a list of custom
    /// api/backend-url", and it had no coverage at all — a provider that could
    /// not be deleted would have gone unnoticed.
    func testRemovingAProviderReachesTheFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-providers-\(UUID().uuidString)")
        let paths = SandboxPaths(root: root)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProviderStore(paths: paths)
        let vllm = Provider(name: "vLLM", kind: .openAICompatible, baseURL: "http://box:8000/v1")
        let ollama = Provider(name: "Ollama", kind: .ollama, baseURL: "http://127.0.0.1:11434")
        try store.add(vllm)
        try store.add(ollama)

        try store.remove(id: vllm.id)
        XCTAssertEqual(store.providers.map(\.name), ["Ollama"])

        // The in-memory list is rebuilt from disk on every launch, so a removal
        // that only mutated the array would silently come back.
        let reloaded = ProviderStore(paths: paths)
        XCTAssertEqual(
            reloaded.providers.map(\.name), ["Ollama"],
            "the removal was not persisted — the provider returns on next launch"
        )
    }

    /// Removing an id that is not there must be a no-op, not a crash and not a
    /// wipe of everything else.
    func testRemovingAnUnknownProviderLeavesTheRestAlone() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-providers-\(UUID().uuidString)")
        let paths = SandboxPaths(root: root)
        try paths.createDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ProviderStore(paths: paths)
        try store.add(Provider(name: "keep", kind: .localGGUF))

        try store.remove(id: UUID())
        XCTAssertEqual(store.providers.map(\.name), ["keep"])
    }

    /// The provider picker shows these strings. An empty one is invisible in a
    /// list; two kinds sharing one makes the choice ambiguous.
    func testEveryProviderKindHasItsOwnDisplayName() {
        let kinds = ProviderKind.allCases
        let names = kinds.map(\.displayName)

        XCTAssertEqual(kinds.count, 4, "a kind was added without updating this test")
        for (kind, name) in zip(kinds, names) {
            XCTAssertFalse(
                name.trimmingCharacters(in: .whitespaces).isEmpty,
                "\(kind) has an empty display name"
            )
        }
        XCTAssertEqual(
            Set(names).count, names.count,
            "two provider kinds share a display name: \(names)"
        )
    }
}

// MARK: - Dynamic isolation proof
//
// The static tests above assert that the environment we *build* is correct.
// These spawn real processes through `Sandbox.run` and check where they land.
// That distinction matters: a dictionary can be right while the process that
// receives it still escapes, because the shell is free to rewrite its own
// environment — and macOS `/etc/zprofile` does exactly that via path_helper.

final class IsolationProofTests: XCTestCase {

    private var root: URL!
    private var sandbox: Sandbox!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-proof-\(UUID().uuidString)")
        sandbox = Sandbox(paths: SandboxPaths(root: root))
        try sandbox.prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Run a script in a login shell inside the sandbox, return its output.
    private func shell(_ script: String) throws -> String {
        let result = try sandbox.run("/bin/zsh", arguments: ["-lc", script])
        XCTAssertTrue(result.succeeded, "command failed (\(result.exitCode)): \(result.combined)")
        return result.combined
    }

    func testSpawnedShellHomeIsInsideSandbox() throws {
        XCTAssertEqual(try shell("print -n $HOME"), sandbox.paths.home.path)
    }

    func testTildeExpansionStaysInsideSandbox() throws {
        let directory = try shell("cd ~ && pwd")
        XCTAssertTrue(
            sandbox.paths.contains(URL(fileURLWithPath: directory)),
            "`cd ~` landed at \(directory)"
        )
    }

    func testWritingToHomeLandsInsideSandbox() throws {
        let marker = "probe-\(UUID().uuidString.prefix(8))"
        let path = try shell("print -n \(marker) > $HOME/.\(marker) && print -n $HOME/.\(marker)")
        XCTAssertTrue(path.hasPrefix(sandbox.paths.home.path), "wrote to \(path)")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), marker)
    }

    func testClaudeConfigDirInSpawnedShell() throws {
        XCTAssertEqual(try shell("print -n $CLAUDE_CONFIG_DIR"), sandbox.paths.claudeConfig.path)
    }

    /// The headline claim of the whole app: Claude Code's *global* memory
    /// resolves to the sandbox file, and never to the host's.
    func testGlobalClaudeMemoryResolvesToSandboxCopy() throws {
        let memory = try shell("print -n $CLAUDE_CONFIG_DIR/CLAUDE.md")
        XCTAssertEqual(memory, sandbox.paths.claudeConfig.appendingPathComponent("CLAUDE.md").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: memory), "seeded memory file is missing")
        XCTAssertNotEqual(memory, NSHomeDirectory() + "/.claude/CLAUDE.md")
    }

    func testNpmPrefixInSpawnedShell() throws {
        XCTAssertEqual(try shell("print -n $npm_config_prefix"), sandbox.paths.npmPrefix.path)
    }

    func testBunInstallInSpawnedShell() throws {
        XCTAssertEqual(try shell("print -n $BUN_INSTALL"), sandbox.paths.bunInstall.path)
    }

    /// `/etc/zprofile` runs `/usr/libexec/path_helper`, which rebuilds PATH from
    /// `/etc/paths` — and that list starts with `/usr/local/bin`. This is the
    /// test that proves the re-assert in `.zprofile`/`.zshrc` actually wins.
    func testPathSurvivesPathHelper() throws {
        let path = try shell("print -n $PATH")
        let entries = path.split(separator: ":").map(String.init)

        XCTAssertTrue(
            entries.contains(sandbox.paths.bin.path),
            "sandbox bin missing from PATH after path_helper: \(path)"
        )
        XCTAssertFalse(entries.contains("/usr/local/bin"), "host tool directory leaked into PATH")
        XCTAssertFalse(entries.contains("/opt/homebrew/bin"), "host Homebrew leaked into PATH")

        let sandboxIndex = try XCTUnwrap(entries.firstIndex(of: sandbox.paths.bin.path))
        let systemIndex = try XCTUnwrap(entries.firstIndex(of: "/usr/bin"))
        XCTAssertLessThan(sandboxIndex, systemIndex, "sandbox entries must precede system ones")
    }

    /// oh-my-pi and Jules have no config-directory override, so $HOME is doing
    /// all the work for them. Assert the directories they will derive.
    func testHomeOnlyToolDirectoriesResolveInsideSandbox() throws {
        let home = try shell("print -n $HOME")
        for tool in [".omp", ".jules", ".bun"] {
            let derived = URL(fileURLWithPath: home).appendingPathComponent(tool)
            XCTAssertTrue(
                sandbox.paths.contains(derived),
                "\(tool) would resolve to \(derived.path)"
            )
        }
    }

    /// ZDOTDIR must point at generated init, otherwise the host `.zshrc` runs
    /// and can rewrite PATH and HOME back to the real ones.
    func testZdotdirIsSandboxLocal() throws {
        XCTAssertEqual(try shell("print -n $ZDOTDIR"), sandbox.paths.zshDir.path)
    }

    /// Host binaries under the real home are the ones a deny list misses.
    ///
    /// `~/.local/bin`, `~/.cargo/bin`, `~/.bun/bin`, `~/.volta/bin`,
    /// `~/.asdf/shims`, `~/Library/pnpm` and every nvm version directory hold
    /// host toolchains. They cannot be enumerated — a new runtime appears every
    /// year — so the rule has to be the directory rather than a list of names.
    ///
    /// The directories do not have to exist: this is a string filter on `PATH`,
    /// and asserting against the real home is the point.
    func testHostToolDirectoriesUnderTheRealHomeAreStripped() throws {
        let realHome = NSHomeDirectory()
        let hostile = [
            "\(realHome)/.local/bin",
            "\(realHome)/.cargo/bin",
            "\(realHome)/.bun/bin",
            "\(realHome)/.volta/bin",
            "\(realHome)/.asdf/shims",
            "\(realHome)/Library/pnpm",
            "\(realHome)/.nvm/versions/node/v20.11.0/bin",
        ]
        let list = hostile.map { "'\($0)'" }.joined(separator: " ")
        let entries = try shell("path=( \(list) '/usr/bin' ); _jx_assert_path; print -n $PATH")
            .split(separator: ":").map(String.init)

        for directory in hostile {
            XCTAssertFalse(entries.contains(directory), "\(directory) survived the re-assert")
        }
        XCTAssertTrue(entries.contains("/usr/bin"), "system entries must survive")
    }

    /// macOS reaches the same directory through `/Users/name` and
    /// `/System/Volumes/Data/Users/name`, so the comparison is made after
    /// resolving symlinks.
    func testARealHomeReachedThroughASymlinkIsStillStripped() throws {
        let link = root.appendingPathComponent("link-to-home")
        try FileManager.default.createSymbolicLink(
            atPath: link.path,
            withDestinationPath: NSHomeDirectory()
        )
        let throughLink = "\(link.path)/.local/bin"

        let entries = try shell("path=( '\(throughLink)' '/usr/bin' ); _jx_assert_path; print -n $PATH")
            .split(separator: ":").map(String.init)

        XCTAssertFalse(entries.contains(throughLink), "\(throughLink) survived the re-assert")
    }

    /// In production the sandbox lives *under* the real home, so "strip
    /// everything under the real home" strips the sandbox's own entries too.
    /// They are re-prepended from `$_JX_PRE`, which is what keeps the rule from
    /// being self-defeating — and this is the arrangement that matters, so it
    /// gets its own test rather than being assumed.
    func testSandboxEntriesSurviveStrippingWhenTheyLiveUnderTheRealHome() throws {
        let hostHome = root.appendingPathComponent("host-home")
        let nestedPaths = SandboxPaths(root: hostHome.appendingPathComponent("JXCode"))
        let nested = Sandbox(paths: nestedPaths)
        try nested.prepare()
        // Re-install with a real home that is an ancestor of the sandbox root.
        try ShellInit.install(paths: nestedPaths, realHome: hostHome.path)

        let result = try nested.run("/bin/zsh", arguments: ["-lc", "path=( '/usr/bin' ); _jx_assert_path; print -n $PATH"])
        XCTAssertTrue(result.succeeded, "command failed (\(result.exitCode)): \(result.combined)")

        let entries = result.combined
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":").map(String.init)

        XCTAssertEqual(
            entries.first, nestedPaths.bin.path,
            "sandbox bin must be re-prepended even though it lies under the real home"
        )
        XCTAssertFalse(
            entries.contains(hostHome.appendingPathComponent(".local/bin").path),
            "a host tool directory beside the sandbox survived"
        )
    }
}

// MARK: - Router environment, proved dynamically

/// The static dictionary is asserted elsewhere; this checks what a spawned
/// process actually receives.
///
/// The distinction matters for the same reason `path_helper` made it matter for
/// `PATH`: a dictionary can be correct while the process that receives it ends
/// up with something else, because the shell is free to rewrite its own
/// environment. Agents read `ANTHROPIC_BASE_URL` to find the router, so if the
/// generated init drops it, every agent silently talks to the real API instead
/// — which is exactly the failure this app exists to prevent, and it produces no
/// error.
final class RouterEnvironmentProofTests: XCTestCase {

    private var root: URL!

    private let routerURL = "http://127.0.0.1:8787"

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-router-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSandbox(routerURL: String? = nil, extraEnv: [String: String] = [:]) throws -> Sandbox {
        let sandbox = Sandbox(
            paths: SandboxPaths(root: root),
            options: SandboxOptions(extraEnv: extraEnv, routerURL: routerURL)
        )
        try sandbox.prepare()
        return sandbox
    }

    /// Run a script in a login shell, returning its output with no trailing newline.
    private func shell(_ sandbox: Sandbox, _ script: String) throws -> String {
        let result = try sandbox.run("/bin/zsh", arguments: ["-lc", script])
        return result.combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testRouterURLReachesASpawnedShell() throws {
        let sandbox = try makeSandbox(routerURL: routerURL)

        XCTAssertEqual(try shell(sandbox, "print -n $ANTHROPIC_BASE_URL"), routerURL)
        XCTAssertEqual(try shell(sandbox, "print -n $OPENAI_BASE_URL"), routerURL)
        XCTAssertEqual(try shell(sandbox, "print -n $JXCODE_ROUTER_URL"), routerURL)
    }

    func testRouterURLSurvivesIntoANestedProcess() throws {
        // The shell's own variables are not the point; the child an agent
        // actually launches is. `/usr/bin/env` re-reads the real environment.
        let sandbox = try makeSandbox(routerURL: routerURL)

        let output = try shell(sandbox, "/usr/bin/env | /usr/bin/grep '^ANTHROPIC_BASE_URL='")

        XCTAssertEqual(output, "ANTHROPIC_BASE_URL=\(routerURL)")
    }

    func testNoRouterURLMeansTheVariablesAreAbsent() throws {
        // Not empty — absent. An empty base URL would be read as "use the
        // default endpoint", which is the real API.
        let sandbox = try makeSandbox(routerURL: nil)

        XCTAssertEqual(try shell(sandbox, "print -n \"${ANTHROPIC_BASE_URL+SET}\""), "")
        XCTAssertEqual(try shell(sandbox, "print -n \"${OPENAI_BASE_URL+SET}\""), "")
        XCTAssertEqual(try shell(sandbox, "print -n \"${JXCODE_ROUTER_URL+SET}\""), "")
    }

    /// The security fix, verified where it actually has to hold.
    ///
    /// Claude Code reads `ANTHROPIC_API_KEY` and sends it as `X-Api-Key`. If it
    /// is *absent* rather than empty, a real key exported in the user's shell is
    /// inherited and sent straight to `api.anthropic.com`, bypassing the router
    /// and billing the user directly. An empty variable is the fix — but an
    /// empty environment variable is exactly the kind of thing a shell or an
    /// `execve` boundary can quietly drop, which would restore the bug while
    /// every unit test still passed.
    func testAnEmptyVariableIsStillPresentRatherThanDropped() throws {
        let sandbox = try makeSandbox(
            routerURL: routerURL,
            extraEnv: ["ANTHROPIC_API_KEY": ""]
        )

        // `${VAR+SET}` distinguishes "set but empty" from "unset".
        XCTAssertEqual(
            try shell(sandbox, "print -n \"${ANTHROPIC_API_KEY+SET}\""), "SET",
            "an empty ANTHROPIC_API_KEY was dropped, so a host key would be inherited"
        )
        XCTAssertEqual(try shell(sandbox, "print -n \"$ANTHROPIC_API_KEY\""), "")

        // And it must still be present one process further down.
        let nested = try shell(sandbox, "/usr/bin/env | /usr/bin/grep '^ANTHROPIC_API_KEY=$'")
        XCTAssertEqual(nested, "ANTHROPIC_API_KEY=", "the empty value did not survive into a child")
    }

    func testAHostKeyInTheEnvironmentDoesNotLeakIn() throws {
        // The sandbox rebuilds its environment rather than inheriting it, so a
        // key in the *host* environment must not appear at all. This is what
        // makes the explicit empty string safe to rely on.
        let sandbox = try makeSandbox(routerURL: routerURL, extraEnv: ["ANTHROPIC_API_KEY": ""])

        // `env` here is the host's, filtered to what the sandbox passed through.
        let output = try shell(sandbox, "/usr/bin/env | /usr/bin/grep -c '^ANTHROPIC_API_KEY=$'")
        XCTAssertEqual(output, "1", "expected exactly one empty ANTHROPIC_API_KEY, got: \(output)")
    }

    func testTheTokenAndModelOverridesReachTheShell() throws {
        // `AgentConfigWriter` puts these in Claude Code's settings.json, but the
        // sandbox can also carry them, and either way they have to survive.
        let sandbox = try makeSandbox(
            routerURL: routerURL,
            extraEnv: [
                "ANTHROPIC_AUTH_TOKEN": "test-token-abc123",
                "ANTHROPIC_MODEL": "claude-sonnet-4-5-20250929",
                "ANTHROPIC_SMALL_FAST_MODEL": "claude-haiku-4-5-20251001",
            ]
        )

        XCTAssertEqual(try shell(sandbox, "print -n $ANTHROPIC_AUTH_TOKEN"), "test-token-abc123")
        XCTAssertEqual(
            try shell(sandbox, "print -n $ANTHROPIC_MODEL"), "claude-sonnet-4-5-20250929"
        )
        XCTAssertEqual(
            try shell(sandbox, "print -n $ANTHROPIC_SMALL_FAST_MODEL"), "claude-haiku-4-5-20251001"
        )
    }

    func testTheRouterURLIsNotOverwrittenByShellInit() throws {
        // The generated init re-asserts PATH. If it were ever extended to reset
        // the environment wholesale, the router seam would break silently.
        //
        // Sourcing `.zshrc` prints the sandbox banner, so the value is marked
        // and extracted rather than compared against the whole output.
        let sandbox = try makeSandbox(routerURL: routerURL)

        let output = try shell(sandbox, """
        source $ZDOTDIR/.zshenv 2>/dev/null; source $ZDOTDIR/.zprofile 2>/dev/null; \
        source $ZDOTDIR/.zshrc 2>/dev/null; print -n "«${ANTHROPIC_BASE_URL}»"
        """)

        let extracted = output
            .components(separatedBy: "«").last?
            .components(separatedBy: "»").first

        XCTAssertEqual(extracted, routerURL, "the init rewrote the router URL; raw output: \(output)")
    }
}

/// Pins the pty launch path.
///
/// `Sandbox`'s doc comment claims "exactly one place where the environment is
/// decided", and a review found it was not true: `TerminalController` and the
/// CLI's `pty` command each built their own `PTYSession` and called `start()`
/// directly. The GUI's copy dropped `agent.environment` outright; the CLI's
/// installed `onData` *after* `start()` returned, and `PTYSession` does not
/// buffer — it calls `onData?(…)` and drops the bytes if nothing is attached —
/// so the first output of every `jxcode pty` run could be lost.
///
/// Both copies existed for the same reason: the handlers have to be installed
/// before the child can write, but `start()` is what forks it. `configure`
/// removes the need for a copy. These tests hold that shape in place.
final class SandboxLaunchPathTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-launch-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSandbox() throws -> Sandbox {
        let sandbox = Sandbox(paths: SandboxPaths(root: root))
        try sandbox.prepare()
        return sandbox
    }

    /// Collects pty output until the child exits, so a test can wait for a
    /// complete transcript instead of sleeping and hoping.
    private final class Transcript {
        private let condition = NSCondition()
        private var buffer = Data()
        private var finished = false
        private var status: Int32?

        func append(_ data: Data) {
            condition.lock()
            buffer.append(data)
            condition.unlock()
        }

        func finish(_ code: Int32) {
            condition.lock()
            finished = true
            status = code
            condition.broadcast()
            condition.unlock()
        }

        /// Waits for exit and returns what was captured.
        func wait(timeout: TimeInterval = 20) -> (text: String, code: Int32?) {
            condition.lock()
            let deadline = Date().addingTimeInterval(timeout)
            while !finished, condition.wait(until: deadline) {}
            let text = String(decoding: buffer, as: UTF8.self)
            let code = status
            condition.unlock()
            return (text, code)
        }

        var isFinished: Bool {
            condition.lock(); defer { condition.unlock() }
            return finished
        }
    }

    /// `print` in a child is the only way to observe what environment it got,
    /// so every check below goes through a real process.
    private func runAndCapture(
        _ sandbox: Sandbox,
        agent: AgentDefinition? = nil,
        command: String? = nil,
        arguments: [String] = [],
        extraEnvironment: [String: String] = [:],
        onSession: ((PTYSession) -> Void)? = nil
    ) throws -> (text: String, code: Int32?) {
        let transcript = Transcript()
        var handedOver: PTYSession?

        let configure: (PTYSession) -> Void = { session in
            handedOver = session
            session.onData = { transcript.append($0) }
            session.onExit = { transcript.finish($0) }
            onSession?(session)
        }

        let session: PTYSession
        if let agent {
            session = try sandbox.launch(
                agent: agent,
                extraEnvironment: extraEnvironment,
                columns: 200, rows: 50,
                configure: configure
            )
        } else {
            session = try sandbox.launchCommand(
                try XCTUnwrap(command),
                arguments: arguments,
                extraEnvironment: extraEnvironment,
                columns: 200, rows: 50,
                configure: configure
            )
        }

        // Deterministic and worth asserting on its own: the hook must be given
        // the very session that was launched, not a stand-in.
        XCTAssertTrue(handedOver === session, "configure was not given the launched session")

        let result = transcript.wait()
        return (result.text, result.code)
    }

    // MARK: - The bug this was written for

    func testAnAgentsOwnEnvironmentReachesTheChild() throws {
        // The GUI's hand-rolled launch skipped this merge. It was invisible
        // because every built-in agent ships an empty environment, which is
        // exactly why it is worth a test rather than a comment.
        let sandbox = try makeSandbox()
        let agent = AgentDefinition(
            id: "probe",
            name: "Probe",
            command: "/usr/bin/env",
            environment: ["JXCODE_AGENT_SCOPE": "from-the-agent-definition"]
        )

        let result = try runAndCapture(sandbox, agent: agent)

        XCTAssertEqual(result.code, 0)
        XCTAssertTrue(
            result.text.contains("JXCODE_AGENT_SCOPE=from-the-agent-definition"),
            "the agent's own environment never reached the child:\n\(result.text)"
        )
    }

    func testExtraEnvironmentOverridesTheAgentEnvironment() throws {
        // Precedence, not just presence: `extraEnvironment` is how the app
        // injects a per-launch value (a router URL, a model override) and it
        // has to win over the definition.
        let sandbox = try makeSandbox()
        let agent = AgentDefinition(
            id: "probe",
            name: "Probe",
            command: "/usr/bin/env",
            environment: ["JXCODE_PRECEDENCE": "agent"]
        )

        let result = try runAndCapture(
            sandbox, agent: agent,
            extraEnvironment: ["JXCODE_PRECEDENCE": "launch"]
        )

        XCTAssertTrue(
            result.text.contains("JXCODE_PRECEDENCE=launch"),
            "the launch override did not win:\n\(result.text)"
        )
        XCTAssertFalse(result.text.contains("JXCODE_PRECEDENCE=agent"))
    }

    func testTheSandboxEnvironmentIsTheBaseForBothLaunchForms() throws {
        // An agent tab and a bare command tab must agree about HOME, or the
        // isolation guarantee depends on which one you used.
        let sandbox = try makeSandbox()
        let agent = AgentDefinition(id: "probe", name: "Probe", command: "/usr/bin/env")

        let viaAgent = try runAndCapture(sandbox, agent: agent)
        let viaCommand = try runAndCapture(sandbox, command: "/usr/bin/env")

        for output in [viaAgent.text, viaCommand.text] {
            XCTAssertTrue(
                output.contains("HOME=\(sandbox.paths.home.path)"),
                "HOME is not the sandbox home:\n\(output)"
            )
        }
    }

    // MARK: - Handler ordering

    func testOutputWrittenImmediatelyIsNotLost() throws {
        // `PTYSession` calls `onData?(…)` and drops the bytes when no handler is
        // attached — there is no buffer. So a handler installed after `start()`
        // returns can miss whatever the child already wrote. `/bin/echo` writes
        // and exits at once, which is the worst case for that ordering.
        //
        // Run repeatedly because the failure is a race: one pass could get lucky.
        let sandbox = try makeSandbox()

        for attempt in 1...8 {
            let result = try runAndCapture(
                sandbox,
                command: "/bin/echo",
                arguments: ["jxcode-probe-\(attempt)"]
            )
            XCTAssertTrue(
                result.text.contains("jxcode-probe-\(attempt)"),
                "attempt \(attempt): the child's first output was dropped"
            )
        }
    }

    func testTheHookRunsBeforeTheChildCanWrite() throws {
        // The ordering claim stated directly: at the moment `configure` runs,
        // the session must not have been started yet, so nothing can have been
        // missed. `isRunning` is the observable form of "start() has returned".
        let sandbox = try makeSandbox()
        var runningWhenConfigured: Bool?

        _ = try runAndCapture(sandbox, command: "/bin/echo", arguments: ["x"]) { session in
            runningWhenConfigured = session.isRunning
        }

        XCTAssertEqual(
            runningWhenConfigured, false,
            "the hook was called after the session started, so early output can be lost"
        )
    }

    // MARK: - Failure modes

    func testAnUnresolvableCommandThrowsRatherThanFallingBack() throws {
        // The whole point of the isolation model: a missing binary must fail
        // loudly instead of quietly running the host's copy, which would write
        // to the host home.
        let sandbox = try makeSandbox()

        XCTAssertThrowsError(
            try sandbox.launchCommand("definitely-not-installed-anywhere")
        ) { error in
            guard case SandboxError.commandNotFound = error else {
                return XCTFail("expected commandNotFound, got \(error)")
            }
        }
    }

    func testAnUnresolvableAgentThrowsAgentNotInstalled() throws {
        let sandbox = try makeSandbox()
        let agent = AgentDefinition(
            id: "ghost", name: "Ghost",
            command: "definitely-not-installed-anywhere",
            installCommand: "npm i -g ghost"
        )

        XCTAssertThrowsError(try sandbox.launch(agent: agent)) { error in
            guard case SandboxError.agentNotInstalled = error else {
                return XCTFail("expected agentNotInstalled, got \(error)")
            }
            // The install hint is the user's way out, so it has to survive.
            XCTAssertTrue("\(error)".contains("npm i -g ghost"))
        }
    }
}

/// Exit-status and output-completeness of a pty session.
///
/// `PTYSession` watches a child two ways at once: a read source on the master
/// fd and a process source on the pid. Both want to be the one that ends the
/// session, and on a short-lived command they become ready at the same moment.
///
/// The original code let the read source finish with a hardcoded `0` on EOF
/// and, in doing so, cancelled the process source — the only place `waitpid`
/// was called. That makes two things possible, neither visible from a passing
/// test suite:
///
///   1. a failing command reported as success, which `jxcode pty` turns into
///      its own exit status and the GUI turns into "exited (0)";
///   2. an unreaped child, i.e. a zombie per tab.
///
/// Both are races, so these tests run a command repeatedly rather than once.
final class PTYExitStatusTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-pty-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSandbox() throws -> Sandbox {
        let sandbox = Sandbox(paths: SandboxPaths(root: root))
        try sandbox.prepare()
        return sandbox
    }

    private final class Exit {
        private let condition = NSCondition()
        private var code: Int32?
        private var output = Data()

        func append(_ data: Data) {
            condition.lock(); output.append(data); condition.unlock()
        }

        func finish(_ code: Int32) {
            condition.lock(); self.code = code; condition.broadcast(); condition.unlock()
        }

        func wait(timeout: TimeInterval = 3) -> (code: Int32?, text: String) {
            condition.lock()
            let deadline = Date().addingTimeInterval(timeout)
            while code == nil, condition.wait(until: deadline) {}
            let result = (code, String(decoding: output, as: UTF8.self))
            condition.unlock()
            return result
        }
    }

    private func launch(
        _ sandbox: Sandbox,
        _ command: String,
        _ arguments: [String]
    ) throws -> (session: PTYSession, exit: Exit) {
        let exit = Exit()
        let session = try sandbox.launchCommand(
            command, arguments: arguments, columns: 200, rows: 50
        ) { session in
            session.onData = { exit.append($0) }
            session.onExit = { exit.finish($0) }
        }
        return (session, exit)
    }

    /// Waits for the child, keeping the session alive for the duration.
    ///
    /// The session has to be held, not discarded: `deinit` closes the master
    /// fd, and with it closed neither the read source nor the process source
    /// ever fires again. A `let (_, exit) = …` here silently turns every
    /// assertion into a timeout, which is how this helper was written first.
    private func collect(
        _ launched: (session: PTYSession, exit: Exit),
        timeout: TimeInterval = 5
    ) -> (code: Int32?, text: String) {
        withExtendedLifetime(launched.session) {
            launched.exit.wait(timeout: timeout)
        }
    }

    func testAFailingCommandReportsItsExitStatus() throws {
        // A command that exits without printing anything is the worst case:
        // the pty reaches EOF at the same instant the process dies, so the
        // read source is as likely to end the session as the process source.
        let sandbox = try makeSandbox()

        for attempt in 1...12 {
            let launched = try launch(sandbox, "/bin/sh", ["-c", "exit 7"])
            let result = collect(launched)
            XCTAssertEqual(
                result.code, 7,
                "attempt \(attempt): a command that exited 7 was reported as \(result.code ?? -1)"
            )
        }
    }

    func testASignalDeathIsReportedAsOneTwentyEightPlusTheSignal() throws {
        let sandbox = try makeSandbox()

        for attempt in 1...8 {
            let launched = try launch(sandbox, "/bin/sh", ["-c", "kill -TERM $$"])
            let result = collect(launched)
            XCTAssertEqual(
                result.code, 128 + 15,
                "attempt \(attempt): SIGTERM was reported as \(result.code ?? -1)"
            )
        }
    }

    func testNoZombieIsLeftBehind() throws {
        // After `onExit` has fired the child is dead, so a `waitpid` that still
        // finds it means nobody reaped it. `waitpid` returning the pid is the
        // proof; ECHILD (-1) means it was already collected.
        let sandbox = try makeSandbox()

        for attempt in 1...12 {
            let launched = try launch(sandbox, "/bin/sh", ["-c", "exit 0"])
            _ = collect(launched)

            var status: Int32 = 0
            let reaped = waitpid(launched.session.pid, &status, WNOHANG)

            XCTAssertEqual(
                reaped, -1,
                "attempt \(attempt): child \(launched.session.pid) was still waiting to be "
                    + "reaped (a zombie). waitpid returned \(reaped)."
            )
            if reaped == -1 {
                // errno is only meaningful after a failure; checking it
                // unconditionally reports whatever the last call left behind.
                XCTAssertEqual(errno, ECHILD, "expected ECHILD, got errno \(errno)")
            }
        }
    }

    func testTheFinalOutputIsNotTruncated() throws {
        // The process source can fire while the pty still holds unread bytes.
        // If finishing cancels the read source at that moment, the tail of the
        // output is discarded — a plausible cause of "the last line of the
        // error message never appeared".
        //
        // Honest scope: this asserts that output is *complete*, which is the
        // property that matters, but it does **not** isolate the ordering that
        // protects it. Mutation testing confirmed as much — deleting the final
        // `self.drain()` from the process-source handler, which is the fix for
        // exactly this, leaves this test green.
        //
        // The reason is that the window cannot be forced from outside. A child
        // that writes more than the pty buffer holds blocks until the reader
        // drains, so it cannot exit with output still pending; a child that
        // writes less leaves the two sources racing on the order libdispatch
        // happens to deliver them, and the read source is resumed first.
        // `testNoOutputArrivesAfterExit` pins the barrier that the ordering
        // provides, which is the part that is observable.
        let sandbox = try makeSandbox()

        for attempt in 1...8 {
            let launched = try launch(
                sandbox, "/bin/sh",
                ["-c", "printf 'first\\n'; printf 'LAST-LINE-%d\\n' \(attempt)"]
            )
            let result = collect(launched)
            XCTAssertTrue(
                result.text.contains("LAST-LINE-\(attempt)"),
                "attempt \(attempt): the final line was lost; got:\n\(result.text)"
            )
        }
    }

    /// `onExit` is a barrier: nothing may be delivered after it.
    ///
    /// This is what "drain before finishing" buys, and unlike the truncation
    /// itself it *is* observable from outside — so it is the part worth
    /// pinning. A refactor that moved the final drain onto another queue, or
    /// let `onExit` fire before the last read landed, would break it.
    func testNoOutputArrivesAfterExit() throws {
        let sandbox = try makeSandbox()

        for attempt in 1...8 {
            let order = OrderRecorder()
            let exit = Exit()
            let session = try sandbox.launchCommand(
                "/bin/sh",
                arguments: ["-c", "printf 'a\\nb\\nc-%d\\n' \(attempt)"],
                columns: 200, rows: 50
            ) { session in
                session.onData = { data in
                    order.record(.data(String(decoding: data, as: UTF8.self)))
                    exit.append(data)
                }
                session.onExit = { code in
                    order.record(.exit)
                    exit.finish(code)
                }
            }

            _ = withExtendedLifetime(session) { exit.wait(timeout: 5) }

            XCTAssertFalse(
                order.sawDataAfterExit,
                "attempt \(attempt): bytes were delivered after onExit, so the tail can be lost"
            )
            XCTAssertTrue(
                order.events.contains { if case .data = $0 { return true } else { return false } },
                "attempt \(attempt): no output was captured at all"
            )
        }
    }

    /// The exit status must be right at every output volume, because the volume
    /// decides how the read loop behaves: a read that comes back exactly full
    /// makes `drain` loop, and a short read makes it return.
    ///
    /// Honest scope: this was written to reach `reap`, the fallback that ends
    /// the session when `drain` returns without reaching EOF. It does not.
    /// Coverage after adding it: the process-source handler fired once across
    /// 66 sessions and `drain` had already finished by then, so `reap`'s body
    /// never ran. The reason is ordering — the read source drains the pty
    /// eagerly, so by the time the process event is dequeued there is nothing
    /// buffered for `drain` to return early on. What this does pin is that the
    /// status is right at every volume, including the exact-buffer boundary
    /// where the loop is easiest to get wrong.
    func testTheExitStatusSurvivesEveryOutputVolume() throws {
        let sandbox = try makeSandbox()

        // 0 and 1 are the "EOF and exit collide" extreme; 65_536 and 200_000
        // cross the read-buffer boundary in `drain`.
        for volume in [0, 1, 4095, 65_536, 200_000] {
            for attempt in 1...3 {
                let launched = try launch(sandbox, "/bin/sh", [
                    "-c", "head -c \(volume) /dev/zero; exit 7",
                ])
                let result = collect(launched, timeout: 15)
                XCTAssertEqual(
                    result.code, 7,
                    "volume \(volume), attempt \(attempt): a command that exited 7 was "
                        + "reported as \(result.code.map(String.init) ?? "nothing")"
                )
            }
        }
    }

    /// An output that is an exact multiple of the read buffer is the boundary
    /// `drain`'s loop turns on: it reads a full 64 KiB, loops, and reads again.
    /// Getting that boundary wrong drops the last chunk.
    ///
    /// `/dev/zero` rather than a text payload on purpose — the pty rewrites
    /// `\n` as `\r\n`, so a newline-bearing payload would not have a
    /// predictable length.
    func testAnExactBufferOfOutputIsDeliveredInFull() throws {
        let sandbox = try makeSandbox()

        for size in [65_536, 131_072] {
            let launched = try launch(sandbox, "/bin/sh", [
                "-c", "head -c \(size) /dev/zero; exit 0",
            ])
            let result = collect(launched, timeout: 15)
            XCTAssertEqual(result.code, 0, "size \(size): reported \(result.code.map(String.init) ?? "nothing")")
            XCTAssertEqual(
                result.text.utf8.count, size,
                "size \(size): delivered \(result.text.utf8.count) bytes"
            )
        }
    }

    /// `ExecutableResolver` filters these out before `PTYSession` sees them, so
    /// this is `PTYSession`'s own contract rather than a reachable user path.
    /// It still matters: `start` is public, and the thrown message is what a
    /// user reads when a launch fails.
    func testStartingWithANonExecutablePathNamesThePath() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let script = root.appendingPathComponent("not-executable.sh")
        try "echo hi\n".write(to: script, atomically: true, encoding: .utf8)

        let session = PTYSession()
        XCTAssertThrowsError(
            try session.start(
                executable: script.path, environment: [:], workingDirectory: root.path
            )
        ) { error in
            guard case PTYError.executableNotFound(let path) = error else {
                return XCTFail("expected executableNotFound, got \(error)")
            }
            XCTAssertEqual(path, script.path)
            XCTAssertTrue(
                "\(error)".contains(script.path),
                "the message a user sees should name the path; got: \(error)"
            )
        }
    }

    /// The one case where `reachedEOF` must step aside: the pty closes while
    /// the child is still alive, so there is no status to take yet.
    ///
    /// Coverage showed this branch had never executed — in 65 sessions the
    /// process source never fired once, because the read source always ended
    /// the session first. That left the step-aside path, and the whole
    /// process-source handler behind it, untested. The risk it covers is real:
    /// if the session ended at EOF, a command that closes its terminal would
    /// be reported as exit 0; if it waited for another read that can never
    /// come, the tab would hang.
    ///
    /// `/usr/bin/python3` because it is the only interpreter here that can
    /// close its descriptors and keep running. `sh -c 'exec 0<&- 1>&- 2>&-'`
    /// does *not* produce the case — `lsof` shows bash holding fds 0, 1 and 2
    /// on the tty afterwards, and the master only sees EOF when the child
    /// exits. Measured with the python child: EOF arrives ~1.0s before the
    /// exit, reproducibly.
    func testAPtyThatClosesBeforeTheChildExitsStillEndsWithTheRealStatus() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("python3 is needed to close the pty from inside the child")
        }

        let sandbox = try makeSandbox()
        let script = """
        import os, time
        os.close(0); os.close(1); os.close(2)
        time.sleep(1.0)
        os._exit(9)
        """

        let launched = try launch(sandbox, "/usr/bin/python3", ["-c", script])
        let result = collect(launched, timeout: 15)

        // 9 can only come from the process source: at the moment the pty
        // closed there was no status to report. A session that finished at EOF
        // would report 0, and one that never finished would time out.
        XCTAssertEqual(
            result.code, 9,
            "a child that closed its pty and exited 9 later was reported as "
                + "\(result.code.map(String.init) ?? "nothing")"
        )
    }

    private enum Event: Equatable {
        case data(String)
        case exit
    }

    private final class OrderRecorder {
        private let lock = NSLock()
        private var _events: [Event] = []

        func record(_ event: Event) {
            lock.lock(); _events.append(event); lock.unlock()
        }

        var events: [Event] {
            lock.lock(); defer { lock.unlock() }
            return _events
        }

        var sawDataAfterExit: Bool {
            let snapshot = events
            guard let exitIndex = snapshot.firstIndex(of: .exit) else { return false }
            return snapshot[(exitIndex + 1)...].contains { if case .data = $0 { return true } else { return false } }
        }
    }
}

// MARK: - Interacting with a live session
//
// `write`, `resize` and `terminate` are what a user does to a terminal all day,
// and none of them had a test: they are called from `TerminalController` (the
// GUI) and the `pty` CLI command, both of which are outside this suite. The
// core layer is where they can be checked, and they are worth checking — a
// broken `write` makes the terminal unusable, a broken `resize` makes every TUI
// render at the wrong width, and a broken `terminate` leaves orphaned processes
// behind when a tab is closed.

final class PTYInteractiveTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-pty-io-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSandbox() throws -> Sandbox {
        let sandbox = Sandbox(paths: SandboxPaths(root: root))
        try sandbox.prepare()
        return sandbox
    }

    private final class Recorder {
        private let condition = NSCondition()
        private var code: Int32?
        private var output = Data()

        func append(_ data: Data) {
            condition.lock(); output.append(data); condition.unlock()
        }

        func finish(_ code: Int32) {
            condition.lock(); self.code = code; condition.broadcast(); condition.unlock()
        }

        func wait(timeout: TimeInterval) -> (code: Int32?, text: String) {
            condition.lock()
            let deadline = Date().addingTimeInterval(timeout)
            while code == nil, condition.wait(until: deadline) {}
            let result = (code, String(decoding: output, as: UTF8.self))
            condition.unlock()
            return result
        }
    }

    /// Holds the session for the duration — `deinit` closes the master fd and
    /// every callback dies with it.
    private func launch(
        _ sandbox: Sandbox,
        _ command: String,
        _ arguments: [String],
        columns: Int = 120,
        rows: Int = 32
    ) throws -> (session: PTYSession, recorder: Recorder) {
        let recorder = Recorder()
        let session = try sandbox.launchCommand(
            command, arguments: arguments, columns: columns, rows: rows
        ) { session in
            session.onData = { recorder.append($0) }
            session.onExit = { recorder.finish($0) }
        }
        return (session, recorder)
    }

    private func collect(
        _ launched: (session: PTYSession, recorder: Recorder),
        timeout: TimeInterval = 10
    ) -> (code: Int32?, text: String) {
        withExtendedLifetime(launched.session) {
            launched.recorder.wait(timeout: timeout)
        }
    }

    // MARK: - write

    /// The child has to actually receive the bytes. `read` in a pty is line
    /// buffered, so the newline is what releases the line — which also makes
    /// this the test for "does pressing Return reach the program".
    func testWritingToTheSessionReachesTheChild() throws {
        let sandbox = try makeSandbox()
        let marker = UUID().uuidString.prefix(8)

        for attempt in 1...3 {
            let launched = try launch(
                sandbox, "/bin/sh", ["-c", "read line; printf 'GOT:%s\\n' \"$line\""]
            )
            launched.session.write("payload-\(marker)-\(attempt)\n")

            let result = collect(launched)
            XCTAssertEqual(result.code, 0, "attempt \(attempt): \(result.text)")
            XCTAssertTrue(
                result.text.contains("GOT:payload-\(marker)-\(attempt)"),
                "attempt \(attempt): stdin did not reach the child:\n\(result.text)"
            )
        }
    }

    /// An empty write must be dropped by the guard, not passed to `write(2)` —
    /// and the `String` overload has to forward to the `Data` one.
    func testWritingNothingIsIgnoredAndTheStringOverloadWorks() throws {
        let sandbox = try makeSandbox()

        let launched = try launch(
            sandbox, "/bin/sh", ["-c", "read line; printf 'GOT:%s\\n' \"$line\""]
        )
        launched.session.write(Data())      // guard: !data.isEmpty
        launched.session.write("")          // String overload
        launched.session.write("real-input\n")

        let result = collect(launched)
        XCTAssertTrue(
            result.text.contains("GOT:real-input"),
            "the session stopped accepting input after an empty write:\n\(result.text)"
        )
    }

    /// Writing after the child is gone must be dropped, not attempted. The
    /// master fd is closed by then, and a `write` to a recycled descriptor
    /// number is the kind of thing that corrupts an unrelated file.
    func testWritingAfterExitIsIgnored() throws {
        let sandbox = try makeSandbox()

        let launched = try launch(sandbox, "/bin/sh", ["-c", "exit 0"])
        _ = collect(launched)
        XCTAssertFalse(launched.session.isRunning, "the session still claims to be running")

        launched.session.write("too late\n")
        launched.session.write(Data("also too late\n".utf8))
        // Reaching here without a crash or a signal is the assertion; the
        // explicit check is that the session stayed finished.
        XCTAssertFalse(launched.session.isRunning)
    }

    // MARK: - resize

    /// The size given at launch has to reach the pty, and a later resize has to
    /// reach it too — that is what raises SIGWINCH and makes a TUI reflow.
    func testTheSizeGivenAtLaunchReachesTheChild() throws {
        let sandbox = try makeSandbox()

        let launched = try launch(sandbox, "/bin/sh", ["-c", "stty size"], columns: 100, rows: 40)
        let result = collect(launched)

        XCTAssertEqual(result.code, 0, result.text)
        XCTAssertTrue(
            result.text.contains("40 100"),
            "`stty size` should report the launch size (rows cols):\n\(result.text)"
        )
    }

    func testResizingReachesTheChild() throws {
        let sandbox = try makeSandbox()

        // The sleep is the window for the resize to land before `stty` reads.
        let launched = try launch(
            sandbox, "/bin/sh", ["-c", "sleep 0.4; stty size"], columns: 100, rows: 40
        )
        launched.session.resize(columns: 132, rows: 50)

        let result = collect(launched)
        XCTAssertTrue(
            result.text.contains("50 132"),
            "the child still sees the old size after resize(columns: 132, rows: 50):\n\(result.text)"
        )
    }

    /// Zero is not a size a pty accepts, and a window can genuinely report it
    /// mid-animation. It is clamped rather than passed through.
    func testAResizeOfZeroIsClampedRatherThanPassedThrough() throws {
        let sandbox = try makeSandbox()

        let launched = try launch(
            sandbox, "/bin/sh", ["-c", "sleep 0.4; stty size"], columns: 100, rows: 40
        )
        launched.session.resize(columns: 0, rows: 0)

        let result = collect(launched)
        XCTAssertTrue(
            result.text.contains("1 1"),
            "a zero resize should clamp to 1x1:\n\(result.text)"
        )
    }

    /// After the session ends the descriptor is closed, so a resize has to be
    /// dropped by the guard rather than ioctl'd onto a closed fd.
    func testResizingAfterExitIsIgnored() throws {
        let sandbox = try makeSandbox()

        let launched = try launch(sandbox, "/bin/sh", ["-c", "exit 0"])
        _ = collect(launched)

        launched.session.resize(columns: 80, rows: 24)
        XCTAssertFalse(launched.session.isRunning)
    }

    // MARK: - terminate

    /// Closing a tab has to end a long-running child. `sleep 60` is not going
    /// to exit on its own, so a status can only mean a signal arrived.
    func testTerminatingEndsALongRunningChild() throws {
        let sandbox = try makeSandbox()
        let launched = try launch(sandbox, "/bin/sh", ["-c", "sleep 60"])
        Thread.sleep(forTimeInterval: 0.3)

        let started = Date()
        launched.session.terminate(gracePeriod: 1.0)
        let result = collect(launched, timeout: 10)
        let elapsed = Date().timeIntervalSince(started)

        let code = try XCTUnwrap(result.code, "the session never ended after terminate()")
        XCTAssertGreaterThanOrEqual(
            code, 128,
            "the child was going to sleep for 60s, so it can only have been killed; got exit \(code)"
        )
        XCTAssertLessThan(elapsed, 5, "terminate took \(elapsed)s to end the session")
    }

    /// The escalation path: a child that ignores SIGHUP must still be killed.
    /// Without it, closing a tab that ignores the hangup leaks the process for
    /// as long as the app runs.
    func testATerminateThatIsIgnoredEscalatesToSIGKILL() throws {
        let sandbox = try makeSandbox()
        let launched = try launch(sandbox, "/bin/sh", ["-c", "trap '' HUP; sleep 60"])
        Thread.sleep(forTimeInterval: 0.3)

        launched.session.terminate(gracePeriod: 0.5)
        let result = collect(launched, timeout: 10)

        let code = try XCTUnwrap(result.code, "the session never ended")
        XCTAssertEqual(
            code, 128 + 9,
            "a child that ignored SIGHUP should have been SIGKILLed after the grace period; got \(code)"
        )
    }

    /// `terminate` on a session that has already finished is a no-op, not a
    /// `kill` aimed at a pid that may have been recycled.
    func testTerminatingAFinishedSessionIsIgnored() throws {
        let sandbox = try makeSandbox()

        let launched = try launch(sandbox, "/bin/sh", ["-c", "exit 3"])
        let result = collect(launched)
        XCTAssertEqual(result.code, 3)

        launched.session.terminate(gracePeriod: 0.2)
        // The recorded status must not change: nothing was killed.
        let after = launched.recorder.wait(timeout: 0.5)
        XCTAssertEqual(after.code, 3, "terminate overwrote the exit status of a finished session")
    }
}

// MARK: - Router seam

/// A tab inherits the router from the sandbox, not from a config file.
///
/// Claude Code decides it is "not logged in" before it dials anything, so a
/// launched tab that lacks `ANTHROPIC_BASE_URL` *and* a credential exits
/// immediately. That made routing look broken whenever the user had not also
/// pressed Bind — two steps where one should do.
final class SandboxRouterSeamTests: XCTestCase {

    private func makeSandbox() -> Sandbox {
        Sandbox(paths: SandboxPaths(
            root: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("jxcode-seam-\(UUID().uuidString)")
        ))
    }

    /// Starting the router must reach processes launched afterwards.
    func testRouterURLReachesTheEnvironment() {
        let sandbox = makeSandbox()
        XCTAssertNil(sandbox.routerURL)

        sandbox.setRouter(url: "http://127.0.0.1:5255")
        XCTAssertEqual(sandbox.routerURL, "http://127.0.0.1:5255")

        let environment = sandbox.env()
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], "http://127.0.0.1:5255")
        XCTAssertEqual(environment["OPENAI_BASE_URL"], "http://127.0.0.1:5255")
    }

    /// The credential matters as much as the URL: with a base URL but no
    /// token, Claude Code still concludes it is not logged in.
    func testRouterCarriesACredential() {
        let sandbox = makeSandbox()
        sandbox.setRouter(url: "http://127.0.0.1:5255")

        let environment = sandbox.env()
        XCTAssertEqual(
            environment["ANTHROPIC_AUTH_TOKEN"], AgentConfigWriter.placeholderToken,
            "a routed tab needs a credential or Claude Code exits before dialling"
        )
        // Some builds prefer the API key when it is non-empty, which would
        // bypass the router's token check.
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "")
    }

    /// Stopping the router must retract it — otherwise a tab opened later
    /// inherits a URL nothing answers, which is the "connection refused" case.
    func testStoppingTheRouterRetractsIt() {
        let sandbox = makeSandbox()
        sandbox.setRouter(url: "http://127.0.0.1:5255")
        XCTAssertNotNil(sandbox.env()["ANTHROPIC_BASE_URL"])

        sandbox.setRouter(url: nil)
        XCTAssertNil(sandbox.routerURL)
        XCTAssertNil(
            sandbox.env()["ANTHROPIC_BASE_URL"],
            "a tab opened after routing stopped must not inherit a dead URL"
        )
    }

    /// An explicit token has to survive; it is what auth mode depends on.
    func testExplicitTokenIsUsed() {
        let sandbox = makeSandbox()
        sandbox.setRouter(url: "http://127.0.0.1:5255", token: "secret-token")
        XCTAssertEqual(sandbox.env()["ANTHROPIC_AUTH_TOKEN"], "secret-token")
    }

    /// Every agent shape has to be able to authenticate, not just Claude Code.
    ///
    /// Gemini, opencode and oh-my-pi reach the router through `OPENAI_BASE_URL`
    /// and nothing else; Codex reads the variable named in its config. When
    /// only the two Anthropic keys were exported, those agents had a base URL
    /// and no credential — with router auth on, every one of them was answered
    /// 401, and the failure looked like the provider or llama-server not
    /// routing rather than like a token that never arrived.
    func testEveryAgentShapeReceivesTheToken() {
        let sandbox = makeSandbox()
        sandbox.setRouter(url: "http://127.0.0.1:5255", token: "secret-token")
        let environment = sandbox.env()

        XCTAssertEqual(environment["OPENAI_BASE_URL"], "http://127.0.0.1:5255")
        XCTAssertEqual(environment["OPENAI_API_KEY"], "secret-token")
        XCTAssertEqual(environment["JXCODE_API_KEY"], "secret-token")
        // The Anthropic key stays empty on purpose: a non-empty value would be
        // preferred by some builds and would bypass the router's token.
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "")
    }

    /// The exported credential has to be one the router will accept.
    func testExportedTokenIsAcceptedByTheRouter() {
        let token = RouterAuth.generateToken()
        let sandbox = makeSandbox()
        sandbox.setRouter(url: "http://127.0.0.1:5255", token: token)
        let environment = sandbox.env()

        let auth = RouterAuth(isEnabled: true, token: token)
        XCTAssertTrue(auth.accepts(headers: [
            "Authorization": "Bearer \(environment["ANTHROPIC_AUTH_TOKEN"] ?? "")",
        ]))
        XCTAssertTrue(auth.accepts(headers: [
            "Authorization": "Bearer \(environment["OPENAI_API_KEY"] ?? "")",
        ]))
        XCTAssertTrue(auth.accepts(headers: [
            "Authorization": "Bearer \(environment["JXCODE_API_KEY"] ?? "")",
        ]))
    }

    /// `SandboxOptions.routerURL` and the runtime seam must agree.
    ///
    /// The two used to be separate code paths with separate lists of exported
    /// keys, which is how they drifted apart in the first place.
    func testOptionsRouterAndSeamProduceTheSameCredential() {
        let token = "secret-token"
        let viaOptions = SandboxEnvironment(
            paths: SandboxPaths(root: URL(fileURLWithPath: NSTemporaryDirectory())),
            options: SandboxOptions(routerURL: "http://127.0.0.1:5255", routerToken: token)
        ).build()

        let sandbox = makeSandbox()
        sandbox.setRouter(url: "http://127.0.0.1:5255", token: token)
        let viaSeam = sandbox.env()

        for key in ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "JXCODE_API_KEY"] {
            XCTAssertEqual(viaOptions[key], viaSeam[key], "\(key) differs between the two paths")
        }
    }
}
