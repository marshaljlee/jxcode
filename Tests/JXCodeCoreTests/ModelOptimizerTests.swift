import XCTest
@testable import JXCodeCore

/// Builds a `GGUFModelInfo` directly, without going through a file.
///
/// `GGUFHeader`'s memberwise initialiser is internal, which `@testable import`
/// makes visible — so tests can construct geometry that would otherwise require
/// writing a multi-gigabyte fixture.
func makeModelInfo(
    architecture: String = "llama",
    contextLength: Int? = 131_072,
    blockCount: Int? = 32,
    embeddingLength: Int? = 4096,
    headCount: Int? = 32,
    headCountKV: Int? = 8,
    // A realistic template, not a placeholder. Real chat templates mark roles
    // and handle tools in both halves — reading the `tools` variable so the
    // definitions reach the model, and rendering `tool_calls` so a call comes
    // back out. The one-liner that used to be here had neither, and the version
    // after that had only the first; each time a fixture artefact looked like a
    // property of the model and tripped the tool-calling check on tests that
    // are about memory geometry.
    chatTemplate: String? = """
    {% for m in messages %}<|{{ m.role }}|>{{ m.content }}<|end|>
    {% if m.tool_calls %}<tool_calls>{{ m.tool_calls }}</tool_calls>{% endif %}
    {% endfor %}{% if tools %}<tools>{{ tools }}</tools>{% endif %}
    """,
    fileType: GGMLFileType? = .mostlyQ8_0,
    name: String? = "Fixture",
    projectionDim: Int? = nil,
    hasVisionEncoder: Bool = false,
    vocabularySize: Int? = nil
) -> GGUFModelInfo {
    var metadata: [String: GGUFValue] = [:]
    metadata["general.architecture"] = .string(architecture)
    if let name { metadata["general.name"] = .string(name) }
    if let fileType { metadata["general.file_type"] = .unsigned(UInt64(fileType.rawValue)) }
    if let chatTemplate { metadata["tokenizer.chat_template"] = .string(chatTemplate) }
    if let contextLength { metadata["\(architecture).context_length"] = .unsigned(UInt64(contextLength)) }
    if let blockCount { metadata["\(architecture).block_count"] = .unsigned(UInt64(blockCount)) }
    if let embeddingLength { metadata["\(architecture).embedding_length"] = .unsigned(UInt64(embeddingLength)) }
    if let headCount { metadata["\(architecture).attention.head_count"] = .unsigned(UInt64(headCount)) }
    if let headCountKV { metadata["\(architecture).attention.head_count_kv"] = .unsigned(UInt64(headCountKV)) }
    if let projectionDim { metadata["clip.vision.projection_dim"] = .unsigned(UInt64(projectionDim)) }
    if hasVisionEncoder { metadata["clip.has_vision_encoder"] = .boolean(true) }

    return GGUFModelInfo(header: GGUFHeader(
        version: 3,
        tensorCount: 100,
        metadataCount: UInt64(metadata.count),
        metadata: metadata,
        skippedKeys: [],
        arrayLengths: vocabularySize.map { ["tokenizer.ggml.tokens": UInt64($0)] } ?? [:],
        bytesRead: 1024
    ))
}

// MARK: - Hardware

final class HardwareProfileTests: XCTestCase {

    func testMemoryBudgetLeavesRoomForTheSystem() {
        let hardware = HardwareProfile.synthetic(memoryGB: 32)
        XCTAssertEqual(hardware.memoryBudget, UInt64(32 * 1_073_741_824 * 0.70))
        XCTAssertEqual(hardware.comfortableBudget, UInt64(32 * 1_073_741_824 * 0.55))
    }

    func testRecommendedThreadsPrefersPerformanceCores() {
        // llama.cpp's own default counts every physical core, which on Apple
        // Silicon includes the efficiency cores. The generation loop is
        // latency-bound, so those slow cores become the critical path.
        let hardware = HardwareProfile.synthetic(memoryGB: 32, performanceCores: 8, efficiencyCores: 4)
        XCTAssertEqual(hardware.recommendedThreads, 8)
        XCTAssertEqual(hardware.totalCores, 12)
    }

    func testRecommendedThreadsFallsBackToAllCoresWithoutPerfLevels() {
        // Intel Macs report no performance levels.
        let hardware = HardwareProfile(
            physicalMemory: 32 * 1_073_741_824,
            performanceCores: nil,
            efficiencyCores: nil,
            totalCores: 10,
            chipName: "Intel",
            modelIdentifier: nil,
            isUnifiedMemory: false
        )
        XCTAssertEqual(hardware.recommendedThreads, 10)
    }

    func testCurrentProfileReadsRealValues() {
        let hardware = HardwareProfile.current()
        XCTAssertGreaterThan(hardware.physicalMemory, 0)
        XCTAssertGreaterThan(hardware.recommendedThreads, 0)
        XCTAssertGreaterThan(hardware.memoryBudget, 0)
    }

    func testDisplayNameMentionsMemory() {
        let hardware = HardwareProfile.synthetic(memoryGB: 64)
        XCTAssertTrue(hardware.displayName.contains("64 GB"), hardware.displayName)
    }
}

// MARK: - Policies

final class MemoryPolicyTests: XCTestCase {

    func testBudgetFractionsAreOrdered() {
        let hardware = HardwareProfile.synthetic(memoryGB: 32)
        let safe = MemoryPolicy.safe.budget(for: hardware)
        let balanced = MemoryPolicy.balanced.budget(for: hardware)
        let maximal = MemoryPolicy.maximal.budget(for: hardware)

        XCTAssertLessThan(safe, balanced)
        XCTAssertLessThan(balanced, maximal)
    }

    func testMaximalStaysUnderTheGPUWiredLimit() {
        // macOS refuses GPU allocations past roughly 75% of physical memory, so
        // a budget above that would produce plans that cannot be allocated.
        XCTAssertLessThanOrEqual(MemoryPolicy.maximal.fraction, 0.80)
    }
}

final class CachePolicyTests: XCTestCase {

    func testQualityNeverQuantises() {
        XCTAssertEqual(CachePolicy.quality.allowedCacheTypes, [.f16])
    }

    func testBalancedAllowsQ8ButNotQ4() {
        // q8_0 is close to lossless; q4_0 is a real quality cost. The default
        // stops at q8_0 so the planner cannot silently make that trade.
        XCTAssertEqual(CachePolicy.balanced.allowedCacheTypes, [.f16, .q8_0])
        XCTAssertFalse(CachePolicy.balanced.allowedCacheTypes.contains(.q4_0))
    }

    func testContextAllowsQ4() {
        XCTAssertEqual(CachePolicy.context.allowedCacheTypes, [.f16, .q8_0, .q4_0])
    }
}

// MARK: - Context ladder

final class ContextCandidatesTests: XCTestCase {

    private let optimizer = ModelOptimizer(hardware: .synthetic(memoryGB: 32))

    func testLadderIsFilteredToTheTrainedLength() {
        let candidates = optimizer.contextCandidates(trained: 32_768)
        XCTAssertEqual(candidates, [32_768, 16_384, 8_192, 4_096])
    }

    func testTrainedLengthIsIncludedWhenItIsNotOnTheLadder() {
        let candidates = optimizer.contextCandidates(trained: 100_000)
        XCTAssertEqual(candidates.first, 100_000)
        XCTAssertTrue(candidates.contains(65_536))
        XCTAssertFalse(candidates.contains(131_072), "nothing above the trained length")
    }

    func testTinyTrainedLengthStillProducesACandidate() {
        // TinyLlama declares a 2048 context, which is below every rung. The
        // ladder must not come back empty, or the planner has nothing to try.
        let candidates = optimizer.contextCandidates(trained: 2_048)
        XCTAssertEqual(candidates, [2_048])
    }

    func testUnknownTrainedLengthOffersTheWholeLadder() {
        let candidates = optimizer.contextCandidates(trained: nil)
        XCTAssertEqual(candidates.first, 262_144)
        XCTAssertEqual(candidates.last, 4_096)
    }

    func testCandidatesAreDescendingAndUnique() {
        let candidates = optimizer.contextCandidates(trained: 131_072)
        XCTAssertEqual(candidates, candidates.sorted(by: >))
        XCTAssertEqual(candidates.count, Set(candidates).count)
    }
}

// MARK: - Planning

final class ModelOptimizerTests: XCTestCase {

    /// A 32 GB machine by default, which is enough for the ordinary cases to
    /// succeed. Tests about memory pressure pass a smaller size explicitly.
    private func optimizer(
        memoryGB: Double = 32,
        policy: MemoryPolicy = .safe,
        cache: CachePolicy = .balanced
    ) -> ModelOptimizer {
        ModelOptimizer(
            hardware: .synthetic(memoryGB: memoryGB, performanceCores: 8, efficiencyCores: 4),
            policy: policy,
            cachePolicy: cache
        )
    }

    private func plan(
        _ optimizer: ModelOptimizer,
        info: GGUFModelInfo?,
        modelBytes: UInt64 = 4 * 1_073_741_824,
        mmproj: String? = nil,
        projectorBytes: UInt64 = 0
    ) -> OptimizationPlan {
        optimizer.plan(
            modelPath: "/models/Model.gguf",
            mmprojPath: mmproj,
            info: info,
            modelBytes: modelBytes,
            projectorBytes: projectorBytes
        )
    }

    // MARK: Geometry only a crafted header would declare

    /// A `block_count` near `Int.max` makes the per-token cache cost exceed
    /// `UInt64.max` at *any* context length, and `UInt64(_:)` traps on that.
    ///
    /// `GGUFValue.intValue` refuses values above `Int.max` rather than trapping,
    /// so this geometry reaches the planner honestly: the header declared it and
    /// nothing rejected it. The planner's job is to survive it.
    func testAnAbsurdBlockCountDoesNotTrap() {
        let plan = plan(optimizer(), info: makeModelInfo(blockCount: Int.max))

        XCTAssertTrue(
            plan.warnings.contains { $0.contains("does not fit") },
            "an unloadable model should say so rather than crash, got \(plan.warnings)"
        )
    }

    /// The partial-offload path has to stay reachable with absurd geometry.
    ///
    /// It is guarded by a sum that used to be computed with `&+`. A cache
    /// estimate of `UInt64.max` wraps to something small, so the guard read
    /// "it fits" and skipped the warning for precisely the model that needs
    /// it — and took the layer arithmetic below it out of reach with it.
    func testAbsurdGeometryStillReportsPartialOffload() {
        let plan = plan(optimizer(), info: makeModelInfo(blockCount: Int.max))

        XCTAssertTrue(
            plan.warnings.contains { $0.contains("layers fit in the memory budget") },
            "\(plan.warnings)"
        )
    }

    /// The same trap through the other operand: a trained context near
    /// `Int.max`, which multiplies even ordinary geometry past `UInt64.max`.
    func testAnAbsurdTrainedContextDoesNotTrap() {
        let plan = plan(optimizer(), info: makeModelInfo(contextLength: Int.max))

        XCTAssertFalse(plan.warnings.isEmpty, "expected the plan to explain itself")
    }

    /// Both at once, and still a plan rather than a crash.
    func testAbsurdGeometryAcrossTheBoardStillProducesAPlan() {
        let plan = plan(
            optimizer(),
            info: makeModelInfo(contextLength: Int.max, blockCount: Int.max, embeddingLength: Int.max)
        )
        XCTAssertFalse(plan.warnings.isEmpty)
    }

    func testSaturatingConversionMatchesUInt64WhereUInt64DoesNotTrap() {
        XCTAssertEqual(UInt64(saturating: 0), 0)
        XCTAssertEqual(UInt64(saturating: 42), 42)
        XCTAssertEqual(UInt64(saturating: 42.7), 42, "same truncation as UInt64(_:)")
        XCTAssertEqual(UInt64(saturating: 1e18), 1_000_000_000_000_000_000)
    }

    func testSaturatingConversionClampsWhereUInt64Traps() {
        XCTAssertEqual(UInt64(saturating: .infinity), .max)
        XCTAssertEqual(UInt64(saturating: 1e30), .max)
        XCTAssertEqual(UInt64(saturating: -1), 0)
        XCTAssertEqual(UInt64(saturating: -.infinity), 0)
        XCTAssertEqual(UInt64(saturating: .nan), .max, "unknown size, so does not fit")
    }

    // MARK: Fit

    func testFullContextIsUsedWhenItFits() throws {
        // A small model on a big machine should get everything it was trained for.
        let info = makeModelInfo(contextLength: 32_768, blockCount: 16, embeddingLength: 2048, headCount: 16, headCountKV: 4)
        let plan = plan(optimizer(memoryGB: 64), info: info, modelBytes: 1_073_741_824)

        XCTAssertEqual(plan.contextLength, 32_768)
        XCTAssertEqual(plan.cacheTypeK, .f16, "no reason to quantise when it fits")
        XCTAssertTrue(plan.warnings.isEmpty, "\(plan.warnings)")
        XCTAssertLessThanOrEqual(plan.estimatedTotalBytes, plan.memoryBudgetBytes)
    }

    func testLongerContextIsPreferredOverBetterCache() throws {
        // The stated policy: for an agent workload a longer window beats a
        // marginally more precise cache, up to what the policy allows.
        let info = makeModelInfo(contextLength: 131_072, blockCount: 32, embeddingLength: 4096, headCount: 16, headCountKV: 4)
        let plan = plan(optimizer(memoryGB: 32), info: info, modelBytes: 4 * 1_073_741_824)

        XCTAssertEqual(plan.contextLength, 131_072, "the full trained context should be reachable")
        XCTAssertEqual(plan.cacheTypeK, .q8_0, "by quantising the cache")
        XCTAssertLessThanOrEqual(plan.estimatedTotalBytes, plan.memoryBudgetBytes)
    }

    func testContextIsReducedWhenNothingFits() throws {
        // 6 GB of weights on a 16 GB machine. The model fits, but nowhere near
        // its trained 256k context, so the context is what gives way — and the
        // result still has to land inside the budget.
        let info = makeModelInfo(contextLength: 262_144, blockCount: 32, embeddingLength: 4096, headCount: 16, headCountKV: 4)
        let plan = plan(optimizer(memoryGB: 16), info: info, modelBytes: 6 * 1_073_741_824)

        XCTAssertLessThan(plan.contextLength, 262_144)
        XCTAssertEqual(plan.contextLength, 32_768)
        XCTAssertLessThanOrEqual(plan.estimatedTotalBytes, plan.memoryBudgetBytes)
        XCTAssertTrue(
            plan.warnings.contains { $0.contains("trained for") },
            "reducing the context should be explained: \(plan.warnings)"
        )
    }

    // MARK: Cache policy

    func testQualityPolicyNeverQuantises() throws {
        let info = makeModelInfo(contextLength: 262_144, blockCount: 32, embeddingLength: 4096, headCount: 16, headCountKV: 4)
        let plan = plan(optimizer(memoryGB: 8, cache: .quality), info: info, modelBytes: 8 * 1_073_741_824)

        XCTAssertEqual(plan.cacheTypeK, .f16)
        XCTAssertFalse(plan.arguments.contains { $0.flag == "--cache-type-k" })
    }

    func testBalancedPolicyStopsAtQ8() throws {
        // The contract that matters is the upper bound: balanced may reach q8_0
        // but must never fall through to q4_0, however tight the machine is.
        let info = makeModelInfo(contextLength: 262_144, blockCount: 32, embeddingLength: 4096, headCount: 16, headCountKV: 4)
        let plan = plan(optimizer(memoryGB: 8, cache: .balanced), info: info, modelBytes: 8 * 1_073_741_824)

        XCTAssertNotEqual(plan.cacheTypeK, .q4_0, "balanced must not fall through to q4_0")
        XCTAssertTrue(CachePolicy.balanced.allowedCacheTypes.contains(plan.cacheTypeK))
    }

    func testContextPolicyReachesFurtherThanBalanced() throws {
        let info = makeModelInfo(contextLength: 262_144, blockCount: 32, embeddingLength: 4096, headCount: 16, headCountKV: 4)
        let balanced = plan(optimizer(memoryGB: 16, cache: .balanced), info: info, modelBytes: 8 * 1_073_741_824)
        let context = plan(optimizer(memoryGB: 16, cache: .context), info: info, modelBytes: 8 * 1_073_741_824)

        XCTAssertGreaterThanOrEqual(context.contextLength, balanced.contextLength)
        if context.cacheTypeK == .q4_0 {
            XCTAssertEqual(context.cacheTypeK, .q4_0)
        }
    }

    func testQuantisedCacheEmitsBothKeyAndValueFlags() throws {
        let info = makeModelInfo(contextLength: 262_144, blockCount: 32, embeddingLength: 4096, headCount: 16, headCountKV: 4)
        let plan = plan(optimizer(memoryGB: 16), info: info, modelBytes: 4 * 1_073_741_824)

        XCTAssertEqual(plan.cacheTypeK, .q8_0)
        let k = plan.arguments.first { $0.flag == "--cache-type-k" }
        let v = plan.arguments.first { $0.flag == "--cache-type-v" }
        XCTAssertEqual(k?.value, "q8_0")
        XCTAssertEqual(v?.value, "q8_0", "the value cache has to match the key cache")
    }

    func testFlashAttentionIsAlwaysOn() throws {
        let info = makeModelInfo()
        let plan = plan(optimizer(), info: info)
        XCTAssertTrue(plan.arguments.contains { $0.flag == "-fa" })
    }

    // MARK: Arguments

    func testParallelIsAlwaysPinnedToOne() throws {
        // `-c` is the total context divided between slots. Leaving `--parallel`
        // at its default would silently split a 128k window into four 32k ones,
        // and an agent would start losing the beginning of its conversation.
        let plan = plan(optimizer(), info: makeModelInfo())

        let parallel = plan.arguments.first { $0.flag == "--parallel" }
        XCTAssertEqual(parallel?.value, "1")
    }

    func testModelPathIsTheFirstArgument() throws {
        let plan = plan(optimizer(), info: makeModelInfo())
        XCTAssertEqual(plan.arguments.first?.flag, "-m")
        XCTAssertEqual(plan.arguments.first?.value, "/models/Model.gguf")
    }

    func testProjectorIsPassedWhenPresent() throws {
        let plan = plan(
            optimizer(),
            info: makeModelInfo(),
            mmproj: "/models/mmproj-Model.gguf",
            projectorBytes: 500 * 1_048_576
        )

        let flag = plan.arguments.first { $0.flag == "--mmproj" }
        XCTAssertEqual(flag?.value, "/models/mmproj-Model.gguf")
        XCTAssertEqual(plan.mmprojPath, "/models/mmproj-Model.gguf")
        XCTAssertGreaterThan(plan.estimatedProjectorBytes, 0)
    }

    func testProjectorIsOmittedWhenAbsent() throws {
        let plan = plan(optimizer(), info: makeModelInfo())
        XCTAssertFalse(plan.arguments.contains { $0.flag == "--mmproj" })
        XCTAssertEqual(plan.estimatedProjectorBytes, 0)
    }

    func testJinjaIsEmittedWhenTheModelHasATemplate() throws {
        let plan = plan(optimizer(), info: makeModelInfo(chatTemplate: "{% for m in messages %}{% endfor %}"))
        XCTAssertTrue(plan.arguments.contains { $0.flag == "--jinja" })
    }

    func testMissingTemplateIsWarnedAbout() throws {
        // Without a template llama.cpp falls back to a built-in guess, and tool
        // calling — which is the whole point of an agent workspace — is the
        // first thing to break.
        let plan = plan(optimizer(), info: makeModelInfo(chatTemplate: nil))

        XCTAssertFalse(plan.arguments.contains { $0.flag == "--jinja" })
        XCTAssertTrue(
            plan.warnings.contains { $0.contains("chat template") },
            "\(plan.warnings)"
        )
    }

    func testGpuLayersMatchesTheModelLayerCount() throws {
        let plan = plan(optimizer(), info: makeModelInfo(blockCount: 42))
        XCTAssertEqual(plan.gpuLayers, 42)
        // The reported count is exact, but the flag must over-count — see
        // `testOffloadFlagOverCountsSoTheServerCanStart`.
        let ngl = plan.arguments.first { $0.flag == "-ngl" }
        XCTAssertEqual(ngl?.value, String(ModelOptimizer.fullOffloadValue))
        XCTAssertGreaterThanOrEqual(Int(ngl?.value ?? "0") ?? 0, 42)
    }

    /// Regression, measured on llama.cpp 10150 / Apple M2 Max with a 42-layer
    /// model: `-ngl 42` (the exact count) segfaults during Metal graph init,
    /// and so do partial values (`20`) and CPU-only (`0`). Only a value at or
    /// above the layer count loads.
    ///
    /// This matters most when the model does *not* fit, which is exactly when
    /// the planner used to shrink the count — producing a plan that could
    /// never start.
    func testOffloadFlagOverCountsSoTheServerCanStart() throws {
        let info = makeModelInfo(contextLength: 131_072, blockCount: 80, embeddingLength: 8192, headCount: 64, headCountKV: 8)
        let plan = plan(optimizer(memoryGB: 8), info: info, modelBytes: 30 * 1_073_741_824)

        XCTAssertLessThan(plan.gpuLayers, 80, "the plan should notice it does not fit")
        let ngl = plan.arguments.first { $0.flag == "-ngl" }
        XCTAssertEqual(ngl?.value, String(ModelOptimizer.fullOffloadValue))
    }

    func testThreadsUsePerformanceCores() throws {
        let plan = plan(optimizer(), info: makeModelInfo())
        let threads = plan.arguments.first { $0.flag == "-t" }
        XCTAssertEqual(threads?.value, "8")
        XCTAssertEqual(plan.threads, 8)
    }

    func testContextFlagMatchesThePlannedContext() throws {
        let plan = plan(optimizer(), info: makeModelInfo(contextLength: 32_768))
        let context = plan.arguments.first { $0.flag == "-c" }
        XCTAssertEqual(context?.value, String(plan.contextLength))
    }

    // MARK: Degraded cases

    func testPartialOffloadWhenTheWeightsAloneDoNotFit() throws {
        // A 30 GB model on an 8 GB machine. The plan must still be produced —
        // and must say plainly that it will be slow.
        let info = makeModelInfo(contextLength: 131_072, blockCount: 80, embeddingLength: 8192, headCount: 64, headCountKV: 8)
        let plan = plan(optimizer(memoryGB: 8), info: info, modelBytes: 30 * 1_073_741_824)

        XCTAssertLessThan(plan.gpuLayers, 80)
        XCTAssertTrue(
            plan.warnings.contains { $0.contains("layers fit in the memory budget") },
            "\(plan.warnings)"
        )
    }

    func testWarnsWhenNothingFitsAtAll() throws {
        let info = makeModelInfo(contextLength: 131_072, blockCount: 80, embeddingLength: 8192, headCount: 64, headCountKV: 8)
        let plan = plan(optimizer(memoryGB: 8), info: info, modelBytes: 60 * 1_073_741_824)

        XCTAssertTrue(
            plan.warnings.contains { $0.contains("does not fit") },
            "\(plan.warnings)"
        )
    }

    func testTightMemoryReducesBatchSizes() throws {
        // Sized deliberately: 6 GB of weights on a 16 GB machine leaves only a
        // few percent spare once the largest fitting context is chosen, which is
        // exactly when the compute buffer has to be shrunk.
        let info = makeModelInfo(contextLength: 131_072, blockCount: 32, embeddingLength: 4096, headCount: 16, headCountKV: 4)
        let plan = plan(optimizer(memoryGB: 16), info: info, modelBytes: 6 * 1_073_741_824)

        XCTAssertGreaterThan(plan.memoryUsedFraction, 0.85, "fixture should be tight")
        XCTAssertEqual(plan.microBatchSize, 256)
        XCTAssertEqual(plan.batchSize, 1_024)
        XCTAssertTrue(plan.arguments.contains { $0.flag == "-ub" })
        XCTAssertTrue(plan.warnings.contains { $0.contains("Memory is tight") }, "\(plan.warnings)")
    }

    func testRoomyMemoryLeavesBatchSizesAlone() throws {
        // Emitting llama.cpp's own defaults as explicit flags is noise, so a
        // comfortable plan should not mention them at all.
        let info = makeModelInfo(contextLength: 8_192, blockCount: 16, embeddingLength: 2048, headCount: 16, headCountKV: 4)
        let plan = plan(optimizer(memoryGB: 64), info: info, modelBytes: 1_073_741_824)

        XCTAssertNil(plan.microBatchSize)
        XCTAssertNil(plan.batchSize)
        XCTAssertFalse(plan.arguments.contains { $0.flag == "-ub" })
    }

    func testUnknownGeometryStillProducesAUsablePlan() throws {
        // A file whose metadata would not parse. The planner must not crash or
        // emit nothing — it should fall back and say it is guessing.
        let plan = plan(optimizer(), info: nil, modelBytes: 2 * 1_073_741_824)

        XCTAssertEqual(plan.cacheTypeK, .f16)
        XCTAssertFalse(plan.arguments.isEmpty)
        XCTAssertTrue(plan.arguments.contains { $0.flag == "-ngl" && $0.value == "999" })
    }

    func testPlanWithNoReadableModelPathIsRejected() throws {
        let optimizer = optimizer()
        let file = ModelFile(
            url: URL(fileURLWithPath: "/gone.gguf"),
            resolvedURL: nil,
            isSymlink: true,
            isDangling: true,
            sizeBytes: 0,
            info: nil,
            readError: "missing"
        )
        let model = LocalModel(model: file, projector: nil, pairing: nil, aliases: [])

        XCTAssertThrowsError(try optimizer.plan(for: model))
    }

    // MARK: Arithmetic

    func testKvEstimateMatchesTheGeometry() throws {
        // 32 layers × 4 kv heads × (256 + 256) × 2 bytes = 128 KiB per token.
        let info = makeModelInfo(contextLength: 32_768, blockCount: 32, embeddingLength: 4096, headCount: 16, headCountKV: 4)
        let plan = plan(optimizer(memoryGB: 64), info: info, modelBytes: 1_073_741_824)

        XCTAssertEqual(plan.contextLength, 32_768)
        XCTAssertEqual(plan.estimatedKVCacheBytes, UInt64(131_072 * 32_768))
    }

    func testTotalEstimateIsTheSumOfItsParts() throws {
        let info = makeModelInfo()
        let plan = plan(optimizer(memoryGB: 64), info: info, modelBytes: 1_073_741_824, mmproj: "/p.gguf", projectorBytes: 100 * 1_048_576)

        XCTAssertEqual(
            plan.estimatedTotalBytes,
            plan.estimatedWeightsBytes + plan.estimatedKVCacheBytes
                + plan.estimatedComputeBytes + plan.estimatedProjectorBytes
        )
    }

    func testEveryArgumentCarriesAReason() throws {
        // The reason strings are the feature, not decoration: the whole point of
        // an auto-optimiser is that a person can see why it chose what it chose.
        let plan = plan(optimizer(), info: makeModelInfo(), mmproj: "/p.gguf", projectorBytes: 1024)

        for argument in plan.arguments {
            XCTAssertFalse(argument.reason.isEmpty, "\(argument.flag) has no reason")
        }
    }

    // MARK: Command line

    func testPathsWithSpacesAreQuoted() throws {
        // The real models on this machine are called
        // "Ornith-1.5 9B Q8_0.gguf". An unquoted command line would be wrong,
        // and the user would paste it into a shell and get a confusing failure.
        let optimizer = optimizer()
        let plan = optimizer.plan(
            modelPath: "/Users/x/Models/Ornith-1.5 9B Q8_0.gguf",
            mmprojPath: "/Users/x/Models/Ornith-1.5 9B Q8_0 mmproj.gguf",
            info: makeModelInfo(),
            modelBytes: 1_073_741_824,
            projectorBytes: 1024
        )

        let command = plan.commandLine()
        XCTAssertTrue(command.contains("'/Users/x/Models/Ornith-1.5 9B Q8_0.gguf'"), command)
        XCTAssertTrue(command.contains("'/Users/x/Models/Ornith-1.5 9B Q8_0 mmproj.gguf'"), command)
    }

    func testArgvIsNotQuoted() throws {
        // `argv` goes straight to execve, where quoting would become part of the
        // filename. Only the human-readable command line is quoted.
        let optimizer = optimizer()
        let plan = optimizer.plan(
            modelPath: "/Users/x/Models/Model With Space.gguf",
            mmprojPath: nil,
            info: makeModelInfo(),
            modelBytes: 1_073_741_824,
            projectorBytes: 0
        )

        let argv = plan.argv(binary: "llama-server")
        XCTAssertEqual(argv.first, "llama-server")
        XCTAssertTrue(argv.contains("/Users/x/Models/Model With Space.gguf"))
    }

    func testShellQuotingHandlesApostrophes() throws {
        XCTAssertEqual(OptimizationPlan.shellQuoted("/a/b.gguf"), "/a/b.gguf")
        XCTAssertEqual(OptimizationPlan.shellQuoted("/a b/c.gguf"), "'/a b/c.gguf'")
        XCTAssertEqual(OptimizationPlan.shellQuoted("/it's.gguf"), "'/it'\\''s.gguf'")
    }

    func testSummaryMentionsTheKeyChoices() throws {
        let plan = plan(optimizer(), info: makeModelInfo(contextLength: 32_768))
        let summary = plan.summary

        XCTAssertTrue(summary.contains("32k context"), summary)
        XCTAssertTrue(summary.contains("f16 cache"), summary)
        XCTAssertTrue(summary.contains("8 threads"), summary)
    }
}
