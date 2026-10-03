import XCTest
@testable import JXCodeCore

/// What the supervisor says about a model, and what it refuses to do.
///
/// The interesting half of this type is the *reporting*, because the decisions
/// it makes are invisible when they are wrong: a model that unloads a
/// millisecond early looks like a crash, a model that never unloads looks like
/// the feature not existing, and a count that is right by accident is a count
/// that will be wrong by accident. So the assertions here are on the sentences
/// and on the counts, not on the absence of a crash.
///
/// Nothing in this file starts a `llama-server`. The supervisor's launch path
/// needs a runtime, a GGUF and several gigabytes; it is exercised live, from
/// `jxcode local serve`, which is where the idle unload was actually observed.
final class ModelSupervisorTests: XCTestCase {

    private var base: URL!
    private var paths: SandboxPaths!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("jxcode-supervisor-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        paths = SandboxPaths(root: base)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    private func makeStore() -> ModelLifecycleStore {
        ModelLifecycleStore(paths: paths)
    }

    private func makeSupervisor(_ store: ModelLifecycleStore? = nil) -> LlamaServerSupervisor {
        LlamaServerSupervisor(store: store ?? makeStore(), paths: paths)
    }

    private func makeRunningModel(
        alias: String = "coder",
        idleTimeout: TimeInterval = 900,
        uses: Int = 0,
        lastUsedAt: Date = Date()
    ) -> RunningModel {
        RunningModel(
            alias: alias,
            modelPath: base.appendingPathComponent("model.gguf").path,
            displayName: "Test Model",
            port: 8_080,
            pid: 4_242,
            startedAt: lastUsedAt,
            lastUsedAt: lastUsedAt,
            idleTimeout: idleTimeout,
            contextLength: 131_072,
            logURL: base.appendingPathComponent("model.log"),
            uses: uses
        )
    }

    // MARK: - The request count

    /// The defect the live run found: `launch` hardcoded `uses: 1`, so
    /// `jxcode local serve` — which loads a model because a person asked, not
    /// because a request arrived — reported "1 request" beside a server that had
    /// answered nothing.
    func testAFreshlyStartedModelHasAnsweredNoRequests() {
        let summary = makeRunningModel(uses: 0).summary(now: Date())

        XCTAssertTrue(summary.contains("0 requests"), summary)
        XCTAssertFalse(summary.contains("1 request"), "a count was invented: \(summary)")
    }

    func testTheRequestCountIsPluralisedFromTwoUp() {
        let now = Date()
        XCTAssertTrue(makeRunningModel(uses: 1).summary(now: now).contains("1 request "))
        XCTAssertTrue(makeRunningModel(uses: 2).summary(now: now).contains("2 requests"))
    }

    // MARK: - The idle clock

    /// Idle is measured from the last *use*, not the last start — otherwise a
    /// long generation is unloaded mid-flight, which reads as the model
    /// crashing.
    func testIdleIsMeasuredFromTheLastUseAndNotTheStart() {
        let started = Date(timeIntervalSinceNow: -3_600)
        let used = Date(timeIntervalSinceNow: -60)
        let model = RunningModel(
            alias: "coder",
            modelPath: "/m/a.gguf",
            displayName: "Test Model",
            port: 8_080,
            pid: 1,
            startedAt: started,
            lastUsedAt: used,
            idleTimeout: 900,
            logURL: base.appendingPathComponent("a.log")
        )

        XCTAssertEqual(model.idleFor(now: Date()), 60, accuracy: 1)
        XCTAssertEqual(model.idleBudgetRemaining(now: Date()) ?? 0, 840, accuracy: 1)
    }

    func testZeroMeansKeptLoadedRatherThanUnloadedImmediately() {
        let model = makeRunningModel(idleTimeout: 0)
        let summary = model.summary(now: Date())

        XCTAssertFalse(model.unloadsWhenIdle)
        XCTAssertNil(model.idleBudgetRemaining(now: Date()))
        XCTAssertTrue(summary.contains("kept loaded until stopped"), summary)
    }

    func testAnExpiredBudgetIsReportedAsDueRatherThanAsANegativeNumber() {
        let model = makeRunningModel(idleTimeout: 30, lastUsedAt: Date(timeIntervalSinceNow: -120))
        let summary = model.summary(now: Date())

        XCTAssertTrue(summary.contains("due to unload"), summary)
        XCTAssertFalse(summary.contains("-"), "a negative duration was rendered: \(summary)")
    }

    func testTheContextIsReportedInWholeK() {
        XCTAssertTrue(makeRunningModel().summary(now: Date()).contains("128k context"))
    }

    // MARK: - An empty supervisor

    func testAnEmptySupervisorHasNothingLoadedAndStopsNothing() async {
        let supervisor = makeSupervisor()

        XCTAssertTrue(supervisor.running().isEmpty)
        XCTAssertEqual(supervisor.loadedCount, 0)

        // Hoisted out of the assertion: `XCTAssertFalse`'s argument is an
        // autoclosure, and an autoclosure cannot carry an `await`.
        let stopped = await supervisor.stop(alias: "coder")
        XCTAssertFalse(stopped)

        let swept = await supervisor.sweep()
        XCTAssertTrue(swept.isEmpty)
    }

    func testAskingForAnUnknownAliasNamesTheOnesThatDoExist() async throws {
        let store = makeStore()
        let file = base.appendingPathComponent("model.gguf")
        try Data("x".utf8).write(to: file)
        try store.setAlias(ModelAlias(name: "coder", modelPath: file.path))

        let supervisor = makeSupervisor(store)

        do {
            _ = try await supervisor.start(alias: "nope")
            XCTFail("expected a refusal")
        } catch {
            guard case .unknownAlias(let name, let profile, let known)? = error as? ModelServingError else {
                return XCTFail("expected unknownAlias, got \(error)")
            }
            XCTAssertEqual(name, "nope")
            XCTAssertEqual(profile, ModelLifecycleStore.defaultProfileName)
            XCTAssertEqual(known, ["coder"], "the refusal did not say what would have worked")
        }
    }

    /// `nil`, not a throw. Every request for a remote model goes through this
    /// hook too, and a throw there would turn an ordinary Claude turn into a 500.
    func testAnUnknownNameIsNotAnAliasRatherThanAnError() async throws {
        let supervisor = makeSupervisor()
        let backend = try await supervisor.backend(for: "claude-sonnet-4-5-20250929")

        XCTAssertNil(backend)
    }

    func testTheAliasListFollowsTheStore() throws {
        let store = makeStore()
        let file = base.appendingPathComponent("model.gguf")
        try Data("x".utf8).write(to: file)
        let supervisor = makeSupervisor(store)

        XCTAssertTrue(supervisor.knownAliases.isEmpty)

        try store.setAlias(ModelAlias(name: "coder", modelPath: file.path))
        XCTAssertEqual(supervisor.knownAliases, ["coder"])
    }

    func testHealthAndMetricsReportTheAbsenceOfAServerRatherThanThrowing() async {
        let supervisor = makeSupervisor()

        let health = await supervisor.health(alias: "coder")
        XCTAssertFalse(health.isHealthy)
        guard case .gone = health else { return XCTFail("expected gone, got \(health)") }

        let report = await supervisor.metrics(alias: "coder")
        XCTAssertFalse(report.hasMetrics)
        XCTAssertNotNil(report.problem)
    }

    func testStoppingEverythingWhenNothingIsLoadedIsANoOp() {
        let supervisor = makeSupervisor()
        supervisor.stopAllBlocking()
        XCTAssertEqual(supervisor.loadedCount, 0)
    }

    // MARK: - What a server says about itself

    /// Five cases rather than two, because the four failures need four different
    /// responses: one is worth waiting for, one is worth reading the log for,
    /// one means the process died, and one is a configuration problem.
    func testOnlyOneHealthCaseIsHealthyAndOnlyOneIsWorthRetrying() {
        XCTAssertTrue(ServerHealth.ok.isHealthy)
        XCTAssertFalse(ServerHealth.starting.isHealthy)
        XCTAssertFalse(ServerHealth.unreachable("no answer").isHealthy)
        XCTAssertFalse(ServerHealth.gone("pid is gone").isHealthy)
        XCTAssertFalse(ServerHealth.failed("no runtime").isHealthy)

        XCTAssertTrue(ServerHealth.starting.description.contains("still loading"))
        XCTAssertTrue(ServerHealth.unreachable("no answer").description.contains("no answer"))
        XCTAssertTrue(ServerHealth.gone("pid is gone").description.contains("pid is gone"))
    }

    // MARK: - Metrics

    /// Parsed generically because the metric set is the build's business. This
    /// build writes `llamacpp:prompt_tokens_total`, and a future one that drops
    /// the prefix should not silently empty the dictionary.
    func testThePrometheusPrefixIsStrippedAndBareNamesStillWork() {
        let metrics = ServerMetrics.parse("""
        # HELP llamacpp:prompt_tokens_total Number of prompt tokens
        # TYPE llamacpp:prompt_tokens_total counter
        llamacpp:prompt_tokens_total 42
        llamacpp:tokens_predicted_total 7
        prompt_tokens_seconds 12.5
        """)

        XCTAssertEqual(metrics.promptTokens, 42)
        XCTAssertEqual(metrics.predictedTokens, 7)
        XCTAssertEqual(metrics.promptTokensPerSecond, 12.5)
        XCTAssertEqual(metrics.values.count, 3, "a comment line was parsed as a sample")
    }

    /// A missing counter is read as "not busy" rather than "busy". The two
    /// errors are not symmetric: holding memory another sweep is recoverable,
    /// and killing a generation the user is waiting on is not — but a build that
    /// does not report the counter also does not report the flag that would make
    /// the answer meaningful, and `/slots` is the check the sweep relies on.
    func testAMissingBusyCounterIsNotReadAsBusy() {
        XCTAssertFalse(ServerMetrics.parse("llamacpp:prompt_tokens_total 3").isBusy)
        XCTAssertFalse(ServerMetrics.parse("llamacpp:requests_processing 0").isBusy)
        XCTAssertTrue(ServerMetrics.parse("llamacpp:requests_processing 1").isBusy)
    }

    func testTheMetricsReportSaysNotReportedRatherThanZero() {
        let report = ServerMetricsReport(
            metrics: ServerMetrics.parse("llamacpp:prompt_tokens_total 3")
        )
        let rendered = ModelLifecycleReport.metrics("coder", report)

        XCTAssertTrue(rendered.contains("3"), rendered)
        XCTAssertTrue(rendered.contains("not reported"), rendered)
        XCTAssertFalse(
            rendered.contains("predicted      0"),
            "an absent counter was rendered as zero:\n\(rendered)"
        )
    }

    /// The most likely failure is not a failure: a server started without
    /// `--metrics` answers 501 and its body says what to do. That sentence is
    /// carried through rather than replaced by one this app made up.
    func testTheServersOwnComplaintIsCarriedThroughInsteadOfAStatusCode() {
        let report = ServerMetricsReport(problem: "Start it with `--metrics`")
        let rendered = ModelLifecycleReport.metrics("coder", report)

        XCTAssertTrue(rendered.contains("Start it with `--metrics`"), rendered)
    }

    // MARK: - The empty-state sentences

    func testNothingLoadedIsExplainedAsOnDemandRatherThanAsAnError() {
        let rendered = ModelLifecycleReport.running([])

        XCTAssertTrue(rendered.contains("No local model is loaded"), rendered)
        XCTAssertTrue(rendered.contains("Nothing loads until a request needs it"), rendered)
    }

    func testOneLoadedModelIsNotReportedAsModels() {
        let rendered = ModelLifecycleReport.running([makeRunningModel()])

        XCTAssertTrue(rendered.contains("1 model loaded"), rendered)
        XCTAssertFalse(rendered.contains("1 models"), rendered)
    }

    func testHealthIsMarkedInTheReport() {
        XCTAssertTrue(ModelLifecycleReport.health("coder", .ok).hasPrefix("[✓]"))
        XCTAssertTrue(ModelLifecycleReport.health("coder", .starting).hasPrefix("[✗]"))
    }

    // MARK: - The four streams in the report

    func testTheLogStreamReportNamesThePerModelOneAsNeedingAnAlias() {
        let rendered = ModelLifecycleReport.logStreams(paths)

        XCTAssertTrue(rendered.contains("needs an alias"), rendered)
        XCTAssertTrue(rendered.contains("proxy"), rendered)
        XCTAssertTrue(rendered.contains("http"), rendered)
        XCTAssertTrue(rendered.contains("upstream"), rendered)
    }

    func testTheLogStreamReportResolvesThePerModelPathOnceGivenOne() {
        let rendered = ModelLifecycleReport.logStreams(paths, alias: "coder")

        XCTAssertFalse(rendered.contains("needs an alias"), rendered)
        XCTAssertTrue(rendered.contains("models/coder.log"), rendered)
    }
}
