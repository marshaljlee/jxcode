import Foundation

// MARK: - The toolchain every npm-based agent needs, and did not have
//
// Every built-in agent except the shell installs through npm:
//
//     npm i -g @anthropic-ai/claude-code
//     npm i -g @openai/codex
//     npm i -g @google/gemini-cli
//     npm i -g opencode-ai
//     npm i -g @oh-my-pi/pi-coding-agent
//     npm i -g @google/jules
//
// And `npm` is not on the sandbox `PATH`. That is not an oversight — it is the
// isolation model. `SandboxEnvironment.buildPath()` deliberately rebuilds
// `PATH` without `/opt/homebrew/bin` or `/usr/local/bin`, and `ShellInit`
// re-asserts it on every login shell, precisely so a host-wide tool cannot be
// reached. On macOS `node` and `npm` live in one of those two directories, so
// inside the sandbox the install command died with:
//
//     zsh:1: command not found: npm        (exit 127)
//
// which is why installing an agent always failed. The failure was total, not
// intermittent: nothing about it depended on the network, the package, or the
// agent. Nothing in the app provided a JavaScript runtime, and
// `SandboxPaths.bin` — documented since the beginning as "PATH[0], JXCode shims
// are written here" — had nothing in it.
//
// ## Why a shim rather than a copy
//
// `LlamaRuntimeInstaller` solves the neighbouring problem by *adopting* a host
// binary: walk the Mach-O dependency closure, rewrite every recorded library
// path, re-sign, then prove the copy launches. Node is a far worse candidate
// for that than `llama-server`:
//
//   - The Homebrew build is a 52 KB launcher over roughly two dozen dylibs
//     spread across `llvm`, `libuv`, `nghttp2`, `brotli`, `c-ares`, `sqlite`
//     and more.
//   - `npm` is not a binary at all. It is 17 MB of JavaScript whose entry point
//     is a `.js` file that needs a Node to run, so adopting the runtime does not
//     even finish the job.
//
// A copy would therefore mean tens of megabytes duplicated into every sandbox,
// with a new class of breakage, to own a runtime the app does not otherwise
// care about.
//
// ## What the shim keeps, and what it gives up
//
// Kept: the part the app actually promises. `npm_config_prefix`, `HOME`,
// `TMPDIR`, `npm_config_cache` and `npm_config_userconfig` all point inside the
// sandbox, so `npm i -g` writes the package to `env/npm/lib/node_modules` and
// the launcher to `env/npm/bin`. The agent binary is then found by the sandbox
// `PATH`, and a host-wide `claude` is still unreachable.
//
// Given up: the runtime. The `node` that executes is the host's. This is worth
// stating plainly rather than hiding behind the word "install" — a shim is a
// seam in the isolation, and the doctor reports it as one.
//
// ## When there is no Node at all
//
// Then the install cannot work, and the honest answer is to say so with the
// list of places that were searched, rather than to fail with `command not
// found` from inside a terminal the user has to interpret.
public enum NodeToolchain {

    /// A runtime found on the host, ready to be shimmed into the sandbox.
    public struct Candidate: Sendable, Equatable {
        public let node: URL
        public let npmCLI: URL?
        public let npxCLI: URL?
    }

    /// A toolchain already shimmed into a sandbox.
    public struct Located: Sendable, Equatable {
        public let node: URL
        public let npmCLI: URL?
        public let npxCLI: URL?
    }

    public enum ToolchainError: Error, CustomStringConvertible {
        case nodeNotFound(searched: [String])
        case npmNotFound(node: URL)
        case shimNotWritten(URL, String)

        public var description: String {
            switch self {
            case .nodeNotFound(let searched):
                return "No Node.js runtime was found on this machine, and every agent except the "
                    + "shell installs through npm. Install Node (for example `brew install node`) "
                    + "and try again. Looked in:\n"
                    + searched.map { "  " + $0 }.joined(separator: "\n")
            case .npmNotFound(let node):
                return "Found \(node.path) but no npm beside it, so packages cannot be installed. "
                    + "A Node install without npm is unusual — check that the toolchain is complete."
            case .shimNotWritten(let url, let reason):
                return "The sandbox toolchain shim could not be written at \(url.path): \(reason)"
            }
        }
    }

    /// Written into the header of every shim this type generates.
    ///
    /// It is how the app tells its own file apart from a real `node` a user has
    /// installed inside the sandbox, and it is also what makes the shim
    /// self-describing: the target paths are recorded as comments, so a later
    /// run can answer "is this still valid?" without executing anything.
    public static let marker = "JXCode sandbox shim"

    /// The commands the shims stand in for. `npm` and `npx` are front-ends to
    /// scripts in npm's own package, so all three resolve to the same Node.
    public static let shimNames = ["node", "npm", "npx"]

    // MARK: - Finding a runtime

    /// Where to look for a Node, in priority order.
    ///
    /// A fixed directory list rather than a probe of `PATH`, because the GUI
    /// app inherits launchd's `PATH` — typically `/usr/bin:/bin:/usr/sbin:/sbin`
    /// — which is not the `PATH` the user's terminal has, and never contains
    /// Homebrew. Probing it would find nothing on most machines while a perfectly
    /// good Node sat in `/opt/homebrew/bin`.
    public static func hostSearchDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> [URL] {
        var directories: [String] = []

        // An explicit answer beats every guess below it.
        if let explicit = environment["JXCODE_NODE"], !explicit.isEmpty {
            directories.append((explicit as NSString).expandingTildeInPath)
        }

        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/opt/homebrew/opt/node/bin",
            "/usr/local/bin",
            "/opt/local/bin",
            "/usr/bin",
        ])

        // Version managers. A developer machine often has Node *only* here, and
        // none of these are inside a Homebrew prefix, so a list that stopped at
        // `/opt/homebrew/bin` would report "no Node found" on a machine with
        // three of them.
        directories.append(contentsOf: versionManagedDirectories(home: home))

        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }.map { URL(fileURLWithPath: $0) }
    }

    /// `~/.nvm/versions/node/<version>/bin` and friends, newest first.
    static func versionManagedDirectories(home: String) -> [String] {
        var directories: [String] = []

        let nvm = URL(fileURLWithPath: home).appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(
            at: nvm, includingPropertiesForKeys: nil
        ) {
            // Lexical descending is not true semantic ordering, but every scheme
            // in use sorts correctly this way for the major versions that matter
            // (`v20` < `v22` < `v9` is the one case it gets wrong, and a v9 Node
            // has not been a plausible default for years).
            directories.append(contentsOf: versions
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin").path })
        }

        for relative in [
            ".volta/bin",
            ".fnm/aliases/default/bin",
            ".asdf/shims",
            "Library/pnpm",
            ".local/share/fnm/aliases/default/bin",
        ] {
            directories.append(URL(fileURLWithPath: home).appendingPathComponent(relative).path)
        }

        return directories
    }

    /// The first directory that holds a runnable `node`, with npm beside it.
    ///
    /// Pure filesystem inspection — nothing is executed here, so this is cheap
    /// enough for the doctor to call.
    public static func discover(in directories: [URL]) -> Candidate? {
        for directory in directories {
            let node = directory.appendingPathComponent("node")
            guard FileManager.default.isExecutableFile(atPath: node.path) else { continue }
            return Candidate(
                node: node.resolvingSymlinksInPath(),
                npmCLI: cliScript(named: "npm", in: directory),
                npxCLI: cliScript(named: "npx", in: directory)
            )
        }
        return nil
    }

    /// Where a `bin/npm` launcher actually points.
    ///
    /// Homebrew ships `bin/npm` as a symlink straight to npm's JS entry point,
    /// so following it *is* the answer. Other installs keep a shell script next
    /// to a `lib/node_modules`, which is the fallback.
    static func cliScript(named name: String, in directory: URL) -> URL? {
        let launcher = directory.appendingPathComponent(name)
        guard FileManager.default.isExecutableFile(atPath: launcher.path) else { return nil }

        let resolved = launcher.resolvingSymlinksInPath()
        if resolved.pathExtension == "js" { return resolved }

        let sibling = directory
            .deletingLastPathComponent()
            .appendingPathComponent("lib/node_modules/npm/bin/\(name)-cli.js")
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
    }

    // MARK: - Shims

    /// Whether `url` is a file this type wrote, rather than a real binary.
    public static func isShim(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.prefix(600).contains(marker)
    }

    /// The shims already present in a sandbox, if their targets still exist.
    ///
    /// Reads the metadata the shims carry rather than re-running a probe, so
    /// this is a single file read. `Sandbox.prepare()` calls it on every tab
    /// launch and must not shell out.
    public static func installed(paths: SandboxPaths) -> Located? {
        let nodeShim = paths.bin.appendingPathComponent("node")
        guard let metadata = readShimMetadata(nodeShim) else { return nil }

        let node = URL(fileURLWithPath: metadata["node"] ?? "")
        guard !node.path.isEmpty, FileManager.default.isExecutableFile(atPath: node.path) else {
            // The borrowed runtime has been uninstalled or upgraded away.
            return nil
        }

        func existing(_ key: String) -> URL? {
            guard let path = metadata[key], !path.isEmpty else { return nil }
            return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }

        return Located(node: node, npmCLI: existing("npm"), npxCLI: existing("npx"))
    }

    /// Parses the `# key: value` header lines a shim records.
    static func readShimMetadata(_ url: URL) -> [String: String]? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        guard text.prefix(600).contains(marker) else { return nil }

        var metadata: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("# "), let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.index(line.startIndex, offsetBy: 2)..<colon]
                .trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty { metadata[key] = value }
        }
        return metadata
    }

    /// Write `node`, `npm` and `npx` into `PATH[0]`.
    ///
    /// Throws rather than reporting success on a partial write: a `node` shim
    /// without an `npm` shim is a sandbox that looks installed and cannot
    /// install anything.
    @discardableResult
    public static func installShims(paths: SandboxPaths, candidate: Candidate) throws -> [URL] {
        try paths.createDirectories()

        var written: [URL] = []
        for name in shimNames {
            let url = paths.bin.appendingPathComponent(name)
            let contents = shim(name: name, candidate: candidate)
            do {
                try contents.write(to: url, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: url.path
                )
            } catch {
                // Do not leave half a toolchain behind: a partial set would be
                // picked up as valid by `installed(paths:)` on the next launch.
                for already in written { try? FileManager.default.removeItem(at: already) }
                throw ToolchainError.shimNotWritten(url, "\(error)")
            }
            written.append(url)
        }
        return written
    }

    /// The script itself.
    ///
    /// `exec` rather than a wrapper process, so signals and the exit status
    /// belong to Node and nothing sits between the sandbox and the runtime.
    /// The environment is inherited untouched — that is the mechanism: the
    /// sandbox's `npm_config_prefix` is what keeps a global install inside.
    static func shim(name: String, candidate: Candidate) -> String {
        let target: [String]
        switch name {
        case "npm":
            target = candidate.npmCLI.map { [candidate.node.path, $0.path] } ?? [candidate.node.path]
        case "npx":
            target = candidate.npxCLI.map { [candidate.node.path, $0.path] } ?? [candidate.node.path]
        default:
            target = [candidate.node.path]
        }

        return """
        #!/bin/sh
        # \(marker) — GENERATED FILE. Rewritten whenever the sandbox is prepared.
        #
        # `\(name)` is borrowed from the host because the sandbox PATH excludes
        # the directories Node installs into. What is NOT borrowed is where the
        # install lands: HOME, npm_config_prefix and npm_config_cache are the
        # sandbox's, so `npm i -g` writes inside it.
        #
        # node: \(candidate.node.path)
        # npm: \(candidate.npmCLI?.path ?? "")
        # npx: \(candidate.npxCLI?.path ?? "")
        exec \(target.map(shellQuoted).joined(separator: " ")) "$@"
        """
    }

    /// Single-quote for `/bin/sh`, closing and reopening the quote so an
    /// embedded apostrophe cannot terminate it. (A path under `Application
    /// Support` is one space away from needing this.)
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - The one call the app makes

    /// Make sure the sandbox can run npm, or explain precisely why it cannot.
    ///
    /// Fast when it has already been done: the shims record their targets, so a
    /// valid existing set is returned without starting a process.
    ///
    /// `directories` exists so the "no Node anywhere" answer can be tested —
    /// on a machine that has one, there is otherwise no way to reach that branch.
    public static func ensure(
        paths: SandboxPaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        directories: [URL]? = nil
    ) -> Result<Located, ToolchainError> {
        if let existing = installed(paths: paths) { return .success(existing) }

        let search = directories ?? hostSearchDirectories(environment: environment, home: home)
        guard let candidate = discover(in: search) else {
            return .failure(.nodeNotFound(searched: search.map { $0.path }))
        }
        guard candidate.npmCLI != nil else {
            return .failure(.npmNotFound(node: candidate.node))
        }

        do {
            try installShims(paths: paths, candidate: candidate)
        } catch let error as ToolchainError {
            return .failure(error)
        } catch {
            return .failure(.shimNotWritten(paths.bin, "\(error)"))
        }

        return .success(Located(
            node: candidate.node,
            npmCLI: candidate.npmCLI,
            npxCLI: candidate.npxCLI
        ))
    }

    /// Best-effort variant for `Sandbox.prepare()`.
    ///
    /// Preparing the sandbox must not fail because a machine has no Node — the
    /// app works fine without one until the first install. But when it *is*
    /// available, having the shims in place means a shell tab opened by hand can
    /// run `npm`, which is what the `PATH[0]` directory was always for.
    @discardableResult
    public static func ensureBestEffort(
        paths: SandboxPaths,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> Located? {
        try? ensure(paths: paths, environment: environment, home: home).get()
    }
}
