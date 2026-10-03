import Foundation

/// Writes the shared connectors into each agent's own MCP config.
///
/// There is no standard here, and this is the part of the collection where that
/// costs the most. Every agent that speaks MCP reads a different file, under a
/// different key, with a different entry shape:
///
/// | Agent | File | Key | stdio entry |
/// |---|---|---|---|
/// | Claude Code | `~/.claude.json` | `mcpServers` | `command` / `args` / `env` |
/// | Codex | `~/.codex/config.toml` | `[mcp_servers.<name>]` | `command` / `args` |
/// | Gemini CLI | `~/.gemini/settings.json` | `mcpServers` | `command` / `args` / `env` |
/// | opencode | `~/.config/opencode/opencode.json` | `mcp` | `type: local`, `command` **as an array** |
///
/// Two of those are worth calling out because they are the natural guesses and
/// both are wrong. Claude Code's MCP config is `~/.claude.json`, a *sibling* of
/// `~/.claude/` rather than a file inside it. opencode's key is `mcp`, not
/// `mcpServers`, and its `command` is an array rather than a string plus
/// separate args.
///
/// Only agents whose schema is documented get a writer. oh-my-pi, Jules and the
/// plain shell are reported as unbound rather than guessed at — a config file
/// written to the wrong shape is harder to diagnose than no config at all,
/// because the agent starts and simply has no tools.
public enum ConnectorBinder {

    /// What happened to one agent.
    public struct Report: Sendable {
        public enum Action: String, Sendable {
            case bound
            case unchanged
            case cleared
            /// This agent has no MCP config JXCode knows how to write.
            case notApplicable
            /// The file exists but is not a JSON object, so it was left alone.
            case refused
        }

        public var agentID: String
        public var agentName: String
        public var action: Action
        public var path: URL?
        public var notes: [String]

        public var summary: String {
            let location = path.map { " — \($0.path)" } ?? ""
            return "\(agentName): \(action.rawValue)\(location)"
        }
    }

    // MARK: - The manifest

    /// The record of what JXCode has written into other people's config files.
    ///
    /// Without this, removing a connector could not be done safely: the only
    /// way to know whether an entry in `mcpServers` was ours or the user's
    /// would be to guess, and guessing wrong deletes their server. The manifest
    /// is also the one canonical, agent-neutral description of the collection,
    /// which is what makes it worth writing even though every agent already has
    /// its own copy.
    public struct Manifest: Codable, Sendable {
        /// Names JXCode owns. The next write removes exactly these.
        public var managed: [String]
        /// The definitions, in the standard `mcpServers` shape.
        public var mcpServers: [String: Server]

        public init(managed: [String] = [], mcpServers: [String: Server] = [:]) {
            self.managed = managed
            self.mcpServers = mcpServers
        }

        public static let empty = Manifest()
    }

    /// One server, in the shape most agents agree on.
    public struct Server: Codable, Sendable {
        public var command: String?
        public var args: [String]?
        public var env: [String: String]?
        /// `http` for a remote endpoint; absent for stdio.
        public var type: String?
        public var url: String?
    }

    /// Read the manifest, or an empty one.
    ///
    /// A corrupt manifest yields `empty` rather than throwing. The consequence
    /// is that a previously-managed entry may be left behind in an agent's
    /// config — untidy, but strictly better than refusing to write at all, and
    /// far better than deleting entries whose ownership is unknown.
    public static func readManifest(paths: SandboxPaths) -> Manifest {
        guard let data = try? Data(contentsOf: paths.sharedMCPManifest) else { return .empty }
        let decoder = JSONDecoder()
        return (try? decoder.decode(Manifest.self, from: data)) ?? .empty
    }

    static func writeManifest(_ manifest: Manifest, paths: SandboxPaths) throws {
        try JSONText.encode(manifest).write(to: paths.sharedMCPManifest, atomically: true, encoding: .utf8)
    }

    // MARK: - Targets

    /// Where an agent reads MCP servers from, and in what shape.
    enum Target {
        case claudeJSON(URL)
        case geminiJSON(URL)
        case opencodeJSON(URL)
        case codexTOML(URL)
    }

    static func target(for agent: AgentDefinition, paths: SandboxPaths) -> Target? {
        switch agent.id {
        case "claude":   return .claudeJSON(paths.claudeMCPFile)
        case "gemini":   return .geminiJSON(paths.geminiSettings)
        case "opencode": return .opencodeJSON(paths.opencodeConfig)
        case "codex":    return .codexTOML(paths.codexMCPFile)
        default:         return nil
        }
    }

    private static func unsupportedReason(for agent: AgentDefinition) -> String {
        if agent.webURL != nil { return "runs against its own cloud service and reads no local MCP config" }
        return "this agent documents no MCP config file, so there is nowhere to register a connector"
    }

    // MARK: - Applying

    /// Write every enabled connector into every agent that can take one.
    @discardableResult
    public static func apply(
        connectors: [Connector],
        agents: [AgentDefinition],
        paths: SandboxPaths
    ) throws -> [Report] {
        let previous = readManifest(paths: paths)
        var reports: [Report] = []

        // An incomplete connector is reported once, not once per agent — it is
        // one mistake, and repeating it five times buries the other four
        // agents' results.
        var usable: [Connector] = []
        for connector in connectors where connector.enabled {
            if let problem = connector.validationError {
                reports.append(Report(
                    agentID: "connector.\(connector.id)",
                    agentName: connector.name,
                    action: .refused,
                    path: nil,
                    notes: [problem]
                ))
                continue
            }

            // The front door refuses this at write time, so reaching it here
            // means the definition arrived some other way — an older JXCode, or
            // a hand edit of `connector.json`. This is the path that has to hold
            // for a file that never went through the front door, and it is the
            // last one before the value is copied into four configs.
            let inlined = connector.inlinedCredentials
            if !inlined.isEmpty {
                reports.append(Report(
                    agentID: "connector.\(connector.id)",
                    agentName: connector.name,
                    action: .refused,
                    path: nil,
                    notes: inlined.map(\.rendered)
                ))
                continue
            }

            usable.append(connector)
        }

        let names = usable.map(\.id).sorted()

        for agent in agents {
            guard let target = target(for: agent, paths: paths) else {
                reports.append(Report(
                    agentID: agent.id,
                    agentName: agent.name,
                    action: .notApplicable,
                    path: nil,
                    notes: [unsupportedReason(for: agent)]
                ))
                continue
            }

            // A reference that this agent cannot carry is a refusal for this
            // agent alone, not for the collection. Everything else in the
            // collection still goes in: one connector that names its secret in
            // a field Gemini does not expand is not a reason to leave Gemini
            // without the four that do.
            let carried = usable.filter { target.canCarryReferences(of: $0) }
            for connector in usable where !target.canCarryReferences(of: connector) {
                let field = CredentialScan.Field.headers
                reports.append(Report(
                    agentID: "\(agent.id).\(connector.id)",
                    agentName: "\(connector.name) → \(agent.name)",
                    action: .refused,
                    path: nil,
                    notes: [
                        target.referenceRefusal(in: field) ?? "its config cannot carry a reference",
                        "\(agent.name) would have to be given the value itself, which is the "
                            + "one thing this refuses to do — so this connector was not written for "
                            + "\(agent.name). The others were.",
                    ]
                ))
            }

            reports.append(try write(
                target: target,
                agent: agent,
                connectors: carried,
                removing: previous.managed,
                paths: paths
            ))
        }

        // Written last, and only after the agents have been updated: if a write
        // throws partway through, the manifest still describes the previous
        // state, so the next run removes the entries this one left behind
        // rather than forgetting them.
        //
        // Skipped when it would say nothing. With no connectors to record and
        // no ledger to correct, the only effect would be to create a file in a
        // sandbox that had none — the same rule `revert` follows, and the
        // reason `shared-bind` on an empty collection is a no-op rather than a
        // first write.
        let existed = FileManager.default.fileExists(atPath: paths.sharedMCPManifest.path)
        if !names.isEmpty || existed {
            try writeManifest(
                Manifest(managed: names, mcpServers: Dictionary(
                    uniqueKeysWithValues: usable.map { ($0.id, server(for: $0)) }
                )),
                paths: paths
            )
        }

        return reports
    }

    private static func write(
        target: Target,
        agent: AgentDefinition,
        connectors: [Connector],
        removing: [String],
        paths: SandboxPaths
    ) throws -> Report {
        switch target {
        case .claudeJSON(let file):
            return try writeJSON(
                file: file,
                containerKey: "mcpServers",
                agent: agent,
                removing: removing,
                entries: Dictionary(uniqueKeysWithValues: connectors.map {
                    ($0.id, claudeEntry(for: $0))
                }),
                paths: paths
            )

        case .geminiJSON(let file):
            return try writeJSON(
                file: file,
                containerKey: "mcpServers",
                agent: agent,
                removing: removing,
                entries: Dictionary(uniqueKeysWithValues: connectors.map {
                    ($0.id, geminiEntry(for: $0))
                }),
                paths: paths
            )

        case .opencodeJSON(let file):
            return try writeJSON(
                file: file,
                containerKey: "mcp",
                agent: agent,
                removing: removing,
                entries: Dictionary(uniqueKeysWithValues: connectors.map {
                    ($0.id, opencodeEntry(for: $0))
                }),
                paths: paths
            )

        case .codexTOML(let file):
            return try writeTOML(
                file: file,
                agent: agent,
                connectors: connectors,
                paths: paths
            )
        }
    }

    // MARK: - Entry shapes
    //
    // Every value here goes through `translated`, and that is the whole of "one
    // definition, four configs". The store holds one spelling — the shell one —
    // and each writer rewrites it into what its own agent expands. Writing the
    // stored value straight out would put `${GITHUB_TOKEN}` into an opencode
    // config, which opencode does not substitute: the server would be handed the
    // literal text as its token, and the failure would surface as an
    // authentication error at the server rather than as anything JXCode said.

    /// Rewrite every reference in `values` into `syntax`.
    ///
    /// A literal passes through untouched, which is what makes this safe to
    /// apply to every value rather than only the ones that look like references.
    private static func translated(
        _ values: [String: String],
        to syntax: CredentialSyntax
    ) -> [String: String] {
        values.mapValues { CredentialReference.rewrite($0, to: syntax) }
    }

    static func claudeEntry(for connector: Connector) -> [String: Any] {
        switch connector.transport {
        case .stdio:
            var entry: [String: Any] = [
                "command": connector.command,
                "args": connector.arguments,
            ]
            if !connector.environment.isEmpty {
                entry["env"] = translated(connector.environment, to: .shell)
            }
            return entry
        case .http:
            var entry: [String: Any] = ["type": "http", "url": connector.url]
            if !connector.headers.isEmpty {
                entry["headers"] = translated(connector.headers, to: .shell)
            }
            return entry
        }
    }

    static func geminiEntry(for connector: Connector) -> [String: Any] {
        switch connector.transport {
        case .stdio:
            var entry: [String: Any] = [
                "command": connector.command,
                "args": connector.arguments,
            ]
            if !connector.environment.isEmpty {
                entry["env"] = translated(connector.environment, to: .shell)
            }
            return entry
        case .http:
            // Gemini names the streamable-HTTP field `httpUrl`; a bare `url`
            // means SSE. Getting this wrong is silent — the server is listed
            // and never connects.
            //
            // A referenced header never reaches here: `apply` drops this
            // connector for Gemini first, because Gemini's `env` block is the
            // only place it expands a reference and a header value written
            // literally would be the token.
            var entry: [String: Any] = ["httpUrl": connector.url]
            if !connector.headers.isEmpty {
                entry["headers"] = translated(connector.headers, to: .shell)
            }
            return entry
        }
    }

    static func opencodeEntry(for connector: Connector) -> [String: Any] {
        switch connector.transport {
        case .stdio:
            // `command` is one array here, not a string plus `args`.
            var entry: [String: Any] = [
                "type": "local",
                "command": connector.argv,
                "enabled": true,
            ]
            if !connector.environment.isEmpty {
                entry["environment"] = translated(connector.environment, to: .opencode)
            }
            return entry
        case .http:
            var entry: [String: Any] = [
                "type": "remote",
                "url": connector.url,
                "enabled": true,
            ]
            if !connector.headers.isEmpty {
                entry["headers"] = translated(connector.headers, to: .opencode)
            }
            return entry
        }
    }

    /// The canonical, agent-neutral description. Also what the manifest stores.
    ///
    /// Deliberately *not* translated. The manifest is the one place the
    /// collection is described in one spelling, and that spelling is the shell
    /// form the store holds — so `shared/mcp.json` says `${GITHUB_TOKEN}` even
    /// on a machine where the only agent bound is opencode, and a reader of it
    /// learns the name of the secret rather than a syntax it would have to
    /// translate back.
    static func server(for connector: Connector) -> Server {
        switch connector.transport {
        case .stdio:
            return Server(
                command: connector.command,
                args: connector.arguments,
                env: connector.environment.isEmpty ? nil : connector.environment,
                type: nil,
                url: nil
            )
        case .http:
            return Server(
                command: nil,
                args: nil,
                env: nil,
                type: "http",
                url: connector.url
            )
        }
    }

    // MARK: - JSON writers

    private static func writeJSON(
        file: URL,
        containerKey: String,
        agent: AgentDefinition,
        removing: [String],
        entries: [String: [String: Any]],
        paths: SandboxPaths
    ) throws -> Report {
        let fm = FileManager.default

        let existed = fm.fileExists(atPath: file.path)
        let currentText = (try? String(contentsOf: file, encoding: .utf8)) ?? ""

        var root: [String: Any] = [:]
        if existed, !currentText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(currentText.utf8)),
                  let object = parsed as? [String: Any]
            else {
                // Refuse rather than overwrite. The file may hold project
                // history (Claude Code) or tool allowlists (Gemini), and
                // replacing it with our own object would delete all of it.
                return Report(
                    agentID: agent.id,
                    agentName: agent.name,
                    action: .refused,
                    path: file,
                    notes: ["\(file.lastPathComponent) is not a JSON object — left untouched"]
                )
            }
            root = object
        }

        let hadContainer = root[containerKey] != nil
        var container = (root[containerKey] as? [String: Any]) ?? [:]

        // Remove exactly what we previously wrote. Never more.
        for name in removing { container.removeValue(forKey: name) }
        for (name, entry) in entries { container[name] = entry }

        if container.isEmpty {
            // Nothing left, and nothing there to begin with: do not leave an
            // empty object behind, which would read as a deliberate setting.
            if hadContainer { root.removeValue(forKey: containerKey) }
        } else {
            root[containerKey] = container
        }

        let rendered = try render(root)

        // Nothing of ours to add, and no file to take anything out of. Creating
        // one here would put a config file into the agent's home directory as a
        // side effect of pressing "Unbind", which is not what unbinding means.
        guard existed || !entries.isEmpty else {
            return Report(
                agentID: agent.id,
                agentName: agent.name,
                action: .unchanged,
                path: file,
                notes: ["nothing to remove — \(file.lastPathComponent) does not exist"]
            )
        }

        if existed, currentText == rendered {
            return Report(
                agentID: agent.id,
                agentName: agent.name,
                action: .unchanged,
                path: file,
                notes: [entries.isEmpty
                        ? "no connectors to register"
                        : "already lists \(entries.count) connector(s)"]
            )
        }

        // Only ever back up a file we are adding to. On a removal the file
        // already holds our own container, so a backup taken here would record
        // our content and not the user's — and because `ConfigFiles.backUp` skips when a
        // backup already exists, that wrong copy would become the permanent one.
        //
        // A file that did not exist is recorded as ours instead. `config.toml`
        // and `settings.json` are each written by two binders, and without this
        // the second one would back up the first one's file.
        //
        // The directory is created here rather than at the top because both
        // guards above can return without writing anything. Making it up front
        // put `~/.config/opencode/` into an agent's home as a side effect of an
        // unbind — the same defect as a revert that creates a config file in
        // order to remove one.
        try ConfigFiles.createDirectory(at: file.deletingLastPathComponent(), upTo: paths.home)

        if existed, !entries.isEmpty {
            ConfigFiles.backUp(file)
        } else if !existed {
            ConfigFiles.markCreated(file)
        }

        try commit(rendered, to: file, isEmpty: root.isEmpty, removing: entries.isEmpty)

        var notes: [String] = []
        if entries.isEmpty {
            notes.append("removed the shared connectors")
        } else {
            notes.append("registered \(entries.count) connector(s) under `\(containerKey)`")
        }
        if existed, !entries.isEmpty { notes.append("merged into the existing file") }

        return Report(
            agentID: agent.id,
            agentName: agent.name,
            action: entries.isEmpty ? .cleared : .bound,
            path: file,
            notes: notes
        )
    }

    /// Pretty-printed with sorted keys, so an unchanged file produces identical
    /// bytes and the "unchanged" check above can be a string comparison.
    static func render(_ object: [String: Any]) throws -> String {
        try JSONText.encode(object)
    }

    // MARK: - TOML writer

    private static func writeTOML(
        file: URL,
        agent: AgentDefinition,
        connectors: [Connector],
        paths: SandboxPaths
    ) throws -> Report {
        let fm = FileManager.default

        let existed = fm.fileExists(atPath: file.path)
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""

        let rendered: String
        if connectors.isEmpty {
            guard ManagedBlock.contains(current, markers: .tomlConnectors) else {
                return Report(
                    agentID: agent.id,
                    agentName: agent.name,
                    action: .unchanged,
                    path: file,
                    notes: ["no connectors to register"]
                )
            }
            // Shape-preserving, and therefore no `+ "\n"`: the result already
            // ends the way the file did.
            rendered = ManagedBlock.removingPreservingShape(
                from: current,
                markers: .tomlConnectors
            )
        } else {
            // Appended, not prepended: a `[table]` header ends TOML's top-level
            // key section, so putting these tables first would make any of the
            // user's own top-level assignments invalid.
            rendered = ManagedBlock.appending(
                tomlBlock(for: connectors),
                to: current,
                markers: .tomlConnectors
            )
        }

        if existed, current == rendered {
            return Report(
                agentID: agent.id,
                agentName: agent.name,
                action: .unchanged,
                path: file,
                notes: ["already lists \(connectors.count) connector(s)"]
            )
        }

        // Only ever back up a file we are adding to — see `writeJSON`. The
        // directory is created here for the same reason too: both guards above
        // can return without writing, and neither should leave a directory
        // behind.
        try ConfigFiles.createDirectory(at: file.deletingLastPathComponent(), upTo: paths.home)

        if existed, !connectors.isEmpty {
            ConfigFiles.backUp(file)
        } else if !existed {
            ConfigFiles.markCreated(file)
        }

        try commit(
            rendered,
            to: file,
            isEmpty: rendered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            removing: connectors.isEmpty
        )

        var notes: [String] = connectors.isEmpty
            ? ["removed the shared connector tables"]
            : ["registered \(connectors.count) connector(s) as [mcp_servers.*]"]

        // Said out loud, because both of these are silent from Codex's side and
        // both are the kind of thing that is diagnosed as "the server has no
        // auth" long after the bind looked fine.
        let inherited = connectors.flatMap { connector in
            connector.environment.keys.sorted().filter {
                CredentialReference.isReference(connector.environment[$0] ?? "")
            }
        }
        if !inherited.isEmpty {
            notes.append("\(inherited.joined(separator: ", ")) left out of `env` — TOML "
                + "expands nothing, so Codex passes its own environment to the server "
                + "instead of JXCode writing the name of a secret into the file")
        }

        let withHeaders = connectors.filter { !$0.headers.isEmpty }
        if !withHeaders.isEmpty {
            // Hoisted rather than interpolated inline: a string literal inside
            // an interpolation inside the literal it belongs to is a parse
            // error in Swift, and it names the *outer* string when it fails.
            let subject = withHeaders.count == 1
                ? "a remote connector reaches"
                : "\(withHeaders.count) remote connectors reach"
            notes.append("headers are not written for Codex — this writer has no field "
                + "for them, so \(subject) Codex unauthenticated")
        }

        return Report(
            agentID: agent.id,
            agentName: agent.name,
            action: connectors.isEmpty ? .cleared : .bound,
            path: file,
            notes: notes
        )
    }

    static func tomlBlock(for connectors: [Connector]) -> String {
        var lines = [
            ManagedBlock.Markers.tomlConnectors.start,
            "# Managed by JXCode — the shared collection. Rewritten whenever the",
            "# connector list changes, so edit outside these markers.",
        ]

        for connector in connectors {
            let key = tomlKey(connector.id)
            lines.append("")
            lines.append("[mcp_servers.\(key)]")
            switch connector.transport {
            case .stdio:
                lines.append("command = \"\(AgentConfigWriter.escapeTOML(connector.command))\"")
                if !connector.arguments.isEmpty {
                    let args = connector.arguments
                        .map { "\"\(AgentConfigWriter.escapeTOML($0))\"" }
                        .joined(separator: ", ")
                    lines.append("args = [\(args)]")
                }
                if !connector.environment.isEmpty {
                    // A referenced variable is left out, not written. TOML has
                    // no expansion of any kind, so the reference would arrive at
                    // the server as the literal text `${GITHUB_TOKEN}` — a
                    // config that reads as though it names the secret and hands
                    // over a string that is not it. Omitting the key is the
                    // correct translation: Codex starts the server with its own
                    // environment inherited, so a variable that is set for Codex
                    // is set for the server, without JXCode writing it down.
                    let pairs = connector.environment.keys.sorted()
                        .filter { !CredentialReference.isReference(connector.environment[$0] ?? "") }
                        .map { name in
                            "\(tomlKey(name)) = \"\(AgentConfigWriter.escapeTOML(connector.environment[name] ?? ""))\""
                        }
                    if !pairs.isEmpty {
                        lines.append("env = { \(pairs.joined(separator: ", ")) }")
                    }
                }
            case .http:
                lines.append("url = \"\(AgentConfigWriter.escapeTOML(connector.url))\"")
            }
        }

        lines.append(ManagedBlock.Markers.tomlConnectors.end)
        return lines.joined(separator: "\n")
    }

    /// Quote a TOML key only when it needs it.
    ///
    /// A bare key may contain letters, digits, `_` and `-`; anything else — a
    /// dot, most importantly — has to be quoted or it becomes a nested table
    /// and the server is registered under the wrong path.
    static func tomlKey(_ name: String) -> String {
        let bare = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        if !name.isEmpty, name.unicodeScalars.allSatisfy({ bare.contains($0) }) {
            return name
        }
        return "\"\(AgentConfigWriter.escapeTOML(name))\""
    }

    // MARK: - Installing the shared payload

    /// Run each connector's install command once, into the shared prefix.
    ///
    /// This is the half of the collection that makes an install shared. The
    /// command runs under the sandbox environment, so `npm i -g` lands in
    /// `~sandbox/env/npm/bin` — which is on every agent's `PATH` — and anything
    /// that writes to `shared/bin` is picked up from there too.
    ///
    /// Delegated to `AgentInstaller` by wrapping the connector in a throwaway
    /// `AgentDefinition`. That is not a trick for its own sake: the staging,
    /// the bounded retries, the fatal-versus-transient classification and the
    /// "exit 0 but no binary" verification are all already implemented and
    /// tested there, and a second copy of that logic would be a second place
    /// for it to be wrong. The synthetic agent's `command` is the connector's
    /// own command, so verification means the same thing for both: does this
    /// resolve on the sandbox `PATH` now?
    @discardableResult
    public static func installShared(
        connectors: [Connector],
        sandbox: Sandbox,
        onProgress: ((String, String) -> Void)? = nil
    ) -> [AgentInstaller.Outcome] {
        var outcomes: [AgentInstaller.Outcome] = []

        for connector in connectors where connector.enabled {
            guard let command = connector.installCommand?
                .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty
            else { continue }

            let synthetic = AgentDefinition(
                id: connector.id,
                name: connector.name,
                command: connector.command,
                installCommand: command
            )

            let outcome = AgentInstaller.install(
                agent: synthetic,
                sandbox: sandbox,
                onProgress: { message in onProgress?(connector.id, message) }
            )
            outcomes.append(outcome)
        }

        return outcomes
    }

    // MARK: - Reverting

    /// Remove every connector JXCode wrote, from every agent.
    ///
    /// Scoped by the manifest, so a server the user added by hand is never
    /// touched — which is the whole reason the manifest exists.
    @discardableResult
    public static func revert(
        agents: [AgentDefinition],
        paths: SandboxPaths
    ) throws -> [String] {
        let previous = readManifest(paths: paths)
        var messages: [String] = []

        for agent in agents {
            guard let target = target(for: agent, paths: paths) else { continue }
            let report = try write(
                target: target,
                agent: agent,
                connectors: [],
                removing: previous.managed,
                paths: paths
            )
            if report.action == .cleared {
                messages.append("cleared the shared connectors from \(report.path?.path ?? agent.name)")
            } else if report.action == .refused {
                messages.append(contentsOf: report.notes)
            }
        }

        // Don't create the ledger in order to record that it is empty.
        // `readManifest` already treats an absent file as `.empty`, so a
        // sandbox that never bound a connector has nothing to forget — and
        // writing here would leave a file behind whose only content is the
        // news that JXCode ran once.
        //
        // An existing manifest *is* rewritten rather than deleted, because it
        // is what scopes the next revert. A `.refused` agent above means an
        // entry may still be live in a config we could not edit, and dropping
        // the manifest would strand it there with nothing left to find it by.
        if FileManager.default.fileExists(atPath: paths.sharedMCPManifest.path) {
            try writeManifest(.empty, paths: paths)
        }

        // After the manifest, because the manifest is what scopes the *next*
        // revert and a directory is only removable once the files inside it are
        // gone. `SkillBinder.revert` sweeps the same list; whichever of the two
        // runs last is the one that finds the directories empty, and the other
        // finds nothing. The record on disk decides, not the order the two
        // binders happen to be called in.
        messages.append(contentsOf: ConfigFiles.removeCreatedDirectories(
            paths.directoriesABindMayCreate,
            upTo: paths.home
        ))

        return messages
    }

    /// Write the result, or remove the file when there is nothing left in it.
    ///
    /// A file that only ever held our own entries is removed rather than left
    /// behind as `{}` or a blank line: reverting means putting the tree back how
    /// it was found, and it was found without this file.
    private static func commit(
        _ rendered: String,
        to file: URL,
        isEmpty: Bool,
        removing: Bool
    ) throws {
        if removing, isEmpty, !ConfigFiles.hasBackup(file) {
            ConfigFiles.remove(file)
            return
        }
        try rendered.write(to: file, atomically: true, encoding: .utf8)
    }
}

// MARK: - What each target can carry
//
// At file scope rather than inside `ConnectorBinder`, because Swift allows an
// extension only at file scope and `Target` is nested — so the qualified form
// is what is left. The compiler's message for getting this wrong is
// "declaration is only valid at file scope", pointed at the `extension` line,
// with no mention of the type it is about.

extension ConnectorBinder.Target {

    /// Why this target cannot carry a reference in `field`, or `nil`.
    ///
    /// One case today. It is a table rather than an `if` because the
    /// interesting part is that it is *not* uniform: the same reference is fine
    /// in Gemini's `env` block and unrepresentable in its `headers`, and a
    /// writer that treated "Gemini" as one capability would get one of the two
    /// wrong. Where this returns `nil` the field is rewritten into the target's
    /// own syntax by its entry writer.
    func referenceRefusal(in field: CredentialScan.Field) -> String? {
        switch (self, field) {
        case (.geminiJSON, .headers):
            return "Gemini expands a reference in the MCP `env` block and documents "
                + "no expansion for `headers`"
        default:
            return nil
        }
    }

    /// Whether every referenced value in `connector` can be written here.
    ///
    /// A literal is always carriable — it is the same text everywhere — so this
    /// only asks about the values that name something.
    func canCarryReferences(of connector: Connector) -> Bool {
        for field in CredentialScan.Field.allCases where referenceRefusal(in: field) != nil {
            let values = field == .environment ? connector.environment : connector.headers
            if values.values.contains(where: CredentialReference.isReference) { return false }
        }
        return true
    }
}
