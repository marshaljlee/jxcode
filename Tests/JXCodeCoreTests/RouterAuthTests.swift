import XCTest
@testable import JXCodeCore

final class RouterAuthTests: XCTestCase {

    private let token = "sBqk3zP0mZ1vT7wR9yXc4nL6hJ2gF5dA8eU0iO3pQ7k"

    private var root: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxcode-routerauth-\(UUID().uuidString)")
        paths = SandboxPaths(root: root)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var enabled: RouterAuth {
        RouterAuth(isEnabled: true, token: token)
    }

    // MARK: - Accepted schemes

    func testXAPIKeyHeaderIsAccepted() {
        XCTAssertTrue(enabled.accepts(headers: ["x-api-key": token]))
    }

    func testBearerAuthorizationIsAccepted() {
        XCTAssertTrue(enabled.accepts(headers: ["Authorization": "Bearer \(token)"]))
    }

    /// HTTP field names are case-insensitive, and clients differ on how they
    /// spell both the name and the scheme word.
    func testHeaderNameAndSchemeWordAreCaseInsensitive() {
        XCTAssertTrue(enabled.accepts(headers: ["X-Api-Key": token]))
        XCTAssertTrue(enabled.accepts(headers: ["X-API-KEY": token]))
        XCTAssertTrue(enabled.accepts(headers: ["AUTHORIZATION": "bearer \(token)"]))
        XCTAssertTrue(enabled.accepts(headers: ["authorization": "BEARER \(token)"]))
        XCTAssertTrue(enabled.accepts(headers: ["Authorization": "BeArEr \(token)"]))
    }

    func testSurroundingWhitespaceIsTolerated() {
        XCTAssertTrue(enabled.accepts(headers: ["x-api-key": "  \(token)\t "]))
        XCTAssertTrue(enabled.accepts(headers: ["Authorization": "  Bearer   \(token)  "]))
    }

    func testEitherSchemeWorksWhenBothArePresent() {
        XCTAssertTrue(enabled.accepts(headers: [
            "Authorization": "Bearer \(token)",
            "x-api-key": token,
        ]))
        XCTAssertTrue(enabled.accepts(headers: [
            "Authorization": "Bearer wrong",
            "x-api-key": token,
        ]))
    }

    // MARK: - Rejections

    func testWrongTokenIsRejected() {
        XCTAssertFalse(enabled.accepts(headers: ["x-api-key": "not-the-token"]))
        XCTAssertFalse(enabled.accepts(headers: ["Authorization": "Bearer not-the-token"]))
    }

    func testMissingHeadersAreRejected() {
        XCTAssertFalse(enabled.accepts(headers: [:]))
        XCTAssertFalse(enabled.accepts(headers: ["Content-Type": "application/json"]))
    }

    func testEmptyHeaderValuesAreRejected() {
        XCTAssertFalse(enabled.accepts(headers: ["x-api-key": ""]))
        XCTAssertFalse(enabled.accepts(headers: ["x-api-key": "   "]))
        XCTAssertFalse(enabled.accepts(headers: ["Authorization": ""]))
        XCTAssertFalse(enabled.accepts(headers: ["Authorization": "Bearer"]))
        XCTAssertFalse(enabled.accepts(headers: ["Authorization": "Bearer "]))
    }

    /// A scheme that merely starts with `bearer` is not the bearer scheme.
    func testBearerPrefixedSchemeIsRejected() {
        XCTAssertFalse(enabled.accepts(headers: ["Authorization": "BearerX \(token)"]))
    }

    func testNonBearerAuthorizationSchemeIsRejected() {
        XCTAssertFalse(enabled.accepts(headers: ["Authorization": "Basic \(token)"]))
        XCTAssertFalse(enabled.accepts(headers: ["Authorization": token]))
    }

    // MARK: - Enabled / disabled semantics

    /// Auth is opt-in; the default must not lock the user out of their router.
    func testDisabledAcceptsEverythingIncludingNoHeaders() {
        let disabled = RouterAuth(isEnabled: false, token: token)
        XCTAssertTrue(disabled.accepts(headers: [:]))
        XCTAssertTrue(disabled.accepts(headers: ["x-api-key": "anything"]))
        XCTAssertTrue(RouterAuth().accepts(headers: [:]))
        XCTAssertTrue(RouterAuth().accepts(headers: ["Authorization": "Bearer garbage"]))
    }

    /// Enabled with no token is a misconfiguration and must fail closed.
    func testEnabledWithoutTokenFailsClosed() {
        let misconfigured = RouterAuth(isEnabled: true, token: nil)
        XCTAssertFalse(misconfigured.accepts(headers: [:]))
        XCTAssertFalse(misconfigured.accepts(headers: ["x-api-key": "anything"]))
        XCTAssertFalse(misconfigured.accepts(headers: ["Authorization": "Bearer anything"]))
    }

    func testEnabledWithEmptyTokenFailsClosed() {
        let misconfigured = RouterAuth(isEnabled: true, token: "")
        XCTAssertFalse(misconfigured.accepts(headers: [:]))
        XCTAssertFalse(misconfigured.accepts(headers: ["x-api-key": ""]))
        XCTAssertFalse(misconfigured.accepts(headers: ["x-api-key": "   "]))
        XCTAssertFalse(misconfigured.accepts(headers: ["Authorization": "Bearer "]))
    }

    // MARK: - Constant-time comparison

    func testConstantTimeComparisonIsCorrect() {
        XCTAssertTrue(RouterAuth.constantTimeEquals(token, token))
        XCTAssertTrue(RouterAuth.constantTimeEquals("", ""))
        XCTAssertTrue(RouterAuth.constantTimeEquals("a", "a"))

        // Same length, differs only in the last byte: the case an early-return
        // comparison is slowest on and therefore the one that leaks most.
        XCTAssertFalse(RouterAuth.constantTimeEquals("aaaa", "aaab"))
        XCTAssertFalse(RouterAuth.constantTimeEquals("baaa", "aaab"))
        XCTAssertFalse(RouterAuth.constantTimeEquals("b", "a"))

        // Different lengths, in both directions.
        XCTAssertFalse(RouterAuth.constantTimeEquals("", "a"))
        XCTAssertFalse(RouterAuth.constantTimeEquals("a", ""))
        XCTAssertFalse(RouterAuth.constantTimeEquals("short", "considerably-longer"))

        // A prefix of the token must not be accepted.
        let prefix = String(token.prefix(token.count - 1))
        XCTAssertFalse(RouterAuth.constantTimeEquals(prefix, token))
        XCTAssertFalse(enabled.accepts(headers: ["x-api-key": prefix]))
        XCTAssertFalse(enabled.accepts(headers: ["Authorization": "Bearer \(prefix)"]))
    }

    /// Non-ASCII input must be compared as bytes, not as characters.
    func testConstantTimeComparisonHandlesNonASCII() {
        XCTAssertTrue(RouterAuth.constantTimeEquals("caf\u{00E9}", "caf\u{00E9}"))
        XCTAssertFalse(RouterAuth.constantTimeEquals("caf\u{00E9}", "cafe"))
    }

    // MARK: - Token generation

    func testGenerateTokenIsNonEmptyAndDistinct() {
        var seen = Set<String>()
        for _ in 0..<200 {
            let generated = RouterAuth.generateToken()
            XCTAssertFalse(generated.isEmpty)
            seen.insert(generated)
        }
        XCTAssertEqual(seen.count, 200, "generated tokens collided")
    }

    /// `+`, `/` and `=` must not appear: they need escaping in JSON, TOML and a
    /// shell, so a token containing them corrupts the config file it is written
    /// into.
    func testGenerateTokenIsURLSafe() {
        for _ in 0..<200 {
            let generated = RouterAuth.generateToken()
            XCTAssertFalse(generated.contains("+"), generated)
            XCTAssertFalse(generated.contains("/"), generated)
            XCTAssertFalse(generated.contains("="), generated)
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
            XCTAssertTrue(generated.unicodeScalars.allSatisfy(allowed.contains), generated)
        }
    }

    func testGenerateTokenHonoursByteCount() {
        // 32 bytes is 44 base64 characters, one of which is dropped padding.
        XCTAssertEqual(RouterAuth.generateToken(byteCount: 32).count, 43)
        XCTAssertEqual(RouterAuth.generateToken(byteCount: 16).count, 22)
        XCTAssertFalse(RouterAuth.generateToken(byteCount: 0).isEmpty)
    }

    func testGeneratedTokenIsAcceptedByItsOwnAuth() {
        let generated = RouterAuth.generateToken()
        let auth = RouterAuth(isEnabled: true, token: generated)
        XCTAssertTrue(auth.accepts(headers: ["x-api-key": generated]))
        XCTAssertTrue(auth.accepts(headers: ["Authorization": "Bearer \(generated)"]))
        XCTAssertFalse(auth.accepts(headers: ["x-api-key": generated + "x"]))
    }

    // MARK: - Persistence

    func testSaveThenLoadRoundTrips() throws {
        let saved = RouterAuth(isEnabled: true, token: token)
        try saved.save(to: paths)

        let loaded = RouterAuth.load(from: paths)
        XCTAssertEqual(loaded, saved)
        XCTAssertTrue(loaded.accepts(headers: ["x-api-key": token]))
    }

    func testSaveThenLoadRoundTripsWhenDisabled() throws {
        let saved = RouterAuth(isEnabled: false, token: nil)
        try saved.save(to: paths)
        XCTAssertEqual(RouterAuth.load(from: paths), saved)
    }

    func testSavedFileIsOwnerOnly() throws {
        try RouterAuth(isEnabled: true, token: token).save(to: paths)

        let file = RouterAuth.fileURL(in: paths)
        XCTAssertEqual(file, paths.state.appendingPathComponent("router-auth.json"))

        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    func testSaveCreatesMissingStateDirectory() throws {
        let missing = SandboxPaths(root: root.appendingPathComponent("nested/deeper"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.state.path))

        try RouterAuth(isEnabled: true, token: token).save(to: missing)
        XCTAssertEqual(RouterAuth.load(from: missing).token, token)
    }

    func testSaveIsIdempotent() throws {
        let auth = RouterAuth(isEnabled: true, token: token)
        try auth.save(to: paths)
        try auth.save(to: paths)

        XCTAssertEqual(RouterAuth.load(from: paths), auth)

        let attributes = try FileManager.default.attributesOfItem(
            atPath: RouterAuth.fileURL(in: paths).path
        )
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    /// A missing file is the normal first-run state.
    func testLoadMissingFileReturnsDisabled() {
        XCTAssertEqual(RouterAuth.load(from: paths), RouterAuth())
        XCTAssertFalse(RouterAuth.load(from: paths).isEnabled)
    }

    /// A file truncated mid-write must not brick the app.
    func testLoadEmptyFileReturnsDisabled() throws {
        let file = RouterAuth.fileURL(in: paths)
        try Data().write(to: file)
        XCTAssertEqual(RouterAuth.load(from: paths), RouterAuth())
    }

    func testLoadGarbageFileReturnsDisabled() throws {
        let file = RouterAuth.fileURL(in: paths)

        for garbage in [
            "not json at all",
            "{\"isEnabled\": true",
            "[]",
            "null",
            "{\"isEnabled\": \"yes\", \"token\": 42}",
            "\u{0000}\u{0001}\u{0002}",
        ] {
            try Data(garbage.utf8).write(to: file)
            let loaded = RouterAuth.load(from: paths)
            XCTAssertFalse(loaded.isEnabled, "garbage decoded as enabled: \(garbage)")
            XCTAssertEqual(loaded, RouterAuth())
        }
    }

    /// Valid JSON with only a token decodes; `isEnabled` defaults to off rather
    /// than failing the whole decode.
    func testLoadPartialJSONDefaultsToDisabled() throws {
        let file = RouterAuth.fileURL(in: paths)
        try Data("{\"token\": \"\(token)\"}".utf8).write(to: file)

        let loaded = RouterAuth.load(from: paths)
        XCTAssertFalse(loaded.isEnabled)
        XCTAssertEqual(loaded.token, token)
    }

    /// Valid JSON that claims to be enabled without a token stays enabled, so
    /// `accepts` fails closed instead of silently handing out access.
    func testLoadEnabledWithoutTokenStaysFailClosed() throws {
        let file = RouterAuth.fileURL(in: paths)
        try Data("{\"isEnabled\": true}".utf8).write(to: file)

        let loaded = RouterAuth.load(from: paths)
        XCTAssertTrue(loaded.isEnabled)
        XCTAssertNil(loaded.token)
        XCTAssertFalse(loaded.accepts(headers: [:]))
        XCTAssertFalse(loaded.accepts(headers: ["x-api-key": "anything"]))
    }

    // MARK: - Agent environment

    func testAgentEnvironmentWhenEnabled() {
        let environment = enabled.agentEnvironment
        XCTAssertEqual(environment["ANTHROPIC_AUTH_TOKEN"], token)
        // Must be present and empty: omitting it lets Claude Code fall back to
        // the user's real Anthropic key.
        XCTAssertEqual(environment["ANTHROPIC_API_KEY"], "")
        XCTAssertEqual(environment["OPENAI_API_KEY"], token)
        // Codex is configured with `env_key = "JXCODE_API_KEY"`, so the name
        // written into config.toml and the name exported here have to agree.
        XCTAssertEqual(environment["JXCODE_API_KEY"], token)
        XCTAssertEqual(environment.count, 4)
    }

    func testAgentEnvironmentWhenDisabled() {
        XCTAssertTrue(RouterAuth().agentEnvironment.isEmpty)
        XCTAssertTrue(RouterAuth(isEnabled: false, token: token).agentEnvironment.isEmpty)
    }

    func testAgentEnvironmentWhenEnabledWithoutToken() {
        XCTAssertTrue(RouterAuth(isEnabled: true, token: nil).agentEnvironment.isEmpty)
        XCTAssertTrue(RouterAuth(isEnabled: true, token: "  ").agentEnvironment.isEmpty)
    }

    /// The environment an agent is handed must actually authenticate.
    func testAgentEnvironmentRoundTripsThroughAccepts() {
        let auth = RouterAuth(isEnabled: true, token: RouterAuth.generateToken())
        let environment = auth.agentEnvironment

        XCTAssertTrue(auth.accepts(headers: [
            "Authorization": "Bearer \(environment["ANTHROPIC_AUTH_TOKEN"] ?? "")",
        ]))
        XCTAssertTrue(auth.accepts(headers: [
            "Authorization": "Bearer \(environment["OPENAI_API_KEY"] ?? "")",
        ]))
        XCTAssertTrue(auth.accepts(headers: [
            "Authorization": "Bearer \(environment["JXCODE_API_KEY"] ?? "")",
        ]))
    }

    // MARK: - Codable shape

    func testCodableRoundTrip() throws {
        let auth = RouterAuth(isEnabled: true, token: token)
        let data = try JSONEncoder().encode(auth)
        XCTAssertEqual(try JSONDecoder().decode(RouterAuth.self, from: data), auth)
    }
}
