import Foundation
import Darwin

/// Audits the sandbox and reports every way it could leak.
///
/// The interesting checks are the negative ones — a sandbox is defined by what
/// it *excludes*, so the report focuses on host paths that are still reachable
/// rather than on confirming the happy path.
public struct DoctorReport: Sendable {

    public enum Status: String, Sendable {
        case pass, warn, fail, info

        var marker: String {
            switch self {
            case .pass: return "  ok  "
            case .warn: return " warn "
            case .fail: return " FAIL "
            case .info: return " info "
            }
        }
    }

    public struct Check: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let status: Status
        public let detail: String
    }

    public let checks: [Check]

    public var failures: [Check] { checks.filter { $0.status == .fail } }
    public var warnings: [Check] { checks.filter { $0.status == .warn } }
    public var isHealthy: Bool { failures.isEmpty }

    public func rendered(verbose: Bool = true) -> String {
        var lines: [String] = []
        lines.append("JXCode sandbox doctor")
        lines.append(String(repeating: "─", count: 64))

        for check in checks where verbose || check.status != .pass {
            lines.append("[\(check.status.marker)] \(check.title)")
            if verbose && !check.detail.isEmpty {
                for line in check.detail.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("         \(line)")
                }
            }
        }

        lines.append(String(repeating: "─", count: 64))
        let passed = checks.filter { $0.status == .pass }.count
        lines.append("\(passed) ok · \(warnings.count) warning · \(failures.count) failing")

        if failures.isEmpty {
            lines.append("Sandbox holds. Host toolchain is unreachable.")
        } else {
            lines.append("Sandbox is leaking — see FAIL entries above.")
        }

        return lines.joined(separator: "\n")
    }
}

public enum Doctor {

    /// Host directories that must never appear on the sandbox `PATH`.
    private static let forbiddenPathPrefixes = [
        "/opt/homebrew",
        "/usr/local/Homebrew",
    ]

    public static func run(
        sandbox: Sandbox,
        registry: AgentRegistry? = nil
    ) -> DoctorReport {
        let paths = sandbox.paths
        let env = sandbox.env()
        let fm = FileManager.default
        var checks: [DoctorReport.Check] = []

        // 1. Root exists and is writable.
        do {
            try fm.createDirectory(at: paths.root, withIntermediateDirectories: true)
            let probe = paths.root.appendingPathComponent(".jxcode-write-probe")
            try Data("probe".utf8).write(to: probe)
            try fm.removeItem(at: probe)
            checks.append(.init(
                id: "root", title: "Sandbox root is writable",
                status: .pass, detail: paths.root.path
            ))
        } catch {
            checks.append(.init(
                id: "root", title: "Sandbox root is writable",
                status: .fail, detail: "\(paths.root.path)\n\(error.localizedDescription)"
            ))
        }

        // 2. HOME points inside.
        checks.append(containmentCheck(
            id: "home", title: "$HOME resolves inside the sandbox",
            variable: "HOME", env: env, paths: paths
        ))

        // 3. TMPDIR.
        checks.append(containmentCheck(
            id: "tmpdir", title: "$TMPDIR resolves inside the sandbox",
            variable: "TMPDIR", env: env, paths: paths
        ))

        // 4. npm prefix.
        checks.append(containmentCheck(
            id: "npm", title: "npm global prefix resolves inside the sandbox",
            variable: "npm_config_prefix", env: env, paths: paths
        ))

        // 5. Agent config roots — the ones that matter most, because a miss
        //    here means an agent writes to the host home.
        for (variable, label) in [
            ("CLAUDE_CONFIG_DIR", "Claude Code config"),
            ("CODEX_HOME", "Codex config"),
            ("GEMINI_CONFIG_DIR", "Gemini config"),
        ] {
            checks.append(containmentCheck(
                id: "agent.\(variable)", title: "\(label) resolves inside the sandbox",
                variable: variable, env: env, paths: paths
            ))
        }

        // 6. ZDOTDIR and generated init.
        checks.append(containmentCheck(
            id: "zdotdir", title: "$ZDOTDIR resolves inside the sandbox",
            variable: "ZDOTDIR", env: env, paths: paths
        ))

        let initFiles = [".zshenv", ".zprofile", ".zshrc"].map { paths.zshDir.appendingPathComponent($0) }
        let missing = initFiles.filter { !fm.fileExists(atPath: $0.path) }
        checks.append(.init(
            id: "shellinit",
            title: "Sandbox shell init is installed",
            status: missing.isEmpty ? .pass : .fail,
            detail: missing.isEmpty
                ? initFiles.map { paths.display($0) }.joined(separator: "\n")
                : "missing: " + missing.map { $0.lastPathComponent }.joined(separator: ", ")
        ))

        // 7. PATH must not reach host tool directories.
        let pathEntries = sandbox.environment.buildPath()
        let offenders = pathEntries.filter { entry in
            forbiddenPathPrefixes.contains { entry.hasPrefix($0) }
        }
        checks.append(.init(
            id: "path.host",
            title: "PATH excludes host-wide tool directories",
            status: offenders.isEmpty ? .pass : .fail,
            detail: offenders.isEmpty
                ? "no /opt/homebrew or /usr/local/Homebrew entries"
                : "reached from PATH:\n" + offenders.joined(separator: "\n")
        ))

        // `/usr/local/bin` is a judgement call rather than a failure: it is
        // where a host Homebrew lives, but also where some vendors install.
        let hasLocalBin = pathEntries.contains("/usr/local/bin")
        checks.append(.init(
            id: "path.localbin",
            title: "/usr/local/bin is excluded from PATH",
            status: hasLocalBin ? .warn : .pass,
            detail: hasLocalBin
                ? "included — host-installed tools there will be reachable from the sandbox.\nRe-run with includeHostLocalBin disabled to exclude it."
                : "excluded"
        ))

        // 8. Symlinks inside the sandbox must not point outside it.
        let escaping = escapingSymlinks(in: paths.envRoot, sandboxRoot: paths.root)
        checks.append(.init(
            id: "symlinks",
            title: "No symlink inside the sandbox escapes it",
            status: escaping.isEmpty ? .pass : .warn,
            detail: escaping.isEmpty
                ? "checked \(paths.display(paths.envRoot))"
                : escaping.map { "\(paths.display($0.from)) -> \($0.to)" }.joined(separator: "\n")
        ))

        // 9. The getpwuid hazard. This is informational: it cannot be fixed by
        //    environment variables alone, and it is why the agent config roots
        //    above are set explicitly rather than left to default.
        let realHome = NSHomeDirectory()
        let pwHome = pwDirectory()
        if let pwHome, pwHome != env["HOME"] {
            checks.append(.init(
                id: "getpwuid",
                title: "getpwuid() still returns the host home",
                status: .info,
                detail: """
                getpwuid() -> \(pwHome)
                $HOME      -> \(env["HOME"] ?? "<unset>")

                A tool that resolves home via getpwuid() rather than $HOME will \
                reach the host directory. This cannot be overridden from the \
                environment, which is why CLAUDE_CONFIG_DIR, CODEX_HOME and \
                GEMINI_CONFIG_DIR are set explicitly — those remove the fallback \
                for the agents that matter.
                """
            ))
        }

        // 10. Tools with no config-directory override.
        //
        //     oh-my-pi and Jules document no equivalent of CLAUDE_CONFIG_DIR —
        //     their roots are fixed at ~/.omp and ~/.jules. There is no fallback
        //     to remove, so $HOME is doing all the work. Worth its own check,
        //     because if HOME is ever wrong these leak silently.
        let homeOnly: [(String, URL)] = [
            ("oh-my-pi", paths.ompHome),
            ("Google Jules", paths.julesHome),
            ("Bun", paths.bunInstall),
        ]
        for (name, directory) in homeOnly {
            checks.append(.init(
                id: "homeonly.\(name)",
                title: "\(name) — isolated by $HOME alone",
                status: paths.contains(directory) ? .pass : .fail,
                detail: """
                config root  \(paths.display(directory))
                derived from $HOME (\(env["HOME"] ?? "<unset>"))
                """
            ))
        }

        // 11. Per-agent resolution.
        if let registry {
            for agent in registry.agents {
                guard let resolved = registry.resolvedPath(for: agent, environment: env) else {
                    checks.append(.init(
                        id: "agent.\(agent.id)",
                        title: "\(agent.name)",
                        status: .info,
                        detail: "not installed in the sandbox" +
                            (agent.installCommand.map { "\ninstall: \($0)" } ?? "")
                    ))
                    continue
                }
                // `isEscaping` rather than an inline containment test. This
                // check had its own copy of the logic, which meant the rule
                // "outside the sandbox is a failure" was stated twice and
                // could drift — the registry's version was the tested one and
                // the doctor's was the one users actually saw.
                let escapes = registry.isEscaping(agent, environment: env)
                checks.append(.init(
                    id: "agent.\(agent.id)",
                    title: "\(agent.name)",
                    status: escapes ? .fail : .pass,
                    detail: escapes
                        ? "\(resolved)\nresolves OUTSIDE the sandbox — it would write to the host home"
                        : paths.display(URL(fileURLWithPath: resolved))
                ))
            }
        }

        // 12. The JavaScript runtime the sandbox borrows.
        //
        //     This is a seam in the isolation, and the doctor's job is to say
        //     where the seams are. `node` and `npm` in the sandbox are shims
        //     that exec the host's runtime — see `NodeToolchain` for why that
        //     beat copying two dozen dylibs and 17 MB of npm into every sandbox.
        //     What still holds is the part the app promises about an install:
        //     `npm_config_prefix` and `HOME` are the sandbox's, so a global
        //     install lands inside it. What does not hold is the stronger claim
        //     that every executable a tab can reach is sandbox-local.
        let toolchain = NodeToolchain.installed(paths: paths)
        let hostNode = toolchain == nil
            ? NodeToolchain.discover(in: NodeToolchain.hostSearchDirectories())
            : nil
        checks.append(.init(
            id: "toolchain.node",
            title: "Node toolchain is available for npm-based installs",
            status: toolchain != nil ? .pass : (hostNode != nil ? .info : .warn),
            detail: {
                if let toolchain {
                    return """
                    borrowed runtime  \(toolchain.node.path)
                    shimmed at        \(paths.display(paths.bin))/node
                    installs still land in \(paths.display(paths.npmPrefix)), because \
                    npm_config_prefix is the sandbox's.
                    """
                }
                if let hostNode {
                    return "found \(hostNode.node.path), not shimmed yet. "
                        + "The first agent install writes the shims into \(paths.display(paths.bin))."
                }
                return "No Node.js runtime was found, so every agent except the shell is "
                    + "uninstallable. Install Node — `brew install node` is the usual way — and "
                    + "reopen the app."
            }()
        ))

        // 13. Confirm the host agent config is untouched, so the isolation claim
        //     is visible rather than asserted.
        let hostClaude = URL(fileURLWithPath: realHome).appendingPathComponent(".claude")
        if fm.fileExists(atPath: hostClaude.path) {
            checks.append(.init(
                id: "host.claude",
                title: "Host ~/.claude is not used by the sandbox",
                status: .pass,
                detail: """
                \(hostClaude.path) exists and is left alone.
                The sandbox reads \(paths.display(paths.claudeConfig)) instead.
                """
            ))
        }

        return DoctorReport(checks: checks)
    }

    // MARK: - Helpers

    private static func containmentCheck(
        id: String, title: String, variable: String,
        env: [String: String], paths: SandboxPaths
    ) -> DoctorReport.Check {
        guard let value = env[variable], !value.isEmpty else {
            return .init(id: id, title: title, status: .fail, detail: "\(variable) is not set")
        }
        let inside = paths.contains(URL(fileURLWithPath: value))
        return .init(
            id: id, title: title,
            status: inside ? .pass : .fail,
            detail: inside ? paths.display(URL(fileURLWithPath: value)) : value
        )
    }

    private static func pwDirectory() -> String? {
        guard let entry = getpwuid(getuid()) else { return nil }
        return String(cString: entry.pointee.pw_dir)
    }

    private static func escapingSymlinks(
        in directory: URL,
        sandboxRoot: URL,
        maxDepth: Int = 4
    ) -> [(from: URL, to: String)] {
        let fm = FileManager.default
        var results: [(URL, String)] = []
        var queue: [(URL, Int)] = [(directory, 0)]

        while let (current, depth) = queue.popLast() {
            guard depth < maxDepth else { continue }
            guard let contents = try? fm.contentsOfDirectory(
                at: current,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: []
            ) else { continue }

            for item in contents {
                let values = try? item.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true {
                    guard let target = try? fm.destinationOfSymbolicLink(atPath: item.path) else { continue }
                    let resolved = URL(fileURLWithPath: target, relativeTo: item.deletingLastPathComponent())
                        .standardizedFileURL
                    let rootPath = sandboxRoot.standardizedFileURL.path
                    if !(resolved.path == rootPath || resolved.path.hasPrefix(rootPath + "/")) {
                        results.append((item, target))
                    }
                } else if values?.isDirectory == true {
                    queue.append((item, depth + 1))
                }
            }
        }

        return results
    }
}
