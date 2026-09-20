import Foundation

/// Points installed agents at the local model router.
///
/// Two mechanisms, in order of how much they can be trusted:
///
///  1. **Environment variables**, injected by `SandboxEnvironment` into every
///     process the app launches. This is the primary mechanism and it works for
///     any agent that honours `ANTHROPIC_BASE_URL` or `OPENAI_BASE_URL`.
///  2. **Config files**, for the agents that ignore those variables or that
///     require a model name and token to be set somewhere persistent.
///
/// Only agents whose config format is documented and stable get a file writer.
/// Guessing at a schema writes a broken config that is harder to diagnose than
/// doing nothing, so anything unrecognised is reported as environment-only and
/// left alone.
public enum AgentConfigWriter {

    /// What happened to one agent.
    public struct Report: Sendable {
        public enum Action: String, Sendable {
            /// A config file was created.
            case created
            /// An existing file was merged into.
            case merged
            /// The file already said the right thing.
            case unchanged
            /// The file exists but is not something we can safely rewrite, so it
            /// was left exactly as it was.
            case refused
            /// Pointed at the router through the environment alone.
            case environmentOnly
            /// Deliberately not routed.
            case notApplicable
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

        /// Whether this agent is pointed at the router now.
        ///
        /// `.refused` is not: the file was left exactly as it was, so the agent
        /// still points wherever it did before. Counting it as bound would
        /// overstate what the bind actually did — the header would claim an
        /// agent is on the router while its config still names Anthropic.
        public var isRouted: Bool {
            switch action {
            case .created, .merged, .unchanged, .environmentOnly:
                return true
            case .refused, .notApplicable:
                return false
            }
        }
    }

    /// The token agents send to the router.
    ///
    /// The router is loopback-only and does not check it, but most agents refuse
    /// to start with an empty credential, so a fixed placeholder is written
    /// rather than leaving it blank.
    public static let placeholderToken = "jxcode-local-router"

    // MARK: - Applying

    /// Write the router settings for every agent that needs a file.
    ///
    /// `overrides` maps an agent id to the model that agent alone should use.
    /// One model does not fit every agent: Claude Code drives a 30B local model
    /// perfectly well while a smaller helper may need something else, and a
    /// user may want a single agent on a stronger remote model with the rest
    /// local. An agent with no entry falls back to `model`, so the ordinary
    /// case stays a single value.
    ///
    /// An override that cannot be honoured is reported rather than dropped. An
    /// id no agent has, or an empty model, is a mistake the user made and can
    /// only fix if they are told about it — a typo that silently does nothing
    /// is exactly the kind of bug that costs an hour.
    ///
    /// Never touches the host home: every path comes from `SandboxPaths`.
    @discardableResult
    public static func apply(
        agents: [AgentDefinition],
        paths: SandboxPaths,
        routerURL: String,
        model: String,
        token: String = placeholderToken,
        overrides: [String: String] = [:],
        contextLength: Int? = nil
    ) throws -> [Report] {
        let resolved = resolveOverrides(overrides, agents: agents, defaultModel: model)
        var reports: [Report] = []

        for agent in agents {
            // Falls back to the shared model, so an empty `overrides` produces
            // exactly what this writer produced before overrides existed.
            let agentModel = resolved.models[agent.id] ?? model

            switch agent.routerBinding {
            case .none:
                reports.append(Report(
                    agentID: agent.id,
                    agentName: agent.name,
                    action: .notApplicable,
                    path: nil,
                    // Jules runs its model on Google's side; a plain shell is not
                    // an agent at all. Saying so is better than reporting a
                    // routing step that did nothing.
                    notes: [agent.webURL != nil
                            ? "runs against its own cloud service"
                            : "not an agent — nothing to route"]
                ))

            case .environment:
                reports.append(Report(
                    agentID: agent.id,
                    agentName: agent.name,
                    action: .environmentOnly,
                    path: nil,
                    notes: ["pointed at the router through ANTHROPIC_BASE_URL / OPENAI_BASE_URL"]
                ))

            case .claudeSettings:
                reports.append(try writeClaudeSettings(
                    agent: agent,
                    paths: paths,
                    routerURL: routerURL,
                    model: agentModel,
                    token: token,
                    contextLength: contextLength
                ))

            case .codexConfig:
                reports.append(try writeCodexConfig(
                    agent: agent,
                    paths: paths,
                    routerURL: routerURL,
                    model: agentModel
                ))
            }
        }

        // A refused override still concerns an agent that exists, so the note
        // belongs on that agent's own report rather than in a separate entry.
        for index in reports.indices {
            if let refusal = resolved.refusals[reports[index].agentID] {
                reports[index].notes.append(refusal)
            }
        }

        // An id that names no agent has no report to attach to, so it gets one
        // of its own. Sorted because `overrides` is a dictionary and iteration
        // order is not stable — the output must be reproducible.
        for agentID in resolved.unknownIDs.sorted() {
            reports.append(Report(
                agentID: agentID,
                agentName: agentID,
                action: .notApplicable,
                path: nil,
                notes: ["no agent has the id `\(agentID)` — the model override was ignored"]
            ))
        }

        return reports
    }

    /// The outcome of checking `overrides` against the agent list.
    private struct OverrideResolution {
        /// agent id -> model, for ids that exist and carry a usable model.
        var models: [String: String] = [:]
        /// agent id -> why that agent's override was refused.
        var refusals: [String: String] = [:]
        /// Ids that name no agent at all.
        var unknownIDs: [String] = []
    }

    private static func resolveOverrides(
        _ overrides: [String: String],
        agents: [AgentDefinition],
        defaultModel: String
    ) -> OverrideResolution {
        var resolution = OverrideResolution()
        let known = Set(agents.map(\.id))

        for (agentID, requested) in overrides {
            guard known.contains(agentID) else {
                resolution.unknownIDs.append(agentID)
                continue
            }

            // Whitespace-only counts as empty: writing it would produce a model
            // name no backend recognises, and a config the agent cannot start
            // from is worse than one that quietly kept the default.
            let trimmed = requested.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                resolution.refusals[agentID] =
                    "ignored the override for `\(agentID)` — the model was empty, so `\(defaultModel)` was used"
                continue
            }

            resolution.models[agentID] = trimmed
        }

        return resolution
    }

    /// Undo everything `apply` wrote. Used when the router is switched off.
    @discardableResult
    public static func revert(agents: [AgentDefinition], paths: SandboxPaths) throws -> [String] {
        var messages: [String] = []

        for agent in agents {
            switch agent.routerBinding {
            case .claudeSettings:
                let file = paths.claudeConfig.appendingPathComponent("settings.json")
                guard let root = readJSONObject(file) else { continue }
                guard var environment = root["env"] as? [String: Any] else { continue }
                let before = environment

                // Put the keys we own back to the values the file held before we
                // first wrote to it, rather than deleting them.
                //
                // Deleting was the bug. `ANTHROPIC_API_KEY` is deliberately
                // overwritten with an empty string on bind — a real key left in
                // place would send Claude Code straight to api.anthropic.com,
                // bypassing the router this feature exists to provide — and
                // unbinding then removed the key outright. A user who had a real
                // key in `settings.json` lost it: the one value the sandbox was
                // meant to be protecting, thrown away by the operation that
                // claims to give the file back.
                //
                // `backUp` copies the file aside on the first write, so the
                // backup is exactly the state to restore into. With no backup
                // the file is one we created and every managed key in it is
                // ours, so removing them is still the right undo.
                let original = originalManagedEnvironment(for: file)
                for key in claudeEnvironmentKeys {
                    if let restored = original[key] {
                        environment[key] = restored
                    } else {
                        environment.removeValue(forKey: key)
                    }
                }

                // Compared as rendered JSON, not by key count. Restoring a key
                // we had overwritten changes what the file says without changing
                // how many keys it holds, so a count test would skip the write
                // and leave our empty string sitting where the user's real key
                // used to be.
                guard try renderJSONObject(environment) != renderJSONObject(before) else {
                    continue
                }

                var updated = root
                if environment.isEmpty {
                    updated.removeValue(forKey: "env")
                } else {
                    updated["env"] = environment
                }

                // Nothing of ours left and nothing of theirs either: this file
                // exists only because we made it, so reverting means removing
                // it rather than leaving `{}` behind in the user's home.
                if updated.isEmpty, !hasBackup(file) {
                    try? FileManager.default.removeItem(at: file)
                    messages.append("removed \(file.path), which held nothing but our settings")
                } else {
                    try writeJSONObject(updated, to: file)
                    messages.append("cleared router settings from \(file.path)")
                }

            case .codexConfig:
                let file = paths.codexHome.appendingPathComponent("config.toml")
                guard let existing = try? String(contentsOf: file, encoding: .utf8) else { continue }
                // The shape-preserving variant, not the writer's one: revert has
                // to give the file back as it found it, not reformat it.
                var stripped = removeManagedBlockPreservingShape(from: existing)
                // Order matters: uncommenting a key while our block is still in
                // the file would produce exactly the duplicate TOML key that
                // commenting it out existed to avoid.
                stripped = restoreCommentedOutTopLevelKeys(in: stripped)
                guard stripped != existing else { continue }

                // Same rule, same reason: a `config.toml` that held nothing but
                // our block is one we created, so it goes rather than being
                // left behind as a zero-byte file.
                if stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !hasBackup(file) {
                    try? FileManager.default.removeItem(at: file)
                    messages.append("removed \(file.path), which held nothing but our block")
                } else {
                    try stripped.write(to: file, atomically: true, encoding: .utf8)
                    messages.append("removed the managed block from \(file.path)")
                }

            case .environment, .none:
                continue
            }
        }

        return messages
    }

    // MARK: - Claude Code

    /// The model name to show Claude Code, which is not always the real one.
    ///
    /// Claude Code warns `unrecognized_model` and falls back to assuming a
    /// 200k window whenever it does not recognise the name — which is every
    /// non-Anthropic model, and every gateway alias like `anthropic/claude-*`
    /// or `meta/llama-3.3-70b`. The warning is noise the user cannot act on.
    ///
    /// The router already maps any `claude-*` request name onto whatever
    /// backend model is selected (`ModelRouter.resolveModel`), so naming a
    /// recognised model here costs nothing and keeps the routing intact.
    static func claudeVisibleModel(_ model: String) -> String {
        let lower = model.lowercased()
        let recognised = lower.contains("claude-opus")
            || lower.contains("claude-sonnet")
            || lower.contains("claude-haiku")
        return recognised ? model : "claude-sonnet-4-5"
    }

    /// Keys `apply` owns inside `settings.json`'s `env` object.
    static let claudeEnvironmentKeys = [
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_MODEL",
        "ANTHROPIC_SMALL_FAST_MODEL",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC",
        "CLAUDE_CODE_MAX_CONTEXT_TOKENS",
    ]

    private static func writeClaudeSettings(
        agent: AgentDefinition,
        paths: SandboxPaths,
        routerURL: String,
        model: String,
        token: String,
        contextLength: Int? = nil
    ) throws -> Report {
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(
            at: paths.claudeConfig,
            withIntermediateDirectories: true
        )

        let existed = FileManager.default.fileExists(atPath: file.path)

        // Merge rather than replace: settings.json also holds permission rules,
        // hooks and status-line configuration that are none of our business.
        //
        // A file that is present but unparseable is one we must not rewrite at
        // all. This used to be `readJSONObject(file) ?? [:]`, so a
        // `settings.json` we could not read — a trailing comma, JSONC comments,
        // any hand-edit — was replaced wholesale by an object holding nothing
        // but our own keys, taking every permission rule and hook with it. A
        // backup was made, but the file the agent actually reads was gone.
        // `ConnectorBinder` refuses in exactly this situation and for exactly
        // this reason; the two writers now agree.
        var root: [String: Any] = [:]
        if existed {
            let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let parsed = readJSONObject(file) else {
                    return Report(
                        agentID: agent.id,
                        agentName: agent.name,
                        action: .refused,
                        path: file,
                        notes: [
                            "\(file.lastPathComponent) is not a JSON object — left untouched"
                        ]
                    )
                }
                root = parsed
            }
        }

        // Only once the file is known to be one we can merge into. A refusal
        // has to leave no trace, and a stray `*.jxcode-backup` sitting next to a
        // file we never touched is a trace.
        if existed { backUp(file) }

        var environment = (root["env"] as? [String: Any]) ?? [:]

        environment["ANTHROPIC_BASE_URL"] = routerURL
        // A gateway authenticates Claude Code with ANTHROPIC_AUTH_TOKEN, which
        // the client sends as `Authorization: Bearer`.
        environment["ANTHROPIC_AUTH_TOKEN"] = token
        // ANTHROPIC_API_KEY is the fallback Claude Code reaches for when the
        // auth token is absent, and it is sent as `X-Api-Key`. It has to be
        // present and *explicitly empty*: leaving it out of this object lets a
        // real Anthropic key exported in the user's shell survive, and Claude
        // Code would then talk to api.anthropic.com directly — silently
        // bypassing the router this whole feature exists to provide.
        environment["ANTHROPIC_API_KEY"] = ""
        let visible = Self.claudeVisibleModel(model)
        environment["ANTHROPIC_MODEL"] = visible
        // Claude Code uses a cheaper model for background work like summarising.
        // Pointing it at the same model avoids a second, unroutable request.
        environment["ANTHROPIC_SMALL_FAST_MODEL"] = visible
        // Stops telemetry and update checks, which would otherwise reach the
        // real Anthropic API from inside the sandbox.
        environment["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        // Claude Code assumes a 200k window for any model it does not
        // recognise. A local model with a smaller context overflows on the
        // first request, and the failure reads as a crash rather than as a
        // size problem — so state the real limit whenever it is known.
        if let contextLength, contextLength > 0 {
            environment["CLAUDE_CODE_MAX_CONTEXT_TOKENS"] = String(contextLength)
        } else {
            // Retract it. The env is merged from the existing file, so a window
            // set for a previously served local model would otherwise survive
            // into the next one — throttling a remote model to 32k.
            environment.removeValue(forKey: "CLAUDE_CODE_MAX_CONTEXT_TOKENS")
        }

        root["env"] = environment

        let rendered = try renderJSONObject(root)
        var notes: [String] = []

        if let current = try? String(contentsOf: file, encoding: .utf8), current == rendered {
            return Report(
                agentID: agent.id,
                agentName: agent.name,
                action: .unchanged,
                path: file,
                notes: ["already pointed at the router"]
            )
        }

        try rendered.write(to: file, atomically: true, encoding: .utf8)
        if existed { notes.append("merged into the existing settings.json") }
        notes.append("ANTHROPIC_BASE_URL → \(routerURL)")
        notes.append(visible == model
                     ? "ANTHROPIC_MODEL → \(model)"
                     : "ANTHROPIC_MODEL → \(visible) (router serves \(model))")

        return Report(
            agentID: agent.id,
            agentName: agent.name,
            action: existed ? .merged : .created,
            path: file,
            notes: notes
        )
    }

    // MARK: - Codex

    private static let blockStart = "# >>> jxcode router >>>"
    private static let blockEnd = "# <<< jxcode router <<<"

    /// Appended to a user's own key when the writer comments it out, so `revert`
    /// can find the line again and put it back.
    ///
    /// One constant used by both directions, because the write and the undo have
    /// to agree character for character: a typo in either would leave the user's
    /// setting disabled with nothing on disk to say why.
    static let supersededMarker = "# superseded by the jxcode router block above"

    private static func writeCodexConfig(
        agent: AgentDefinition,
        paths: SandboxPaths,
        routerURL: String,
        model: String
    ) throws -> Report {
        let file = paths.codexHome.appendingPathComponent("config.toml")
        try FileManager.default.createDirectory(
            at: paths.codexHome,
            withIntermediateDirectories: true
        )

        let existed = FileManager.default.fileExists(atPath: file.path)
        if existed { backUp(file) }

        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""

        // Codex picks a provider by name from config.toml and does not read a
        // bare OPENAI_BASE_URL, so a provider table has to be declared.
        let block = """
        \(blockStart)
        # Managed by JXCode. Everything between these markers is rewritten
        # whenever the router settings change — edit outside them instead.
        model = "\(escapeTOML(model))"
        model_provider = "jxcode"

        [model_providers.jxcode]
        name = "JXCode Router"
        base_url = "\(escapeTOML(routerURL))/v1"
        wire_api = "chat"
        env_key = "JXCODE_API_KEY"
        \(blockEnd)
        """

        var notes: [String] = []
        // Shape-preserving: the writer's `removeManagedBlock` collapses blank
        // lines, which would eat the user's own runs on every re-bind and make
        // it look like our block was the cause. Only the block is ours to move.
        var body = removeManagedBlockPreservingShape(from: existing)
        body = commentOutConflictingTopLevelKeys(in: body, keys: ["model", "model_provider"], notes: &notes)

        // The block goes first: top-level keys must precede any `[table]`
        // header, and a user file usually ends with one.
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let rendered = trimmedBody.isEmpty
            ? block + "\n"
            : block + "\n\n" + trimmedBody + "\n"

        if let current = try? String(contentsOf: file, encoding: .utf8), current == rendered {
            return Report(
                agentID: agent.id,
                agentName: agent.name,
                action: .unchanged,
                path: file,
                notes: ["already pointed at the router"]
            )
        }

        try rendered.write(to: file, atomically: true, encoding: .utf8)
        if existed { notes.append("merged into the existing config.toml") }
        notes.append("provider `jxcode` → \(routerURL)/v1")

        return Report(
            agentID: agent.id,
            agentName: agent.name,
            action: existed ? .merged : .created,
            path: file,
            notes: notes
        )
    }

    /// Remove the managed block the way it was written, leaving the rest of the
    /// file byte for byte.
    ///
    /// "Preserving shape" is the contract, not a contrast: there used to be a
    /// second variant that trimmed the result and collapsed runs of blank lines,
    /// on the theory that the collapse only touched the gap our block left
    /// behind. It did not — it collapsed *every* blank run in the file,
    /// including the user's own, so a re-bind quietly ate a line of their text
    /// and `revert` could not put it back. Both the write path and `revert` now
    /// use this one, and the collapsing variant is gone rather than left lying
    /// around — the whole bug family came from having two behaviours available
    /// and picking the wrong one.
    static func removeManagedBlockPreservingShape(from text: String) -> String {
        guard text.contains(blockStart) else { return text }

        var lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains(blockStart) }),
              let end = lines.firstIndex(where: { $0.contains(blockEnd) }),
              start <= end
        else { return text }

        // The writer composes `block + "\n\n" + body`, so the single blank line
        // directly after the block is ours to take with it. Any further blank
        // lines are the user's and stay put.
        var last = end
        if last + 1 < lines.count,
           lines[last + 1].trimmingCharacters(in: .whitespaces).isEmpty {
            last += 1
        }

        lines.removeSubrange(start...last)
        return lines.joined(separator: "\n")
    }

    /// Comment out top-level assignments that would clash with the managed block.
    ///
    /// TOML forbids a duplicate key rather than letting the last one win, so
    /// leaving a user's own `model = ...` in place would make the whole file
    /// invalid. Commenting preserves the original for the user to restore.
    ///
    /// Only lines before the first `[table]` header count as top-level; a
    /// `model = ` inside a section belongs to that section and is left alone.
    static func commentOutConflictingTopLevelKeys(
        in text: String,
        keys: [String],
        notes: inout [String]
    ) -> String {
        var output: [String] = []
        var inSection = false
        var commented = 0

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") { inSection = true }

            if !inSection, !trimmed.hasPrefix("#") {
                let isConflict = keys.contains { key in
                    guard trimmed.hasPrefix(key) else { return false }
                    let rest = trimmed.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
                    return rest.hasPrefix("=")
                }
                if isConflict {
                    output.append("# \(line)   \(supersededMarker)")
                    commented += 1
                    continue
                }
            }
            output.append(line)
        }

        if commented > 0 {
            notes.append("commented out \(commented) conflicting top-level key(s) — restore them to stop using the router")
        }
        return output.joined(separator: "\n")
    }

    /// Undo `commentOutConflictingTopLevelKeys`.
    ///
    /// Commenting a user's own `model = …` out is necessary — TOML forbids the
    /// duplicate key, so leaving it would make the whole file invalid — but it
    /// is only half a contract. `revert` removed our block and left the line
    /// commented, so a bind→unbind cycle permanently switched off the user's own
    /// Codex model and Codex silently fell back to its default provider. The
    /// README promised the line was preserved; this is the half that makes that
    /// true.
    ///
    /// Only lines the writer produced are matched, which is what the shared
    /// marker buys: a line the user had commented out themselves is skipped on
    /// the way in, so it never carries the marker and is never uncommented here.
    static func restoreCommentedOutTopLevelKeys(in text: String) -> String {
        let suffix = "   " + supersededMarker
        var output: [String] = []

        for line in text.components(separatedBy: "\n") {
            guard line.hasPrefix("# "), line.hasSuffix(suffix) else {
                output.append(line)
                continue
            }
            // `# ` in front, the marker behind: what is left is the line as the
            // user wrote it, indentation and all.
            output.append(String(line.dropFirst(2).dropLast(suffix.count)))
        }

        return output.joined(separator: "\n")
    }

    /// Minimal TOML string escaping. Enough for model names and URLs.
    static func escapeTOML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    // MARK: - File helpers

    /// Copy a file aside once, before the first modification.
    ///
    /// Skipped if a backup already exists, so a second run cannot overwrite a
    /// good backup with an already-modified file.
    private static func backUp(_ file: URL) {
        let backup = file.appendingPathExtension("jxcode-backup")
        guard !FileManager.default.fileExists(atPath: backup.path) else { return }
        try? FileManager.default.copyItem(at: file, to: backup)
    }

    /// Whether a backup exists for this file.
    ///
    /// This doubles as the record that the file **predated JXCode**. `backUp`
    /// runs on the first write to a file that was already there, so a missing
    /// backup means we created it — and on revert the state to restore is
    /// "no file", not "an empty one". The shared binders use the same rule; a
    /// `settings.json` left as `{}` is a file in the user's home that was never
    /// there, and it makes "never configured" and "configured, then unbound"
    /// look identical on disk.
    private static func hasBackup(_ file: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: file.appendingPathExtension("jxcode-backup").path
        )
    }

    private static func readJSONObject(_ file: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The values the managed keys held before JXCode first wrote to this file.
    ///
    /// Empty when there is no backup, which is also the record that we created
    /// the file: every managed key in it is one we added, so removing them is
    /// the right undo. When a backup does exist it is the pre-JXCode file, and
    /// the keys we own are restored from it while every other key in the live
    /// file is left as the user last had it — so a `MY_OWN_VAR` added while
    /// bound survives the unbind.
    private static func originalManagedEnvironment(for file: URL) -> [String: Any] {
        let backup = file.appendingPathExtension("jxcode-backup")
        guard let root = readJSONObject(backup),
              let environment = root["env"] as? [String: Any]
        else { return [:] }

        return environment.filter { claudeEnvironmentKeys.contains($0.key) }
    }

    private static func writeJSONObject(_ object: [String: Any], to file: URL) throws {
        try renderJSONObject(object).write(to: file, atomically: true, encoding: .utf8)
    }

    /// Pretty-printed with sorted keys, so repeated runs produce identical bytes
    /// and the "unchanged" check above can be a plain string comparison.
    private static func renderJSONObject(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        // JSONSerialization escapes every `/` as `\/`. That is legal JSON but
        // reads badly in a config file a human is meant to inspect. Undoing it
        // is safe: a literal backslash is itself escaped as `\\`, so a `\/`
        // sequence in the output can only ever be an escaped slash.
        return text.replacingOccurrences(of: "\\/", with: "/") + "\n"
    }
}
