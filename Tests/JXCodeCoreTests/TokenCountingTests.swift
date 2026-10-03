import XCTest
@testable import JXCodeCore

/// Track 2.3 — a token count is a measurement wherever one can be taken.
///
/// The route used to estimate unconditionally. What these tests pin is the
/// distinction the route could not previously make: which of the two answers it
/// gave, and why. The distinction is not cosmetic — the estimate under-counts a
/// tool-bearing request by roughly a factor of three, and Claude Code compacts
/// from this number, so "which one answered" decides whether the client makes a
/// good decision or overflows its context.

// MARK: - Which backends can be asked

final class ProviderCountTokensPathTests: XCTestCase {

    func testOnlyBackendsThatServeTheAnthropicWireGetACountingPath() {
        XCTAssertNotNil(ProviderKind.anthropic.countTokensPath)
        XCTAssertNotNil(ProviderKind.localGGUF.countTokensPath)
        XCTAssertNil(
            ProviderKind.openAICompatible.countTokensPath,
            "vLLM, LM Studio and OpenRouter have no counting endpoint; inventing "
            + "one would post an Anthropic body to a route that does not speak it"
        )
        XCTAssertNil(ProviderKind.ollama.countTokensPath)
    }

    /// The capability is the path, so the two cannot disagree.
    ///
    /// This is the same rule `messagesPath` already follows and the reason
    /// `requiresTranslation` is derived rather than restated: a kind cannot be
    /// left claiming a counting endpoint it has no path for, nor holding a path
    /// it does not claim.
    func testTheCountingPathExistsExactlyWhereTheMessagesPathDoes() {
        for kind in ProviderKind.allCases {
            switch (kind.messagesPath, kind.countTokensPath) {
            case (nil, nil):
                break
            case (let messages?, let counting?):
                XCTAssertEqual(
                    counting, messages + "/count_tokens",
                    "\(kind.rawValue) does not derive its counting path"
                )
            case let (messages, counting):
                XCTFail(
                    "\(kind.rawValue) disagrees with itself: messagesPath=\(String(describing: messages)) "
                    + "countTokensPath=\(String(describing: counting))"
                )
            }
        }
    }

    func testTheCountingURLCarriesTheNormalisedBase() {
        let bare = Provider(name: "Local", kind: .localGGUF, baseURL: "http://127.0.0.1:8080")
        XCTAssertEqual(
            bare.countTokensURL?.absoluteString,
            "http://127.0.0.1:8080/v1/messages/count_tokens",
            "a bare host:port must gain the /v1 the counting route lives under"
        )

        let trailingSlash = Provider(
            name: "Local", kind: .localGGUF, baseURL: "http://127.0.0.1:8080/"
        )
        XCTAssertEqual(trailingSlash.countTokensURL, bare.countTokensURL)

        // Anthropic carries its own prefix, so it must not be given a second.
        let anthropic = Provider(name: "A", kind: .anthropic, baseURL: "https://api.anthropic.com")
        XCTAssertEqual(
            anthropic.countTokensURL?.absoluteString,
            "https://api.anthropic.com/v1/messages/count_tokens"
        )
    }

    func testABackendWithNoCountingEndpointHasNoCountingURL() {
        let vllm = Provider(name: "vLLM", kind: .openAICompatible, baseURL: "http://127.0.0.1:8000")
        XCTAssertNil(vllm.countTokensURL)
    }

    /// Never claim a measurement where there is no endpoint to take one.
    ///
    /// The same rule the shared-collection bind follows — do not report success
    /// on the strength of having written something down. Here the failure would
    /// be a banner line promising a measured count for a backend the router is
    /// about to silently estimate, which is exactly the kind of claim this
    /// codebase refuses to make elsewhere.
    func testTheCountSummaryClaimsMeasuredExactlyWhereThereIsAnEndpoint() {
        for kind in ProviderKind.allCases {
            XCTAssertEqual(
                kind.countTokensSummary.hasPrefix("measured"),
                kind.countTokensPath != nil,
                "\(kind.rawValue) says \"\(kind.countTokensSummary)\" but its "
                + "counting path is \(kind.countTokensPath == nil ? "absent" : "present")"
            )
        }
    }
}

// MARK: - Reading the reply

final class TokenCountReplyTests: XCTestCase {

    func testTheShapeBothBackendsAnswerWithIsRead() {
        // Measured against a running llama-server, and identical to Anthropic's.
        XCTAssertEqual(TokenCountReply.decode(Data(#"{"input_tokens":18}"#.utf8)), 18)
        XCTAssertEqual(TokenCountReply.decode(Data(#"{"input_tokens": 4242}"#.utf8)), 4242)
    }

    /// Zero is the one answer that must never be invented.
    ///
    /// A client told it has used no context believes it has unlimited room and
    /// overflows instead of compacting. Refusing the zero hands the question to
    /// the estimate, which is always at least 1.
    func testAZeroCountIsRefusedRatherThanReported() {
        XCTAssertNil(TokenCountReply.decode(Data(#"{"input_tokens":0}"#.utf8)))
    }

    func testAReplyThatIsNotTheShapeIsRefused() {
        let rejected: [(String, String)] = [
            (#"{}"#, "no input_tokens key"),
            (#"{"input_tokens":"18"}"#, "a string where a number belongs"),
            (#"{"inputTokens":18}"#, "the wrong key entirely"),
            (#"{"input_tokens":-5}"#, "a negative count"),
            (#"not json at all"#, "not JSON"),
            (#""#, "empty"),
            (#"{"error":{"type":"not_found_error","message":"File Not Found"}}"#,
             "an Anthropic-shaped 404 body, which a server may return with a 200"),
        ]
        for (body, reason) in rejected {
            XCTAssertNil(
                TokenCountReply.decode(Data(body.utf8)),
                "accepted \(body) — \(reason)"
            )
        }
    }
}

// MARK: - Remembering which backends cannot count

final class TokenCountCapabilityTests: XCTestCase {

    private func provider(
        _ url: String = "http://127.0.0.1:8080",
        id: UUID = UUID()
    ) -> Provider {
        Provider(id: id, name: "P", kind: .localGGUF, baseURL: url)
    }

    func testABackendIsAssumedAbleUntilItSaysOtherwise() {
        let capability = TokenCountCapability()
        XCTAssertTrue(capability.supports(provider()))
    }

    func testARefusalIsRemembered() {
        let capability = TokenCountCapability()
        let backend = provider()
        capability.markUnsupported(backend)
        XCTAssertFalse(capability.supports(backend))
    }

    /// Keyed on the backend, not on the registry entry.
    ///
    /// The same identity `ProviderStore.add` collapses on. Re-registering a
    /// backend — which the local-model registrar does on every activation —
    /// must not re-arm a probe that has already been answered.
    func testTheMemoryFollowsTheBackendRatherThanTheEntry() {
        let capability = TokenCountCapability()
        let url = "http://127.0.0.1:8080"
        let first = provider(url)
        capability.markUnsupported(first)

        let reRegistered = provider(url, id: UUID())
        XCTAssertNotEqual(
            reRegistered.id, first.id, "the two entries are genuinely different"
        )
        XCTAssertFalse(
            capability.supports(reRegistered),
            "a fresh entry pointing at the same backend re-armed the probe"
        )
    }

    func testADifferentBackendIsUnaffected() {
        let capability = TokenCountCapability()
        capability.markUnsupported(provider("http://127.0.0.1:8080"))
        XCTAssertTrue(capability.supports(provider("http://127.0.0.1:9999")))
    }

    func testForgettingReArms() {
        let capability = TokenCountCapability()
        let backend = provider()
        capability.markUnsupported(backend)
        capability.forget()
        XCTAssertTrue(capability.supports(backend))
    }
}

// MARK: - The route, end to end

final class CountTokensRouteTests: XCTestCase {

    private let body = """
    {"model":"claude-sonnet-4-5-20250929","max_tokens":512,
     "messages":[{"role":"user","content":"say hello"}]}
    """

    private func count(
        _ harness: RouterHarness
    ) async throws -> Int {
        let (data, response) = try await harness.post("/v1/messages/count_tokens", body: body)
        XCTAssertEqual(response.statusCode, 200)
        let payload = try JSONDecoder().decode(JSONValue.self, from: data)
        return try XCTUnwrap(payload.objectValue?["input_tokens"]?.intValue)
    }

    private func probes(_ harness: RouterHarness) -> [HTTPRequest] {
        harness.upstream.requests.filter { $0.path.hasSuffix("/count_tokens") }
    }

    func testALocalBackendIsMeasuredRatherThanEstimated() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        harness.upstream.countTokensValue = 4242

        let tokens = try await count(harness)
        XCTAssertEqual(tokens, 4242)
        XCTAssertEqual(probes(harness).count, 1, "the backend was never asked")
    }

    func testTheMeasuredNumberIsNotTheEstimate() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        harness.upstream.countTokensValue = 4242

        let estimate = TokenEstimator.estimate(
            try JSONDecoder().decode(AnthropicRequest.self, from: Data(body.utf8))
        )
        let tokens = try await count(harness)
        XCTAssertNotEqual(
            tokens, estimate,
            "the test cannot tell a measurement from an estimate if the fake "
            + "happens to answer what the estimator would have said"
        )
    }

    /// The half of the old comment that is still true, pinned.
    func testAnOpenAIBackendIsEstimatedAndNeverProbed() async throws {
        let harness = try RouterHarness(kind: .openAICompatible)

        let tokens = try await count(harness)
        XCTAssertGreaterThan(
            tokens, 0,
            "an estimate of zero tells the client it has unlimited context"
        )
        XCTAssertTrue(
            probes(harness).isEmpty,
            "a backend with no counting endpoint was probed anyway"
        )
    }

    /// The count, not the presence.
    ///
    /// `>= 1` would pass on three probes, and the point of the memory is that
    /// there is exactly one. A presence assertion cannot see a duplicate — the
    /// same lesson `--jinja --jinja` taught on the flag side.
    func testABackendThatRefusesIsAskedExactlyOnce() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        harness.upstream.countTokensRouteStatus = 404

        for _ in 0..<3 {
            let tokens = try await count(harness)
            XCTAssertGreaterThan(tokens, 0, "the route stopped answering")
        }
        XCTAssertEqual(
            probes(harness).count, 1,
            "a backend that has already refused was asked again"
        )
    }

    func testARefusalStillAnswersWithAUsableNumber() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        harness.upstream.countTokensRouteStatus = 404

        let tokens = try await count(harness)
        XCTAssertGreaterThan(tokens, 0)
        XCTAssertTrue(
            harness.router.log.snapshot().contains { $0.contains("no counting endpoint") },
            "the fallback was silent, so a user cannot find out why the number "
            + "disagrees with the server's own"
        )
    }

    /// Only the negative answer is cached.
    ///
    /// A backend that can count is asked every time, because the count changes
    /// with every request — caching it would cache the one thing this exists to
    /// keep current.
    func testASuccessfulMeasurementIsNotCached() async throws {
        let harness = try RouterHarness(kind: .localGGUF)

        for _ in 0..<3 { _ = try await count(harness) }
        XCTAssertEqual(
            probes(harness).count, 3,
            "a working backend was asked once and its answer reused"
        )
    }

    func testTheLogSaysWhichAnswerWasGiven() async throws {
        let measured = try RouterHarness(kind: .localGGUF)
        _ = try await count(measured)
        XCTAssertTrue(
            measured.router.log.snapshot().contains { $0.contains("(measured)") },
            "a measured count is not distinguishable from an estimate in the log:\n"
            + measured.router.log.snapshot().joined(separator: "\n")
        )

        let estimated = try RouterHarness(kind: .openAICompatible)
        _ = try await count(estimated)
        XCTAssertTrue(
            estimated.router.log.snapshot().contains { $0.contains("(estimated)") },
            "an estimated count is not distinguishable from a measurement in the log:\n"
            + estimated.router.log.snapshot().joined(separator: "\n")
        )
    }

    /// A malformed request is still a malformed request.
    ///
    /// The measurement path must not become a way for a bad body to reach the
    /// backend: the body is decoded first, so a body that is not an Anthropic
    /// request is refused here rather than forwarded.
    func testABodyThatIsNotAMessagesRequestIsStillRefused() async throws {
        let harness = try RouterHarness(kind: .localGGUF)
        let (_, response) = try await harness.post("/v1/messages/count_tokens", body: #"{"nope":1}"#)

        XCTAssertNotEqual(response.statusCode, 200)
        XCTAssertTrue(probes(harness).isEmpty, "a bad body was forwarded to the backend")
    }
}
