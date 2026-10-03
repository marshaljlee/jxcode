import XCTest
@testable import JXCodeCore

/// The environment policy a user may tune, and the parts of it they may not.
///
/// Every field in `SandboxConfiguration` is a lever on the isolation boundary,
/// so the tests that matter most are the refusals. A settings surface that lets
/// `HOME` be repointed is not a settings surface — it is a way to turn the app
/// off while it still looks like it is on.
final class SandboxConfigurationTests: XCTestCase {

    private var base: URL!
    private var paths: SandboxPaths!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("jxcode-sandboxconfig-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        paths = SandboxPaths(root: base)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - Refusals

    /// The one that would undo the whole app.
    func testHomeCannotBeRepointed() {
        XCTAssertThrowsError(try SandboxConfiguration.validate(key: "HOME", value: "/Users/someone")) {
            XCTAssertEqual($0 as? SandboxConfiguration.ValidationError, .reservedKey("HOME"))
        }
    }

    func testEverySandboxOwnedVariableIsRefused() {
        for key in ["PATH", "TMPDIR", "ZDOTDIR", "XDG_CONFIG_HOME", "CLAUDE_CONFIG_DIR",
                    "CODEX_HOME", "GEMINI_CONFIG_DIR", "npm_config_prefix", "HOMEBREW_PREFIX",
                    "ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY"] {
            XCTAssertThrowsError(
                try SandboxConfiguration.validate(key: key, value: "x"),
                "\(key) is set by the sandbox and must not be settable from a file"
            )
        }
    }

    /// An "extra path" into a host-wide tool directory is the same door the
    /// `includeHostLocalBin` toggle exists to keep shut.
    func testHostWideToolDirectoriesCannotBeAddedAsPathEntries() {
        for entry in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/local/sbin"] {
            XCTAssertThrowsError(
                try SandboxConfiguration.validate(pathEntry: entry),
                "\(entry) is a host-wide tool directory"
            )
        }
    }

    func testPathEntriesMustBeAbsolute() {
        XCTAssertThrowsError(try SandboxConfiguration.validate(pathEntry: "relative/bin")) {
            XCTAssertEqual($0 as? SandboxConfiguration.ValidationError, .notAbsolute("relative/bin"))
        }
    }

    func testEmptyValuesAndMalformedKeysAreRefused() {
        XCTAssertThrowsError(try SandboxConfiguration.validate(key: "", value: "x"))
        XCTAssertThrowsError(try SandboxConfiguration.validate(key: "has-dash", value: "x"))
        XCTAssertThrowsError(try SandboxConfiguration.validate(key: "GOOD", value: ""))
    }

    /// A path that merely *contains* a denied directory is fine — the check is
    /// on whole components, so a user's own `~/usr/local-ish` is not caught.
    func testOnlyWholeComponentsAreDenied() throws {
        XCTAssertNoThrow(try SandboxConfiguration.validate(pathEntry: "/opt/homebrewish/bin"))
        XCTAssertNoThrow(try SandboxConfiguration.validate(pathEntry: "/Users/me/bin"))
    }

    // MARK: - Round trip

    func testAFreshStoreIsTheDefault() {
        let store = SandboxConfigurationStore(paths: paths)
        XCTAssertEqual(store.configuration, .default)
        XCTAssertFalse(store.configuration.includeHostLocalBin)
    }

    func testValuesSurviveAReload() throws {
        let store = SandboxConfigurationStore(paths: paths)
        try store.set(key: "SSH_AUTH_SOCK", value: "/tmp/agent.sock")
        try store.addPathEntry("/Users/me/bin")

        let reloaded = SandboxConfigurationStore(paths: paths)
        XCTAssertEqual(reloaded.configuration.extraEnv["SSH_AUTH_SOCK"], "/tmp/agent.sock")
        XCTAssertEqual(reloaded.configuration.extraPathEntries, ["/Users/me/bin"])
    }

    func testPathEntriesAreNormalisedAndDeduplicated() throws {
        let store = SandboxConfigurationStore(paths: paths)
        try store.addPathEntry("/Users/me/bin")
        try store.addPathEntry("/Users/me/../me/bin")
        XCTAssertEqual(store.configuration.extraPathEntries, ["/Users/me/bin"])
    }

    /// Highest priority first, because that is what the list means to `PATH`.
    func testTheMostRecentlyAddedEntryWins() throws {
        let store = SandboxConfigurationStore(paths: paths)
        try store.addPathEntry("/Users/me/bin")
        try store.addPathEntry("/Users/me/other/bin")
        XCTAssertEqual(
            store.configuration.extraPathEntries,
            ["/Users/me/other/bin", "/Users/me/bin"]
        )
    }

    func testUnsettingReportsWhetherThereWasAnythingToUnset() throws {
        let store = SandboxConfigurationStore(paths: paths)
        try store.set(key: "FOO", value: "1")
        XCTAssertTrue(try store.unset(key: "FOO"))
        XCTAssertFalse(try store.unset(key: "FOO"))
    }

    /// A file written by an older build, under rules that no longer hold, is
    /// ignored rather than applied — otherwise the guardrails would only bind
    /// files written after the guardrails existed.
    func testAFileThatNoLongerValidatesFallsBackToTheDefault() throws {
        try fm.createDirectory(
            at: paths.sandboxConfigurationFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let hostile = #"{"includeHostLocalBin":false,"extraPathEntries":[],"extraEnv":{"HOME":"/Users/someone"}}"#
        try Data(hostile.utf8).write(to: paths.sandboxConfigurationFile)

        XCTAssertEqual(SandboxConfigurationStore(paths: paths).configuration, .default)
    }

    // MARK: - The seam to SandboxOptions

    /// The file owns three fields; routing owns two. Neither may clobber the
    /// other, which is the whole reason they are separate types.
    func testOptionsCarryBothTheUsersFieldsAndTheRouters() throws {
        let store = SandboxConfigurationStore(paths: paths)
        try store.set(key: "SSH_AUTH_SOCK", value: "/tmp/agent.sock")

        let options = store.configuration.options(
            routerURL: "http://127.0.0.1:62217",
            routerToken: "token"
        )
        XCTAssertEqual(options.extraEnv["SSH_AUTH_SOCK"], "/tmp/agent.sock")
        XCTAssertEqual(options.routerURL, "http://127.0.0.1:62217")
        XCTAssertEqual(options.routerToken, "token")
    }
}
