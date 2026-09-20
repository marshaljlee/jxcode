import Foundation

// MARK: - Owning the model runner
//
// The app's promise is that installing a tool inside JXCode keeps it inside
// JXCode. The model runner was the one exception: `llama-server` was borrowed
// from Homebrew, so on a machine without Homebrew local GGUF serving was
// simply unreachable. This module closes that gap by letting the app own a
// copy of the runtime.
//
// Closing it is not a file copy, and the reason is worth writing down. The
// Homebrew `llama-server` is a 42 KB launcher. The work lives in a dozen
// dylibs spread across `/opt/homebrew/opt/llama.cpp`, `/opt/homebrew/opt/ggml`,
// `/opt/homebrew/opt/openssl@3` and `/opt/homebrew/opt/libomp`, reached
// through a mix of `@rpath` and absolute Homebrew paths. Copy the launcher
// alone and it will not launch. Copy the dylibs but leave the recorded paths
// alone and it still will not launch -- dyld follows those paths back out to
// the host, which defeats the isolation even on a machine that still has
// Homebrew.
//
// So adoption is a sequence in which every step can fail:
//
//   1. Walk the transitive dependency closure with `otool -L`. Resolve
//      `@rpath`, `@loader_path` and `@executable_path` against each image's own
//      `LC_RPATH` list, then recurse into each dylib's dependencies -- the
//      ggml and openssl libraries have their own transitive edges, and one of
//      them (`libggml-base`) reaches all the way out to `libomp`.
//   2. Copy the binary to `<prefix>/bin` and every non-system library to
//      `<prefix>/lib`, preserving the relative layout the rewrites assume.
//   3. Rewrite install names with `install_name_tool`: every reference from
//      the binary becomes `@executable_path/../lib/<name>`, every reference
//      between libraries becomes `@rpath/<name>`, and each library gets
//      `-id @rpath/<name>` so it no longer advertises a Homebrew path.
//   4. Re-sign every touched file with `codesign --force --sign -`. On Apple
//      Silicon, editing a Mach-O invalidates its signature and the kernel
//      refuses to execute the result, so skipping this yields a binary that
//      exists, looks correct, and dies with SIGKILL.
//   5. Run the copied binary with `--version` and require exit 0 with output.
//
// Step 5 is the only step that proves anything, and it is why `adopt` does not
// report success on the basis that the copies completed. A binary that cannot
// launch is the exact failure this module exists to prevent: the locator
// searches the private prefix first, so a broken copy there would shadow a
// working host binary and turn "llama-server works" into "llama-server
// crashes". Every failure therefore throws and leaves the prefix exactly as it
// was found.

public struct LlamaRuntimeInstaller: Sendable {

    // MARK: - API types

    public enum Method: Sendable, Equatable {
        /// Copy an existing binary (and its dependencies) into the sandbox.
        case adoptHostBinary(URL)
        /// Build llama.cpp from source inside the sandbox's own toolchain.
        case buildFromSource
    }

    public struct Plan: Sendable, Equatable {
        public let method: Method
        public let destination: URL
        /// Plain-language description of what would happen, for the UI.
        public let explanation: String
        public let warnings: [String]

        public init(method: Method, destination: URL, explanation: String, warnings: [String]) {
            self.method = method
            self.destination = destination
            self.explanation = explanation
            self.warnings = warnings
        }
    }

    /// Every way adoption can fail. Each case names the step that failed, so a
    /// user reading the error knows whether the problem is theirs to fix.
    public enum InstallError: Error, CustomStringConvertible {
        case sourceMissing(URL)
        case sourceNotExecutable(URL)
        /// A recorded dependency could not be found on disk. Adoption stops
        /// rather than shipping a binary with a dangling library reference.
        case dependencyNotFound(installName: String, loadedBy: URL)
        /// Two different libraries share a basename, so both cannot occupy the
        /// single `lib/<name>` slot without one silently replacing the other.
        case dependencyNameConflict(name: String, first: URL, second: URL)
        case toolFailed(tool: String, status: Int32, output: String)
        case toolTimedOut(tool: String)
        /// The copy exists but does not launch. Nothing is installed.
        case verificationFailed(binary: URL, status: Int32, output: String)

        public var description: String {
            switch self {
            case .sourceMissing(let url):
                return "There is no file to adopt at \(url.path)."
            case .sourceNotExecutable(let url):
                return "\(url.path) exists but is not executable, so it cannot be a llama-server."
            case .dependencyNotFound(let name, let loadedBy):
                return "\(loadedBy.lastPathComponent) needs \(name), which could not be found on this "
                    + "machine. The runtime was not installed, because a copy with a missing library "
                    + "would be found by the app and fail at launch."
            case .dependencyNameConflict(let name, let first, let second):
                return "Two different libraries are both named \(name): \(first.path) and \(second.path). "
                    + "They cannot both be installed beside the binary."
            case .toolFailed(let tool, let status, let output):
                let detail = output.isEmpty ? "no output" : output
                return "\(tool) failed with status \(status): \(detail)"
            case .toolTimedOut(let tool):
                return "\(tool) did not finish in time and was terminated."
            case .verificationFailed(let binary, let status, let output):
                let detail = output.isEmpty ? "no output" : output
                return "The copied \(binary.lastPathComponent) did not run: exit status \(status), "
                    + "\(detail). The copy was discarded."
            }
        }
    }

    // MARK: - Planning

    /// What the app would do, given what it can currently see.
    ///
    /// Pure: it inspects and describes, it never installs. The dependency walk
    /// runs here anyway because "this binary needs eight libraries from outside
    /// the sandbox" is exactly the kind of thing a user should learn before
    /// clicking the button, not after.
    public static func plan(paths: SandboxPaths, hostRuntime: LlamaRuntime?) -> Plan {
        let destination = LlamaRuntimeLocator(paths: paths)
            .installationDirectory
            .appendingPathComponent(LlamaRuntimeLocator.binaryName)

        guard let hostRuntime else {
            return Plan(
                method: .buildFromSource,
                destination: destination,
                explanation: "No llama-server was found on this machine, so there is nothing to adopt. "
                    + "JXCode can build llama.cpp from source inside its own prefix at "
                    + "\(paths.display(paths.brewPrefix)) and install llama-server there. The result "
                    + "depends on nothing outside the sandbox.",
                warnings: [
                    "A source build takes roughly 30 minutes and needs git and cmake.",
                    "It clones llama.cpp from github.com, so it needs network access.",
                ]
            )
        }

        if hostRuntime.origin == .sandbox {
            return Plan(
                method: .adoptHostBinary(hostRuntime.binary),
                destination: hostRuntime.binary,
                explanation: "llama-server is already installed inside the sandbox at "
                    + "\(paths.display(hostRuntime.binary)). Nothing needs to be copied: the app owns "
                    + "this binary, and deleting the sandbox removes it.",
                warnings: []
            )
        }

        let source = hostRuntime.binary.resolvingSymlinksInPath()
        var warnings: [String] = []

        guard MachOFile.isMachO(source) else {
            warnings.append("This file is not a Mach-O binary, so it has no shared libraries and will "
                + "be copied verbatim.")
            return Plan(
                method: .adoptHostBinary(hostRuntime.binary),
                destination: destination,
                explanation: "Copy \(source.path) into \(paths.display(destination)). It loads no "
                    + "libraries from the host, so there is nothing to rewrite.",
                warnings: warnings
            )
        }

        guard let (_, libraries) = try? dependencyClosure(executable: source) else {
            warnings.append("The libraries this binary loads could not all be located, so adoption "
                + "would fail. Building from source is the fallback.")
            return Plan(
                method: .adoptHostBinary(hostRuntime.binary),
                destination: destination,
                explanation: "Copy \(source.path) into \(paths.display(destination)).",
                warnings: warnings
            )
        }

        let names = libraries.keys.sorted().joined(separator: ", ")
        if !libraries.isEmpty {
            warnings.append("\(libraries.count) shared libraries from outside the sandbox will be "
                + "copied in: \(names).")
        }
        warnings.append("The adopted copy is a snapshot. Updating llama.cpp on the host will not "
            + "update it.")

        return Plan(
            method: .adoptHostBinary(hostRuntime.binary),
            destination: destination,
            explanation: "Copy \(source.path) and the \(libraries.count) libraries it loads into "
                + "\(paths.display(paths.brewPrefix)), rewrite every recorded library path so each one "
                + "is found beside the binary, re-sign the copies, and run --version to confirm the "
                + "result actually launches. Nothing outside the sandbox is modified.",
            warnings: warnings
        )
    }

    // MARK: - Adoption

    /// Perform an adoption. Throws on any failure, leaving nothing behind.
    /// Returns the URL of the installed, verified, runnable binary.
    public static func adopt(from source: URL, into paths: SandboxPaths) throws -> URL {
        let fileManager = FileManager.default
        let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL

        // Validate before touching the filesystem. A rejection here costs
        // nothing and leaves no directory tree behind for the user to wonder
        // about.
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedSource.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw InstallError.sourceMissing(source)
        }
        guard fileManager.isExecutableFile(atPath: resolvedSource.path) else {
            throw InstallError.sourceNotExecutable(source)
        }

        try paths.createDirectories()

        // Everything is assembled in the sandbox's own temp directory. The
        // prefix is not written to until a copy has been proven to launch, so
        // an aborted adoption cannot shadow a working host binary.
        let stage = paths.tmp.appendingPathComponent("adopt-\(UUID().uuidString)", isDirectory: true)
        let stageBin = stage.appendingPathComponent("bin", isDirectory: true)
        let stageLib = stage.appendingPathComponent("lib", isDirectory: true)
        try fileManager.createDirectory(at: stageBin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: stageLib, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: stage) }

        let binaryName = resolvedSource.lastPathComponent
        let isMachO = MachOFile.isMachO(resolvedSource)

        var images: [Image] = []
        var libraries: [String: URL] = [:]
        if isMachO {
            (images, libraries) = try dependencyClosure(executable: resolvedSource)
        }

        let stagedBinary = stageBin.appendingPathComponent(binaryName)
        try fileManager.copyItem(at: resolvedSource, to: stagedBinary)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedBinary.path)

        for (name, origin) in libraries {
            try fileManager.copyItem(at: origin, to: stageLib.appendingPathComponent(name))
        }

        if isMachO {
            try rewriteExecutable(stagedBinary, image: images[0], executableDirectory: resolvedSource.deletingLastPathComponent())
            for image in images.dropFirst() {
                let staged = stageLib.appendingPathComponent(image.url.lastPathComponent)
                try rewriteLibrary(staged, image: image, executableDirectory: resolvedSource.deletingLastPathComponent())
            }
            for name in libraries.keys.sorted() {
                try sign(stageLib.appendingPathComponent(name))
            }
            try sign(stagedBinary)
        }

        // The gate. A binary that cannot run must never reach the prefix.
        try verifyLaunches(stagedBinary)

        // The staged layout mirrors the installed layout exactly, so the
        // relative paths proven above hold after the move. Libraries go first:
        // the binary is the only file the locator looks for, so placing it last
        // means a failure mid-move leaves an unused lib/ rather than a
        // discoverable runtime that cannot start.
        let binDirectory = paths.brewPrefix.appendingPathComponent("bin", isDirectory: true)
        let libDirectory = paths.brewPrefix.appendingPathComponent("lib", isDirectory: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: libDirectory, withIntermediateDirectories: true)

        let destination = binDirectory.appendingPathComponent(binaryName)
        var journal: [(destination: URL, backup: URL?)] = []
        do {
            for name in libraries.keys.sorted() {
                try install(
                    stageLib.appendingPathComponent(name),
                    to: libDirectory.appendingPathComponent(name),
                    stage: stage,
                    journal: &journal
                )
            }
            try install(stagedBinary, to: destination, stage: stage, journal: &journal)
        } catch {
            rollback(journal)
            throw error
        }

        return destination
    }

    /// Move one staged file into the prefix, remembering what was there first.
    ///
    /// The backup exists so that a failure halfway through the move can restore
    /// a previous installation instead of destroying it: replacing a working
    /// runtime with nothing is its own kind of half-installed state.
    private static func install(
        _ source: URL,
        to destination: URL,
        stage: URL,
        journal: inout [(destination: URL, backup: URL?)]
    ) throws {
        let fileManager = FileManager.default
        var backup: URL?
        if fileManager.fileExists(atPath: destination.path) {
            let holder = stage.appendingPathComponent("replaced", isDirectory: true)
            try fileManager.createDirectory(at: holder, withIntermediateDirectories: true)
            let saved = holder.appendingPathComponent(UUID().uuidString + "-" + destination.lastPathComponent)
            try fileManager.moveItem(at: destination, to: saved)
            backup = saved
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            if let backup { try? fileManager.moveItem(at: backup, to: destination) }
            throw error
        }
        journal.append((destination, backup))
    }

    private static func rollback(_ journal: [(destination: URL, backup: URL?)]) {
        let fileManager = FileManager.default
        for entry in journal.reversed() {
            try? fileManager.removeItem(at: entry.destination)
            if let backup = entry.backup {
                try? fileManager.moveItem(at: backup, to: entry.destination)
            }
        }
    }

    // MARK: - Source builds

    /// A shell script that builds llama.cpp from source inside the sandbox.
    /// Returned as a string; the caller decides whether to run it.
    public static func buildScript(paths: SandboxPaths) -> String {
        let prefix = paths.brewPrefix.path
        let source = paths.tmp.appendingPathComponent("llama.cpp", isDirectory: true).path
        let build = paths.tmp.appendingPathComponent("llama.cpp-build", isDirectory: true).path

        return """
        #!/bin/sh
        # Install llama-server into the JXCode sandbox, built from source.
        #
        # WHY THIS EXISTS: adoption copies a binary out of Homebrew and rewrites
        # its library paths. That works, but the result is whatever the host
        # happened to install. This script produces a binary that owes the host
        # nothing: a static build with the Metal shader library embedded, so
        # there is no dylib closure to rewrite and no signature to repair
        # afterwards. That is also why BUILD_SHARED_LIBS is OFF below.
        #
        # HOW LONG IT TAKES: roughly 30 minutes on an Apple Silicon laptop, and
        # longer from a cold start. Most of the time goes into the Metal shader
        # library and the ggml backend objects. Nothing here is interactive, so
        # it is safe to run in the background and stream the output.
        #
        # NOTHING OUTSIDE THE SANDBOX IS TOUCHED: the clone, the build tree and
        # the install prefix all live under the sandbox root.
        set -eu

        PREFIX=\(shellQuoted(prefix))
        SOURCE=\(shellQuoted(source))
        BUILD=\(shellQuoted(build))

        # Keep the toolchain's own scratch space inside the sandbox too.
        export TMPDIR=\(shellQuoted(paths.tmp.path))
        export PATH="$PREFIX/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        mkdir -p "$PREFIX/bin" "$PREFIX/lib"

        if [ -d "$SOURCE/.git" ]; then
          git -C "$SOURCE" pull --ff-only
        else
          git clone --depth 1 https://github.com/ggml-org/llama.cpp.git "$SOURCE"
        fi

        cmake -S "$SOURCE" -B "$BUILD" \\
          -DCMAKE_BUILD_TYPE=Release \\
          -DCMAKE_INSTALL_PREFIX="$PREFIX" \\
          -DBUILD_SHARED_LIBS=OFF \\
          -DGGML_METAL=ON \\
          -DGGML_METAL_EMBED_LIBRARY=ON \\
          -DGGML_ACCELERATE=ON \\
          -DLLAMA_CURL=OFF \\
          -DLLAMA_BUILD_TESTS=OFF \\
          -DLLAMA_BUILD_SERVER=ON

        cmake --build "$BUILD" --config Release --target llama-server \\
          --parallel "$(sysctl -n hw.ncpu)"

        cmake --install "$BUILD" --config Release

        # A freshly linked binary is unsigned on Apple Silicon and will not
        # launch until it is signed, even ad-hoc.
        codesign --force --sign - "$PREFIX/bin/llama-server"
        "$PREFIX/bin/llama-server" --version
        """
    }

    // MARK: - Discovery

    /// The installed binary, if one is present and executable.
    public static func installedRuntime(paths: SandboxPaths) -> URL? {
        let candidates = [
            paths.brewPrefix.appendingPathComponent("bin/\(LlamaRuntimeLocator.binaryName)"),
            paths.bin.appendingPathComponent(LlamaRuntimeLocator.binaryName),
            paths.localBin.appendingPathComponent(LlamaRuntimeLocator.binaryName),
        ]
        return candidates.first { LlamaRuntimeLocator.isExecutable($0) }
    }

    // MARK: - Dependency closure

    /// One Mach-O file, with the load commands adoption needs.
    struct Image {
        let url: URL
        let isExecutable: Bool
        /// Recorded install names, excluding system libraries and the image's
        /// own `LC_ID_DYLIB`.
        let dependencies: [String]
        let rpaths: [String]
    }

    /// Every non-system file the executable needs, and where each lives now.
    ///
    /// Breadth-first rather than a single `otool -L` pass because the
    /// dependencies have dependencies: `libllama-server-impl` reaches ggml and
    /// openssl, and `libggml-base` reaches `libomp` two levels further down.
    /// Stopping at the first level would install a runtime that fails to load
    /// the moment it touches a tensor.
    static func dependencyClosure(executable: URL) throws -> (images: [Image], libraries: [String: URL]) {
        var images: [Image] = []
        var libraries: [String: URL] = [:]
        var visited: Set<String> = []
        var queue: [(url: URL, isExecutable: Bool)] = [(executable, true)]
        let executableDirectory = executable.deletingLastPathComponent()

        while !queue.isEmpty {
            let (url, isExecutable) = queue.removeFirst()
            guard !visited.contains(url.path) else { continue }
            visited.insert(url.path)

            let image = try inspect(url, isExecutable: isExecutable)
            images.append(image)

            for name in image.dependencies {
                guard !isSystemLibrary(name) else { continue }
                guard let resolved = resolve(
                    name,
                    loadedBy: url,
                    executableDirectory: executableDirectory,
                    rpaths: image.rpaths
                ) else {
                    throw InstallError.dependencyNotFound(installName: name, loadedBy: url)
                }

                let basename = resolved.lastPathComponent
                if let existing = libraries[basename], existing.path != resolved.path {
                    throw InstallError.dependencyNameConflict(name: basename, first: existing, second: resolved)
                }
                libraries[basename] = resolved

                if !visited.contains(resolved.path) {
                    queue.append((resolved, false))
                }
            }
        }

        return (images, libraries)
    }

    static func inspect(_ url: URL, isExecutable: Bool) throws -> Image {
        let listing = try runTool(otool, ["-L", url.path])
        guard listing.succeeded else {
            throw InstallError.toolFailed(tool: "otool", status: listing.status, output: listing.output)
        }

        var dependencies = parseDependencies(listing.output)

        if !isExecutable {
            // `otool -L` prints a dylib's own `LC_ID_DYLIB` first. Rewriting
            // that would be wrong: it is the library's identity, not a
            // reference to something it loads.
            let identity = try runTool(otool, ["-D", url.path])
            if identity.succeeded, let ownID = parseIdentity(identity.output) {
                dependencies.removeAll { $0 == ownID }
            } else if !dependencies.isEmpty {
                dependencies.removeFirst()
            }
        }

        // Only pay for `otool -l` when a relative lookup will actually happen.
        var rpaths: [String] = []
        if dependencies.contains(where: { $0.hasPrefix("@rpath/") }) {
            let commands = try runTool(otool, ["-l", url.path])
            guard commands.succeeded else {
                throw InstallError.toolFailed(tool: "otool", status: commands.status, output: commands.output)
            }
            rpaths = parseRPaths(commands.output)
        }

        return Image(url: url, isExecutable: isExecutable, dependencies: dependencies, rpaths: rpaths)
    }

    /// `otool -L` prints the file's path, then one line per load command.
    static func parseDependencies(_ output: String) -> [String] {
        var lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard !lines.isEmpty else { return [] }
        lines.removeFirst()
        return lines.compactMap(parseInstallName)
    }

    /// The install name runs up to the `(compatibility version ...)` suffix.
    /// Splitting on whitespace instead would truncate any path containing a
    /// space, which is common enough in `/Applications`.
    static func parseInstallName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let range = trimmed.range(of: " (compatibility version") {
            let name = String(trimmed[trimmed.startIndex..<range.lowerBound])
            return name.isEmpty ? nil : name
        }
        return trimmed
    }

    static func parseIdentity(_ output: String) -> String? {
        output.split(separator: "\n")
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    /// Collect `LC_RPATH` values only, tracked by command so that an unrelated
    /// load command with a `path` field cannot leak in.
    static func parseRPaths(_ output: String) -> [String] {
        var results: [String] = []
        var inRPath = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("cmd ") {
                inRPath = (line == "cmd LC_RPATH")
                continue
            }
            guard inRPath, line.hasPrefix("path ") else { continue }
            var value = String(line.dropFirst("path ".count))
            if let range = value.range(of: " (offset") {
                value = String(value[value.startIndex..<range.lowerBound])
            }
            results.append(value.trimmingCharacters(in: .whitespaces))
        }
        return results
    }

    static func isSystemLibrary(_ path: String) -> Bool {
        path.hasPrefix("/usr/lib/")
            || path.hasPrefix("/System/")
            || path.hasPrefix("/Library/Apple/")
    }

    /// Library directories worth trying when an `@rpath` has no `LC_RPATH` to
    /// expand, or when its rpaths do not contain the library. Homebrew's
    /// `lib/` is a flat directory of symlinks into the Cellar, which is what
    /// makes a single fallback root sufficient for most formulae.
    static let fallbackLibraryDirectories = [
        URL(fileURLWithPath: "/opt/homebrew/lib"),
        URL(fileURLWithPath: "/usr/local/lib"),
        URL(fileURLWithPath: "/opt/local/lib"),
    ]

    /// Turn a recorded install name into the file it refers to right now.
    static func resolve(
        _ installName: String,
        loadedBy loader: URL,
        executableDirectory: URL,
        rpaths: [String]
    ) -> URL? {
        let loaderDirectory = loader.deletingLastPathComponent()

        func existing(_ url: URL) -> URL? {
            let candidate = url.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else { return nil }
            return candidate.resolvingSymlinksInPath().standardizedFileURL
        }

        if installName.hasPrefix("@rpath/") {
            let name = String(installName.dropFirst("@rpath/".count))
            var roots = rpaths.compactMap {
                expandRPath($0, loaderDirectory: loaderDirectory, executableDirectory: executableDirectory)
            }
            roots.append(loaderDirectory)
            roots.append(contentsOf: fallbackLibraryDirectories)
            for root in roots {
                if let found = existing(root.appendingPathComponent(name)) { return found }
            }
            return nil
        }

        if installName.hasPrefix("@loader_path/") {
            return existing(loaderDirectory.appendingPathComponent(String(installName.dropFirst("@loader_path/".count))))
        }

        if installName.hasPrefix("@executable_path/") {
            return existing(executableDirectory.appendingPathComponent(String(installName.dropFirst("@executable_path/".count))))
        }

        if installName.hasPrefix("/") {
            return existing(URL(fileURLWithPath: installName))
        }

        return existing(loaderDirectory.appendingPathComponent(installName))
    }

    static func expandRPath(_ rpath: String, loaderDirectory: URL, executableDirectory: URL) -> URL? {
        if rpath.hasPrefix("@loader_path") {
            return URL(fileURLWithPath: rpath.replacingOccurrences(of: "@loader_path", with: loaderDirectory.path))
        }
        if rpath.hasPrefix("@executable_path") {
            return URL(fileURLWithPath: rpath.replacingOccurrences(of: "@executable_path", with: executableDirectory.path))
        }
        if rpath.hasPrefix("/") {
            return URL(fileURLWithPath: rpath)
        }
        return URL(fileURLWithPath: loaderDirectory.appendingPathComponent(rpath).path)
    }

    // MARK: - Rewriting

    private static func rewriteExecutable(_ file: URL, image: Image, executableDirectory: URL) throws {
        for name in image.dependencies where !isSystemLibrary(name) {
            guard let resolved = resolve(
                name,
                loadedBy: image.url,
                executableDirectory: executableDirectory,
                rpaths: image.rpaths
            ) else {
                throw InstallError.dependencyNotFound(installName: name, loadedBy: image.url)
            }
            try change(file, from: name, to: "@executable_path/../lib/\(resolved.lastPathComponent)")
        }
        try addRPathIfNeeded(file, "@executable_path/../lib")
    }

    private static func rewriteLibrary(_ file: URL, image: Image, executableDirectory: URL) throws {
        try setIdentity(file, to: "@rpath/\(file.lastPathComponent)")

        for name in image.dependencies where !isSystemLibrary(name) {
            guard let resolved = resolve(
                name,
                loadedBy: image.url,
                executableDirectory: executableDirectory,
                rpaths: image.rpaths
            ) else {
                throw InstallError.dependencyNotFound(installName: name, loadedBy: image.url)
            }
            // References between libraries stay relative to the loader, so a
            // library loaded from `lib/` resolves its own siblings there
            // rather than at whatever path the host used.
            try change(file, from: name, to: "@rpath/\(resolved.lastPathComponent)")
        }

        // `@rpath` needs something to expand. The executable's rpath is usually
        // enough, but adding the same one here keeps each library
        // independently loadable, which matters when dyld resolves a chain
        // that does not start at the main executable.
        try addRPathIfNeeded(file, "@executable_path/../lib")
    }

    private static func change(_ file: URL, from old: String, to new: String) throws {
        let result = try runTool(installNameTool, ["-change", old, new, file.path])
        guard result.succeeded else {
            throw InstallError.toolFailed(tool: "install_name_tool", status: result.status, output: result.output)
        }
    }

    private static func setIdentity(_ file: URL, to identity: String) throws {
        let result = try runTool(installNameTool, ["-id", identity, file.path])
        guard result.succeeded else {
            throw InstallError.toolFailed(tool: "install_name_tool", status: result.status, output: result.output)
        }
    }

    /// Add an rpath only when it is absent. `install_name_tool -add_rpath`
    /// fails on a duplicate, so checking first keeps the exit status meaningful
    /// instead of teaching the caller to ignore it.
    private static func addRPathIfNeeded(_ file: URL, _ rpath: String) throws {
        let commands = try runTool(otool, ["-l", file.path])
        guard commands.succeeded else {
            throw InstallError.toolFailed(tool: "otool", status: commands.status, output: commands.output)
        }
        guard !parseRPaths(commands.output).contains(rpath) else { return }

        let result = try runTool(installNameTool, ["-add_rpath", rpath, file.path])
        guard result.succeeded else {
            throw InstallError.toolFailed(tool: "install_name_tool", status: result.status, output: result.output)
        }
    }

    /// Ad-hoc signing is mandatory, not cosmetic: editing a Mach-O invalidates
    /// the signature Homebrew shipped, and the kernel refuses to start an
    /// arm64 binary with an invalid signature.
    private static func sign(_ file: URL) throws {
        let result = try runTool(codesign, ["--force", "--sign", "-", file.path], timeout: 120)
        guard result.succeeded else {
            throw InstallError.toolFailed(tool: "codesign", status: result.status, output: result.output)
        }
    }

    /// Run the copy and require a version. Nothing else in this file proves
    /// the runtime works, and a runtime that does not work is worse than none.
    private static func verifyLaunches(_ binary: URL) throws {
        let result = try runTool(binary, ["--version"], timeout: 120)
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, !output.isEmpty else {
            throw InstallError.verificationFailed(binary: binary, status: result.status, output: output)
        }
    }

    // MARK: - Process plumbing

    static let otool = URL(fileURLWithPath: "/usr/bin/otool")
    static let installNameTool = URL(fileURLWithPath: "/usr/bin/install_name_tool")
    static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")

    struct ToolResult: Sendable {
        let status: Int32
        let output: String
        var succeeded: Bool { status == 0 }
    }

    /// Runs a tool to completion with a hard timeout.
    ///
    /// `Process` has no timeout of its own, and a wedged `codesign` or a
    /// `--version` on a runtime that hangs at startup would otherwise block the
    /// caller forever. Output is drained on a background handler so a tool that
    /// writes more than a pipe buffer cannot deadlock against `isRunning`.
    static func runTool(_ tool: URL, _ arguments: [String], timeout: TimeInterval = 30) throws -> ToolResult {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBox = OutputBox()
        let errBox = OutputBox()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { outBox.append(chunk) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { errBox.append(chunk) }
        }

        let name = tool.lastPathComponent
        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw InstallError.toolFailed(tool: name, status: -1, output: error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }

        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let grace = Date().addingTimeInterval(2)
            while process.isRunning && Date() < grace {
                usleep(20_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outBox.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        errBox.append(errPipe.fileHandleForReading.readDataToEndOfFile())

        if timedOut {
            throw InstallError.toolTimedOut(tool: name)
        }

        let text = String(decoding: outBox.snapshot(), as: UTF8.self)
            + String(decoding: errBox.snapshot(), as: UTF8.self)
        return ToolResult(status: process.terminationStatus, output: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Accumulates pipe output across the reader thread and the caller.
    final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }

        func snapshot() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    /// Single-quote a value for `/bin/sh`, closing and reopening the quote so
    /// an embedded apostrophe cannot terminate it.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Mach-O detection.
///
/// Adoption treats a script differently from a binary: a script has no load
/// commands, so running `otool` on it would fail and `install_name_tool` would
/// corrupt it. The magic numbers cover thin and fat images in both byte
/// orders, because a copied binary may have come from anywhere.
enum MachOFile {

    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else { return false }

        let bytes = [UInt8](magic)
        let value = UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])

        switch value {
        case 0xFEEDFACE,  // MH_MAGIC
             0xFEEDFACF,  // MH_MAGIC_64
             0xCEFAEDFE,  // MH_CIGAM
             0xCFFAEDFE,  // MH_CIGAM_64
             0xCAFEBABE,  // FAT_MAGIC
             0xBEBAFECA,  // FAT_CIGAM
             0xCAFEBABF,  // FAT_MAGIC_64
             0xBFBAFECA:  // FAT_CIGAM_64
            return true
        default:
            return false
        }
    }
}
