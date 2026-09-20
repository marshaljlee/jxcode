import XCTest
@testable import JXCodeCore

/// Adoption is the only part of this module that can be proven rather than
/// argued about, so the tests here actually perform it -- against the real
/// Homebrew `llama-server` when it is present -- and then run the result.
///
/// A test that only asserted "the file was copied" would pass for a binary that
/// cannot launch, which is precisely the failure this feature exists to
/// prevent.
final class LlamaRuntimeInstallerTests: XCTestCase {

    private var root: URL!
    private var scratch: URL!

    /// The real thing, if this machine has it.
    private static let hostBinary = URL(fileURLWithPath: "/opt/homebrew/bin/llama-server")

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("llama-installer-\(UUID().uuidString)", isDirectory: true)
        scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A throwaway sandbox. Never the user's real Application Support tree.
    private var paths: SandboxPaths { SandboxPaths(root: root.appendingPathComponent("sandbox")) }

    // MARK: - Fixtures

    @discardableResult
    private func makeScript(named name: String, body: String, executable: Bool = true) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(body.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: executable ? 0o755 : 0o644],
            ofItemAtPath: url.path
        )
        return url
    }

    private func otoolDependencies(_ url: URL) throws -> [String] {
        let result = try LlamaRuntimeInstaller.runTool(
            LlamaRuntimeInstaller.otool,
            ["-L", url.path]
        )
        guard result.succeeded else {
            throw XCTSkip("otool could not read \(url.path): \(result.output)")
        }
        return LlamaRuntimeInstaller.parseDependencies(result.output)
    }

    private func run(_ url: URL, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let result = try LlamaRuntimeInstaller.runTool(url, arguments, timeout: 120)
        return (result.status, result.output)
    }

    private func contents(of directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    }

    /// Build a small executable that links a dylib whose own dependency has
    /// been pointed at a path that does not exist. This is the only way to
    /// exercise "the closure could not be completed" without depending on a
    /// particular Homebrew layout.
    private func makeBrokenClosureFixture() throws -> URL {
        let clang = URL(fileURLWithPath: "/usr/bin/clang")
        guard FileManager.default.isExecutableFile(atPath: clang.path) else {
            throw XCTSkip("clang is needed to build the broken-closure fixture")
        }

        let directory = scratch.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let implementation = directory.appendingPathComponent("fake.c")
        try Data("int fake(void) { return 42; }\n".utf8).write(to: implementation)
        let dylib = directory.appendingPathComponent("libfake.dylib")
        try runCompiler(clang, [
            "-dynamiclib", "-o", dylib.path, implementation.path,
            "-Wl,-install_name,@rpath/libfake.dylib",
        ])

        // Break the dylib's edge to libSystem. Adoption must notice before it
        // installs anything.
        let broken = try LlamaRuntimeInstaller.runTool(
            LlamaRuntimeInstaller.installNameTool,
            ["-change", "/usr/lib/libSystem.B.dylib", "/nonexistent/libmissing.dylib", dylib.path]
        )
        guard broken.succeeded else {
            throw XCTSkip("could not break the fixture dylib: \(broken.output)")
        }

        let main = directory.appendingPathComponent("main.c")
        try Data("int fake(void);\nint main(void) { return fake() == 42 ? 0 : 1; }\n".utf8).write(to: main)
        let executable = directory.appendingPathComponent("fake-tool")
        try runCompiler(clang, [
            "-o", executable.path, main.path,
            "-L\(directory.path)", "-lfake",
            "-Wl,-rpath,\(directory.path)",
        ])

        // Guard the fixture itself: if the dylib edge did not survive, the
        // test would prove nothing.
        let dependencies = try otoolDependencies(executable)
        guard dependencies.contains(where: { $0.hasSuffix("libfake.dylib") }) else {
            throw XCTSkip("the fixture executable did not link the fake dylib: \(dependencies)")
        }
        let dylibDependencies = try otoolDependencies(dylib)
        guard dylibDependencies.contains("/nonexistent/libmissing.dylib") else {
            throw XCTSkip("the fixture dylib kept its libSystem edge: \(dylibDependencies)")
        }

        return executable
    }

    private func runCompiler(_ clang: URL, _ arguments: [String]) throws {
        let result = try LlamaRuntimeInstaller.runTool(clang, arguments, timeout: 120)
        guard result.succeeded else {
            throw XCTSkip("clang failed: \(result.output)")
        }
    }

    // MARK: - Planning

    func testPlanWithoutHostRuntimeBuildsFromSource() {
        let plan = LlamaRuntimeInstaller.plan(paths: paths, hostRuntime: nil)

        XCTAssertEqual(plan.method, .buildFromSource)
        XCTAssertEqual(
            plan.destination,
            paths.brewPrefix.appendingPathComponent("bin/llama-server")
        )
        XCTAssertTrue(plan.explanation.contains("build llama.cpp from source"))
        XCTAssertFalse(plan.warnings.isEmpty, "a 30 minute build should warn about itself")
    }

    func testPlanWithHostRuntimeAdoptsIt() {
        let host = LlamaRuntime(binary: URL(fileURLWithPath: "/opt/homebrew/bin/llama-server"), origin: .host)
        let plan = LlamaRuntimeInstaller.plan(paths: paths, hostRuntime: host)

        XCTAssertEqual(plan.method, .adoptHostBinary(host.binary))
        XCTAssertEqual(
            plan.destination,
            paths.brewPrefix.appendingPathComponent("bin/llama-server")
        )
        XCTAssertTrue(paths.contains(plan.destination))
        XCTAssertFalse(plan.explanation.isEmpty)
    }

    func testPlanForSandboxRuntimeSaysItIsAlreadyIsolated() {
        let installed = paths.brewPrefix.appendingPathComponent("bin/llama-server")
        let sandboxed = LlamaRuntime(binary: installed, origin: .sandbox)

        let plan = LlamaRuntimeInstaller.plan(paths: paths, hostRuntime: sandboxed)

        XCTAssertEqual(plan.method, .adoptHostBinary(installed))
        XCTAssertEqual(plan.destination, installed)
        XCTAssertTrue(
            plan.explanation.lowercased().contains("already"),
            "the plan should say no work is needed, got: \(plan.explanation)"
        )
    }

    // MARK: - Discovery

    func testInstalledRuntimeIsNilWhenNothingIsInstalled() {
        XCTAssertNil(LlamaRuntimeInstaller.installedRuntime(paths: paths))
    }

    func testInstalledRuntimeFindsThePrivatePrefixCopy() throws {
        let binary = paths.brewPrefix.appendingPathComponent("bin/llama-server")
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        XCTAssertEqual(LlamaRuntimeInstaller.installedRuntime(paths: paths), binary)
    }

    // MARK: - Failure modes

    func testAdoptRejectsAMissingSourceAndLeavesNothingBehind() throws {
        let missing = scratch.appendingPathComponent("does-not-exist")

        XCTAssertThrowsError(try LlamaRuntimeInstaller.adopt(from: missing, into: paths)) { error in
            guard case LlamaRuntimeInstaller.InstallError.sourceMissing = error else {
                return XCTFail("expected sourceMissing, got \(error)")
            }
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.brewPrefix.appendingPathComponent("bin/llama-server").path
            )
        )
    }

    func testAdoptRejectsANonExecutableSource() throws {
        let source = try makeScript(named: "llama-server", body: "#!/bin/sh\nexit 0\n", executable: false)

        XCTAssertThrowsError(try LlamaRuntimeInstaller.adopt(from: source, into: paths)) { error in
            guard case LlamaRuntimeInstaller.InstallError.sourceNotExecutable = error else {
                return XCTFail("expected sourceNotExecutable, got \(error)")
            }
        }
    }

    func testAdoptFailsHonestlyWhenTheClosureCannotBeCompleted() throws {
        let source = try makeBrokenClosureFixture()

        XCTAssertThrowsError(try LlamaRuntimeInstaller.adopt(from: source, into: paths)) { error in
            guard case LlamaRuntimeInstaller.InstallError.dependencyNotFound(let name, _) = error else {
                return XCTFail("expected dependencyNotFound, got \(error)")
            }
            XCTAssertEqual(name, "/nonexistent/libmissing.dylib")
        }

        // The point of the whole exercise: a runtime that cannot launch must
        // not be left where the locator would find it.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.brewPrefix.appendingPathComponent("bin/fake-tool").path
            )
        )
        XCTAssertEqual(contents(of: paths.brewPrefix.appendingPathComponent("lib")), [])
        XCTAssertTrue(
            contents(of: paths.tmp).filter { $0.hasPrefix("adopt-") }.isEmpty,
            "the staging directory should have been removed"
        )
    }

    // MARK: - Adoption

    func testAdoptCopiesAPlainScriptWithNoDependencies() throws {
        let source = try makeScript(
            named: "llama-server",
            body: "#!/bin/sh\necho \"version: 1.2.3\"\n"
        )

        let installed = try LlamaRuntimeInstaller.adopt(from: source, into: paths)

        XCTAssertEqual(installed, paths.brewPrefix.appendingPathComponent("bin/llama-server"))
        XCTAssertTrue(paths.contains(installed))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.path))

        let executed = try run(installed, ["--version"])
        XCTAssertEqual(executed.status, 0)
        XCTAssertTrue(executed.output.contains("1.2.3"))
    }

    func testAdoptReplacesAPreviousInstall() throws {
        let first = try makeScript(named: "first", body: "#!/bin/sh\necho \"version: one\"\n")
        let second = try makeScript(named: "second", body: "#!/bin/sh\necho \"version: two\"\n")

        _ = try LlamaRuntimeInstaller.adopt(from: first, into: paths)
        let installed = try LlamaRuntimeInstaller.adopt(from: second, into: paths)

        let executed = try run(installed, ["--version"])
        XCTAssertEqual(executed.status, 0)
        XCTAssertTrue(executed.output.contains("two"), "the second adoption should win")
    }

    // MARK: - The real thing

    func testAdoptRealHomebrewLlamaServerProducesARunnableBinary() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.hostBinary.path) else {
            throw XCTSkip("no Homebrew llama-server on this machine")
        }

        let installed = try LlamaRuntimeInstaller.adopt(from: Self.hostBinary, into: paths)

        // 1. It landed inside the sandbox, not beside the original.
        XCTAssertTrue(paths.contains(installed))
        XCTAssertFalse(installed.path.hasPrefix("/opt/homebrew"))
        XCTAssertEqual(installed, paths.brewPrefix.appendingPathComponent("bin/llama-server"))

        // 2. It actually runs. Everything else is decoration.
        let executed = try run(installed, ["--version"])
        XCTAssertEqual(executed.status, 0, "the adopted binary failed to launch: \(executed.output)")
        XCTAssertTrue(
            executed.output.lowercased().contains("version"),
            "expected a version line, got: \(executed.output)"
        )

        // 3. It runs without reaching back to the host.
        let dependencies = try otoolDependencies(installed)
        let external = dependencies.filter { $0.hasPrefix("/opt/homebrew") }
        XCTAssertTrue(external.isEmpty, "the copy still points at Homebrew: \(external)")
        XCTAssertTrue(
            dependencies.contains { $0.hasPrefix("@executable_path/../lib/") },
            "expected rewritten install names, got: \(dependencies)"
        )

        // 4. The libraries came along and were rewritten too.
        let libraries = contents(of: paths.brewPrefix.appendingPathComponent("lib"))
        XCTAssertFalse(libraries.isEmpty, "no libraries were copied")
        for library in libraries {
            let path = paths.brewPrefix.appendingPathComponent("lib/\(library)")
            let libraryDependencies = try otoolDependencies(path)
            let leaked = libraryDependencies.filter { $0.hasPrefix("/opt/homebrew") }
            XCTAssertTrue(leaked.isEmpty, "\(library) still points at Homebrew: \(leaked)")
        }

        // 5. The app can find what was installed.
        XCTAssertEqual(LlamaRuntimeInstaller.installedRuntime(paths: paths), installed)

        // 6. And the locator agrees on where it came from.
        let runtime = try XCTUnwrap(LlamaRuntimeLocator(paths: paths).locate())
        XCTAssertEqual(runtime.binary, installed)
        XCTAssertEqual(runtime.origin, .sandbox)
    }

    // MARK: - Build script

    func testBuildScriptInstallsIntoThePrivatePrefix() {
        let script = LlamaRuntimeInstaller.buildScript(paths: paths)

        XCTAssertTrue(script.contains("https://github.com/ggml-org/llama.cpp.git"))
        XCTAssertTrue(script.contains(paths.brewPrefix.path))
        XCTAssertTrue(script.contains("-DGGML_METAL=ON"))
        XCTAssertTrue(script.contains("-DCMAKE_INSTALL_PREFIX=\"$PREFIX\""))
        XCTAssertTrue(script.contains("codesign --force --sign -"))
        XCTAssertTrue(script.contains("\"$PREFIX/bin/llama-server\" --version"))
        XCTAssertFalse(script.contains("/opt/homebrew"), "the build must not install over the host")
    }

    /// The build itself takes half an hour, so the script's syntax is the one
    /// thing about it that can be checked here. A script that does not parse
    /// would fail after the clone.
    func testBuildScriptIsValidShell() throws {
        let script = try makeScript(named: "build-llama.sh", body: LlamaRuntimeInstaller.buildScript(paths: paths))

        let result = try LlamaRuntimeInstaller.runTool(
            URL(fileURLWithPath: "/bin/sh"),
            ["-n", script.path]
        )

        XCTAssertEqual(result.status, 0, "the generated script does not parse: \(result.output)")
    }

    func testBuildScriptQuotesPrefixesContainingApostrophes() {
        let awkward = SandboxPaths(root: root.appendingPathComponent("it's here"))
        let script = LlamaRuntimeInstaller.buildScript(paths: awkward)

        XCTAssertTrue(script.contains("'\\''"), "the prefix should be shell-quoted: \(script)")
        XCTAssertFalse(script.contains("/opt/homebrew"))
    }

    // MARK: - Parsing

    func testParsesInstallNamesWithSpaces() {
        // Homebrew paths are tidy, but LM Studio lives under
        // "/Applications/LM Studio.app", and splitting on whitespace there
        // would silently truncate the path.
        let line = "\t/Applications/LM Studio.app/Contents/lib/libllama.0.dylib (compatibility version 0.0.0, current version 0.0.0)"
        XCTAssertEqual(
            LlamaRuntimeInstaller.parseInstallName(line),
            "/Applications/LM Studio.app/Contents/lib/libllama.0.dylib"
        )
    }

    func testParsesOnlyRPathLoadCommands() {
        let output = """
        Load command 5
              cmd LC_RPATH
          cmdsize 32
             path @loader_path/../lib (offset 12)
        Load command 6
              cmd LC_LOAD_DYLIB
          cmdsize 56
             name /opt/homebrew/lib/libfoo.dylib (offset 24)
        """

        XCTAssertEqual(LlamaRuntimeInstaller.parseRPaths(output), ["@loader_path/../lib"])
    }
}
