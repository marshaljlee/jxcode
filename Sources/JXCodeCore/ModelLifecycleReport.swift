import Foundation

// MARK: - Rendering the model lifecycle as text
//
// In the core for the same reason `ModelReport` is: `jxcode local` prints this
// and the Models pane shows the same facts, and one renderer is what stops the
// terminal and the window disagreeing about what a name means.
//
// The rule every function here follows is the one `SandboxConfiguration`'s pane
// already follows: **show the effective value, not the form.** An alias with no
// idle timeout of its own is not "no timeout" — it inherits the profile's, and
// the difference decides whether a 16 GB model survives a coffee break. So the
// number printed is the one that will actually be used, with the reason it won
// attached to it.
//
// The same rule applied to the file: an alias whose model has been moved,
// renamed or deleted is still a perfectly valid row, and the only place that
// failure is visible before a request fails minutes later is here.

public enum ModelLifecycleReport {

    // MARK: Profiles and aliases

    /// The active profile, its aliases, and the other profiles that exist.
    public static func profiles(_ store: ModelLifecycleStore) -> String {
        var lines: [String] = []
        let profile = store.activeProfile

        lines.append("profile  \(profile.name)")
        lines.append("  \(idleLine(profile.idleTimeout, origin: "the profile"))")
        lines.append("")

        if profile.aliases.isEmpty {
            lines.append("  no aliases bound.")
            lines.append("")
            lines.append("  An alias is the stable name an agent's config holds, so binding one")
            lines.append("  is what lets the file behind it move without a rewrite:")
            lines.append("    jxcode local alias coder ~/Models/Qwen3.5-27B-Q4_K_M.gguf")
        } else {
            let width = profile.aliases.map(\.name.count).max() ?? 0
            for alias in profile.aliases {
                lines.append("  \(ModelReport.pad(alias.name, to: max(width, 5) + 2))"
                    + "\(alias.modelPath)")
                lines.append("  \(String(repeating: " ", count: max(width, 5) + 2))"
                    + "\(idleLine(effectiveIdle(alias, in: profile), origin: idleOrigin(alias)))"
                    + "  ·  \(fileState(alias))")
            }
        }

        let others = store.knownProfileNames.filter { $0 != profile.name }
        if !others.isEmpty {
            lines.append("")
            lines.append("other profiles  \(others.joined(separator: ", "))")
            lines.append("  switching re-points every alias at once, without writing an agent's config")
        }

        lines.append("")
        lines.append("state file  \(store.file.path)")
        return lines.joined(separator: "\n")
    }

    /// The idle timeout an alias will actually be unloaded on.
    ///
    /// Extracted rather than inlined at the print site because the supervisor
    /// makes the same choice in `launch(_:)` and the two must agree — a report
    /// that says 900s while the supervisor uses 60 is worse than no report.
    public static func effectiveIdle(_ alias: ModelAlias, in profile: ModelProfile) -> TimeInterval {
        alias.idleTimeout ?? profile.idleTimeout
    }

    public static func idleOrigin(_ alias: ModelAlias) -> String {
        alias.idleTimeout == nil ? "the profile" : "this alias"
    }

    /// `0` means keep it loaded; saying "0s" would read as "unload immediately",
    /// which is the opposite of what it does. That flag's own vocabulary is the
    /// trap, and this is the one place it is spelled out.
    public static func idleLine(_ seconds: TimeInterval, origin: String) -> String {
        guard seconds > 0 else {
            return "idle timeout  none — kept loaded until stopped by hand (from \(origin))"
        }
        return "idle timeout  \(RunningModel.duration(seconds)) (from \(origin))"
    }

    /// Whether the file an alias names is still there.
    ///
    /// Reported, not refused. An alias to a model on an unmounted external drive
    /// is a normal state to be in, and the honest thing is to say so on the row
    /// rather than to reject the whole table.
    static func fileState(_ alias: ModelAlias) -> String {
        let path = (alias.modelPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            return "missing — no file at that path"
        }
        return "on disk"
    }

    // MARK: What is loaded

    public static func running(_ models: [RunningModel], now: Date = Date()) -> String {
        guard !models.isEmpty else {
            return "No local model is loaded.\n"
                + "\n"
                + "  Nothing loads until a request needs it — the first agent to ask for an\n"
                + "  alias starts its model, and the idle timeout stops it again."
        }

        var lines: [String] = []
        lines.append("\(models.count) model\(models.count == 1 ? "" : "s") loaded")
        lines.append("")

        let width = models.map(\.alias.count).max() ?? 0
        for model in models {
            lines.append("  \(ModelReport.pad(model.alias, to: max(width, 5) + 2))"
                + "\(model.filename)")
            lines.append("  \(String(repeating: " ", count: max(width, 5) + 2))"
                + model.summary(now: now))
            lines.append("  \(String(repeating: " ", count: max(width, 5) + 2))"
                + model.baseURL)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: One server's own account of itself

    public static func health(_ alias: String, _ health: ServerHealth) -> String {
        let mark = health.isHealthy ? "✓" : "✗"
        return "[\(mark)] \(alias)  \(health.description)"
    }

    public static func metrics(_ alias: String, _ report: ServerMetricsReport) -> String {
        guard let metrics = report.metrics else {
            return "[ ] \(alias)  no metrics: \(report.problem ?? "the server said nothing")"
        }

        var lines: [String] = []
        lines.append("\(alias)  prometheus")
        lines.append("")

        // Only the counters this build was observed to report. A metric that is
        // absent is named as absent rather than printed as 0: "0 requests" and
        // "this build does not count requests" are different facts, and only one
        // of them is a reason to go and look at the server.
        let rows: [(String, Double?, String)] = [
            ("prompt tokens",   metrics.promptTokens, "total since the server started"),
            ("predicted",       metrics.predictedTokens, "tokens generated"),
            ("prompt tok/s",    metrics.promptTokensPerSecond, "prompt evaluation rate"),
            ("predicted tok/s", metrics.predictedTokensPerSecond, "generation rate"),
            ("processing",      metrics.requestsProcessing, "in flight right now"),
            ("deferred",        metrics.requestsDeferred, "queued behind another request"),
            ("decodes",         metrics.decodes, "decode steps"),
        ]
        for (label, value, reason) in rows {
            let shown = value.map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.2f", $0) }
            lines.append("  \(ModelReport.pad(label, to: 18))"
                + "\(ModelReport.pad(shown ?? "not reported", to: 14))\(reason)")
        }

        lines.append("")
        lines.append("  busy  \(metrics.isBusy ? "yes — the idle sweep will not unload it" : "no")")
        return lines.joined(separator: "\n")
    }

    // MARK: Servers this process did not start

    /// One `llama-server` found on the machine, with whatever could be read off
    /// its command line.
    public struct ForeignServer: Sendable, Equatable {
        public var pid: Int32
        public var port: Int?
        /// The file it was told to load, when the command line names one.
        public var modelPath: String?
        /// The alias that points at that file in the active profile, if any.
        public var alias: String?
        /// Which of the two ways this server could be serving. Carried rather
        /// than derived at the print site, because "the command line names no
        /// model" has exactly one meaning for a `llama-server` — it is in its
        /// own router mode — and a reader who is told only that will read it as
        /// "we could not tell".
        public var mode: ModelServingMode

        public init(
            pid: Int32,
            port: Int?,
            modelPath: String?,
            alias: String?,
            mode: ModelServingMode
        ) {
            self.pid = pid
            self.port = port
            self.modelPath = modelPath
            self.alias = alias
            self.mode = mode
        }

        public var baseURL: String? { port.map { "http://127.0.0.1:\($0)" } }
    }

    /// Read a port and a model out of a `llama-server` command line.
    ///
    /// Pure, and separate from the lookup, because the input is another
    /// program's argv and that is the part worth pinning with a test. Two
    /// details that are easy to get wrong:
    ///
    ///   - the model is taken from `-m` / `--model` when it is there, and only
    ///     then from the first `.gguf` token. A path can contain spaces, and
    ///     `pgrep -fl` joins argv with single spaces, so a naive split cannot
    ///     reconstruct it — but the flag position at least identifies which
    ///     token *begins* the path rather than picking up a projector.
    ///   - `--port=8080` and `--port 8080` are both accepted. llama-server
    ///     accepts both, so a parser that handles one reports "no port" for a
    ///     server that is plainly listening on one.
    public static func parseServerCommandLine(_ command: String) -> (port: Int?, modelPath: String?) {
        let tokens = command.split(separator: " ").map(String.init)

        var port: Int?
        var modelPath: String?

        for (index, token) in tokens.enumerated() {
            if token.hasPrefix("--port=") {
                port = Int(token.dropFirst("--port=".count))
            } else if token == "--port", index + 1 < tokens.count {
                port = Int(tokens[index + 1])
            }

            if modelPath == nil, token == "-m" || token == "--model", index + 1 < tokens.count {
                modelPath = tokens[index + 1]
            }
        }

        if modelPath == nil {
            modelPath = tokens.first { $0.lowercased().hasSuffix(".gguf") }
        }
        return (port, modelPath)
    }

    /// Match servers found on the machine against the alias table.
    public static func runningElsewhere(
        _ entries: [RunningServers.Entry],
        store: ModelLifecycleStore
    ) -> [ForeignServer] {
        let aliases = store.activeProfile.aliases

        return entries.map { entry in
            let parsed = parseServerCommandLine(entry.command)
            let match = parsed.modelPath.flatMap { path in
                aliases.first {
                    URL(fileURLWithPath: $0.modelPath).standardizedFileURL.path
                        == URL(fileURLWithPath: path).standardizedFileURL.path
                }
            }
            // A `llama-server` with no model on its command line is not a server
            // whose argv could not be read — it is a server in its own router
            // mode, which is what the binary does when no model is named. That is
            // measured (see `ModelServingPolicy`), so the two cases are told
            // apart here rather than merged into "no model found".
            return ForeignServer(
                pid: entry.pid,
                port: parsed.port,
                modelPath: parsed.modelPath,
                alias: match?.name,
                mode: parsed.modelPath.map(ModelServingMode.oneModel(path:)) ?? .router
            )
        }
    }

    /// What is running that this process did not start.
    ///
    /// The counterpart to `running(_:)`, and the reason both exist: a
    /// supervisor's registry lives in the process that made it, so a freshly
    /// started `jxcode local` knows about nothing at all. Reporting its own
    /// empty table as "nothing is loaded" would be a confident wrong answer to
    /// the one question the command was asked.
    public static func foreignServers(_ servers: [ForeignServer]) -> String {
        guard !servers.isEmpty else {
            return "No llama-server is running on this machine."
        }

        var lines: [String] = []
        lines.append("\(servers.count) llama-server process\(servers.count == 1 ? "" : "es") "
            + "running on this machine")
        lines.append("")

        for server in servers {
            let name = server.alias.map { "\($0)  →  " } ?? ""
            switch server.mode {
            case .router:
                // Said plainly. "No model on the command line" reads as a gap in
                // the reading; this is a fact about the server, and the one fact
                // that explains why its models are nowhere in the alias table.
                lines.append("  \(name)router mode — no model named, a model is chosen per request")
            case .oneModel(let path):
                lines.append("  \(name)\(path)")
            case .malformed:
                lines.append("  \(name)-m is present and names nothing, so this server cannot start")
            }

            lines.append("    pid \(server.pid)"
                + (server.baseURL.map { "  ·  \($0)" } ?? "  ·  no --port on the command line"))

            if server.mode.isRouter {
                lines.append("    jxcode does not start servers in router mode, so nothing here "
                    + "is in the alias table")
            } else if server.alias == nil, server.modelPath != nil {
                // Not an error: a server started by `jxcode serve`, by llama.app
                // or by hand is a normal thing to find. Named so the row is not
                // read as a broken alias.
                lines.append("    not bound to an alias in the active profile")
            }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Logs

    /// The four streams, and which of them is per-model.
    ///
    /// `model` without an alias is a caller mistake and is reported as one. It
    /// is the only stream that cannot answer without a name, and silently
    /// falling back to a shared file would answer a per-model question with
    /// every model's output.
    public static func logStreams(_ paths: SandboxPaths, alias: String? = nil) -> String {
        var lines: [String] = []
        let logs = ModelLogs(paths: paths)

        lines.append("four streams, split the way llama-swap splits them")
        lines.append("")
        for stream in ModelLogStream.allCases {
            let needsAlias = stream.isPerModel && (alias?.isEmpty ?? true)
            let location = needsAlias
                ? "needs an alias — this one is per model"
                : (logs.fileURL(stream, alias: alias).map { paths.display($0) } ?? "—")
            lines.append("  \(ModelReport.pad(stream.title, to: 10))\(ModelReport.pad(location, to: 34))")
            lines.append("  \(String(repeating: " ", count: 10))\(stream.purpose)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: How many models one server may serve

    /// The one-router decision, with this machine's own facts attached.
    ///
    /// Rendered in the core because `jxcode local policy` prints it and the
    /// Models pane shows the same text — the rule this file exists to keep, so
    /// the terminal and the window cannot disagree about a decision.
    ///
    /// Three things it says that a written-down policy cannot: whether the binary
    /// on this machine even has the feature, which of its flags configure it, and
    /// whether the rule is being broken right now by a server somebody else
    /// started.
    public static func servingPolicy(
        _ store: ModelLifecycleStore,
        capabilities: LlamaServerCapabilities,
        foreignServers: [ForeignServer] = []
    ) -> String {
        var lines: [String] = []

        lines.append(contentsOf: ModelServingPolicy.decision.split(separator: "\n").map(String.init))
        lines.append("")

        // Whether the feature exists is a fact about the binary, so it is read
        // from the binary. `defines` answers "yes" to everything when the help
        // text is empty — right for planning against an assumed build, and a
        // false claim in a report — so an unprobed binary is named as unprobed
        // rather than reported as capable.
        lines.append("this machine's llama-server")
        if capabilities.helpText.isEmpty {
            lines.append("  no binary was found, so nothing is known about its flags yet.")
            lines.append("  `jxcode runtime` shows where it was looked for.")
        } else {
            for flag in ModelServingPolicy.routerConfigurationFlags {
                let present = capabilities.defines(flag) ? "defined" : "not in this build"
                lines.append("  \(ModelReport.pad(flag, to: 20))"
                    + "\(ModelReport.pad(present, to: 18))"
                    + ModelServingPolicy.role(of: flag))
            }
        }
        lines.append("")

        lines.append("what jxcode does instead")
        let profile = store.activeProfile
        let aliases = profile.aliases
        if aliases.isEmpty {
            lines.append("  no aliases are bound in profile '\(profile.name)', so nothing is")
            lines.append("  reachable by name yet:")
            lines.append("    jxcode local alias coder ~/Models/Qwen3.5-27B-Q4_K_M.gguf")
        } else {
            lines.append("  \(aliases.count) alias\(aliases.count == 1 ? "" : "es") in profile "
                + "'\(profile.name)':")
            lines.append("    \(aliases.map(\.name).joined(separator: ", "))")
            lines.append("  One server per alias, started by the first request that names it.")
        }
        lines.append("")

        // The question a user actually has. Answering it with the rule alone
        // would leave them to work out that "two models at once" is what the
        // alias table already does — which is the whole reason the rule is not
        // a limitation.
        lines.append("to serve two models at once")
        lines.append("  bind both and let the requests start them:")
        lines.append("    jxcode local alias coder ~/Models/coder.gguf")
        lines.append("    jxcode local alias writer ~/Models/writer.gguf")
        lines.append("  Each gets its own port and its own idle timer, and the router sends")
        lines.append("  a request to whichever alias that request names.")

        if !foreignServers.isEmpty {
            let routers = foreignServers.filter(\.mode.isRouter)
            lines.append("")
            if routers.isEmpty {
                lines.append("\(foreignServers.count) llama-server process"
                    + "\(foreignServers.count == 1 ? "" : "es") found on this machine, none of "
                    + "them in router mode.")
            } else {
                lines.append("\(routers.count) llama-server process"
                    + "\(routers.count == 1 ? "" : "es") on this machine "
                    + "\(routers.count == 1 ? "is" : "are") in router mode:")
                for server in routers {
                    lines.append("  pid \(server.pid)"
                        + (server.baseURL.map { "  ·  \($0)" } ?? ""))
                }
                lines.append("  jxcode did not start them, and their models are not in the alias table.")
            }
        }

        return lines.joined(separator: "\n")
    }
}
