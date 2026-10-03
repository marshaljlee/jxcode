import XCTest
@testable import JXCodeCore

/// One definition, four configs, no secret in any of them.
///
/// The rule this file exists for is a single sentence — a connector *names* its
/// secret and never holds it — and almost everything here is one of the two
/// ways that can be got wrong. The first is writing the value down, which is
/// what `writeConnector` and `ConnectorBinder` both refuse. The second is
/// writing the *name* in a spelling the agent does not expand, which is worse
/// than the first in one specific way: it looks correct in every file, and the
/// failure arrives later as an authentication error at an MCP server.
final class CredentialReferenceTests: XCTestCase {

    private var root: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("jxcode-credentials-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func stdioConnector(
        id: String = "github",
        environment: [String: String]
    ) -> Connector {
        Connector(
            id: id,
            name: id,
            transport: .stdio,
            command: "npx",
            arguments: ["-y", "@modelcontextprotocol/server-github"],
            environment: environment
        )
    }

    private func remoteConnector(
        id: String = "acme",
        headers: [String: String]
    ) -> Connector {
        Connector(
            id: id,
            name: id,
            transport: .http,
            url: "https://acme.example.com/mcp",
            headers: headers
        )
    }

    private func json(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Write a connector's file the way the store does.
    ///
    /// The date strategy is the whole reason this is not a one-liner. The store
    /// reads with `.iso8601`; a default `JSONEncoder` writes a bare number for
    /// `Date`, and the decoder then fails on the *whole* record and returns
    /// `nil` — so the fixture is silently absent rather than obviously broken.
    private func write(_ connector: Connector, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(connector)
            .write(to: directory.appendingPathComponent("connector.json"))
    }

    /// Every file under the sandbox root, as bytes.
    private func everyFile() throws -> [(path: String, text: String)] {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let url = enumerator?.nextObject() as? URL {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append((url.path, text))
        }
        return out
    }

    // MARK: - Naming a secret

    /// The whole point of two accepted forms is that they mean the same thing.
    func testBothAcceptedFormsNameTheSameVariable() {
        let braced = CredentialReference.names(in: "${GITHUB_TOKEN}")
        let opencode = CredentialReference.names(in: "{env:GITHUB_TOKEN}")

        XCTAssertEqual(braced, ["GITHUB_TOKEN"])
        XCTAssertEqual(opencode, braced, "the two spellings have to mean the same variable")
    }

    /// A bare `$NAME` is prose as often as it is a reference, so it is neither
    /// accepted nor rewritten — and the message that refuses a literal says
    /// which form to write instead.
    func testABareDollarNameIsNotAReference() {
        for value in ["$GITHUB_TOKEN", "Bearer $GITHUB_TOKEN", "Costs $USD per call"] {
            XCTAssertTrue(
                CredentialReference.names(in: value).isEmpty,
                "\(value) was read as a reference"
            )
            XCTAssertEqual(
                CredentialReference.rewrite(value, to: .opencode), value,
                "a value with no reference in it must come back unchanged"
            )
        }
    }

    /// A header is usually mostly literal, so the reference is found inside a
    /// larger value and the rest of it survives the rewrite.
    func testAReferenceInsideALargerValueKeepsEverythingAroundIt() {
        XCTAssertEqual(
            CredentialReference.rewrite("Bearer ${ACME_TOKEN}", to: .opencode),
            "Bearer {env:ACME_TOKEN}"
        )
        XCTAssertEqual(
            CredentialReference.rewrite("Bearer {env:ACME_TOKEN}", to: .shell),
            "Bearer ${ACME_TOKEN}"
        )
    }

    /// A name that the shell would not accept is not a reference. Each of these
    /// is a way for a *literal* to be mistaken for one, and a literal that is
    /// mistaken for a reference is a literal that gets translated and never
    /// refused.
    func testANameThatCouldNotBeAVariableIsNotAReference() {
        for value in ["${}", "${a b}", "${1TOKEN}", "${A-B}", "${A.B}", "{env:}"] {
            XCTAssertTrue(
                CredentialReference.names(in: value).isEmpty,
                "\(value) was read as a reference"
            )
        }
    }

    /// The suggested name goes straight into a message a user acts on, so it
    /// has to be one the parser would accept back. `2fa-token` is the case that
    /// makes this worth asserting: the mechanical mapping produces a name
    /// starting with a digit, which is not a variable name at all.
    func testASuggestedNameIsAlwaysAValidReference() {
        let keys = ["GITHUB_TOKEN", "Authorization", "api-key", "2fa-token", "X", "…", "a b c"]

        for key in keys {
            let suggestion = CredentialReference.suggestedVariableName(for: key)
            XCTAssertTrue(
                CredentialReference.isValidName(suggestion),
                "`\(key)` suggested `\(suggestion)`, which is not a name"
            )
            XCTAssertTrue(CredentialReference.isReference("${\(suggestion)}"))
        }
    }

    // MARK: - Catching the literal

    /// The shape is enough on its own. A GitHub token is a GitHub token whatever
    /// the key it was filed under is called.
    func testASecretShapeIsCaughtWhateverTheKeyIsCalled() {
        for value in [
            "ghp_" + String(repeating: "a", count: 36),
            "sk-" + String(repeating: "b", count: 20),
            "AKIA" + String(repeating: "C", count: 16),
        ] {
            XCTAssertTrue(
                CredentialScan.looksLikeLiteralCredential(key: "harmless", value: value),
                "\(value.prefix(12))… was not caught by its shape"
            )
        }
    }

    /// The other half: an ordinary-looking value under a key that is asking to
    /// hold a credential.
    func testAnOrdinaryValueUnderACredentialKeyIsCaught() {
        let token = String(repeating: "9f3a2b1c", count: 5)

        XCTAssertTrue(
            CredentialScan.looksLikeLiteralCredential(key: "Authorization", value: "Bearer \(token)")
        )
        XCTAssertTrue(
            CredentialScan.looksLikeLiteralCredential(key: "api-key", value: token)
        )
    }

    /// The negative controls. Each of these is something a person writes on
    /// purpose, and a rule that flagged them would be turned off within a day.
    func testWhatIsNotACredential() {
        let cases: [(key: String, value: String)] = [
            ("BROWSER", "chromium"),
            ("LOG_LEVEL", "debug"),
            ("Authorization", "Bearer your-token-here"),
            ("Authorization", "Bearer <token>"),
            ("Authorization", "Bearer administrator"),
            ("api_key", "sk-short"),
            ("token", "changeme"),
            ("Authorization", "Bearer " + String(repeating: "a", count: 40) + " placeholder"),
        ]

        for (key, value) in cases {
            XCTAssertFalse(
                CredentialScan.looksLikeLiteralCredential(key: key, value: value),
                "`\(key): \(value)` was refused, and it is not a secret"
            )
        }
    }

    /// **The one place this rule is not a literal port of the upstream one.**
    ///
    /// Claude Code exempts a value containing `${…}` and nothing else, because
    /// `${…}` is the only form it expands. opencode's form is `{env:…}`, which
    /// passes every one of the upstream rule's numeric gates — it is over 20
    /// characters, contains no whitespace, and carries more than 3 bits per
    /// character — so a faithful port refuses opencode's own way of naming a
    /// secret. The gates are asserted here rather than described, so that
    /// removing the widened exemption fails this test instead of quietly
    /// refusing every referenced opencode connector.
    func testOpencodeSReferenceFormPassesTheGatesAndIsStillExempt() {
        let value = "{env:MY_LONG_VARIABLE_NAME}"

        XCTAssertGreaterThanOrEqual(value.count, CredentialScan.minimumLength)
        XCTAssertFalse(value.contains { $0.isWhitespace })
        XCTAssertGreaterThanOrEqual(CredentialScan.entropy(value), CredentialScan.minimumEntropy)

        XCTAssertFalse(
            CredentialScan.looksLikeLiteralCredential(key: "Authorization", value: value),
            "opencode's own reference form was refused as a literal credential"
        )
        XCTAssertFalse(
            CredentialScan.looksLikeLiteralCredential(
                key: "Authorization", value: "Bearer \(value)"
            )
        )
    }

    /// Ordered so a refusal reads the same twice.
    ///
    /// The values have to be high-entropy on purpose. A 40-character run of one
    /// letter is under the rule's entropy floor, which is the rule working: a
    /// repeated pattern is not a token, and a check that flagged it would flag
    /// every padded placeholder anyone ever typed.
    func testFindingsAreOrderedSoTwoRunsAgree() {
        let findings = CredentialScan.findings(
            environment: ["Z_TOKEN": "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5b",
                          "A_TOKEN": "qW8eR2tY6uI0oP4aS8dF2gH6jK0lZ4xC8vB2n"],
            headers: ["Authorization": "Bearer mN7bV1cX5zL9kJ3hG7fD1sA5pO9iU3yT7rE1w"]
        )

        XCTAssertEqual(findings.count, 3)
        XCTAssertEqual(findings.map(\.field), [.environment, .environment, .headers])
        XCTAssertEqual(findings.map(\.key), ["A_TOKEN", "Z_TOKEN", "Authorization"])
    }

    // MARK: - The front door

    func testAConnectorHoldingASecretIsRefusedAndNothingIsWritten() throws {
        let store = SharedStore(paths: paths)
        let connector = stdioConnector(environment: [
            "GITHUB_TOKEN": "ghp_" + String(repeating: "a", count: 36)
        ])

        XCTAssertThrowsError(try store.writeConnector(connector)) { error in
            let described = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(described.contains("environment.GITHUB_TOKEN"), described)
            XCTAssertTrue(described.contains("${GITHUB_TOKEN}"), described)
        }

        // Nothing on disk, and no empty directory left behind for
        // `loadConnectors` to skip and `removeConnector` never to find.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: paths.sharedConnectors.appendingPathComponent("github").path
            ),
            "a refused connector left a directory behind"
        )
        XCTAssertTrue(SharedStore(paths: paths).connectors.isEmpty)
    }

    /// The escape hatch, and it has to stay open. A definition can already hold
    /// a secret — written by an older JXCode, or edited by hand — and the switch
    /// that turns it off must keep working, or the row offers an action that
    /// throws.
    func testAConnectorThatAlreadyHoldsASecretCanStillBeSwitchedOff() throws {
        let connector = stdioConnector(id: "legacy", environment: [
            "API_KEY": "sk-" + String(repeating: "b", count: 24)
        ])
        try write(
            connector,
            to: paths.sharedConnectors.appendingPathComponent("legacy")
        )

        let store = SharedStore(paths: paths)
        let loaded = try XCTUnwrap(store.connectors.first, "the fixture did not load")
        XCTAssertEqual(store.connectors.count, 1)
        XCTAssertEqual(loaded.inlinedCredentials.count, 1)

        XCTAssertNoThrow(try store.setConnectorEnabled(id: "legacy", enabled: false))
        XCTAssertEqual(store.connectors.first?.enabled, false)

        // And re-registering it is still refused, so switching it off is not a
        // way to launder it back in.
        let switchedOff = try XCTUnwrap(store.connectors.first)
        XCTAssertThrowsError(try store.writeConnector(switchedOff))
    }

    // MARK: - Four configs

    /// The translation table, asserted against the files rather than against
    /// the entry functions — the entry functions are what the files come from,
    /// and a test that read them would agree with itself.
    func testOneDefinitionBecomesFourDifferentSpellings() throws {
        let store = SharedStore(paths: paths)
        try store.writeConnector(stdioConnector(environment: ["GITHUB_TOKEN": "${GITHUB_TOKEN}"]))
        try store.writeConnector(remoteConnector(headers: ["Authorization": "Bearer ${ACME_TOKEN}"]))

        _ = try ConnectorBinder.apply(
            connectors: store.connectors, agents: AgentRegistry.builtIns, paths: paths
        )

        let claude = try json(at: paths.claudeMCPFile)["mcpServers"] as? [String: Any]
        let claudeGithub = try XCTUnwrap(claude?["github"] as? [String: Any])
        XCTAssertEqual(
            (claudeGithub["env"] as? [String: String])?["GITHUB_TOKEN"], "${GITHUB_TOKEN}"
        )
        XCTAssertEqual(
            ((claude?["acme"] as? [String: Any])?["headers"] as? [String: String])?["Authorization"],
            "Bearer ${ACME_TOKEN}"
        )

        let gemini = try json(at: paths.geminiSettings)["mcpServers"] as? [String: Any]
        XCTAssertEqual(
            ((gemini?["github"] as? [String: Any])?["env"] as? [String: String])?["GITHUB_TOKEN"],
            "${GITHUB_TOKEN}"
        )

        let opencode = try json(at: paths.opencodeConfig)["mcp"] as? [String: Any]
        XCTAssertEqual(
            ((opencode?["github"] as? [String: Any])?["environment"] as? [String: String])?["GITHUB_TOKEN"],
            "{env:GITHUB_TOKEN}",
            "opencode does not substitute the shell form, so the shell form must not be written"
        )
        XCTAssertEqual(
            ((opencode?["acme"] as? [String: Any])?["headers"] as? [String: String])?["Authorization"],
            "Bearer {env:ACME_TOKEN}"
        )

        // Codex has no expansion at all, so the key is left out rather than
        // written in any spelling.
        let toml = try String(contentsOf: paths.codexMCPFile, encoding: .utf8)
        XCTAssertTrue(toml.contains("[mcp_servers.github]"), toml)
        XCTAssertFalse(toml.contains("GITHUB_TOKEN"), "TOML cannot expand, so it must not name it")
    }

    /// **The invariant.** A reference is a name, and binding must never turn a
    /// name into the value it stands for. A "helpful" implementation that
    /// resolved `${GITHUB_TOKEN}` while writing the config would produce a
    /// correct-looking file in which the secret is now in four places — so the
    /// variable is set to a sentinel and every file under the sandbox is read
    /// back.
    func testTheValueBehindAReferenceNeverReachesAConfigFile() throws {
        let sentinel = "SENTINEL_DO_NOT_LEAK_9f3a2b1c"
        setenv("JXCODE_TEST_TOKEN", sentinel, 1)
        defer { unsetenv("JXCODE_TEST_TOKEN") }

        let store = SharedStore(paths: paths)
        try store.writeConnector(stdioConnector(environment: ["JXCODE_TEST_TOKEN": "${JXCODE_TEST_TOKEN}"]))
        try store.writeConnector(remoteConnector(headers: ["Authorization": "Bearer ${JXCODE_TEST_TOKEN}"]))

        _ = try ConnectorBinder.apply(
            connectors: store.connectors, agents: AgentRegistry.builtIns, paths: paths
        )

        let files = try everyFile()
        XCTAssertGreaterThan(files.count, 4, "the bind did not write enough to be evidence")
        let leaks = files.filter { $0.text.contains(sentinel) }
        XCTAssertEqual(
            leaks.count, 0,
            "the value reached: \(leaks.map(\.path).joined(separator: ", "))"
        )
    }

    /// The manifest is the one agent-neutral description, so it keeps the
    /// canonical spelling — not whichever agent happened to be bound last.
    func testTheManifestKeepsTheCanonicalSpelling() throws {
        let store = SharedStore(paths: paths)
        try store.writeConnector(stdioConnector(environment: ["GITHUB_TOKEN": "${GITHUB_TOKEN}"]))

        _ = try ConnectorBinder.apply(
            connectors: store.connectors, agents: AgentRegistry.builtIns, paths: paths
        )

        let manifest = ConnectorBinder.readManifest(paths: paths)
        XCTAssertEqual(manifest.mcpServers["github"]?.env?["GITHUB_TOKEN"], "${GITHUB_TOKEN}")
    }

    /// A reference one agent cannot carry is a refusal for that agent alone.
    /// Gemini expands references in its `env` block and documents none for
    /// `headers`, so the remote connector is refused there and the local one
    /// still lands — which is the difference between a refusal and a failure.
    func testGeminiRefusesOnlyTheConnectorWhoseHeaderIsAReference() throws {
        let store = SharedStore(paths: paths)
        try store.writeConnector(stdioConnector(environment: ["GITHUB_TOKEN": "${GITHUB_TOKEN}"]))
        try store.writeConnector(remoteConnector(headers: ["Authorization": "Bearer ${ACME_TOKEN}"]))

        let reports = try ConnectorBinder.apply(
            connectors: store.connectors, agents: AgentRegistry.builtIns, paths: paths
        )

        let refused = reports.filter { $0.action == .refused }
        XCTAssertEqual(refused.count, 1, "\(refused.map(\.summary))")
        XCTAssertEqual(refused.first?.agentID, "gemini.acme")
        XCTAssertEqual(reports.first { $0.agentID == "gemini" }?.action, .bound)

        let gemini = try json(at: paths.geminiSettings)["mcpServers"] as? [String: Any]
        XCTAssertEqual(gemini?.keys.sorted(), ["github"])

        // Every other agent takes both.
        for id in ["claude", "opencode", "codex"] {
            XCTAssertEqual(
                reports.first { $0.agentID == id }?.action, .bound,
                "\(id) should still have been given both connectors"
            )
        }
    }

    /// Codex is told what it did not get. Both omissions are silent from
    /// Codex's side, and both are diagnosed later as "the server has no auth".
    func testCodexSaysWhatItLeftOut() throws {
        let store = SharedStore(paths: paths)
        try store.writeConnector(stdioConnector(environment: ["GITHUB_TOKEN": "${GITHUB_TOKEN}"]))
        try store.writeConnector(remoteConnector(headers: ["Authorization": "Bearer ${ACME_TOKEN}"]))

        let reports = try ConnectorBinder.apply(
            connectors: store.connectors, agents: AgentRegistry.builtIns, paths: paths
        )

        let notes = try XCTUnwrap(reports.first { $0.agentID == "codex" }?.notes
            .joined(separator: " "))
        XCTAssertTrue(notes.contains("GITHUB_TOKEN"), notes)
        XCTAssertTrue(notes.contains("headers"), notes)
    }

    /// A connector that starts holding a secret *after* it was bound has to
    /// leave the configs it was bound into. The manifest still names it, so the
    /// refusal has to run the removal rather than skip the agent.
    func testARefusedConnectorIsAlsoRemovedFromWhereItWasBound() throws {
        let store = SharedStore(paths: paths)
        try store.writeConnector(remoteConnector(headers: ["Authorization": "Bearer ${ACME_TOKEN}"]))
        _ = try ConnectorBinder.apply(
            connectors: store.connectors, agents: AgentRegistry.builtIns, paths: paths
        )

        let bound = try json(at: paths.claudeMCPFile)["mcpServers"] as? [String: Any]
        XCTAssertEqual(bound?.keys.sorted(), ["acme"], "the fixture did not bind")

        // The same definition, edited by hand to hold the value instead.
        var edited = try XCTUnwrap(store.connectors.first)
        edited.headers["Authorization"] = "Bearer ghp_" + String(repeating: "a", count: 36)
        try write(edited, to: paths.sharedConnectors.appendingPathComponent("acme"))

        let reports = try ConnectorBinder.apply(
            connectors: [edited], agents: AgentRegistry.builtIns, paths: paths
        )

        XCTAssertEqual(reports.filter { $0.action == .refused }.count, 1)

        // Stated as "nothing still lists it" rather than "the file is empty",
        // which is the same rule `testRevertRemovesTheBlockFromEveryAgent`
        // follows and for the same reason: the file held nothing but our own
        // entry, so the removal takes the file with it, and an assertion that
        // read it would fail on a correct implementation.
        let after = FileManager.default.fileExists(atPath: paths.claudeMCPFile.path)
            ? try json(at: paths.claudeMCPFile)["mcpServers"] as? [String: Any]
            : nil
        XCTAssertEqual(
            after?.keys.sorted() ?? [], [],
            "the entry holding a secret is still in Claude Code's config"
        )
    }
}
