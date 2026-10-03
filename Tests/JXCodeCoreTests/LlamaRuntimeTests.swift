import XCTest
@testable import JXCodeCore

final class LlamaRuntimeLocatorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llama-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var paths: SandboxPaths { SandboxPaths(root: root) }

    /// Create an executable file, optionally without the execute bit.
    @discardableResult
    private func makeBinary(_ url: URL, executable: Bool = true) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url
    }

    // MARK: Isolation preference

    func testFindsTheSandboxCopyFirst() throws {
        // Both exist. The private prefix must win, because a runtime installed
        // by the app is the one the app can vouch for and clean up.
        let sandbox = try makeBinary(paths.brewPrefix.appendingPathComponent("bin/llama-server"))
        let host = try makeBinary(root.appendingPathComponent("hostbin/llama-server"))

        let locator = LlamaRuntimeLocator(paths: paths, extraSearchPaths: [host.deletingLastPathComponent()])
        let runtime = try XCTUnwrap(locator.locate())

        XCTAssertEqual(runtime.binary, sandbox)
        XCTAssertEqual(runtime.origin, .sandbox)
        XCTAssertTrue(runtime.isIsolated)
    }

    func testFallsBackToTheHostCopy() throws {
        let hostDirectory = root.appendingPathComponent("hostbin")
        let host = try makeBinary(hostDirectory.appendingPathComponent("llama-server"))

        let locator = LlamaRuntimeLocator(paths: paths, extraSearchPaths: [hostDirectory])
        let runtime = try XCTUnwrap(locator.locate())

        XCTAssertEqual(runtime.binary, host)
        XCTAssertEqual(runtime.origin, .host)
        XCTAssertFalse(runtime.isIsolated)
    }

    func testHostOriginIsExplainedRatherThanHidden() throws {
        let hostDirectory = root.appendingPathComponent("hostbin")
        try makeBinary(hostDirectory.appendingPathComponent("llama-server"))

        let locator = LlamaRuntimeLocator(paths: paths, extraSearchPaths: [hostDirectory])
        let runtime = try XCTUnwrap(locator.locate())

        // The app must not silently use a binary it does not own without saying
        // so — the user needs to know updating Homebrew may affect this.
        XCTAssertTrue(runtime.isolationNote.contains("outside the sandbox"), runtime.isolationNote)
    }

    func testReturnsTheHostCopyWhenTheSandboxHasNone() {
        let locator = LlamaRuntimeLocator(paths: paths, extraSearchPaths: [])
        guard let runtime = locator.locate() else { return }

        // Nothing was placed in the sandbox, so whatever is found must be the
        // host's — and must be labelled as such rather than passed off as ours.
        XCTAssertEqual(runtime.origin, .host)
        XCTAssertFalse(runtime.isIsolated)
        XCTAssertFalse(paths.contains(runtime.binary))
    }

    // MARK: Executability

    func testNonExecutableFileIsNotAccepted() throws {
        // A file with the right name but no execute bit is not a runtime, and
        // treating it as one produces a confusing launch failure later.
        let fake = try makeBinary(paths.bin.appendingPathComponent("llama-server"), executable: false)

        let locator = LlamaRuntimeLocator(paths: paths, extraSearchPaths: [])
        XCTAssertNotEqual(locator.locate()?.binary.path, fake.path)
        // And the diagnostic view reports it as absent, not present.
        //
        // Compared by `.path`, not by `URL ==`. Foundation's URL equality
        // compares the base/relative split rather than the resolved path, so
        // two URLs pointing at the same file can compare unequal.
        let entry = locator.diagnostics().first { $0.path.path == fake.path }
        XCTAssertEqual(entry?.exists, false)
    }

    func testDirectoryNamedLikeTheBinaryIsNotAccepted() throws {
        let fake = paths.bin.appendingPathComponent("llama-server")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)

        let locator = LlamaRuntimeLocator(paths: paths, extraSearchPaths: [])
        XCTAssertNotEqual(locator.locate()?.binary.path, fake.path)
        XCTAssertEqual(locator.diagnostics().first { $0.path.path == fake.path }?.exists, false)
    }

    // MARK: Search order and diagnostics

    func testSearchOrderStartsInsideTheSandbox() {
        let locator = LlamaRuntimeLocator(paths: paths, extraSearchPaths: [])
        let candidates = locator.candidates()

        XCTAssertFalse(candidates.isEmpty)
        XCTAssertEqual(candidates.first?.origin, .sandbox)
        XCTAssertTrue(candidates.first!.url.path.hasPrefix(root.path))

        // Every sandbox candidate must come before every host candidate, or the
        // app would prefer a binary it does not own.
        let firstHost = candidates.firstIndex { $0.origin == .host }
        let lastSandbox = candidates.lastIndex { $0.origin == .sandbox }
        if let firstHost, let lastSandbox {
            XCTAssertLessThan(lastSandbox, firstHost)
        }
    }

    func testDiagnosticsReportEveryLocationChecked() throws {
        let created = try makeBinary(paths.brewPrefix.appendingPathComponent("bin/llama-server"))

        let locator = LlamaRuntimeLocator(paths: paths, extraSearchPaths: [])
        let diagnostics = locator.diagnostics()

        XCTAssertEqual(diagnostics.count, locator.candidates().count)

        // The binary that was created must be reported as present, and every
        // other candidate must be reported with its own status — the point of
        // this view is that a user can see *where* the app looked.
        XCTAssertEqual(diagnostics.first { $0.path.path == created.path }?.exists, true)
        XCTAssertEqual(diagnostics.first { $0.path.path == created.path }?.origin, .sandbox)
        XCTAssertTrue(diagnostics.allSatisfy { $0.path.lastPathComponent == "llama-server" })
    }

    func testDiagnosticsAreAvailableEvenWhenNothingIsFound() {
        // "Not found" with no explanation is the worst outcome. The app must be
        // able to show where it looked.
        let locator = LlamaRuntimeLocator(paths: paths, extraSearchPaths: [])
        XCTAssertFalse(locator.diagnostics().isEmpty)
        XCTAssertTrue(locator.installationHint.contains("llama-server"))
        XCTAssertTrue(locator.installationHint.contains("~sandbox"), locator.installationHint)
    }

    func testInstallationDirectoryIsInsideTheSandbox() {
        let locator = LlamaRuntimeLocator(paths: paths)
        XCTAssertTrue(paths.contains(locator.installationDirectory))
    }

    // MARK: Bundled runtimes

    func testFindsABundledRuntimeNestedSeveralLevelsDeep() throws {
        // LM Studio ships llama-server under a versioned path a few levels down,
        // so a fixed path check would miss it.
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let lmStudioRoot = home.appendingPathComponent(".lmstudio/extensions/backends")
        guard FileManager.default.fileExists(atPath: lmStudioRoot.path) else {
            throw XCTSkip("LM Studio is not installed on this machine")
        }

        let locator = LlamaRuntimeLocator(paths: paths, extraSearchPaths: [], bundleSearchDepth: 6)
        // Only assert the walk produced candidates; whether a binary is present
        // depends on the installation.
        XCTAssertFalse(locator.candidates().isEmpty)
    }

    func testDepthLimitedDirectoryWalkStops() throws {
        let deep = root.appendingPathComponent("a/b/c/d/e/f/g", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)

        let shallow = LlamaRuntimeLocator.directories(under: root.appendingPathComponent("a"), depth: 2)
        XCTAssertTrue(shallow.contains { $0.lastPathComponent == "b" })
        XCTAssertFalse(shallow.contains { $0.lastPathComponent == "f" })
    }
}

// MARK: - Capability parsing

final class LlamaServerCapabilitiesTests: XCTestCase {

    /// A help text in the shape a bare-flag build prints.
    private let legacyHelp = """
    usage: llama-server [options]

    ----- common params -----
    -m,    --model FNAME       model path to load
    -fa,   --flash-attn        enable flash attention
           --jinja             enable jinja2 chat template
    -c,    --ctx-size N        size of the prompt context
    """

    /// The same build after `--flash-attn` grew a value.
    private let modernHelp = """
    usage: llama-server [options]

    ----- common params -----
    -m,    --model FNAME       model path to load
    -fa,   --flash-attn [on|off|auto]   set flash attention
           --jinja             enable jinja2 chat template
           --cache-type-k TYPE kv cache data type for K
           --cache-type-v TYPE kv cache data type for V
    -np,   --parallel N        number of parallel sequences
    """

    func testParsesABareFlagFlashAttentionBuild() {
        let capabilities = LlamaServerCapabilities.parse(helpText: legacyHelp)

        XCTAssertTrue(capabilities.supportsFlashAttention)
        XCTAssertEqual(capabilities.flashAttentionStyle, .bareFlag)
        XCTAssertTrue(capabilities.supportsJinja)
    }

    func testParsesAValueTakingFlashAttentionBuild() {
        // Getting this wrong is a startup argument error that looks like an app
        // bug rather than a version mismatch, which is why it is parsed.
        let capabilities = LlamaServerCapabilities.parse(helpText: modernHelp)

        XCTAssertTrue(capabilities.supportsFlashAttention)
        XCTAssertEqual(capabilities.flashAttentionStyle, .explicitValue)
        XCTAssertTrue(capabilities.supportsCacheType)
        XCTAssertTrue(capabilities.supportsParallel)
    }

    func testMissingFeaturesAreReportedAsMissing() {
        let minimal = """
        usage: llama-server [options]
        -m, --model FNAME   model path
        """
        let capabilities = LlamaServerCapabilities.parse(helpText: minimal)

        XCTAssertFalse(capabilities.supportsJinja)
        XCTAssertFalse(capabilities.supportsCacheType)
        XCTAssertFalse(capabilities.supportsFlashAttention)
    }

    func testAdaptRewritesFlashAttentionForAValueTakingBuild() {
        let arguments = [
            LlamaArgument(flag: "-fa", reason: "faster", category: .performance),
            LlamaArgument(flag: "-c", value: "4096", reason: "context", category: .context),
        ]

        let adapted = LlamaServerCapabilities.parse(helpText: modernHelp).adapt(arguments)

        let flash = adapted.first { $0.flag == "--flash-attn" }
        XCTAssertEqual(flash?.value, "on")
        XCTAssertFalse(adapted.contains { $0.flag == "-fa" })
        // Unrelated flags pass through untouched.
        XCTAssertTrue(adapted.contains { $0.flag == "-c" && $0.value == "4096" })
    }

    func testAdaptLeavesABareFlagBuildAlone() {
        let arguments = [LlamaArgument(flag: "-fa", reason: "faster", category: .performance)]
        let adapted = LlamaServerCapabilities.parse(helpText: legacyHelp).adapt(arguments)

        XCTAssertEqual(adapted, arguments)
    }

    func testAdaptDropsUnsupportedFlags() {
        // Better to run without a feature than to fail to start because of it.
        let minimal = LlamaServerCapabilities.parse(helpText: "usage: llama-server\n-m, --model FNAME")
        let arguments = [
            LlamaArgument(flag: "--jinja", reason: "template", category: .template),
            LlamaArgument(flag: "--cache-type-k", value: "q8_0", reason: "memory", category: .memory),
            LlamaArgument(flag: "--parallel", value: "1", reason: "slots", category: .context),
            LlamaArgument(flag: "-m", value: "/m.gguf", reason: "model", category: .model),
        ]

        let adapted = minimal.adapt(arguments)

        XCTAssertEqual(adapted.map(\.flag), ["-m"])
    }

    func testAssumedModernEnablesEverything() {
        let assumed = LlamaServerCapabilities.assumedModern
        XCTAssertTrue(assumed.supportsJinja)
        XCTAssertTrue(assumed.supportsFlashAttention)
        XCTAssertTrue(assumed.supportsCacheType)
    }

    func testAdaptPreservesReasons() {
        let arguments = [LlamaArgument(flag: "-fa", reason: "a specific reason", category: .performance)]
        let adapted = LlamaServerCapabilities.parse(helpText: modernHelp).adapt(arguments)
        XCTAssertEqual(adapted.first?.reason, "a specific reason")
    }
}

// MARK: - Loading mode

/// `--mlock` / `--no-mmap` / `--direct-io` were collapsed into `--load-mode`
/// and then marked DEPRECATED. The awkward part is that a modern build's help
/// text *mentions* `--load-mode` on the deprecation lines, so a naive
/// `contains("--load-mode")` reports the modern spelling on a build that would
/// reject it — and llama-server exits at startup on an unknown flag. These
/// tests exist to keep that distinction from regressing.
final class LlamaLoadModeTests: XCTestCase {

    /// Captured from the real build 10150 help text, including the deprecation
    /// notices that make a substring check wrong.
    private let modernHelp = """
    usage: llama-server [options]

    ----- common params -----
    --mlock                                 DEPRECATED in favor of `--load-mode`: force system to keep model in
                                            RAM rather than swapping or compressing
                                            (env: LLAMA_ARG_MLOCK)
    --mmap, --no-mmap                       DEPRECATED in favor of `--load-mode`: whether to memory-map model. (if
                                            mmap disabled, slower load but may reduce pageouts if not using mlock)
                                            (env: LLAMA_ARG_MMAP)
    --dio,  --direct-io, -ndio, --no-direct-io
                                            DEPRECATED in favor of `--load-mode`: use DirectIO if available
    -lm,   --load-mode MODE                 model loading mode (default: mmap)
                                            - none: no special loading mode
                                            - mmap: memory-map model
                                            - mlock: force system to keep model in RAM
    """

    private let legacyHelp = """
    usage: llama-server [options]
    --mlock              force system to keep model in RAM
    --mmap, --no-mmap    whether to memory-map model
    """

    func testModernBuildIsNotConfusedByItsOwnDeprecationNotices() {
        let capabilities = LlamaServerCapabilities.parse(helpText: modernHelp)

        XCTAssertEqual(capabilities.loadModeStyle, .explicitValue)
        XCTAssertTrue(capabilities.supportsMmap)
    }

    func testLegacyBuildReportsTheOldSpelling() {
        let capabilities = LlamaServerCapabilities.parse(helpText: legacyHelp)

        XCTAssertEqual(capabilities.loadModeStyle, .legacy)
        XCTAssertTrue(capabilities.supportsMmap)
    }

    func testABuildWithNoLoadingControlsIsUnsupported() {
        let capabilities = LlamaServerCapabilities.parse(
            helpText: "usage: llama-server\n-m, --model FNAME"
        )

        XCTAssertEqual(capabilities.loadModeStyle, .unsupported)
        XCTAssertFalse(capabilities.supportsMmap)
    }

    func testModernBuildPassesLoadModeThrough() {
        let arguments = [
            LlamaArgument(flag: "--load-mode", value: "mlock", reason: "resident", category: .performance)
        ]

        let adapted = LlamaServerCapabilities.parse(helpText: modernHelp).adapt(arguments)

        XCTAssertEqual(adapted.count, 1)
        XCTAssertEqual(adapted.first?.flag, "--load-mode")
        XCTAssertEqual(adapted.first?.value, "mlock")
    }

    func testLegacyBuildGetsTheEquivalentOldFlags() {
        let arguments = [
            LlamaArgument(flag: "--load-mode", value: "mlock", reason: "resident", category: .performance)
        ]

        let adapted = LlamaServerCapabilities.parse(helpText: legacyHelp).adapt(arguments)

        XCTAssertEqual(adapted.map(\.flag), ["--mlock"])
        XCTAssertNil(adapted.first?.value)
    }

    func testLegacyTranslationCoversEveryDocumentedMode() {
        let capabilities = LlamaServerCapabilities.parse(helpText: legacyHelp)

        func flags(for mode: String) -> [String] {
            capabilities.adapt([
                LlamaArgument(flag: "--load-mode", value: mode, reason: "r", category: .performance)
            ]).map(\.flag)
        }

        XCTAssertEqual(flags(for: "mlock"), ["--mlock"])
        XCTAssertEqual(flags(for: "none"), ["--no-mmap"])
        XCTAssertEqual(flags(for: "dio"), ["--direct-io"])
        XCTAssertEqual(flags(for: "mmap+mlock"), ["--mlock", "--mmap"])
        // Plain mmap is the default in every build, so it needs no flag. An
        // empty result is the correct translation, not a dropped feature.
        XCTAssertEqual(flags(for: "mmap"), [])
        XCTAssertEqual(flags(for: "nonsense"), [])
    }

    func testUnsupportedBuildDropsTheFlagRatherThanFailingToStart() {
        let minimal = LlamaServerCapabilities.parse(helpText: "usage: llama-server\n-m, --model FNAME")
        let adapted = minimal.adapt([
            LlamaArgument(flag: "--load-mode", value: "mlock", reason: "r", category: .performance),
            LlamaArgument(flag: "-m", value: "/m.gguf", reason: "model", category: .model),
        ])

        XCTAssertEqual(adapted.map(\.flag), ["-m"])
    }

    func testAssumedModernUsesTheModernSpelling() {
        // Guessing wrong here is a visible startup error, whereas guessing the
        // old spelling would silently produce deprecation warnings forever.
        XCTAssertEqual(LlamaServerCapabilities.assumedModern.loadModeStyle, .explicitValue)
    }

    func testLegacyShortFlagIsAlsoRecognised() {
        let arguments = [
            LlamaArgument(flag: "-lm", value: "mlock", reason: "resident", category: .performance)
        ]
        let adapted = LlamaServerCapabilities.parse(helpText: legacyHelp).adapt(arguments)
        XCTAssertEqual(adapted.map(\.flag), ["--mlock"])
    }
}

// MARK: - Ports

final class PortAllocatorTests: XCTestCase {

    func testAnUnusedPortIsFree() {
        // Ports in the ephemeral range are the ones least likely to be taken.
        let port = PortAllocator.firstFree(from: 49_100)
        XCTAssertNotNil(port)
        XCTAssertTrue(PortAllocator.isFree(port!))
    }

    func testABoundPortIsNotFree() throws {
        // Hold a port open and confirm the allocator notices.
        let listener = try XCTUnwrap(PortAllocator.firstFree(from: 49_200))
        let held = try HeldPort(port: listener)
        defer { held.release() }

        XCTAssertFalse(PortAllocator.isFree(listener))
    }

    func testFirstFreeSkipsPastABoundPort() throws {
        let base = try XCTUnwrap(PortAllocator.firstFree(from: 49_300))
        let held = try HeldPort(port: base)
        defer { held.release() }

        let next = try XCTUnwrap(PortAllocator.firstFree(from: base))
        XCTAssertNotEqual(next, base, "it must not hand back the port that is taken")
        XCTAssertGreaterThan(next, base)
    }

    func testReturnsNilWhenTheRangeIsExhausted() {
        XCTAssertNil(PortAllocator.firstFree(from: 70_000))
    }
}

/// Holds a TCP port open for the duration of a test.
private final class HeldPort {
    private let descriptor: Int32

    init(port: Int) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw XCTSkip("could not open a socket") }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 1) == 0 else {
            close(descriptor)
            throw XCTSkip("could not bind port \(port)")
        }
    }

    func release() {
        close(descriptor)
    }
}

// MARK: - Configuration

final class LlamaServerConfigurationTests: XCTestCase {

    private func makePlan() -> OptimizationPlan {
        ModelOptimizer(
            hardware: .synthetic(memoryGB: 32),
            policy: .safe,
            cachePolicy: .balanced
        ).plan(
            modelPath: "/models/Model.gguf",
            mmprojPath: nil,
            info: makeModelInfo(contextLength: 8_192),
            modelBytes: 1_073_741_824,
            projectorBytes: 0
        )
    }

    func testArgumentsIncludeHostAndPort() {
        let configuration = LlamaServerConfiguration(
            binary: URL(fileURLWithPath: "/usr/local/bin/llama-server"),
            plan: makePlan(),
            port: 9_090,
            logURL: URL(fileURLWithPath: "/tmp/x.log")
        )

        let arguments = configuration.arguments
        XCTAssertTrue(arguments.contains("--host"))
        XCTAssertTrue(arguments.contains("127.0.0.1"), "the server must not be reachable from the network")
        XCTAssertTrue(arguments.contains("--port"))
        XCTAssertTrue(arguments.contains("9090"))
    }

    func testModelFlagsComeFromThePlan() {
        let plan = makePlan()
        let configuration = LlamaServerConfiguration(
            binary: URL(fileURLWithPath: "/bin/llama-server"),
            plan: plan,
            logURL: URL(fileURLWithPath: "/tmp/x.log")
        )

        let arguments = configuration.arguments
        XCTAssertEqual(arguments.first, "-m")
        XCTAssertEqual(arguments[1], "/models/Model.gguf")
        XCTAssertTrue(arguments.contains(String(plan.contextLength)))
    }

    func testBaseURLIsLoopback() {
        let configuration = LlamaServerConfiguration(
            binary: URL(fileURLWithPath: "/bin/llama-server"),
            plan: makePlan(),
            port: 8_080,
            logURL: URL(fileURLWithPath: "/tmp/x.log")
        )

        XCTAssertEqual(configuration.baseURL, "http://127.0.0.1:8080")
    }
}

// MARK: - Supervisor

final class LlamaServerSupervisorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llama-server-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func configuration(binary: URL, timeout: TimeInterval = 5) -> LlamaServerConfiguration {
        let plan = ModelOptimizer(hardware: .synthetic(memoryGB: 32)).plan(
            modelPath: "/models/Model.gguf",
            mmprojPath: nil,
            info: makeModelInfo(contextLength: 4_096),
            modelBytes: 1_073_741_824,
            projectorBytes: 0
        )
        return LlamaServerConfiguration(
            binary: binary,
            plan: plan,
            port: 49_400,
            logURL: root.appendingPathComponent("llama-server.log"),
            startupTimeout: timeout
        )
    }

    func testStartingWithAMissingBinaryFailsImmediately() async {
        let server = LlamaServer(
            configuration: configuration(binary: root.appendingPathComponent("nope/llama-server")),
            paths: SandboxPaths(root: root)
        )

        do {
            try await server.start()
            XCTFail("expected a launch failure")
        } catch {
            guard case LlamaServerError.binaryMissing = error else {
                return XCTFail("expected binaryMissing, got \(error)")
            }
        }
        XCTAssertEqual(server.state, .stopped)
    }

    func testAProcessThatExitsIsReportedRatherThanWaitedOn() async throws {
        // `/usr/bin/false` exits at once. Waiting out the full startup timeout
        // for a process that is already gone would make the app feel broken, so
        // the failure must come back straight away with the log.
        let server = LlamaServer(
            configuration: configuration(binary: URL(fileURLWithPath: "/usr/bin/false"), timeout: 30),
            paths: SandboxPaths(root: root)
        )

        let started = Date()
        do {
            try await server.start()
            XCTFail("expected an exit failure")
        } catch {
            guard case LlamaServerError.exited(let code, _) = error else {
                return XCTFail("expected exited, got \(error)")
            }
            XCTAssertEqual(code, 1)
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "it should not wait out the timeout")
        if case .failed = server.state {} else {
            XCTFail("a failed server should record that it failed, was \(server.state)")
        }
    }

    func testStoppingAServerThatNeverStartedIsSafe() {
        let server = LlamaServer(
            configuration: configuration(binary: URL(fileURLWithPath: "/usr/bin/false")),
            paths: SandboxPaths(root: root)
        )

        server.stop()
        XCTAssertEqual(server.state, .stopped)
    }

    func testLogTailIsEmptyBeforeAnythingIsWritten() {
        let server = LlamaServer(
            configuration: configuration(binary: URL(fileURLWithPath: "/usr/bin/false")),
            paths: SandboxPaths(root: root)
        )

        XCTAssertEqual(server.logTail(), "")
    }

    func testLogTailReadsFromTheEnd() throws {
        let logURL = root.appendingPathComponent("llama-server.log")
        let lines = (0..<5_000).map { "line \($0) padding padding padding padding" }
        try lines.joined(separator: "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let server = LlamaServer(
            configuration: configuration(binary: URL(fileURLWithPath: "/usr/bin/false")),
            paths: SandboxPaths(root: root)
        )

        let tail = server.logTail(maxBytes: 512)
        XCTAssertLessThan(tail.count, 1_024, "the tail must be bounded, not the whole file")
        XCTAssertTrue(tail.contains("line 4999"), "the tail should end with the newest output")
        XCTAssertFalse(tail.contains("line 0 "), "and must not reach back to the start")
    }

    func testResolvedCapabilitiesIsRecordedWhenStartRuns() async {
        // `resolvedCapabilities` is written from `start()`, which now does it
        // under the queue. This pins that the guarded write still happens —
        // a queue.sync dropped on the floor would leave it nil forever, and
        // nothing else in the suite would notice.
        let configuration = self.configuration(binary: URL(fileURLWithPath: "/usr/bin/false"), timeout: 2)
        let server = LlamaServer(configuration: configuration, paths: SandboxPaths(root: root))

        try? await server.start()

        XCTAssertEqual(
            server.resolvedCapabilities,
            configuration.capabilities,
            "a binary that reports nothing should fall back to the configured set"
        )
    }

    /// Read the state from several threads while a start is in flight.
    ///
    /// `start()` has `await` points, so it writes `state` from a different task
    /// than the one that called it. Under the thread sanitizer this reports a
    /// race if any write escapes the queue; without it, it can only assert the
    /// reads stay consistent — which is why the fix is a queue discipline
    /// rather than something this test proves on its own.
    func testStateIsReadableWhileAnotherTaskStartsTheServer() async {
        let server = LlamaServer(
            configuration: configuration(binary: URL(fileURLWithPath: "/usr/bin/false"), timeout: 2),
            paths: SandboxPaths(root: root)
        )
        let counter = Counter()
        let readerCount = 6
        let group = DispatchGroup()

        for _ in 0..<readerCount {
            DispatchQueue.global().async(group: group) {
                while !counter.isDone {
                    _ = server.state
                    _ = server.isProcessAlive
                    _ = server.resolvedCapabilities
                }
                counter.increment()
            }
        }

        try? await server.start()
        counter.markDone()
        group.wait()

        XCTAssertEqual(counter.value, readerCount, "readers did not finish")
        if case .failed = server.state {} else {
            XCTFail("the fake server cannot become healthy, was \(server.state)")
        }
    }

    func testFailureMessageIncludesTheLog() async throws {
        // The log is where llama-server says why it refused to start, so the
        // error has to carry it — otherwise the user sees "failed" and nothing
        // else, with the explanation sitting in a file they do not know about.
        let script = root.appendingPathComponent("bad-server")
        try Data("#!/bin/sh\necho 'error: failed to load model' >&2\nexit 3\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let server = LlamaServer(
            configuration: configuration(binary: script, timeout: 10),
            paths: SandboxPaths(root: root)
        )

        do {
            try await server.start()
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(
                "\(error)".contains("failed to load model"),
                "the error should carry the server's own output: \(error)"
            )
        }
    }

}

/// Counts readers, and tells them when to stop, from several threads at once.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var done = false

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func markDone() {
        lock.lock()
        done = true
        lock.unlock()
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
