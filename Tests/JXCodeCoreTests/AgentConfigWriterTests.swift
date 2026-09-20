import XCTest
@testable import JXCodeCore

final class AgentConfigWriterTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var routerURL: String { "http://127.0.0.1:5255" }

    private func claudeSettings() throws -> [String: Any] {
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        let data = try Data(contentsOf: file)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func codexConfig() throws -> String {
        let file = paths.codexHome.appendingPathComponent("config.toml")
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func claudeAgent() throws -> AgentDefinition {
        try XCTUnwrap(AgentRegistry.builtIns.first { $0.id == "claude" })
    }

    // MARK: - Claude Code

    func testClaudeSettingsIsCreatedWithTheRouterEnvironment() throws {
        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "qwen3-coder"
        )

        let report = try XCTUnwrap(reports.first { $0.agentID == "claude" })
        XCTAssertEqual(report.action, .created)

        let settings = try claudeSettings()
        let environment = try XCTUnwrap(settings["env"] as? [String: String])
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], routerURL)
                // Claude Code only recognises Anthropic's own model names; anything else
        // makes it warn and assume a 200k window. The router maps the name it is
        // given back onto the real model, so this must be a name it recognises.
        XCTAssertEqual(environment["ANTHROPIC_MODEL"], AgentConfigWriter.claudeVisibleModel("qwen3-coder"))
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], AgentConfigWriter.placeholderToken)
        // Otherwise background summarisation tries to reach the real API.
        XCTAssertEqual(environment["ANTHROPIC_SMALL_FAST_MODEL"], AgentConfigWriter.claudeVisibleModel("qwen3-coder"))
    }

    /// Claude Code sends `X-Api-Key` from `ANTHROPIC_API_KEY` when it has no
    /// auth token. If this key is merely absent from `env`, a real Anthropic key
    /// exported in the user's shell survives and Claude Code talks to
    /// api.anthropic.com directly — the router is bypassed and nothing says so.
    /// It therefore has to be present and explicitly empty.
    func testClaudeEnvironmentCarriesTheWholeGatewayCredentialSet() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "qwen3-coder"
        )

        let environment = try XCTUnwrap(try claudeSettings()["env"] as? [String: String])

        let apiKey = try XCTUnwrap(
            environment["ANTHROPIC_API_KEY"],
            "ANTHROPIC_API_KEY must be written, not left unset"
        )
        XCTAssertEqual(apiKey, "", "it must be empty so a real key cannot leak through")
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], AgentConfigWriter.placeholderToken)
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], routerURL)
                // Claude Code only recognises Anthropic's own model names; anything else
        // makes it warn and assume a 200k window. The router maps the name it is
        // given back onto the real model, so this must be a name it recognises.
        XCTAssertEqual(environment["ANTHROPIC_MODEL"], AgentConfigWriter.claudeVisibleModel("qwen3-coder"))
        XCTAssertEqual(environment["ANTHROPIC_SMALL_FAST_MODEL"], AgentConfigWriter.claudeVisibleModel("qwen3-coder"))
    }

    /// settings.json also holds permissions and hooks. Clobbering it would be
    /// the kind of bug that silently destroys a user's setup.
    func testExistingClaudeSettingsAreMergedNotReplaced() throws {
        try FileManager.default.createDirectory(at: paths.claudeConfig, withIntermediateDirectories: true)
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        try """
        {"permissions":{"allow":["Bash(ls:*)"]},"env":{"MY_OWN_VAR":"keep-me"},"statusLine":{"type":"command"}}
        """.write(to: file, atomically: true, encoding: .utf8)

        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "m"
        )
        XCTAssertEqual(reports.first { $0.agentID == "claude" }?.action, .merged)

        let settings = try claudeSettings()
        let environment = try XCTUnwrap(settings["env"] as? [String: String])
        XCTAssertEqual(environment["MY_OWN_VAR"], "keep-me")
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], routerURL)

        let permissions = try XCTUnwrap(settings["permissions"] as? [String: Any])
        XCTAssertNotNil(permissions["allow"])
        XCTAssertNotNil(settings["statusLine"])
    }

    func testSecondRunReportsUnchanged() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        let second = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        XCTAssertEqual(second.first { $0.agentID == "claude" }?.action, .unchanged)
    }

    /// `JSONSerialization` escapes every `/` as `\/`. Legal, but a config file a
    /// human is meant to read should not look like that — and the unescaping
    /// must not corrupt the JSON.
    func testRouterURLIsWrittenWithoutSlashEscapes() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )

        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        let text = try String(contentsOf: file, encoding: .utf8)

        XCTAssertTrue(text.contains("http://127.0.0.1:5255"))
        XCTAssertFalse(text.contains("\\/"))
        // Still parses, and still says the right thing.
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let environment = try XCTUnwrap(parsed["env"] as? [String: String])
        XCTAssertEqual(environment["ANTHROPIC_BASE_URL"], routerURL)
    }

    /// A literal backslash before a slash must survive the unescaping intact.
    func testBackslashesSurviveTheSlashUnescaping() throws {
        try FileManager.default.createDirectory(at: paths.claudeConfig, withIntermediateDirectories: true)
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        let awkward = #"{"env":{"PATH_LIKE":"C:\\/weird\\/path"}}"#
        try awkward.write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )

        let text = try String(contentsOf: file, encoding: .utf8)
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        )
        let environment = try XCTUnwrap(parsed["env"] as? [String: String])
        // One backslash then one slash, exactly as written.
        XCTAssertEqual(environment["PATH_LIKE"], #"C:\/weird\/path"#)
    }

    func testChangingTheModelRewritesTheSettings() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "first"
        )
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "second"
        )
        let environment = try XCTUnwrap(try claudeSettings()["env"] as? [String: String])
        XCTAssertEqual(environment["ANTHROPIC_MODEL"], AgentConfigWriter.claudeVisibleModel("second"))
    }

    func testExistingSettingsAreBackedUpOnce() throws {
        try FileManager.default.createDirectory(at: paths.claudeConfig, withIntermediateDirectories: true)
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        try #"{"env":{"A":"1"}}"#.write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        let backup = file.appendingPathExtension("jxcode-backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path))

        // A second run must not overwrite the backup with the modified file.
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "other"
        )
        let backupText = try String(contentsOf: backup, encoding: .utf8)
        XCTAssertEqual(backupText, #"{"env":{"A":"1"}}"#)
    }

    func testRevertRemovesOnlyOurClaudeKeys() throws {
        try FileManager.default.createDirectory(at: paths.claudeConfig, withIntermediateDirectories: true)
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        try #"{"env":{"MY_OWN_VAR":"keep-me"}}"#.write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        let messages = try AgentConfigWriter.revert(agents: AgentRegistry.builtIns, paths: paths)
        XCTAssertFalse(messages.isEmpty)

        let environment = try XCTUnwrap(try claudeSettings()["env"] as? [String: String])
        XCTAssertEqual(environment["MY_OWN_VAR"], "keep-me")
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
        XCTAssertNil(environment["ANTHROPIC_MODEL"])
    }

    /// Our keys are removed from `env`, and when that leaves `env` empty the
    /// object goes too — a stray `"env": {}` is a key the user never wrote.
    ///
    /// The file is given one key of the user's own, so it is theirs and has to
    /// survive. Without that it would be a file we created, and reverting means
    /// removing it outright — a different rule, tested just below.
    func testRevertDropsTheEnvObjectWhenItBecomesEmpty() throws {
        try FileManager.default.createDirectory(at: paths.claudeConfig, withIntermediateDirectories: true)
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        try #"{"numStartups":42}"#.write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        _ = try AgentConfigWriter.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertNil(try claudeSettings()["env"])
        XCTAssertEqual(try claudeSettings()["numStartups"] as? Int, 42,
                       "the user's own key must survive")
    }

    // MARK: - Unbinding leaves nothing of ours behind
    //
    // The rule the shared binders follow, checked on this writer's own paths.
    // Both files here live in the user's home, so a leftover is not cosmetic:
    // it makes "never configured" and "configured, then unbound" look identical
    // on disk, and it puts a file there that was never there before.

    func testRevertRemovesASettingsFileItCreated() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "the fixture should have created settings.json")

        _ = try AgentConfigWriter.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "settings.json held nothing but our keys, so it should be removed rather than left as {}")
    }

    func testRevertRemovesACodexConfigItCreated() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        let file = paths.codexHome.appendingPathComponent("config.toml")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "the fixture should have created config.toml")

        _ = try AgentConfigWriter.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path),
                       "config.toml held nothing but our managed block, so it should be removed rather than left blank")
    }

    /// The other half: a file the user owned is emptied of our keys, never
    /// deleted. Deleting it would take `numStartups` and `MY_OWN_VAR` with it.
    func testRevertKeepsASettingsFileTheUserOwned() throws {
        try FileManager.default.createDirectory(at: paths.claudeConfig, withIntermediateDirectories: true)
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        try #"{"numStartups":42,"env":{"MY_OWN_VAR":"keep-me"}}"#
            .write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        _ = try AgentConfigWriter.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "the user's settings.json predated us, so it must survive")
        let root = try claudeSettings()
        XCTAssertEqual(root["numStartups"] as? Int, 42)
        let environment = try XCTUnwrap(root["env"] as? [String: String])
        XCTAssertEqual(environment["MY_OWN_VAR"], "keep-me")
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"], "our key should be gone")
    }

    // MARK: - Codex

    func testCodexConfigDeclaresTheProvider() throws {
        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "qwen3-coder"
        )
        XCTAssertEqual(reports.first { $0.agentID == "codex" }?.action, .created)

        let config = try codexConfig()
        XCTAssertTrue(config.contains(#"model = "qwen3-coder""#))
        XCTAssertTrue(config.contains(#"model_provider = "jxcode""#))
        XCTAssertTrue(config.contains("[model_providers.jxcode]"))
        XCTAssertTrue(config.contains("base_url = \"\(routerURL)/v1\""))
        // Codex's default wire API is the Responses API, which the router does
        // not implement; the chat API has to be named explicitly.
        XCTAssertTrue(config.contains(#"wire_api = "chat""#))
    }

    /// Codex reads the credential from the *named* variable, so the name this
    /// file declares has to be one the sandbox actually exports.
    ///
    /// This is the cross-check that was missing. `env_key` named
    /// `JXCODE_API_KEY` while the process environment exported only
    /// `ANTHROPIC_AUTH_TOKEN` and `OPENAI_API_KEY`, so Codex resolved its key
    /// from a variable nobody had set and sent no credential at all. Both
    /// halves looked right in isolation — the config named a variable, the
    /// environment carried a token — and only their conjunction was broken,
    /// which is why the assertion has to span the two files.
    func testCodexEnvKeyNamesAVariableTheEnvironmentExports() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: routerURL,
            model: "qwen3-coder"
        )
        let config = try codexConfig()

        let pattern = try NSRegularExpression(pattern: #"env_key\s*=\s*"([^"]+)""#)
        let range = NSRange(config.startIndex..., in: config)
        guard let match = pattern.firstMatch(in: config, range: range),
              let nameRange = Range(match.range(at: 1), in: config) else {
            return XCTFail("config.toml declares no env_key")
        }
        let declared = String(config[nameRange])

        let token = RouterAuth.generateToken()
        let exported = RouterAuth(isEnabled: true, token: token).agentEnvironment
        XCTAssertEqual(
            exported[declared], token,
            "config.toml makes Codex read $\(declared), but nothing exports it — "
                + "Codex would reach the router unauthenticated"
        )
    }

    /// TOML forbids duplicate keys rather than letting the last win, so a user's
    /// own `model = ...` would make the whole file invalid.
    func testConflictingTopLevelKeysAreCommentedOut() throws {
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        let file = paths.codexHome.appendingPathComponent("config.toml")
        try """
        model = "gpt-5"
        model_provider = "openai"
        approval_policy = "on-request"
        """.write(to: file, atomically: true, encoding: .utf8)

        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "local"
        )

        let config = try codexConfig()
        XCTAssertTrue(config.contains(#"# model = "gpt-5""#))
        XCTAssertTrue(config.contains(#"# model_provider = "openai""#))
        // Unrelated settings survive untouched.
        XCTAssertTrue(config.contains(#"approval_policy = "on-request""#))
        XCTAssertTrue(
            reports.first { $0.agentID == "codex" }?
                .notes.contains { $0.contains("commented out") } == true
        )
    }

    /// A `model = ` inside a `[section]` belongs to that section and must not be
    /// touched — only top-level keys clash.
    func testSectionLocalKeysAreLeftAlone() throws {
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        let file = paths.codexHome.appendingPathComponent("config.toml")
        try """
        [profiles.fast]
        model = "gpt-5-mini"
        """.write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "local"
        )

        let config = try codexConfig()
        XCTAssertTrue(config.contains(#"model = "gpt-5-mini""#))
        XCTAssertFalse(config.contains(#"# model = "gpt-5-mini""#))
    }

    func testManagedBlockIsReplacedNotDuplicated() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "first"
        )
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: "http://127.0.0.1:9999", model: "second"
        )

        let config = try codexConfig()
        let occurrences = config.components(separatedBy: "# >>> jxcode router >>>").count - 1
        XCTAssertEqual(occurrences, 1, "the managed block must be replaced, not appended")
        XCTAssertTrue(config.contains(#"model = "second""#))
        XCTAssertFalse(config.contains(#"model = "first""#))
        XCTAssertTrue(config.contains("http://127.0.0.1:9999/v1"))
    }

    func testUserContentSurvivesARewrite() throws {
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        let file = paths.codexHome.appendingPathComponent("config.toml")
        try """
        approval_policy = "never"

        [mcp_servers.files]
        command = "npx"
        """.write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m2"
        )

        let config = try codexConfig()
        XCTAssertTrue(config.contains(#"approval_policy = "never""#))
        XCTAssertTrue(config.contains("[mcp_servers.files]"))
        XCTAssertTrue(config.contains(#"command = "npx""#))
        XCTAssertEqual(config.components(separatedBy: "[mcp_servers.files]").count - 1, 1)
    }

    /// The block must come before any `[table]` header, or its top-level keys
    /// would land inside that table.
    func testManagedBlockPrecedesAnyTableHeader() throws {
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        let file = paths.codexHome.appendingPathComponent("config.toml")
        try "[mcp_servers.x]\ncommand = \"y\"\n".write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )

        let config = try codexConfig()
        let blockIndex = try XCTUnwrap(config.range(of: #"model_provider = "jxcode""#)?.lowerBound)
        let tableIndex = try XCTUnwrap(config.range(of: "[mcp_servers.x]")?.lowerBound)
        XCTAssertLessThan(blockIndex, tableIndex)
    }

    func testRevertRemovesTheManagedBlock() throws {
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        let file = paths.codexHome.appendingPathComponent("config.toml")
        try "approval_policy = \"never\"\n".write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        _ = try AgentConfigWriter.revert(agents: AgentRegistry.builtIns, paths: paths)

        let config = try codexConfig()
        XCTAssertFalse(config.contains("# >>> jxcode router >>>"))
        XCTAssertTrue(config.contains(#"approval_policy = "never""#))
    }

    /// Unbinding gives the file back the way it was — byte for byte.
    ///
    /// `removeManagedBlock` is the **writer's** helper. It trims and collapses
    /// blank lines, which is right when composing a fresh file and wrong when
    /// taking our block back out of someone else's: reusing it on the way out
    /// eats the trailing newline and any run of blank lines they wrote. The test
    /// above only asserts our block is gone and their text is present, which is
    /// true either way — the *shape* is what it misses.
    func testUnbindingReturnsTheFileByteForByte() throws {
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        let file = paths.codexHome.appendingPathComponent("config.toml")
        let original = "key1 = \"a\"\n\n\n[table]\nkey2 = \"b\"\n"
        try original.write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        _ = try AgentConfigWriter.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8), original,
            "unbinding must return the file as it found it, not reformatted"
        )
    }

    /// With no managed block present the text is returned byte-for-byte, so a
    /// file that has nothing to do with the router is never rewritten.
    func testRemoveManagedBlockIsANoOpWhenAbsent() {
        let text = "model = \"x\"\n\n[mcp]\ncommand = \"y\"\n"
        XCTAssertEqual(AgentConfigWriter.removeManagedBlockPreservingShape(from: text), text)
    }

    func testTOMLStringsAreEscaped() {
        XCTAssertEqual(AgentConfigWriter.escapeTOML(#"a"b\c"#), #"a\"b\\c"#)
    }

    // MARK: - Reporting

    func testEnvironmentOnlyAgentsAreReportedAsSuch() throws {
        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        for id in ["gemini", "opencode", "omp"] {
            XCTAssertEqual(
                reports.first { $0.agentID == id }?.action,
                .environmentOnly,
                "\(id) should be pointed at the router through the environment"
            )
        }
    }

    /// Jules runs its model on Google's side, so there is nothing to route and
    /// claiming otherwise would be misleading.
    func testJulesIsNotRouted() throws {
        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        XCTAssertEqual(reports.first { $0.agentID == "jules" }?.action, .notApplicable)
    }

    func testEveryBuiltInAgentIsAccountedFor() throws {
        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        XCTAssertEqual(reports.count, AgentRegistry.builtIns.count)
    }

    /// The whole app rests on this: nothing may be written outside the sandbox.
    func testNothingIsWrittenOutsideTheSandbox() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        var checked = 0
        while let item = enumerator?.nextObject() as? URL {
            XCTAssertTrue(
                paths.contains(item),
                "\(item.path) escapes the sandbox root"
            )
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "expected at least one file to have been written")
    }

    // MARK: - The bind/unbind contract
    //
    // Unbinding has to give the file back, not merely stop using it. Three ways
    // it did not: a commented-out Codex key was never uncommented, a real
    // `ANTHROPIC_API_KEY` was deleted rather than restored, and an unparseable
    // `settings.json` was replaced wholesale. Each of these is silent — the
    // agent starts, and simply behaves differently from before.

    /// A real `ANTHROPIC_API_KEY` the user had comes back on unbind.
    ///
    /// Bind *has* to overwrite it with an empty string: a real key left in place
    /// sends Claude Code to api.anthropic.com and bypasses the router this whole
    /// feature exists to provide. But revert then removed the key, so unbinding
    /// destroyed the one value the sandbox was meant to protect. It has to be
    /// restored from the backup instead.
    func testRevertRestoresAPreexistingClaudeAPIKey() throws {
        try FileManager.default.createDirectory(at: paths.claudeConfig, withIntermediateDirectories: true)
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        try #"{"env":{"ANTHROPIC_API_KEY":"sk-ant-real","MY_OWN_VAR":"keep-me"}}"#
            .write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        XCTAssertEqual(
            try XCTUnwrap(try claudeSettings()["env"] as? [String: String])["ANTHROPIC_API_KEY"], "",
            "while bound the key must be blank, or Claude Code bypasses the router"
        )

        _ = try AgentConfigWriter.revert(agents: AgentRegistry.builtIns, paths: paths)

        let environment = try XCTUnwrap(try claudeSettings()["env"] as? [String: String])
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "sk-ant-real",
                       "unbinding must give the user their key back")
        XCTAssertEqual(environment["MY_OWN_VAR"], "keep-me")
        XCTAssertNil(environment["ANTHROPIC_BASE_URL"])
    }

    /// The other half of the same rule: a key the *user* never had is ours, so
    /// removing it is the right undo — restoring from the backup must not turn
    /// into "leave every key we ever wrote behind".
    func testRevertRemovesManagedKeysTheUserNeverHad() throws {
        try FileManager.default.createDirectory(at: paths.claudeConfig, withIntermediateDirectories: true)
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        try #"{"env":{"MY_OWN_VAR":"keep-me"}}"#.write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )
        _ = try AgentConfigWriter.revert(agents: AgentRegistry.builtIns, paths: paths)

        let environment = try XCTUnwrap(try claudeSettings()["env"] as? [String: String])
        XCTAssertEqual(environment["MY_OWN_VAR"], "keep-me")
        for key in AgentConfigWriter.claudeEnvironmentKeys {
            XCTAssertNil(environment[key], "\(key) was ours and the user never had it")
        }
    }

    /// A `settings.json` we cannot parse is one we must not rewrite.
    ///
    /// The fallback used to be `?? [:]`, so a file carrying a comment — legal in
    /// JSONC, which is what people write by hand, and a hard parse failure for
    /// `JSONSerialization` — got the whole file replaced by an object holding
    /// only our keys. A backup existed; the live file did not.
    ///
    /// A *trailing comma* is deliberately not the fixture: `JSONSerialization`
    /// on macOS accepts one, so it would exercise nothing. `//` it rejects.
    func testUnparseableClaudeSettingsAreRefusedNotReplaced() throws {
        try FileManager.default.createDirectory(at: paths.claudeConfig, withIntermediateDirectories: true)
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        let original = "{\n  // keep this in sync with the team wiki\n"
            + "  \"permissions\": { \"allow\": [\"Bash(ls:*)\"] }\n}\n"
        try original.write(to: file, atomically: true, encoding: .utf8)

        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )

        XCTAssertEqual(reports.first { $0.agentID == "claude" }?.action, .refused)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original,
                       "the file must be left exactly as it was")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: file.appendingPathExtension("jxcode-backup").path),
            "a refusal must leave no trace, including a backup of a file we never touched"
        )
    }

    /// Valid JSON that is not an object is the same hazard by a different route:
    /// `as? [String: Any]` fails, and the old code would have written over it.
    func testClaudeSettingsThatAreNotAnObjectAreRefused() throws {
        try FileManager.default.createDirectory(at: paths.claudeConfig, withIntermediateDirectories: true)
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        let original = #"["not","an","object"]"#
        try original.write(to: file, atomically: true, encoding: .utf8)

        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )

        XCTAssertEqual(reports.first { $0.agentID == "claude" }?.action, .refused)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original)
    }

    /// An empty file is not an unparseable one. Treating it as a refusal would
    /// leave Claude Code unrouted for no reason at all.
    func testAnEmptyClaudeSettingsFileIsStillConfigured() throws {
        try FileManager.default.createDirectory(at: paths.claudeConfig, withIntermediateDirectories: true)
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        try "".write(to: file, atomically: true, encoding: .utf8)

        let reports = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "m"
        )

        XCTAssertEqual(reports.first { $0.agentID == "claude" }?.action, .merged)
        XCTAssertEqual(try XCTUnwrap(try claudeSettings()["env"] as? [String: String])["ANTHROPIC_BASE_URL"],
                       routerURL)
    }

    /// Unbinding gives the user their own Codex model setting back, live.
    ///
    /// The writer has to comment a conflicting top-level key out, because TOML
    /// forbids the duplicate. It only did half the job: revert removed our block
    /// and left the line commented, so a bind→unbind cycle permanently disabled
    /// the user's setting and Codex silently fell back to its default provider.
    func testUnbindingRestoresCommentedOutCodexKeys() throws {
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        let file = paths.codexHome.appendingPathComponent("config.toml")
        let original = "model = \"gpt-5\"\nmodel_provider = \"openai\"\napproval_policy = \"on-request\"\n"
        try original.write(to: file, atomically: true, encoding: .utf8)

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns, paths: paths, routerURL: routerURL, model: "local"
        )
        XCTAssertTrue(try codexConfig().contains(#"# model = "gpt-5""#),
                      "while bound the user's key has to be commented out or the file is invalid TOML")

        _ = try AgentConfigWriter.revert(agents: AgentRegistry.builtIns, paths: paths)

        XCTAssertEqual(
            try String(contentsOf: file, encoding: .utf8), original,
            "unbinding must leave the user's own keys live again, and the file as it was"
        )
    }

    /// The marker is the whole reason a user's own comment is safe: a line they
    /// commented out themselves never carries it, so it is never uncommented.
    func testRestoreLeavesTheUsersOwnCommentsAlone() {
        let text = "# model = \"gpt-5\"\n# a note of my own\n"
        XCTAssertEqual(AgentConfigWriter.restoreCommentedOutTopLevelKeys(in: text), text)
    }

    func testRestoreUncommentsExactlyWhatTheWriterCommented() {
        let written = "# model = \"gpt-5\"   " + AgentConfigWriter.supersededMarker
        XCTAssertEqual(
            AgentConfigWriter.restoreCommentedOutTopLevelKeys(in: written),
            #"model = "gpt-5""#
        )
    }

    /// A refusal wrote nothing, so it must not be counted as routed — the header
    /// would otherwise claim an agent is on the router while its config still
    /// names Anthropic's API.
    func testARefusedReportIsNotCountedAsRouted() {
        func report(_ action: AgentConfigWriter.Report.Action) -> AgentConfigWriter.Report {
            AgentConfigWriter.Report(
                agentID: "claude", agentName: "Claude Code", action: action, path: nil, notes: []
            )
        }
        XCTAssertTrue(report(.created).isRouted)
        XCTAssertTrue(report(.merged).isRouted)
        XCTAssertTrue(report(.unchanged).isRouted)
        XCTAssertTrue(report(.environmentOnly).isRouted)
        XCTAssertFalse(report(.refused).isRouted)
        XCTAssertFalse(report(.notApplicable).isRouted)
    }
}


// MARK: - Model name shown to Claude Code

final class ClaudeVisibleModelTests: XCTestCase {

    /// A recognised name must pass through untouched — rewriting it would
    /// change which model the user actually gets.
    func testRecognisedClaudeNamesPassThrough() {
        for name in ["claude-sonnet-4-5", "claude-opus-4-6", "claude-haiku-4-5",
                     "Claude-Sonnet-4-5", "anthropic/claude-haiku-4.5"] {
            XCTAssertEqual(AgentConfigWriter.claudeVisibleModel(name), name, "\(name)")
        }
    }

    /// Anything else becomes a name Claude Code recognises, because it warns
    /// `unrecognized_model` and assumes a 200k window otherwise.
    func testUnrecognisedNamesFallBackToAKnownClaudeName() {
        for name in ["fake-qwen3-coder", "meta/llama-3.3-70b-instruct", "gpt-4o",
                     "deepseek-v4-flash-free", "Qwen3.5-4B_Q8_0"] {
            let visible = AgentConfigWriter.claudeVisibleModel(name)
            XCTAssertTrue(visible.contains("claude"), "\(name) → \(visible)")
        }
    }

    /// The fallback has to be one the router maps back onto the real model.
    /// `resolveModel` rewrites any `claude*` request name, so the substituted
    /// name must keep that prefix or routing silently breaks.
    func testFallbackIsRoutable() {
        let visible = AgentConfigWriter.claudeVisibleModel("meta/llama-3.3-70b-instruct")
        XCTAssertTrue(visible.hasPrefix("claude"))
    }
}

// MARK: - Context window told to Claude Code

final class ClaudeContextWindowTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-ctx-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func env() throws -> [String: String] {
        let file = paths.claudeConfig.appendingPathComponent("settings.json")
        let dict = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        return try XCTUnwrap(dict?["env"] as? [String: String])
    }

    /// A local model's window is known from its GGUF metadata. Claude Code
    /// assumes 200k otherwise, which overflows a smaller model immediately.
    func testKnownContextIsWritten() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: "http://127.0.0.1:5255",
            model: "local-gguf",
            contextLength: 32_768
        )
        XCTAssertEqual(try env()["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "32768")
    }

    /// Unknown is not the same as 200k: the key must be absent, so Claude Code
    /// uses its own default rather than a number we invented.
    func testUnknownContextIsOmitted() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: "http://127.0.0.1:5255",
            model: "remote-model"
        )
        XCTAssertNil(try env()["CLAUDE_CODE_MAX_CONTEXT_TOKENS"])
    }

    /// Switching from a local model to a remote one has to retract the limit —
    /// a stale window from the previous model would be worse than none.
    func testStaleContextIsRetractedOnRebind() throws {
        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: "http://127.0.0.1:5255",
            model: "local-gguf",
            contextLength: 32_768
        )
        XCTAssertEqual(try env()["CLAUDE_CODE_MAX_CONTEXT_TOKENS"], "32768")

        _ = try AgentConfigWriter.apply(
            agents: AgentRegistry.builtIns,
            paths: paths,
            routerURL: "http://127.0.0.1:5255",
            model: "remote-model"
        )
        XCTAssertNil(
            try env()["CLAUDE_CODE_MAX_CONTEXT_TOKENS"],
            "the previous model's limit must not linger"
        )
    }
}
