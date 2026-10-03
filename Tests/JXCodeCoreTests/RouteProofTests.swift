import XCTest
@testable import JXCodeCore

/// 2.6 — the router's own proof, and the corpus that feeds it.
///
/// The claim under test is not "the router answers". It is "the router sent the
/// backend what the route it chose promises" — which is the only claim that
/// distinguishes 2.1's passthrough from the translation it replaced, because the
/// client gets a perfectly good Anthropic answer either way.
final class RouteProofTests: XCTestCase {

    /// Every route, every fixture, no failures.
    ///
    /// The subject set is asserted rather than the pass/fail count alone: a
    /// fixture that silently stopped being driven would leave every remaining
    /// check green, and the corpus is the part that decides what the proof is
    /// actually evidence about.
    func testEveryRouteJudgesEveryFixture() async throws {
        let report = await RouteProof.run()

        XCTAssertTrue(report.isPassing, report.rendered())
        XCTAssertEqual(
            report.routes.map(\.kind).sorted { $0.rawValue < $1.rawValue },
            RouteProof.routes.sorted { $0.rawValue < $1.rawValue },
            "a route was dropped from the proof"
        )

        for route in report.routes {
            XCTAssertEqual(
                Set(route.checks.map(\.subject)),
                Set(RouteCorpus.fixtures.map(\.name)),
                "route \(route.kind.rawValue) did not judge every fixture"
            )
        }

        // The count, pinned. 122 = 40 native × 2 + 42 translated: per fixture,
        // the shared checks, plus the tool-vocabulary pair where the fixture
        // defines a tool, plus the stream bracketing where it streams, plus the
        // usage trailer where the route translates. It is here so that deleting
        // a check is a deliberate act rather than a silent one — the number
        // moves only when the corpus or the check list does.
        XCTAssertEqual(report.checks.count, 122, "the number of checks changed")
    }

    /// The two routes must be told *different* things, or the corpus is proving
    /// nothing about either.
    ///
    /// A suite that only ever ran one route would pass just as green if the
    /// router translated everything, or proxied everything. This asserts the
    /// split directly, from the backend's side of the wire.
    func testThePassthroughAndTheTranslatingRouteAreAskedForDifferentPaths() async throws {
        let report = await RouteProof.run()
        let byKind = Dictionary(uniqueKeysWithValues: report.routes.map { ($0.kind, $0) })

        // Both native kinds converge on Anthropic's own route — one because it
        // is Anthropic, one because llama-server serves it too.
        for kind in [ProviderKind.localGGUF, .anthropic] {
            let route = try XCTUnwrap(byKind[kind])
            XCTAssertEqual(
                Set(route.backendPaths), ["/v1/messages"],
                "\(kind.rawValue) did not send every request to the native route"
            )
        }

        let translated = try XCTUnwrap(byKind[.openAICompatible])
        XCTAssertEqual(
            Set(translated.backendPaths), ["/v1/chat/completions"],
            "the translating route did not use the chat endpoint"
        )

        // And the two native kinds are told the same body but must be
        // authenticated differently — which is the one place `anthropic` and
        // `localGGUF` differ at all.
        XCTAssertNotEqual(
            ProviderKind.anthropic.authHeaders(apiKey: "k"),
            ProviderKind.localGGUF.authHeaders(apiKey: "k"),
            "the auth headers collapsed, so the check on them proves nothing"
        )
    }

    /// The negative control: a backend that refuses the Anthropic route must
    /// make the proof fail.
    ///
    /// A 404 from `/v1/messages` is not a contrived failure — it is exactly what
    /// a llama-server build predating the route answers, and the router's
    /// fallback to the translating path exists for it. So this test says two
    /// things at once: the proof bites, and the fallback is visible as *two*
    /// requests at the backend rather than as a clean pass.
    func testABackendThatRefusesTheAnthropicRouteIsReportedAsAFailure() async throws {
        let spy = try SpyUpstream()
        try spy.start()
        defer { spy.stop() }
        spy.messagesRouteStatus = 404

        let route = await RouteProof.run(kind: .localGGUF, against: spy)

        XCTAssertFalse(
            route.isPassing,
            "the proof passed against a backend that refuses the route it promised:\n"
                + route.checks.map { "\($0.status.rawValue) \($0.subject): \($0.title)" }
                    .joined(separator: "\n")
        )

        // The count is the *only* thing that catches it, and that is the point
        // of pinning it. The router falls back, the fallback answers 200, and
        // the client is handed a perfectly good Anthropic message — so the path
        // check passes (the first request did go to the native route), the model
        // check passes, the reply checks pass, and the whole thing would be
        // reported as working if the count were not there.
        let failures = route.checks.filter { $0.status == .fail }
        XCTAssertEqual(
            failures.count, RouteCorpus.fixtures.count,
            "expected exactly one failure per fixture — the count check — and got: "
                + failures.map { "\($0.subject): \($0.title)" }.joined(separator: ", ")
        )
        XCTAssertTrue(
            failures.allSatisfy { $0.title == "the backend was reached exactly once" },
            "a check other than the count fired, so the fallback was visible some other way: "
                + failures.map(\.title).joined(separator: ", ")
        )

        XCTAssertTrue(
            route.backendPaths.contains("/v1/messages"),
            "the native route was never attempted"
        )
        XCTAssertTrue(
            route.backendPaths.contains("/v1/chat/completions"),
            "the router never fell back to the translating route"
        )

        // And the failure is legible. The default rendering is failures-only, so
        // a report that dropped them would print a green tick over a broken
        // route — the exact shape of the mistake this command exists to catch.
        let text = RouteProofReport(routes: [route]).rendered()
        XCTAssertTrue(text.contains("✗"), "the failure was not rendered:\n\(text)")
        XCTAssertTrue(text.contains("checks failed:"), text)
        XCTAssertFalse(text.contains("all passed"), text)
    }

    /// The report renders, and names the route and the path in it.
    ///
    /// A report that threw away the observation would be a list of green ticks
    /// nobody could argue with — which is the failure mode this whole command
    /// exists to avoid.
    func testTheReportNamesTheRouteAndThePathItObserved() async throws {
        let report = await RouteProof.run()
        let text = report.rendered()

        XCTAssertTrue(text.contains("JXCode route proof"))
        XCTAssertTrue(text.contains("/v1/chat/completions"), text)
        XCTAssertTrue(text.contains("/v1/messages"), text)
        XCTAssertTrue(
            text.contains("checks passed across \(report.routes.count) route(s)"),
            text
        )
    }
}
