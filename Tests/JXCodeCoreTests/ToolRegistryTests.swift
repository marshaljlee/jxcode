import XCTest
@testable import JXCodeCore

/// The dashboard's tool list, and the catalogs behind it.
///
/// The registry exists because the tool list was a `let` — correct while it was
/// a constant, and the reason "add a tool" had no implementation at all. What is
/// worth pinning is the same thing `AgentRegistry` had to learn the hard way:
/// `saveCustom()` writes only the non-built-in entries, so an entry that claims
/// to be built in is dropped on the next write and the tool disappears on
/// relaunch, with the add having appeared to succeed.
final class ToolRegistryTests: XCTestCase {

    private var base: URL!
    private var paths: SandboxPaths!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("jxcode-toolregistry-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        paths = SandboxPaths(root: base)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func tool(_ id: String, builtIn: Bool = true) -> ToolDefinition {
        ToolDefinition(
            id: id,
            name: id.capitalized,
            binary: id,
            tagline: "a test tool",
            installCommand: nil,
            isBuiltIn: builtIn
        )
    }

    // MARK: - The list

    func testAFreshRegistryIsTheBuiltInCatalog() {
        let registry = ToolRegistry(paths: paths)
        XCTAssertEqual(registry.tools.map(\.id), ToolCatalog.builtIns.map(\.id))
    }

    func testAnAddedToolSurvivesAReload() throws {
        try ToolRegistry(paths: paths).add(tool("mycli", builtIn: false))

        let reloaded = ToolRegistry(paths: paths)
        XCTAssertEqual(reloaded.tools.map(\.id).last, "mycli")
        XCTAssertTrue(reloaded.isCustom(id: "mycli"))
    }

    /// The rule the agent registry needed a comment to explain: an entry added
    /// through `add` is custom by definition, whatever the caller passed. A
    /// caller relying on the initialiser's default of `true` would write an
    /// empty array to disk and the tool would be gone on the next launch.
    func testAddingForcesTheEntryToBeCustomEvenIfTheCallerSaysOtherwise() throws {
        try ToolRegistry(paths: paths).add(tool("mycli", builtIn: true))

        let reloaded = ToolRegistry(paths: paths)
        XCTAssertTrue(reloaded.isCustom(id: "mycli"))

        let onDisk = try JSONDecoder().decode(
            [ToolDefinition].self,
            from: Data(contentsOf: paths.toolsFile)
        )
        XCTAssertEqual(onDisk.map(\.id), ["mycli"],
                       "the file holds only the entries the user added")
    }

    func testAddingIsIdempotentOnTheID() throws {
        let registry = ToolRegistry(paths: paths)
        try registry.add(tool("mycli", builtIn: false))
        try registry.add(ToolDefinition(
            id: "mycli", name: "My CLI", binary: "mycli", tagline: "updated"
        ))

        XCTAssertEqual(registry.tools.filter { $0.id == "mycli" }.count, 1)
        XCTAssertEqual(registry.tools.first { $0.id == "mycli" }?.tagline, "updated")
    }

    // MARK: - Removing

    func testRemovingAToolYouAddedWorksAndPersists() throws {
        let registry = ToolRegistry(paths: paths)
        try registry.add(tool("mycli", builtIn: false))

        XCTAssertTrue(try registry.remove(id: "mycli"))
        XCTAssertFalse(registry.tools.contains { $0.id == "mycli" })
        XCTAssertFalse(ToolRegistry(paths: paths).tools.contains { $0.id == "mycli" })
    }

    /// A built-in cannot be removed, because it is not in `tools.json` to begin
    /// with — deleting it would look like it worked and it would be back on the
    /// next launch.
    func testRemovingABuiltInIsRefusedAndChangesNothing() throws {
        let registry = ToolRegistry(paths: paths)
        let builtInID = ToolCatalog.builtIns[0].id

        XCTAssertFalse(try registry.remove(id: builtInID))
        XCTAssertTrue(registry.tools.contains { $0.id == builtInID })
    }

    func testRemovingSomethingThatIsNotThereIsRefused() throws {
        XCTAssertFalse(try ToolRegistry(paths: paths).remove(id: "never-existed"))
    }

    // MARK: - Reading a file written by an older version

    /// The two fields that arrived after the type did. The synthesised decoder
    /// would throw on both, and a throw here is a user's tool list disappearing
    /// with no explanation.
    func testAnEntryWithoutTheNewerFieldsStillDecodes() throws {
        let json = """
        [{"id":"mycli","name":"My CLI","binary":"mycli","tagline":"older"}]
        """
        try fm.createDirectory(at: paths.state, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: paths.toolsFile)

        let registry = ToolRegistry(paths: paths)
        let loaded = registry.tools.first { $0.id == "mycli" }
        XCTAssertNotNil(loaded)
        XCTAssertNil(loaded?.installCommand)
        XCTAssertEqual(loaded?.arguments, [])
        XCTAssertTrue(registry.isCustom(id: "mycli"),
                      "an entry with no isBuiltIn is a user's, not the catalog's")
    }

    func testACorruptFileLeavesTheBuiltInsAlone() throws {
        try fm.createDirectory(at: paths.state, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: paths.toolsFile)

        XCTAssertEqual(ToolRegistry(paths: paths).tools.map(\.id),
                       ToolCatalog.builtIns.map(\.id))
    }

    // MARK: - Slugs

    func testASlugIsUsableAsAnIDAndAFileName() {
        let slug = ToolRegistry.slug(for: "My Fancy CLI 2.0")
        XCTAssertFalse(slug.isEmpty)
        XCTAssertFalse(slug.contains(" "))
        XCTAssertFalse(slug.contains("/"))
    }

    // MARK: - The catalog

    func testTheCatalogIsWellFormed() {
        var seen = Set<String>()
        for tool in ToolCatalog.discoverable {
            XCTAssertTrue(seen.insert(tool.id).inserted, "\(tool.id) is listed twice")
            XCTAssertFalse(tool.binary.isEmpty, "\(tool.id) has no binary to look for")
            XCTAssertFalse(tool.tagline.isEmpty, "\(tool.id) has no tagline for its card")
        }
    }

    /// The rule `ToolCatalogTests` pins for the built-ins, which has to hold for
    /// the catalog too: a binary containing a slash is resolved as a *path* and
    /// would bypass the sandbox `PATH` search the locator is built on.
    func testEveryCatalogBinaryIsABareNameNotAPath() {
        for tool in ToolCatalog.discoverable {
            XCTAssertFalse(tool.binary.contains("/"),
                           "\(tool.id) should name a binary, not a location")
        }
    }

    func testTheCatalogDoesNotRepeatTheBuiltIns() {
        let builtIn = Set(ToolCatalog.builtIns.map(\.id))
        for tool in ToolCatalog.discoverable {
            XCTAssertFalse(builtIn.contains(tool.id),
                           "\(tool.id) is already on the dashboard")
        }
    }

    func testSuggestionsExcludeWhatIsAlreadyListed() {
        let current = [tool("herdr"), tool("mycli")]
        let suggestions = ToolCatalog.suggestions(absentFrom: current)

        XCTAssertFalse(suggestions.contains { $0.id == "herdr" })
        XCTAssertFalse(suggestions.contains { $0.id == "mycli" })
        XCTAssertEqual(suggestions.count, ToolCatalog.discoverable.count)
    }

    /// Hermes is the case that prompted the catalog, so it gets its own check.
    /// It is a bare `hermes` on `PATH` with no npm install — the shape a tool
    /// catalog entry has, not an agent's.
    func testHermesIsOfferedAsATool() {
        let hermes = ToolCatalog.discoverable.first { $0.id == "hermes" }
        XCTAssertNotNil(hermes)
        XCTAssertEqual(hermes?.binary, "hermes")
    }
}

/// The agent catalog, which the launcher offers from the same sheet.
final class AgentCatalogTests: XCTestCase {

    func testTheCatalogIsWellFormed() {
        var seen = Set<String>()
        for agent in AgentCatalog.discoverable {
            XCTAssertTrue(seen.insert(agent.id).inserted, "\(agent.id) is listed twice")
            XCTAssertFalse(agent.command.isEmpty, "\(agent.id) has no command")
            XCTAssertNotNil(agent.tagline, "\(agent.id) has nothing to put on its card")
        }
    }

    /// An agent is installed *into* the sandbox, so a catalog entry without an
    /// install command is one that can only ever fail — the launcher would offer
    /// it, the click would try to install it, and there would be nothing to run.
    func testEveryCatalogAgentCanActuallyBeInstalled() {
        for agent in AgentCatalog.discoverable {
            XCTAssertNotNil(agent.installCommand,
                            "\(agent.id) cannot be installed, so its card could never work")
        }
    }

    /// Same rule as the tools: an install that writes to a path of its own
    /// choosing escapes the sandbox, which is the one thing the app exists to
    /// prevent.
    func testNoCatalogAgentInstallsThroughACurlPipe() {
        for agent in AgentCatalog.discoverable {
            let install = agent.installCommand ?? ""
            XCTAssertFalse(install.contains("| sh") || install.contains("| bash"),
                           "\(agent.id) would install outside the sandbox")
        }
    }

    func testSuggestionsExcludeWhatIsAlreadyOffered() {
        let registry = AgentRegistry(paths: SandboxPaths(
            root: FileManager.default.temporaryDirectory
                .appendingPathComponent("jxcode-agentcatalog-\(UUID().uuidString)")
        ))
        let suggestions = AgentCatalog.suggestions(absentFrom: registry.agents)

        XCTAssertEqual(suggestions.count, AgentCatalog.discoverable.count,
                       "the built-in list does not overlap the catalog")
    }
}
