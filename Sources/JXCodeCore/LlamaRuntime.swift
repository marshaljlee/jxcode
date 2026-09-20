import Foundation

// MARK: - Finding llama-server
//
// Pillar 03 needs a `llama-server` binary. This machine has none: no Homebrew,
// no LM Studio, nothing on `PATH`. That is not a problem to work around — it is
// the app's thesis arriving on schedule. The runtime should be installed into
// the sandbox's private prefix, so that installing a model runner does not
// modify the user's machine any more than installing Claude Code does.
//
// So the search is deliberately ordered: **the private prefix first, the host
// second**. Both are legitimate, but which one was found changes what the app
// promises. A binary inside the sandbox is isolated; a binary in
// `/opt/homebrew` is the user's own and updating or removing it is their
// business. Rather than hide that difference, `LlamaRuntime.origin` records it
// and the UI shows it.

public struct LlamaRuntime: Sendable, Equatable {
    /// Where the binary came from, which determines whether it is isolated.
    public enum Origin: String, Sendable, Codable {
        /// Inside the sandbox's private prefix. Installed by the app, isolated
        /// from the host, and removed with the sandbox.
        case sandbox
        /// The user's own installation — Homebrew, LM Studio, a manual build.
        /// Usable, but not isolated, and not ours to manage.
        case host
    }

    public let binary: URL
    public let origin: Origin
    /// Whatever `--version` reported, when it was worth running.
    public let version: String?

    public init(binary: URL, origin: Origin, version: String? = nil) {
        self.binary = binary
        self.origin = origin
        self.version = version
    }

    public var isIsolated: Bool { origin == .sandbox }

    public var displayName: String {
        var text = binary.path
        if let version, !version.isEmpty { text += " (\(version))" }
        return text
    }

    /// A sentence explaining what finding this binary means, for the UI.
    public var isolationNote: String {
        switch origin {
        case .sandbox:
            return "Running the isolated llama-server installed inside this app's sandbox."
        case .host:
            return "Running llama-server from \(binary.deletingLastPathComponent().path), "
                + "which is outside the sandbox. The app will not modify or update it."
        }
    }
}

public struct LlamaRuntimeLocator: Sendable {

    public static let binaryName = "llama-server"

    public var paths: SandboxPaths
    /// Extra directories to search, ahead of the built-in host locations.
    /// Tests use this; so would a user pointing the app at a custom build.
    public var extraSearchPaths: [URL]
    /// How deep to look inside known bundle directories (LM Studio nests its
    /// backends several levels down).
    public var bundleSearchDepth: Int

    public init(
        paths: SandboxPaths = .default,
        extraSearchPaths: [URL] = [],
        bundleSearchDepth: Int = 4
    ) {
        self.paths = paths
        self.extraSearchPaths = extraSearchPaths
        self.bundleSearchDepth = bundleSearchDepth
    }

    /// Every location that will be checked, in order.
    ///
    /// Exposed so the UI can show the user where the app looked rather than
    /// just reporting "not found" — a dead end with no explanation is the most
    /// frustrating possible outcome.
    public func candidates() -> [(url: URL, origin: LlamaRuntime.Origin)] {
        var results: [(URL, LlamaRuntime.Origin)] = []

        // 1. The private prefix. Anything installed by the app lives here.
        results.append((paths.brewPrefix.appendingPathComponent("bin/\(Self.binaryName)"), .sandbox))
        results.append((paths.bin.appendingPathComponent(Self.binaryName), .sandbox))
        results.append((paths.localBin.appendingPathComponent(Self.binaryName), .sandbox))

        // 2. Anything the caller added explicitly.
        for directory in extraSearchPaths {
            results.append((directory.appendingPathComponent(Self.binaryName), .host))
        }

        // 3. The host's usual places.
        for directory in Self.hostDirectories() {
            results.append((directory.appendingPathComponent(Self.binaryName), .host))
        }

        // 4. Bundled copies inside apps that ship llama.cpp.
        for directory in Self.bundledRuntimeDirectories(depth: bundleSearchDepth) {
            results.append((directory.appendingPathComponent(Self.binaryName), .host))
        }

        return results.map { (url: $0.0, origin: $0.1) }
    }

    /// The first candidate that exists and is executable.
    public func locate() -> LlamaRuntime? {
        for candidate in candidates() where Self.isExecutable(candidate.url) {
            return LlamaRuntime(binary: candidate.url, origin: candidate.origin)
        }
        return nil
    }

    /// Every candidate with whether it was found, for a diagnostics view.
    public func diagnostics() -> [(path: URL, origin: LlamaRuntime.Origin, exists: Bool)] {
        candidates().map { ($0.url, $0.origin, Self.isExecutable($0.url)) }
    }

    /// The private prefix where the app would install its own copy.
    public var installationDirectory: URL {
        paths.brewPrefix.appendingPathComponent("bin", isDirectory: true)
    }

    /// What the app would do to obtain a runtime, phrased as a single action.
    public var installationHint: String {
        "No llama-server was found. It can be installed into "
            + paths.display(installationDirectory)
            + " so the app stays self-contained and nothing is added to the host."
    }

    // MARK: Helpers

    static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    static func hostDirectories() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [
            URL(fileURLWithPath: "/opt/homebrew/bin"),   // Apple Silicon Homebrew
            URL(fileURLWithPath: "/usr/local/bin"),      // Intel Homebrew, manual builds
            URL(fileURLWithPath: "/opt/local/bin"),      // MacPorts
            home.appendingPathComponent("bin"),
            home.appendingPathComponent(".local/bin"),
        ]
    }

    /// Directories inside applications that ship their own llama.cpp.
    ///
    /// LM Studio bundles a `llama-server` under a versioned path several levels
    /// deep, which is why this walks rather than checking a fixed location.
    static func bundledRuntimeDirectories(depth: Int) -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let roots = [
            home.appendingPathComponent(".lmstudio/extensions/backends"),
            home.appendingPathComponent(".cache/lm-studio/extensions/backends"),
            URL(fileURLWithPath: "/Applications/LM Studio.app/Contents/Resources/app/.webpack/llm-engine"),
        ]

        var found: [URL] = []
        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            found.append(contentsOf: directories(under: root, depth: depth))
        }
        return found
    }

    /// Every directory at or below `root`, bounded by `depth`.
    ///
    /// A plain bounded walk rather than a recursive search for the binary: the
    /// binary name is known, so collecting the directories and appending it once
    /// keeps the candidate list uniform with every other entry.
    static func directories(under root: URL, depth: Int) -> [URL] {
        guard depth > 0 else { return [] }
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [URL] = []
        for url in contents {
            guard (try? url.resourceValues(forKeys: Set(keys)))?.isDirectory == true else { continue }
            out.append(url)
            out.append(contentsOf: directories(under: url, depth: depth - 1))
        }
        return out
    }
}

// MARK: - What the binary supports

/// Flag spellings differ between llama.cpp releases, and one of them matters.
///
/// `--flash-attn` was a bare flag for years and then grew an optional value
/// (`--flash-attn on|off|auto`). Passing a bare `-fa` to a build that wants a
/// value, or the reverse, makes llama-server exit at startup with an argument
/// error — a failure that looks like a bug in this app rather than a version
/// mismatch. Rather than guess, the help text is parsed once and the arguments
/// are rendered to match.
public struct LlamaServerCapabilities: Sendable, Equatable {

    public enum FlashAttentionStyle: String, Sendable, Equatable {
        /// `-fa` with no argument.
        case bareFlag
        /// `--flash-attn on`
        case explicitValue
    }

    /// How this build expresses "keep the weights in memory".
    ///
    /// Builds up to ~10100 spelled this as a pair of independent flags
    /// (`--mlock`, `--no-mmap`). Later builds collapsed all of them into a
    /// single `--load-mode MODE` and now mark the old spellings DEPRECATED —
    /// they still parse, but they print a warning at startup. Emitting the
    /// modern form on a modern build keeps the log clean; emitting it on an old
    /// build is a startup error, so the choice has to be made from the help
    /// text rather than hardcoded.
    public enum LoadModeStyle: String, Sendable, Equatable {
        /// `--load-mode none|mmap|mlock|mmap+mlock|dio`
        case explicitValue
        /// `--mlock` / `--no-mmap` / `--direct-io`
        case legacy
        /// The build advertises no way to control loading at all.
        case unsupported
    }

    public let supportsJinja: Bool
    public let supportsFlashAttention: Bool
    public let flashAttentionStyle: FlashAttentionStyle
    public let supportsCacheType: Bool
    public let supportsParallel: Bool
    /// Whether the build can slide the KV cache instead of refusing once the
    /// context fills. Agents need this: they resend a long, growing transcript
    /// every turn, so a session that outlives its context is the ordinary case
    /// rather than an edge one.
    public let supportsContextShift: Bool
    public let supportsMmap: Bool
    public let loadModeStyle: LoadModeStyle
    /// The help text this was derived from, kept for diagnostics.
    public let helpText: String

    public init(
        supportsJinja: Bool,
        supportsFlashAttention: Bool,
        flashAttentionStyle: FlashAttentionStyle,
        supportsCacheType: Bool,
        supportsParallel: Bool,
        supportsContextShift: Bool = true,
        supportsMmap: Bool,
        loadModeStyle: LoadModeStyle = .legacy,
        helpText: String
    ) {
        self.supportsJinja = supportsJinja
        self.supportsFlashAttention = supportsFlashAttention
        self.flashAttentionStyle = flashAttentionStyle
        self.supportsCacheType = supportsCacheType
        self.supportsParallel = supportsParallel
        self.supportsContextShift = supportsContextShift
        self.supportsMmap = supportsMmap
        self.loadModeStyle = loadModeStyle
        self.helpText = helpText
    }

    /// Assume a modern build when the help text cannot be read.
    ///
    /// Optimistic on purpose: the failure mode of guessing wrong here is a
    /// startup error the user can see and report, whereas assuming the oldest
    /// behaviour would silently disable features that are present.
    ///
    /// "Modern" means `-fa` takes a value. This used to be `.bareFlag`, which
    /// is what made every model load fail: llama.cpp read the argument after
    /// `-fa` as its value. Probing is the real fix; this is only the fallback,
    /// and the fallback has to match the binaries people actually have.
    public static let assumedModern = LlamaServerCapabilities(
        supportsJinja: true,
        supportsFlashAttention: true,
        flashAttentionStyle: .explicitValue,
        supportsCacheType: true,
        supportsParallel: true,
        supportsContextShift: true,
        supportsMmap: true,
        loadModeStyle: .explicitValue,
        helpText: ""
    )

    /// Ask a binary what it accepts, by running it with `--help`.
    ///
    /// `nil` when it cannot be run; callers fall back to `.assumedModern`.
    ///
    /// This exists because `parse(helpText:)` is worthless on its own. For a
    /// long time nothing called it: every caller took `.assumedModern`, whose
    /// `flashAttentionStyle` was `.bareFlag`. But `-fa` stopped being a bare
    /// flag when it gained `[on|off|auto]` — a bare `-fa` makes llama.cpp read
    /// the *next* argument as its value, so it consumed `-t`, printed
    /// `unknown value for --flash-attn: '-t'` and exited 1. Every model load
    /// failed before loading anything, and all 631 tests still passed, because
    /// no test ever ran a real `llama-server`.
    public static func probe(
        binary: URL,
        timeout: TimeInterval = 10
    ) async -> LlamaServerCapabilities? {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }

        let process = Process()
        process.executableURL = binary
        process.arguments = ["--help"]
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        // Drain both pipes before waiting. A `--help` page is well under the
        // pipe buffer today, but reading *after* `waitUntilExit()` deadlocks
        // the moment some build's usage text grows past it.
        let box = PipeBox()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            box.set(out, err)
            drained.signal()
        }

        if drained.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()

        let (outData, errData) = box.get()
        var text = String(data: outData, encoding: .utf8) ?? ""
        let errText = String(data: errData, encoding: .utf8) ?? ""
        // Some builds print usage to stderr instead.
        if text.isEmpty { text = errText } else if !errText.isEmpty { text += "\n" + errText }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return parse(helpText: text)
    }

    public static func parse(helpText: String) -> LlamaServerCapabilities {
        let lines = helpText.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }

        func mentions(_ token: String) -> Bool {
            lines.contains { $0.contains(token) }
        }

        let flashLine = lines.first { $0.contains("--flash-attn") || $0.contains("-fa,") || $0.contains("-fa ") }

        // A build that takes a value documents the choices in the flag's own
        // help line — "on|off|auto" or a bracketed placeholder. A bare-flag
        // build just describes what the flag does.
        var style: FlashAttentionStyle = .bareFlag
        if let flashLine {
            let lower = flashLine.lowercased()
            if lower.contains("on|off") || lower.contains("[on") || lower.contains("<on")
                || lower.contains("on,off") || lower.contains("{on") {
                style = .explicitValue
            }
        }

        return LlamaServerCapabilities(
            supportsJinja: mentions("--jinja"),
            supportsFlashAttention: flashLine != nil,
            flashAttentionStyle: style,
            supportsCacheType: mentions("--cache-type-k"),
            supportsParallel: mentions("--parallel") || mentions("-np"),
            supportsContextShift: mentions("--context-shift") || mentions("-cs"),
            supportsMmap: mentions("--no-mmap") || mentions("--mmap") || mentions("--load-mode"),
            loadModeStyle: loadModeStyle(in: lines),
            helpText: helpText
        )
    }

    /// Decide which loading-mode spelling this build defines.
    ///
    /// The discriminator has to be the *definition* line, not a bare mention:
    /// a modern build's help text says "DEPRECATED in favor of `--load-mode`"
    /// on the old flags, so `mentions("--load-mode")` is true on a build that
    /// would reject `--load-mode` as an argument. The definition line is the
    /// one that carries a value placeholder.
    private static func loadModeStyle(in lines: [String]) -> LoadModeStyle {
        let definesLoadMode = lines.contains { line in
            guard line.contains("--load-mode") || line.hasPrefix("-lm,") else { return false }
            return line.contains("MODE") || line.contains("<") || line.contains("[")
        }
        if definesLoadMode { return .explicitValue }

        let legacy = lines.contains { line in
            let head = line.prefix(24)
            return head.contains("--mlock") || head.contains("--mmap") || head.contains("--no-mmap")
        }
        return legacy ? .legacy : .unsupported
    }

    /// Rewrite a plan's arguments to match what this binary accepts.
    ///
    /// Only the flags whose spelling actually varies are touched; everything
    /// else is passed through unchanged.
    public func adapt(_ arguments: [LlamaArgument]) -> [LlamaArgument] {
        var out: [LlamaArgument] = []

        for argument in arguments {
            switch argument.flag {
            case "-fa", "--flash-attn":
                guard supportsFlashAttention else { continue }
                switch flashAttentionStyle {
                case .bareFlag:
                    out.append(argument)
                case .explicitValue:
                    out.append(LlamaArgument(
                        flag: "--flash-attn",
                        value: "on",
                        reason: argument.reason,
                        category: argument.category
                    ))
                }

            case "--cache-type-k", "--cache-type-v":
                guard supportsCacheType else { continue }
                out.append(argument)

            case "--parallel":
                guard supportsParallel else { continue }
                out.append(argument)

            // Older llama.cpp builds have no notion of shifting the cache, and
            // passing the flag to one is a startup error rather than a warning.
            case "--context-shift", "-cs":
                guard supportsContextShift else { continue }
                out.append(argument)

            case "--jinja":
                guard supportsJinja else { continue }
                out.append(argument)

            // The planner always emits the modern spelling. Translating here
            // rather than in the planner keeps the version knowledge in one
            // place, and means a plan stays readable as "what we want" instead
            // of "what some particular build happens to accept".
            case "-lm", "--load-mode":
                guard supportsMmap else { continue }
                switch loadModeStyle {
                case .explicitValue:
                    out.append(argument)
                case .unsupported:
                    continue
                case .legacy:
                    guard let legacy = Self.legacyArguments(forLoadMode: argument.value) else {
                        continue
                    }
                    out.append(contentsOf: legacy)
                }

            default:
                out.append(argument)
            }
        }

        return out
    }

    /// Map a `--load-mode` value onto the pre-`--load-mode` flag set.
    ///
    /// Returns `nil` when the value has no legacy equivalent that is worth
    /// emitting — notably plain `mmap`, which is the default in every build and
    /// therefore needs no flag at all.
    static func legacyArguments(forLoadMode mode: String?) -> [LlamaArgument]? {
        switch mode?.lowercased() {
        case "mlock":
            return [LlamaArgument(flag: "--mlock", value: nil,
                                  reason: "keep the weights resident in RAM",
                                  category: .performance)]
        case "none":
            return [LlamaArgument(flag: "--no-mmap", value: nil,
                                  reason: "read the weights instead of mapping them",
                                  category: .performance)]
        case "mmap+mlock":
            return [
                LlamaArgument(flag: "--mlock", value: nil,
                              reason: "keep the weights resident in RAM",
                              category: .performance),
                LlamaArgument(flag: "--mmap", value: nil,
                              reason: "map the weights and keep them resident",
                              category: .performance),
            ]
        case "dio":
            return [LlamaArgument(flag: "--direct-io", value: nil,
                                  reason: "bypass the page cache when reading weights",
                                  category: .performance)]
        default:
            return nil
        }
    }
}

/// Carries both pipe reads back from a background queue.
///
/// A tuple captured by an escaping closure is not safe to mutate from another
/// thread, and `readDataToEndOfFile()` has to happen off the caller's thread.
private final class PipeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func set(_ out: Data, _ err: Data) {
        lock.lock()
        stdout = out
        stderr = err
        lock.unlock()
    }

    func get() -> (Data, Data) {
        lock.lock()
        defer { lock.unlock() }
        return (stdout, stderr)
    }
}
