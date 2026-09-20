import XCTest
@testable import JXCodeCore

/// A registered backend's context window.
///
/// The window decides whether an agent's first turn fits at all. Claude Code
/// assumes 200k for any model it does not recognise — which is every local one
/// — so a backend that knows better has to say so, and the answer has to
/// survive being written to disk and read back by a later launch.
final class ProviderContextTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-provider-ctx-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var paths: SandboxPaths { SandboxPaths(root: root) }

    /// The window has to reach the bind, which runs in a fresh process for
    /// `jxcode bind` and in a different pane for the app.
    func testContextLengthRoundTripsThroughTheStore() throws {
        let store = ProviderStore(paths: paths)
        try store.add(Provider(
            name: "MiniCPM (local)",
            kind: .localGGUF,
            baseURL: "http://127.0.0.1:8080",
            models: ["MiniCPM5-2B.gguf"],
            contextLength: 32_768
        ))

        let reloaded = ProviderStore(paths: paths)
        XCTAssertEqual(reloaded.providers.first?.contextLength, 32_768)
    }

    /// A providers.json written before this field existed must still load.
    ///
    /// Optional properties decode with `decodeIfPresent`, so the missing key
    /// becomes nil rather than throwing over the whole file. Losing every
    /// registered backend on upgrade would be far worse than losing one number.
    func testAFileWithoutTheFieldStillDecodes() throws {
        let legacy = """
        [
          {
            "id" : "6FAEC08E-9BC9-4D65-8D3D-E6FA77D1BF6C",
            "name" : "Legacy",
            "kind" : "openAICompatible",
            "baseURL" : "https://example.invalid/v1",
            "models" : []
          }
        ]
        """
        try FileManager.default.createDirectory(
            at: paths.state, withIntermediateDirectories: true
        )
        try Data(legacy.utf8).write(to: paths.providersFile)

        let store = ProviderStore(paths: paths)
        XCTAssertEqual(store.providers.count, 1)
        XCTAssertNil(
            store.providers.first?.contextLength,
            "an absent window is unknown, not zero — zero would cap the agent at nothing"
        )
    }

    /// Re-registering the same backend replaces the window rather than keeping
    /// a stale one from the previous model on that port.
    func testReRegisteringReplacesTheWindow() throws {
        let store = ProviderStore(paths: paths)
        try store.add(Provider(
            name: "Old", kind: .localGGUF, baseURL: "http://127.0.0.1:8080", contextLength: 8192
        ))
        try store.add(Provider(
            name: "New", kind: .localGGUF, baseURL: "http://127.0.0.1:8080", contextLength: 65_536
        ))

        let reloaded = ProviderStore(paths: paths)
        XCTAssertEqual(reloaded.providers.count, 1, "same URL and kind is the same backend")
        XCTAssertEqual(reloaded.providers.first?.contextLength, 65_536)
    }

    /// A remote backend with no known window must report none, not a guess.
    ///
    /// The bind only writes the cap when there is one, so nil means "let the
    /// agent assume its own default" — correct for a hosted model, and the
    /// reason a local backend must not fall back to a remote one's value.
    func testAnUnknownWindowIsAbsent() throws {
        let provider = Provider(name: "Remote", kind: .openAICompatible, baseURL: "https://api.example.com")
        XCTAssertNil(provider.contextLength)
        // Unrelated to the window, but it pins that adding the field did not
        // disturb how a remote backend is addressed.
        XCTAssertEqual(provider.normalizedBaseURL, "https://api.example.com/v1")
    }
}
