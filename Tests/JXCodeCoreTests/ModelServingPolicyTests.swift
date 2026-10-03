import XCTest
@testable import JXCodeCore

/// The one-router decision, and the measurement it rests on.
///
/// Track 1.4 recorded the decision as "do not delegate to `--models-dir`", which
/// reads as a rule about a flag. The installed binary disagrees: router mode is
/// what `llama-server` does when *no model is named*, and the four `--models-*`
/// flags only configure it. These tests pin the correction, because the
/// correction is the part a future reader will otherwise re-derive wrongly.
///
/// Four runs on build 10150 back the claim, and they are what the discriminator
/// below encodes:
///
///     llama-server                                      → router mode, 0 models
///     llama-server --models-max 2                       → router mode, 0 models
///     llama-server -m /nonexistent.gguf                 → not router mode; exits
///     llama-server -m /nonexistent.gguf --models-dir D  → not router mode; exits
///
/// The first two also answer `/health` **200** while their own log says
/// `Available models (0)`, which is the failure the refusal exists to prevent.
final class ModelServingPolicyTests: XCTestCase {

    private let fm = FileManager.default
    private var base: URL!
    private var paths: SandboxPaths!

    override func setUpWithError() throws {
        base = fm.temporaryDirectory.appendingPathComponent("jxcode-policy-\(UUID().uuidString)")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        paths = SandboxPaths(root: base)
        try paths.createDirectories()
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: base)
    }

    // MARK: - Fixtures

    private func argument(_ flag: String, _ value: String? = nil) -> LlamaArgument {
        LlamaArgument(flag: flag, value: value, reason: "fixture", category: .server)
    }

    /// A plan of the shape the app actually builds.
    private func makePlan(modelPath: String = "/models/coder.gguf") -> OptimizationPlan {
        let optimizer = ModelOptimizer(
            hardware: .synthetic(memoryGB: 32, performanceCores: 8, efficiencyCores: 4),
            policy: .safe,
            cachePolicy: .balanced,
            sampling: .agent,
            capabilities: .assumedModern
        )
        return optimizer.plan(
            modelPath: modelPath,
            mmprojPath: nil,
            info: makeModelInfo(),
            modelBytes: 4 * 1_073_741_824,
            projectorBytes: 0
        )
    }

    /// The same plan with one flag taken out — how a defect of this kind would
    /// actually arrive, rather than as a hand-written argument list.
    private func plan(_ plan: OptimizationPlan, dropping flag: String) -> OptimizationPlan {
        OptimizationPlan(
            modelPath: plan.modelPath,
            mmprojPath: plan.mmprojPath,
            arguments: plan.arguments.filter { $0.flag != flag },
            contextLength: plan.contextLength,
            cacheTypeK: plan.cacheTypeK,
            cacheTypeV: plan.cacheTypeV,
            gpuLayers: plan.gpuLayers,
            threads: plan.threads,
            batchSize: plan.batchSize,
            microBatchSize: plan.microBatchSize,
            estimatedWeightsBytes: plan.estimatedWeightsBytes,
            estimatedKVCacheBytes: plan.estimatedKVCacheBytes,
            estimatedComputeBytes: plan.estimatedComputeBytes,
            estimatedProjectorBytes: plan.estimatedProjectorBytes,
            memoryBudgetBytes: plan.memoryBudgetBytes,
            hardware: plan.hardware,
            policy: plan.policy,
            cachePolicy: plan.cachePolicy,
            sampling: plan.sampling,
            templateNote: plan.templateNote,
            templateToolCalling: plan.templateToolCalling,
            warnings: plan.warnings,
            templateKwargs: plan.templateKwargs
        )
    }

    /// The four flag lines, copied out of `llama-server --help` on build 10150.
    ///
    /// A fixture built from the real text rather than from a hand-written list,
    /// because the point of `defines(_:)` is that it reads a help page — and a
    /// fixture that is already in the shape the parser wants tests nothing.
    private func capabilitiesDefiningRouterFlags() -> LlamaServerCapabilities {
        LlamaServerCapabilities.parse(helpText: """
        --media-path PATH                       directory for loading local media files
        --models-dir PATH                       directory containing models for the router server (default: disabled)
                                                (env: LLAMA_ARG_MODELS_DIR)
        --models-preset PATH                    path to INI file containing model presets for the router server
                                                (default: disabled)
        --models-max N                          for router server, maximum number of models to load simultaneously
                                                (default: 4, 0 = unlimited)
        --models-autoload, --no-models-autoload
                                                for router server, whether to automatically load models (default:
                                                enabled)
        --jinja, --no-jinja                     whether to use jinja template engine for chat (default: enabled)
        """)
    }

    // MARK: - The discriminator

    /// The correction, in one test. No model and no flag is router mode; a
    /// router-configuring flag on its own is *still* router mode, because the
    /// flag does not switch the feature on.
    func testRouterModeIsTheAbsenceOfAModelNotThePresenceOfAFlag() {
        XCTAssertEqual(ModelServingPolicy.mode(of: []), .router)
        XCTAssertEqual(
            ModelServingPolicy.mode(of: [argument("--models-dir", "/models")]),
            .router
        )
        XCTAssertEqual(
            ModelServingPolicy.mode(of: [argument("--models-max", "2")]),
            .router
        )
    }

    func testAModelNamedWithMinusMIsOneModelMode() {
        XCTAssertEqual(
            ModelServingPolicy.mode(of: [argument("-m", "/models/a.gguf")]),
            .oneModel(path: "/models/a.gguf")
        )
    }

    func testTheLongSpellingOfTheModelFlagCountsToo() {
        XCTAssertEqual(
            ModelServingPolicy.mode(of: [argument("--model", "/models/a.gguf")]),
            .oneModel(path: "/models/a.gguf")
        )
    }

    /// Separated from `.router` on purpose: the causes differ, so the remedies
    /// do. One plan never named a model; the other named it wrongly and would
    /// make llama.cpp read the next argument as the path.
    func testAMinusMWithNoValueIsMalformedRatherThanRouterMode() {
        XCTAssertEqual(ModelServingPolicy.mode(of: [argument("-m")]), .malformed)
    }

    // MARK: - The flags

    /// Pinned as a count as well as a set. The plan named two of these; the
    /// binary defines four, and a fifth added later has to move this number
    /// deliberately rather than slip in unnoticed.
    func testTheRouterFlagSetIsTheFourTheInstalledBinaryDefines() {
        XCTAssertEqual(ModelServingPolicy.routerConfigurationFlags.count, 4)
        XCTAssertEqual(
            Set(ModelServingPolicy.routerConfigurationFlags),
            ["--models-dir", "--models-preset", "--models-max", "--models-autoload"]
        )
    }

    func testTheNegatedTwinOfAutoloadIsRecognisedAsTheSameFlag() {
        XCTAssertTrue(ModelServingPolicy.isRouterConfigurationFlag("--no-models-autoload"))
    }

    func testOnlyTheRouterFlagsAreRecognised() {
        for flag in ModelServingPolicy.routerConfigurationFlags {
            XCTAssertTrue(ModelServingPolicy.isRouterConfigurationFlag(flag), flag)
        }
        for other in ["-m", "--model", "--parallel", "--cache-ram", "--host", "--metrics"] {
            XCTAssertFalse(ModelServingPolicy.isRouterConfigurationFlag(other), other)
        }
    }

    /// Every flag carries a reason of its own. A generic fallback would make
    /// four different facts read as one, which is the defect `--cache-ram 8192`
    /// was recorded for.
    func testEveryRouterFlagHasItsOwnReason() {
        let reasons = ModelServingPolicy.routerConfigurationFlags.map(ModelServingPolicy.role(of:))
        XCTAssertEqual(Set(reasons).count, 4, "two flags share a reason: \(reasons)")
        XCTAssertFalse(reasons.contains("not a router-mode flag"))
    }

    // MARK: - The invariant the app has to keep

    func testAPlanTheAppBuildsNamesExactlyOneModel() {
        let plan = makePlan()
        XCTAssertEqual(
            ModelServingPolicy.mode(of: plan.arguments),
            .oneModel(path: "/models/coder.gguf")
        )
    }

    /// The rule the whole track rests on, pinned by count rather than by
    /// absence of a named flag — "no `--models-dir`" would pass on a plan that
    /// had acquired `--models-preset`.
    func testAPlanTheAppBuildsNamesNoRouterFlagAtAll() {
        let plan = makePlan()
        XCTAssertEqual(ModelServingPolicy.configuredRouterFlags(in: plan.arguments).count, 0)
    }

    func testARouterFlagBesideAModelIsReportedRatherThanIgnored() {
        let flags = ModelServingPolicy.configuredRouterFlags(in: [
            argument("-m", "/models/a.gguf"),
            argument("--models-dir", "/models"),
            argument("--models-max", "2"),
            argument("--models-dir", "/models"),
        ])

        // Deduplicated, and in the order they appear.
        XCTAssertEqual(flags, ["--models-dir", "--models-max"])
    }

    // MARK: - The refusal

    /// `/bin/echo` is the binary because it is executable and is never reached:
    /// the refusal is checked before the capabilities probe and before anything
    /// is spawned.
    func testAServerWithNoModelInItIsRefusedRatherThanStarted() async {
        let configuration = LlamaServerConfiguration(
            binary: URL(fileURLWithPath: "/bin/echo"),
            plan: plan(makePlan(), dropping: "-m"),
            port: 8_080,
            logURL: base.appendingPathComponent("model-less.log"),
            capabilities: .assumedModern
        )

        XCTAssertEqual(configuration.mode, .router)

        let server = LlamaServer(configuration: configuration, paths: paths)
        do {
            try await server.start()
            XCTFail("a server with no model in it was started instead of refused")
        } catch let error as LlamaServerError {
            guard case .noModelNamed(let mode) = error else {
                return XCTFail("expected noModelNamed, got \(error)")
            }
            XCTAssertEqual(mode, .router)
        } catch {
            XCTFail("expected a LlamaServerError, got \(error)")
        }
    }

    /// The refusal has to name the thing that makes this dangerous rather than
    /// merely forbidden, or the next reader will "fix" it by allowing it.
    func testTheRefusalNamesTheHealthCheckThatWouldHaveMissedIt() {
        let refusal = LlamaServerError.noModelNamed(mode: .router).description
        XCTAssertTrue(refusal.contains("/health"), refusal)
        XCTAssertTrue(refusal.contains("200"), refusal)
    }

    func testAMalformedPlanGetsItsOwnSentence() {
        let malformed = LlamaServerError.noModelNamed(mode: .malformed).description
        let router = LlamaServerError.noModelNamed(mode: .router).description
        XCTAssertNotEqual(malformed, router)
        XCTAssertTrue(malformed.contains("-m"), malformed)
    }

    // MARK: - The report

    func testTheReportNamesTheAlternativeToRouterMode() {
        let store = ModelLifecycleStore(paths: paths)
        let report = ModelLifecycleReport.servingPolicy(
            store,
            capabilities: capabilitiesDefiningRouterFlags()
        )

        // The remedy, not just the rule. A policy that says "no" without saying
        // what to do instead is the thing this track was warned against.
        XCTAssertTrue(report.contains("to serve two models at once"), report)
        XCTAssertTrue(report.contains("jxcode local alias"), report)
    }

    func testTheReportSaysWhichOfTheFourFlagsThisBinaryHas() {
        let store = ModelLifecycleStore(paths: paths)
        let report = ModelLifecycleReport.servingPolicy(
            store,
            capabilities: capabilitiesDefiningRouterFlags()
        )

        for flag in ModelServingPolicy.routerConfigurationFlags {
            XCTAssertTrue(report.contains(flag), "\(flag) missing from:\n\(report)")
        }
        XCTAssertEqual(
            report.components(separatedBy: "defined").count - 1,
            4,
            "a flag was reported as absent on a build that defines all four:\n\(report)"
        )
    }

    /// `defines` answers "yes" to everything when the help text is empty, which
    /// is right for planning against an assumed build and a false claim in a
    /// report. An unprobed binary must not be described as capable.
    func testAnUnprobedBinaryIsNotReportedAsCapable() {
        let store = ModelLifecycleStore(paths: paths)
        let report = ModelLifecycleReport.servingPolicy(store, capabilities: .assumedModern)

        XCTAssertTrue(report.contains("no binary was found"), report)
        XCTAssertFalse(report.contains("defined"), report)
    }

    func testAForeignServerInRouterModeIsNamedAsSuch() {
        let rendered = ModelLifecycleReport.foreignServers([
            ModelLifecycleReport.ForeignServer(
                pid: 9, port: 8_080, modelPath: nil, alias: nil, mode: .router
            )
        ])

        XCTAssertTrue(rendered.contains("router mode"), rendered)
        XCTAssertTrue(rendered.contains("alias table"), rendered)
    }

    /// The exact command line the probe used to start a router-mode server, read
    /// back through the same path the pane and `jxcode local show` use.
    func testAServerWithNoModelOnItsCommandLineIsReadAsRouterMode() {
        let store = ModelLifecycleStore(paths: paths)
        let matched = ModelLifecycleReport.runningElsewhere(
            [RunningServers.Entry(pid: 33, command: "llama-server --host 127.0.0.1 --port 8080")],
            store: store
        )

        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched[0].mode, .router)
        XCTAssertEqual(matched[0].port, 8_080)
    }
}
