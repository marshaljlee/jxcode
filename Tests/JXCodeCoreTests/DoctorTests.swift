import XCTest
@testable import JXCodeCore

/// The sandbox self-audit.
///
/// This file did not exist until a dead-code sweep noticed that **no test
/// mentioned `Doctor` at all** — while `AgentRegistry.isEscaping` sat unused,
/// because the doctor had inlined its own copy of the same containment rule.
/// The rule was therefore stated twice, the tested version was the one nobody
/// called, and the version users actually read was the untested one.
///
/// The doctor is the worst place to have no tests, because its failure mode is
/// silence. Every check is a claim that the sandbox holds; if one stops firing,
/// the report still ends with "Sandbox holds." and looks healthier than it is.
/// So the tests below are weighted towards that: that each check is *present*,
/// and that a real leak is reported as a failure rather than a pass.
final class DoctorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-doctor-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSandbox(
        options: SandboxOptions = .default
    ) throws -> Sandbox {
        let sandbox = Sandbox(paths: SandboxPaths(root: root), options: options)
        try sandbox.prepare()
        return sandbox
    }

    private func check(_ report: DoctorReport, _ id: String) -> DoctorReport.Check? {
        report.checks.first { $0.id == id }
    }

    // MARK: - The report is complete

    /// Every check the doctor is supposed to run, run.
    ///
    /// This is the guard against the silent-failure mode: a check that is
    /// deleted, renamed, or skipped leaves the summary line reading "Sandbox
    /// holds." and nothing to notice the difference.
    func testEveryCheckIsPresent() throws {
        let report = Doctor.run(sandbox: try makeSandbox())

        let required = [
            "root",                              // the root is writable
            "home", "tmpdir", "npm",             // the containment trio
            "agent.CLAUDE_CONFIG_DIR",           // the agent config roots — a miss
            "agent.CODEX_HOME",                  //   here means an agent writes to
            "agent.GEMINI_CONFIG_DIR",           //   the host home
            "zdotdir",
            "shellinit",
            "path.host",                         // PATH must not reach host tool dirs
            "path.localbin",
            "symlinks",
            "homeonly.oh-my-pi",                 // isolated by $HOME alone, because
            "homeonly.Google Jules",             //   neither documents a config-dir
            "homeonly.Bun",                      //   override
            "getpwuid",                          // the hazard we cannot fix
        ]

        for id in required {
            XCTAssertNotNil(
                check(report, id),
                "the doctor stopped reporting `\(id)`. Present: "
                    + report.checks.map(\.id).joined(separator: ", ")
            )
        }
    }

    func testAHealthySandboxHasNoFailures() throws {
        let report = Doctor.run(sandbox: try makeSandbox())

        XCTAssertTrue(
            report.isHealthy,
            "a freshly prepared sandbox should be healthy, but failed: "
                + report.failures.map { "\($0.id): \($0.detail)" }.joined(separator: " | ")
        )
        XCTAssertTrue(report.failures.isEmpty)
    }

    func testAHealthySandboxWithTheRealRegistryHasNoFailures() throws {
        // The app always passes its registry, which switches on the per-agent
        // checks. Without this case the suite only ever exercised the
        // registry-less path, and `Plain shell` — `/bin/zsh`, which is outside
        // the sandbox by definition — made the sidebar read "1 leak" on a
        // sandbox that was in fact holding.
        let sandbox = try makeSandbox()
        let report = Doctor.run(sandbox: sandbox, registry: AgentRegistry(paths: sandbox.paths))

        XCTAssertTrue(
            report.isHealthy,
            "a freshly prepared sandbox should be healthy, but failed: "
                + report.failures.map { "\($0.id): \($0.detail)" }.joined(separator: " | ")
        )
    }

    // MARK: - A leak must be reported, not absorbed

    func testAnAgentConfigRootOutsideTheSandboxIsAFailure() throws {
        // The most consequential check in the file: this is the one that means
        // "Claude Code will write to your real ~/.claude".
        let hostPath = NSHomeDirectory() + "/.claude"
        let sandbox = try makeSandbox(
            options: SandboxOptions(extraEnv: ["CLAUDE_CONFIG_DIR": hostPath])
        )

        let report = Doctor.run(sandbox: sandbox)
        let found = try XCTUnwrap(check(report, "agent.CLAUDE_CONFIG_DIR"))

        XCTAssertEqual(found.status, .fail, "a host path must not pass containment")
        XCTAssertEqual(found.detail, hostPath)
        XCTAssertFalse(report.isHealthy, "the report must not call itself healthy while leaking")
    }

    func testAnEmptyVariableFailsRatherThanPassingVacuously() throws {
        // An empty value is not a contained value. `containmentCheck` has a
        // separate branch for it precisely because "" would otherwise be
        // treated as a path that happens to be short.
        let sandbox = try makeSandbox(
            options: SandboxOptions(extraEnv: ["CODEX_HOME": ""])
        )

        let found = try XCTUnwrap(check(Doctor.run(sandbox: sandbox), "agent.CODEX_HOME"))

        XCTAssertEqual(found.status, .fail)
        XCTAssertTrue(found.detail.contains("is not set"), "got: \(found.detail)")
    }

    func testAHomeOutsideTheSandboxIsAFailure() throws {
        let sandbox = try makeSandbox(options: SandboxOptions(extraEnv: ["HOME": "/tmp"]))

        let found = try XCTUnwrap(check(Doctor.run(sandbox: sandbox), "home"))

        XCTAssertEqual(found.status, .fail)
        XCTAssertEqual(found.detail, "/tmp")
    }

    func testMissingShellInitIsAFailure() throws {
        // The generated init is what re-asserts PATH after `/etc/zprofile` runs
        // `path_helper`. Without it the deny-list silently stops applying.
        let sandbox = try makeSandbox()
        try FileManager.default.removeItem(at: sandbox.paths.zshDir.appendingPathComponent(".zshrc"))

        let found = try XCTUnwrap(check(Doctor.run(sandbox: sandbox), "shellinit"))

        XCTAssertEqual(found.status, .fail)
        XCTAssertTrue(found.detail.contains(".zshrc"), "got: \(found.detail)")
    }

    func testAnAgentResolvingOutsideTheSandboxIsAFailure() throws {
        // This is the check that `AgentRegistry.isEscaping` exists for. It had
        // no caller: the doctor re-derived containment inline, so the shared
        // rule and the displayed rule could drift apart.
        //
        // The binary has to live somewhere that is *not* a system directory.
        // `/bin/echo` would no longer do: those directories are shared with the
        // host on purpose, so a binary found there is not a leak. This mirrors
        // the real hazard — an agent picking up a host-wide Homebrew toolchain.
        let sandbox = try makeSandbox()
        let rogue = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-rogue-\(UUID().uuidString)")
        try "#!/bin/sh\nexit 0\n".write(to: rogue, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: rogue.path
        )
        defer { try? FileManager.default.removeItem(at: rogue) }

        let registry = AgentRegistry(paths: sandbox.paths)
        try registry.add(AgentDefinition(
            id: "rogue",
            name: "Rogue host binary",
            command: rogue.path      // absolute, executable, and outside the root
        ))

        let report = Doctor.run(sandbox: sandbox, registry: registry)
        let found = try XCTUnwrap(check(report, "agent.rogue"))

        XCTAssertEqual(found.status, .fail, "a binary outside the root must fail")
        XCTAssertTrue(
            found.detail.contains("OUTSIDE"),
            "the detail must say what is wrong, got: \(found.detail)"
        )
        XCTAssertFalse(report.isHealthy)
    }

    func testTheSystemShellIsNotReportedAsALeak() throws {
        // `Plain shell` is `/bin/zsh`, which is always outside the sandbox and
        // always will be. Flagging it made a healthy install report "1 failing",
        // and a leak report that cries wolf is a leak report nobody reads.
        let sandbox = try makeSandbox()
        let registry = AgentRegistry(paths: sandbox.paths)
        let shell = try XCTUnwrap(registry.agent(id: "shell"))

        let environment = sandbox.env()
        XCTAssertNotNil(
            registry.resolvedPath(for: shell, environment: environment),
            "the system shell must still resolve"
        )
        XCTAssertFalse(
            registry.isEscaping(shell, environment: environment),
            "/bin/zsh is a shared system binary, not a host leak"
        )

        let found = try XCTUnwrap(check(Doctor.run(sandbox: sandbox, registry: registry), "agent.shell"))
        XCTAssertEqual(found.status, .pass, "detail: \(found.detail)")
    }

    func testOnlyWholePathComponentsCountAsSystemDirectories() throws {
        // Prefix matching would treat `/binary/foo` as a child of `/bin`, which
        // would silently exempt a real leak.
        XCTAssertTrue(SandboxEnvironment.isSharedSystemPath("/bin/zsh"))
        XCTAssertTrue(SandboxEnvironment.isSharedSystemPath("/usr/bin/git"))
        XCTAssertTrue(SandboxEnvironment.isSharedSystemPath("/bin"))
        XCTAssertFalse(SandboxEnvironment.isSharedSystemPath("/binary/foo"))
        XCTAssertFalse(SandboxEnvironment.isSharedSystemPath("/usr/binx/foo"))
        XCTAssertFalse(SandboxEnvironment.isSharedSystemPath("/opt/homebrew/bin/node"))
    }

    func testAnInstalledAgentInsideTheSandboxPasses() throws {
        // The mirror of the test above, so the check cannot pass by failing
        // everything.
        let sandbox = try makeSandbox()
        let binary = sandbox.paths.bin.appendingPathComponent("inside-agent")
        try FileManager.default.createDirectory(
            at: sandbox.paths.bin, withIntermediateDirectories: true
        )
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: binary.path
        )

        let registry = AgentRegistry(paths: sandbox.paths)
        try registry.add(AgentDefinition(
            id: "insider", name: "Insider", command: binary.path
        ))

        let report = Doctor.run(sandbox: sandbox, registry: registry)
        let found = try XCTUnwrap(check(report, "agent.insider"))

        XCTAssertEqual(found.status, .pass, "detail: \(found.detail)")
    }

    func testAnAgentThatIsNotInstalledIsInformationalNotAFailure() throws {
        // Not installed is a normal state — it is what the install hint is for.
        // Reporting it as a failure would make every fresh install look broken.
        let sandbox = try makeSandbox()
        let registry = AgentRegistry(paths: sandbox.paths)

        let report = Doctor.run(sandbox: sandbox, registry: registry)

        for agent in registry.agents where registry.resolvedPath(for: agent, environment: sandbox.env()) == nil {
            let found = try XCTUnwrap(check(report, "agent.\(agent.id)"))
            XCTAssertEqual(found.status, .info, "\(agent.id) should be info, not \(found.status)")
        }
    }

    // MARK: - Warnings and notes are not failures

    func testAHostLocalBinEntryWarnsWithoutFailingTheReport() throws {
        // `/usr/local/bin` is a judgement call: where a host Homebrew lives, but
        // also where some vendors install. It has to be visible without being
        // fatal, or users learn to ignore the report.
        let sandbox = try makeSandbox(options: SandboxOptions(includeHostLocalBin: true))

        let report = Doctor.run(sandbox: sandbox)
        let found = try XCTUnwrap(check(report, "path.localbin"))

        XCTAssertEqual(found.status, .warn)
        XCTAssertFalse(found.detail.isEmpty, "a warning has to say what to do")
        XCTAssertTrue(report.isHealthy, "a warning must not make the sandbox unhealthy")
        XCTAssertTrue(
            report.warnings.contains { $0.id == "path.localbin" },
            "warnings were: \(report.warnings.map(\.id))"
        )
    }

    func testTheGetpwuidHazardIsInformationalAndDoesNotFailTheReport() throws {
        // `getpwuid()` cannot be overridden from the environment, so this can
        // never be "fixed" — which is exactly why it must not read as a
        // failure. It is a note explaining why the config roots are set
        // explicitly.
        let report = Doctor.run(sandbox: try makeSandbox())

        let found = try XCTUnwrap(check(report, "getpwuid"))
        XCTAssertEqual(found.status, .info)
        XCTAssertTrue(found.detail.contains(NSHomeDirectory()))
        XCTAssertTrue(report.isHealthy)
    }

    func testASymlinkEscapingTheSandboxIsWarnedAbout() throws {
        // The import path recreates host symlinks rather than following them,
        // so an escaping link is a realistic outcome rather than a contrived
        // one — and the doctor is the only place that would notice.
        let sandbox = try makeSandbox()
        let link = sandbox.paths.envRoot.appendingPathComponent("escaping-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")

        let report = Doctor.run(sandbox: sandbox)
        let found = try XCTUnwrap(check(report, "symlinks"))

        XCTAssertEqual(found.status, .warn)
        XCTAssertTrue(found.detail.contains("escaping-link"), "got: \(found.detail)")
    }

    // MARK: - Rendering

    func testTheSummarySaysWhetherTheSandboxHolds() throws {
        let healthy = Doctor.run(sandbox: try makeSandbox())
        XCTAssertTrue(healthy.rendered().contains("Sandbox holds"))

        let leaking = Doctor.run(
            sandbox: try makeSandbox(options: SandboxOptions(extraEnv: ["HOME": "/tmp"]))
        )
        XCTAssertTrue(leaking.rendered().contains("Sandbox is leaking"))
    }

    func testNonVerboseRenderingKeepsFailuresAndDropsPasses() throws {
        let report = Doctor.run(
            sandbox: try makeSandbox(options: SandboxOptions(extraEnv: ["HOME": "/tmp"]))
        )

        let quiet = report.rendered(verbose: false)

        XCTAssertTrue(quiet.contains("$HOME resolves inside the sandbox"), "failures must survive")
        XCTAssertFalse(quiet.contains("Sandbox root is writable"), "passing checks should be dropped")
    }
}
