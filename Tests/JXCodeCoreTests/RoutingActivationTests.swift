import XCTest
@testable import JXCodeCore

/// The one-click chain.
///
/// What is worth pinning here is not that the happy path works — it is that
/// every *early* failure stops where it should. The defect this replaces was
/// never "the button did nothing": it was a chain that carried on past a broken
/// hop, so the UI showed a loaded model and a listening router while the agents
/// were still on Anthropic. Each test below asserts that a hop failing means the
/// hops after it never ran.
final class RoutingActivationTests: XCTestCase {

    // MARK: - Fixtures

    private func provider(
        id: UUID = UUID(),
        name: String = "Test API",
        kind: ProviderKind = .openAICompatible,
        base: String = "https://api.example.com/v1",
        models: [String] = ["test-model"]
    ) -> Provider {
        Provider(id: id, name: name, kind: kind, baseURL: base, models: models)
    }

    private func report(
        _ action: AgentConfigWriter.Report.Action,
        name: String = "Claude Code"
    ) -> AgentConfigWriter.Report {
        AgentConfigWriter.Report(agentID: name, agentName: name, action: action, path: nil, notes: [])
    }

    /// A handle set that records what ran, so "did not run" is checkable.
    private final class Recorder {
        var served: [ActivationSource] = []
        var started: [(String, String, UInt16)] = []
        var bound: [(String, String)] = []
        var probed: [String] = []
        var registered: [Provider] = []
    }

    private func handles(
        recorder: Recorder = Recorder(),
        providers: @escaping () async -> [Provider] = { [] },
        serve: @escaping (ActivationSource) async throws -> ServedLocalModel = { _ in
            throw TestFailure.unexpected("serveLocal should not have been called")
        },
        register: ((Provider) async throws -> Provider)? = nil,
        startRouter: @escaping (Provider, String, UInt16) async throws -> String = { _, _, _ in
            throw TestFailure.unexpected("startRouter should not have been called")
        },
        bind: @escaping (String, String) async throws -> [AgentConfigWriter.Report] = { _, _ in
            throw TestFailure.unexpected("bind should not have been called")
        },
        probeModels: @escaping (Provider) async throws -> [String] = { _ in
            throw TestFailure.unexpected("probeModels should not have been called")
        }
    ) -> ActivationHandles {
        ActivationHandles(
            serveLocal: { source in
                recorder.served.append(source)
                return try await serve(source)
            },
            providers: providers,
            register: { provider in
                recorder.registered.append(provider)
                if let register { return try await register(provider) }
                return provider
            },
            startRouter: { provider, model, port in
                recorder.started.append((provider.name, model, port))
                return try await startRouter(provider, model, port)
            },
            bind: { base, model in
                recorder.bound.append((base, model))
                return try await bind(base, model)
            },
            probeModels: { provider in
                recorder.probed.append(provider.name)
                return try await probeModels(provider)
            },
            auth: { RouterAuth() }
        )
    }

    private enum TestFailure: Error, CustomStringConvertible {
        case unexpected(String)
        case boom(String)

        var description: String {
            switch self {
            case .unexpected(let what): return what
            case .boom(let what): return what
            }
        }
    }

    // MARK: - The happy path

    func testARegisteredBackendGoesAllTheWayToTheAgents() async {
        let recorder = Recorder()
        let backend = provider()

        let result = await RoutingActivation.run(
            ActivationRequest(
                source: .registered(id: backend.id, model: "test-model"),
                bindAgents: true,
                verify: false
            ),
            handles: handles(
                recorder: recorder,
                providers: { [backend] },
                startRouter: { _, _, _ in "http://127.0.0.1:5255" },
                bind: { _, _ in [self.report(.merged)] },
                probeModels: { _ in ["test-model"] }
            )
        )

        XCTAssertTrue(result.isWorking, result.rendered())
        XCTAssertEqual(result.routerURL, "http://127.0.0.1:5255")
        XCTAssertEqual(recorder.probed, ["Test API"])
        XCTAssertEqual(recorder.started.count, 1)
        XCTAssertEqual(recorder.started.first?.1, "test-model")
        XCTAssertEqual(recorder.bound.count, 1)
        XCTAssertEqual(recorder.bound.first?.0, "http://127.0.0.1:5255")
        XCTAssertTrue(result.warnings.isEmpty, result.rendered())
    }

    // MARK: - Hop 1: nothing to activate

    func testNoRegisteredBackendStopsBeforeAnythingRuns() async {
        let recorder = Recorder()

        let result = await RoutingActivation.run(
            ActivationRequest(source: .registered(id: nil, model: nil), verify: false),
            handles: handles(recorder: recorder, providers: { [] })
        )

        XCTAssertFalse(result.isWorking)
        XCTAssertEqual(result.failures.first?.id, ActivationSteps.target)
        XCTAssertNotNil(result.failures.first?.remedy)
        XCTAssertTrue(recorder.started.isEmpty)
        XCTAssertTrue(recorder.bound.isEmpty)
    }

    func testABackendWithNoModelStopsWithTheFix() async {
        let backend = provider(models: [])

        let result = await RoutingActivation.run(
            ActivationRequest(source: .registered(id: backend.id, model: nil), verify: false),
            handles: handles(providers: { [backend] })
        )

        XCTAssertEqual(result.failures.first?.id, ActivationSteps.target)
        XCTAssertTrue(result.failures.first?.detail.contains("no model selected") == true)
    }

    // MARK: - Hop 2: the upstream

    func testAnUnreachableBackendStopsBeforeTheRouterStarts() async {
        let recorder = Recorder()
        let backend = provider()

        let result = await RoutingActivation.run(
            ActivationRequest(source: .registered(id: backend.id, model: "test-model"), verify: false),
            handles: handles(
                recorder: recorder,
                providers: { [backend] },
                probeModels: { _ in throw TestFailure.boom("connection refused") }
            )
        )

        XCTAssertFalse(result.isWorking)
        XCTAssertEqual(result.failures.first?.id, ActivationSteps.upstream)
        XCTAssertTrue(result.failures.first?.detail.contains("connection refused") == true)
        XCTAssertTrue(recorder.started.isEmpty,
                      "starting a router pointed at a dead backend is the failure this prevents")
    }

    /// A backend that answers but does not serve the chosen model still routes —
    /// the router rewrites whatever an agent asks for — so it is a warning, not
    /// a failure.
    func testAModelTheBackendDoesNotAdvertiseIsAWarningNotAFailure() async {
        let backend = provider(models: ["something-else"])

        let result = await RoutingActivation.run(
            ActivationRequest(source: .registered(id: backend.id, model: "test-model"), verify: false),
            handles: handles(
                providers: { [backend] },
                startRouter: { _, _, _ in "http://127.0.0.1:5255" },
                bind: { _, _ in [self.report(.merged)] },
                probeModels: { _ in ["something-else"] }
            )
        )

        XCTAssertTrue(result.isWorking, result.rendered())
        XCTAssertEqual(result.warnings.first?.id, ActivationSteps.upstream)
        XCTAssertTrue(result.warnings.first?.remedy?.contains("something-else") == true)
    }

    // MARK: - Hop 4: the router

    func testAPortThatWillNotBindStopsBeforeTheAgentsAreWritten() async {
        let recorder = Recorder()
        let backend = provider()

        let result = await RoutingActivation.run(
            ActivationRequest(source: .registered(id: backend.id, model: "test-model"), verify: false),
            handles: handles(
                recorder: recorder,
                providers: { [backend] },
                startRouter: { _, _, _ in throw TestFailure.boom("address already in use") },
                probeModels: { _ in ["test-model"] }
            )
        )

        XCTAssertFalse(result.isWorking)
        XCTAssertEqual(result.failures.first?.id, ActivationSteps.router)
        XCTAssertTrue(recorder.bound.isEmpty,
                      "pointing agents at a port nothing is listening on bricks every agent")
    }

    // MARK: - Hop 5: the agents

    func testBindingNothingIsAFailureWithTheReason() async {
        let backend = provider()

        let result = await RoutingActivation.run(
            ActivationRequest(source: .registered(id: backend.id, model: "test-model"), verify: false),
            handles: handles(
                providers: { [backend] },
                startRouter: { _, _, _ in "http://127.0.0.1:5255" },
                bind: { _, _ in [self.report(.notApplicable, name: "Plain shell")] },
                probeModels: { _ in ["test-model"] }
            )
        )

        XCTAssertFalse(result.isWorking)
        XCTAssertEqual(result.failures.first?.id, ActivationSteps.bind)
        XCTAssertEqual(result.routerURL, "http://127.0.0.1:5255",
                       "the router is up — the report has to say so even when the bind failed")
    }

    func testARefusedConfigIsAWarningAndIsNamed() async {
        let backend = provider()

        let result = await RoutingActivation.run(
            ActivationRequest(source: .registered(id: backend.id, model: "test-model"), verify: false),
            handles: handles(
                providers: { [backend] },
                startRouter: { _, _, _ in "http://127.0.0.1:5255" },
                bind: { _, _ in
                    [self.report(.merged), self.report(.refused, name: "Codex CLI")]
                },
                probeModels: { _ in ["test-model"] }
            )
        )

        XCTAssertTrue(result.isWorking, result.rendered())
        XCTAssertEqual(result.warnings.first?.id, ActivationSteps.bind)
        XCTAssertTrue(result.warnings.first?.detail.contains("Codex CLI") == true)
    }

    func testAskingNotToBindSkipsTheStepRatherThanFailing() async {
        let recorder = Recorder()
        let backend = provider()

        let result = await RoutingActivation.run(
            ActivationRequest(
                source: .registered(id: backend.id, model: "test-model"),
                bindAgents: false,
                verify: false
            ),
            handles: handles(
                recorder: recorder,
                providers: { [backend] },
                startRouter: { _, _, _ in "http://127.0.0.1:5255" },
                probeModels: { _ in ["test-model"] }
            )
        )

        XCTAssertTrue(result.isWorking, result.rendered())
        XCTAssertTrue(recorder.bound.isEmpty)
        XCTAssertEqual(result.steps.first { $0.id == ActivationSteps.bind }?.status, .skipped)
        XCTAssertTrue(result.headline.contains("no agent was pointed at it"))
    }

    // MARK: - The local path

    /// The port is chosen by the server, so the backend entry has to be built
    /// from what the server reports — not from the default URL on the provider
    /// the path was resolved into. Getting this wrong is a 500 "could not
    /// connect" on the first request, which says nothing about the port.
    func testALocalModelRegistersThePortItActuallyTook() async {
        let recorder = Recorder()

        let result = await RoutingActivation.run(
            ActivationRequest(
                source: .localModel(
                    path: "/tmp/Model.gguf",
                    memory: .safe,
                    cache: .balanced,
                    sampling: .default
                ),
                verify: false
            ),
            handles: handles(
                recorder: recorder,
                serve: { _ in
                    ServedLocalModel(
                        displayName: "Model 9B",
                        filename: "Model.gguf",
                        port: 8_123,
                        contextLength: 32_768
                    )
                },
                startRouter: { _, _, _ in "http://127.0.0.1:5255" },
                bind: { _, _ in [self.report(.created)] }
            )
        )

        XCTAssertTrue(result.isWorking, result.rendered())

        let registered = recorder.registered.first
        XCTAssertEqual(registered?.normalizedBaseURL, "http://127.0.0.1:8123/v1")
        XCTAssertEqual(registered?.kind, .localGGUF)
        XCTAssertEqual(registered?.models, ["Model.gguf"])
        XCTAssertEqual(registered?.contextLength, 32_768,
                       "the window has to reach the agent config, or Claude Code assumes 200k")
        XCTAssertEqual(recorder.started.first?.1, "Model.gguf")
        XCTAssertEqual(recorder.probed, [],
                       "a local model has already been probed by loading it — asking again is a second round trip")
    }

    func testALocalModelThatWillNotLoadStopsBeforeTheRouter() async {
        let recorder = Recorder()

        let result = await RoutingActivation.run(
            ActivationRequest(
                source: .localModel(
                    path: "/tmp/Model.gguf",
                    memory: .safe,
                    cache: .balanced,
                    sampling: .default
                ),
                verify: false
            ),
            handles: handles(
                recorder: recorder,
                serve: { _ in throw TestFailure.boom("llama-server exited during load") }
            )
        )

        XCTAssertFalse(result.isWorking)
        XCTAssertEqual(result.failures.first?.id, ActivationSteps.upstream)
        XCTAssertTrue(result.failures.first?.detail.contains("exited during load") == true)
        XCTAssertTrue(recorder.started.isEmpty)
    }

    func testServingWarningsBecomeAWarningStepNotAFailure() async {
        let result = await RoutingActivation.run(
            ActivationRequest(
                source: .localModel(
                    path: "/tmp/Model.gguf",
                    memory: .safe,
                    cache: .balanced,
                    sampling: .default
                ),
                verify: false
            ),
            handles: handles(
                serve: { _ in
                    ServedLocalModel(
                        displayName: "Model 9B",
                        filename: "Model.gguf",
                        port: 8_123,
                        contextLength: 4_096,
                        warnings: ["2 other llama-server process(es) share unified memory."]
                    )
                },
                startRouter: { _, _, _ in "http://127.0.0.1:5255" },
                bind: { _, _ in [self.report(.created)] }
            )
        )

        XCTAssertTrue(result.isWorking, result.rendered())
        let upstream = result.steps.first { $0.id == ActivationSteps.upstream }
        XCTAssertEqual(upstream?.status, .warn)
        XCTAssertNotNil(upstream?.remedy)
    }

    // MARK: - The report

    func testTheHeadlineNamesTheFirstFailureAndItsReason() {
        let report = ActivationReport(
            source: "Test API",
            routerURL: nil,
            steps: [
                ActivationStep(id: ActivationSteps.target, title: "Backend chosen",
                               status: .pass, detail: "ok"),
                ActivationStep(id: ActivationSteps.upstream, title: "Backend is answering",
                               status: .fail, detail: "HTTP 401 — bad key",
                               remedy: "Fix the key."),
            ]
        )

        XCTAssertFalse(report.isWorking)
        XCTAssertTrue(report.headline.contains("HTTP 401 — bad key"), report.headline)
        XCTAssertTrue(report.rendered().contains("→ Fix the key."), report.rendered())
    }

    func testARefusedReportCarriesTheReasonAndTheFix() {
        let report = ActivationReport.refused(
            source: "no model",
            reason: "no local model is selected",
            remedy: "Pick one in the Library."
        )

        XCTAssertFalse(report.isWorking)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(report.failures.first?.remedy, "Pick one in the Library.")
        XCTAssertTrue(report.rendered().contains("no local model is selected"))
    }

    func testTheRenderedReportMarksEveryStep() {
        let report = ActivationReport(
            source: "Test API",
            routerURL: "http://127.0.0.1:5255",
            steps: [
                ActivationStep(id: ActivationSteps.target, title: "A", status: .pass, detail: ""),
                ActivationStep(id: ActivationSteps.upstream, title: "B", status: .warn, detail: ""),
                ActivationStep(id: ActivationSteps.router, title: "C", status: .fail, detail: ""),
                ActivationStep(id: ActivationSteps.bind, title: "D", status: .skipped, detail: ""),
            ]
        )

        let text = report.rendered()
        XCTAssertTrue(text.contains("[  ok  ] A"))
        XCTAssertTrue(text.contains("[ warn ] B"))
        XCTAssertTrue(text.contains("[ FAIL ] C"))
        XCTAssertTrue(text.contains("[ skip ] D"))
    }

    // MARK: - The self-test's wording

    func testEveryStatusTheSelfTestCanSeeHasARemedy() {
        for status in [401, 403, 404, 408, 429, 500, 502, 503, 504, 418] {
            XCTAssertNotNil(RouterSelfTest.remedy(for: status),
                            "\(status) has no sentence telling the user what to do")
        }
    }

    func testTheSelfTestSaysSoWhenNothingIsListening() async {
        // Port 1 on loopback is not something anything serves; the connection is
        // refused immediately rather than timing out.
        let outcome = await RouterSelfTest.roundTrip(
            routerURL: "http://127.0.0.1:1",
            model: "test-model",
            token: nil
        )

        XCTAssertFalse(outcome.ok)
        XCTAssertNotNil(outcome.remedy)
    }

    func testWaitingForARouterThatIsNotThereGivesUpQuickly() async {
        let started = Date()
        let listening = await RouterSelfTest.waitUntilListening(
            routerURL: "http://127.0.0.1:1",
            timeout: 0.5
        )
        XCTAssertFalse(listening)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}
