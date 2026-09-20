import XCTest
@testable import JXCodeCore

// MARK: - Filename matching

final class ProjectorNameMatcherTests: XCTestCase {

    // Every one of these filename pairs is a real convention, and all four were
    // found in `~/Models` on the machine this was built on. They must all reduce
    // to the same key, or the projector is not found and a vision model silently
    // gets served as text-only.

    func testSpaceSuffixedProjectorMatchesItsModel() {
        let model = ProjectorNameMatcher.key(for: "Ornith-1.5 9B Q8_0.gguf", role: .model)
        let projector = ProjectorNameMatcher.key(for: "Ornith-1.5 9B Q8_0 mmproj.gguf", role: .projector)

        XCTAssertEqual(model.compact, "ornith159b")
        XCTAssertEqual(projector.compact, "ornith159b")
        XCTAssertEqual(ProjectorNameMatcher.score(model: model, projector: projector), 1.0)
    }

    func testSpacePrefixedProjectorMatchesItsModel() {
        let model = ProjectorNameMatcher.key(for: "Ornith-1.5 9B Q8_0.gguf", role: .model)
        let projector = ProjectorNameMatcher.key(for: "mmproj Ornith-1.5 9B Q8_0.gguf", role: .projector)

        XCTAssertEqual(projector.compact, "ornith159b")
        XCTAssertEqual(ProjectorNameMatcher.score(model: model, projector: projector), 1.0)
    }

    func testDashPrefixedProjectorMatchesItsModel() {
        // The awkward one: the separator before the quantisation is a dot in the
        // model file and a dash in the projector, and the quantisation itself is
        // spelled `Q8_0` versus `Q8-0`.
        let model = ProjectorNameMatcher.key(for: "Ornith-1.5-9B.Q8_0.gguf", role: .model)
        let projector = ProjectorNameMatcher.key(for: "mmproj-Ornith-1.5-9B-Q8_0.gguf", role: .projector)

        XCTAssertEqual(model.compact, "ornith159b")
        XCTAssertEqual(projector.compact, "ornith159b")
        XCTAssertEqual(ProjectorNameMatcher.score(model: model, projector: projector), 1.0)
    }

    func testUnderscoreAndSpaceSeparatorsAgree() {
        let a = ProjectorNameMatcher.key(for: "Qwen3.5-4B_Q8_0.gguf", role: .model)
        let b = ProjectorNameMatcher.key(for: "mmproj-Qwen3.5-4B_Q8_0.gguf", role: .projector)

        XCTAssertEqual(a.compact, "qwen354b")
        XCTAssertEqual(b.compact, "qwen354b")
    }

    func testDifferentModelsDoNotCollide() {
        let ornith = ProjectorNameMatcher.key(for: "Ornith-1.5 9B Q8_0.gguf", role: .model)
        let qwen = ProjectorNameMatcher.key(for: "Qwen3.5-4B_Q8_0.gguf", role: .model)
        let minicpm = ProjectorNameMatcher.key(for: "MiniCPM5-2B.gguf", role: .model)
        let deepseek = ProjectorNameMatcher.key(for: "DeepSeek-R1-0528.gguf", role: .model)

        XCTAssertEqual(Set([ornith.compact, qwen.compact, minicpm.compact, deepseek.compact]).count, 4)
        XCTAssertEqual(ProjectorNameMatcher.score(model: ornith, projector: qwen), 0)
    }

    func testQuantisationVariantsOfOneModelAgree() {
        // The same model at two quantisations should not be mistaken for two
        // models, or a directory holding both would get two library entries.
        let q8 = ProjectorNameMatcher.key(for: "Model-7B-Q8_0.gguf", role: .model)
        let q4 = ProjectorNameMatcher.key(for: "Model-7B-Q4_K_M.gguf", role: .model)
        let f16 = ProjectorNameMatcher.key(for: "Model-7B-f16.gguf", role: .model)

        XCTAssertEqual(q8.compact, "model7b")
        XCTAssertEqual(q4.compact, "model7b")
        XCTAssertEqual(f16.compact, "model7b")
    }

    func testBF16IsNotMangledByF16Removal() {
        // `bf16` contains the substring `f16`. Token matching is what stops the
        // shorter pattern from chewing a hole in the longer one.
        let key = ProjectorNameMatcher.key(for: "Model-7B-bf16.gguf", role: .model)
        XCTAssertEqual(key.compact, "model7b")
    }

    func testLongerQuantisationPatternsWinOverShorterOnes() {
        // `q4-0-4-4` must be removed whole; if `q4-0` ran first it would leave
        // `-4-4` behind and the key would never match anything.
        let key = ProjectorNameMatcher.key(for: "Model-7B-Q4_0_4_4.gguf", role: .model)
        XCTAssertEqual(key.compact, "model7b")
    }

    func testVisionIsKeptInModelNamesButStrippedFromProjectors() {
        // The bug this guards against: `Llama-3.2-11B-Vision.gguf` and
        // `Llama-3.2-11B.gguf` are different models. Stripping "vision" from the
        // model side would make them identical, and a directory containing both
        // would attach the projector to whichever was seen first.
        let visionModel = ProjectorNameMatcher.key(for: "Llama-3.2-11B-Vision.gguf", role: .model)
        let plainModel = ProjectorNameMatcher.key(for: "Llama-3.2-11B.gguf", role: .model)

        XCTAssertEqual(visionModel.compact, "llama3211bvision")
        XCTAssertEqual(plainModel.compact, "llama3211b")
        XCTAssertNotEqual(visionModel.compact, plainModel.compact)

        // The projector still matches the vision model exactly, and the plain
        // model only loosely — so scoring picks the right one.
        let projector = ProjectorNameMatcher.key(for: "mmproj-Llama-3.2-11B-Vision.gguf", role: .projector)
        XCTAssertEqual(ProjectorNameMatcher.score(model: visionModel, projector: projector), 1.0)
        XCTAssertLessThan(ProjectorNameMatcher.score(model: plainModel, projector: projector), 1.0)
    }

    func testContainmentScoresBelowExactMatch() {
        let base = ProjectorNameMatcher.key(for: "Qwen2.5-7B.gguf", role: .model)
        let instruct = ProjectorNameMatcher.key(for: "Qwen2.5-7B-Instruct.gguf", role: .model)
        let projector = ProjectorNameMatcher.key(for: "mmproj-Qwen2.5-7B.gguf", role: .projector)

        XCTAssertEqual(ProjectorNameMatcher.score(model: base, projector: projector), 1.0)
        XCTAssertEqual(ProjectorNameMatcher.score(model: instruct, projector: projector), 0.8)
    }

    func testTinyKeysDoNotMatchByContainment() {
        // A key of "4b" would otherwise be contained in half the directory.
        let short = ProjectorNameMatcher.key(for: "4B.gguf", role: .model)
        let other = ProjectorNameMatcher.key(for: "Qwen3.5-4B-Q8_0.gguf", role: .projector)

        XCTAssertLessThan(ProjectorNameMatcher.score(model: short, projector: other), 1.0)
    }

    func testUnrelatedNamesScoreZero() {
        let a = ProjectorNameMatcher.key(for: "Llama-3-8B.gguf", role: .model)
        let b = ProjectorNameMatcher.key(for: "mmproj-Mistral-7B.gguf", role: .projector)

        XCTAssertEqual(ProjectorNameMatcher.score(model: a, projector: b), 0)
    }

    func testProjectorClassifierIgnoresVisionAsAMarker() {
        // "vision" appears in ordinary model names, so it cannot be evidence
        // that a file is a projector. "mmproj" can.
        XCTAssertTrue(ProjectorNameMatcher.looksLikeProjector("mmproj-model.gguf"))
        XCTAssertTrue(ProjectorNameMatcher.looksLikeProjector("Model mmproj.gguf"))
        XCTAssertTrue(ProjectorNameMatcher.looksLikeProjector("mmproj-Model.gguf"))
        XCTAssertTrue(ProjectorNameMatcher.looksLikeProjector("vit-large.gguf"))
        XCTAssertFalse(ProjectorNameMatcher.looksLikeProjector("Llama-3.2-11B-Vision.gguf"))
        XCTAssertFalse(ProjectorNameMatcher.looksLikeProjector("Model-Q8_0.gguf"))
    }
}

// MARK: - Scanner

final class ModelScannerTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("models-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixture helpers

    @discardableResult
    private func writeGGUF(_ relativePath: String, _ builder: GGUFFixtureBuilder) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try builder.write(to: url)
        return url
    }

    private func symlink(_ linkPath: String, to destination: URL) throws {
        let url = root.appendingPathComponent(linkPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: destination)
    }

    private func scan(readMetadata: Bool = true) -> ModelLibraryScan {
        ModelScanner(options: .init(readMetadata: readMetadata)).scan(roots: [root])
    }

    // MARK: Discovery

    func testFindsGGUFFilesByExtension() throws {
        try writeGGUF("a.gguf", .llama())
        try writeGGUF("b.gguf", .llama())
        try writeGGUF("notes.txt", .llama())

        let result = scan()

        XCTAssertEqual(result.models.count, 2)
    }

    func testFindsExtensionlessGGUFByMagicBytes() throws {
        // HuggingFace `blobs/` directories store files under names like
        // `blob_ornith_q8_0` with no extension, so extension alone is not enough.
        try writeGGUF("blobs/blob_model_q8_0", .llama())
        try writeGGUF("blobs/refs_main", .llama())

        // Make the second file not-a-GGUF by overwriting its first bytes.
        let notGGUF = root.appendingPathComponent("blobs/refs_main")
        try Data("abc123".utf8).write(to: notGGUF)

        let result = scan()

        XCTAssertEqual(result.models.count, 1)
        XCTAssertEqual(result.models.first?.model.filename, "blob_model_q8_0")
    }

    func testIgnoresNonGGUFFilesWithKnownExtensions() throws {
        try writeGGUF("readme.md", .llama())
        try writeGGUF("image.png", .llama())

        // .md and .png are not sniffed, so these are never even considered.
        let result = scan()

        XCTAssertEqual(result.models.count, 0)
    }

    func testSkipsHiddenDirectoriesAndExcludedOnes() throws {
        try writeGGUF(".git/objects/thing.gguf", .llama())
        try writeGGUF("node_modules/pkg/model.gguf", .llama())
        try writeGGUF("real/model.gguf", .llama())

        let result = scan()

        XCTAssertEqual(result.models.count, 1)
        XCTAssertEqual(result.models.first?.model.filename, "model.gguf")
    }

    // MARK: Deduplication

    func testSymlinksToTheSameFileAreCollapsed() throws {
        // The HuggingFace cache layout on this machine points `snapshots/<sha>/x`
        // and `blobs/x` at one physical file. Reporting the model three times
        // would be wrong.
        let real = try writeGGUF("Model.gguf", .llama())
        try symlink("models--local--m/blobs/blob_model", to: real)
        try symlink("models--local--m/snapshots/abc123/Model.gguf", to: real)

        let result = scan()

        XCTAssertEqual(result.models.count, 1)
        // The plain path is the one a person recognises, so it is the one shown.
        XCTAssertEqual(result.models.first?.model.filename, "Model.gguf")
        // The other paths are kept as aliases rather than discarded.
        XCTAssertEqual(result.models.first?.aliases.count, 2)
    }

    func testBrokenSymlinksAreReportedNotListedAsModels() throws {
        let missing = root.appendingPathComponent("gone.gguf")
        try symlink("mmproj-Ornith.gguf", to: missing)

        let result = scan()

        XCTAssertTrue(result.models.isEmpty)
        XCTAssertEqual(result.unreadable.count, 1)
        XCTAssertTrue(result.unreadable.first?.isDangling == true)
        XCTAssertTrue(
            result.warnings.contains { $0.contains("not there") },
            "expected a warning about the broken symlink, got \(result.warnings)"
        )
    }

    // MARK: Pairing

    func testPairsEveryRealNamingConvention() throws {
        // One directory per convention, mirroring what is actually on disk.
        try writeGGUF("a/Ornith-1.5 9B Q8_0.gguf", .llama(architecture: "qwen35"))
        try writeGGUF("a/Ornith-1.5 9B Q8_0 mmproj.gguf", .clip())

        try writeGGUF("b/Ornith-1.5 9B Q8_0.gguf", .llama(architecture: "qwen35"))
        try writeGGUF("b/mmproj Ornith-1.5 9B Q8_0.gguf", .clip())

        try writeGGUF("c/Ornith-1.5-9B.Q8_0.gguf", .llama(architecture: "qwen35"))
        try writeGGUF("c/mmproj-Ornith-1.5-9B-Q8_0.gguf", .clip())

        try writeGGUF("d/Qwen3.5-4B_Q8_0.gguf", .llama(architecture: "qwen35"))
        try writeGGUF("d/mmproj-Qwen3.5-4B_Q8_0.gguf", .clip())

        let result = scan()

        XCTAssertEqual(result.models.count, 4)
        for model in result.models {
            XCTAssertTrue(model.hasVision, "\(model.model.filename) was not paired")
            XCTAssertEqual(model.pairing, .exactName)
            XCTAssertNotNil(model.mmprojPath)
        }
        XCTAssertTrue(result.orphanProjectors.isEmpty)
    }

    func testProjectorsAreNotListedAsModels() throws {
        try writeGGUF("m/Model.gguf", .llama())
        try writeGGUF("m/mmproj-Model.gguf", .clip())

        let result = scan()

        // The projector must never appear as a servable model of its own.
        XCTAssertEqual(result.models.count, 1)
        XCTAssertFalse(result.models.contains { $0.model.filename.hasPrefix("mmproj") })
    }

    func testMetadataOverridesAMisleadingFilename() throws {
        // On this machine `DeepSeek-R1-0528.gguf` is actually a Qwen3 8B
        // fine-tune. The filename lies; the metadata does not. A file named like
        // a projector that is really a language model must be treated as a model.
        try writeGGUF("tricky/mmproj-not-really.gguf", .llama(architecture: "qwen3"))

        let result = scan()

        XCTAssertEqual(result.models.count, 1)
        XCTAssertEqual(result.models.first?.model.info?.architecture, "qwen3")
        XCTAssertFalse(result.models.first?.model.isProjector == true)
    }

    func testOrphanProjectorIsReported() throws {
        // Two models and one projector whose name matches neither. The
        // last-resort "one model, one projector" heuristic deliberately does not
        // apply here, so the projector is reported rather than guessed at.
        try writeGGUF("m/Model-A-7B.gguf", .llama())
        try writeGGUF("m/Model-B-13B.gguf", .llama())
        try writeGGUF("m/mmproj-Something-Else-Entirely.gguf", .clip())

        let result = scan()

        XCTAssertEqual(result.models.count, 2)
        XCTAssertFalse(result.models.contains { $0.hasVision })
        XCTAssertEqual(result.orphanProjectors.count, 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("no model to go with it") })
    }

    func testProjectorsAreNotBorrowedFromOtherDirectories() throws {
        // A projector in a sibling folder belongs to whatever is in that folder,
        // not to a model one directory up.
        try writeGGUF("family/model-a/Model-A-7B.gguf", .llama())
        try writeGGUF("family/model-b/mmproj-Model-A-7B.gguf", .clip())

        let result = scan()

        XCTAssertEqual(result.models.count, 1)
        XCTAssertFalse(result.models.first?.hasVision ?? true)
        XCTAssertEqual(result.orphanProjectors.count, 1)
    }

    func testSingleModelAndProjectorInOneDirectoryPairDespiteUnrelatedNames() throws {
        // Last-resort heuristic: one model, one projector, one directory. There
        // is nothing else they could belong to.
        try writeGGUF("solo/whatever.gguf", .llama())
        try writeGGUF("solo/projector-thing.gguf", .clip())

        let result = scan()

        XCTAssertEqual(result.models.count, 1)
        XCTAssertTrue(result.models.first?.hasVision ?? false)
        XCTAssertEqual(result.models.first?.pairing, .heuristic)
    }

    func testModelWithoutAnyProjectorIsFine() throws {
        try writeGGUF("plain/MiniCPM5-2B.gguf", .llama())

        let result = scan()

        XCTAssertEqual(result.models.count, 1)
        XCTAssertFalse(result.models.first?.hasVision ?? true)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testBestMatchWinsWhenTwoModelsCouldClaimOneProjector() throws {
        // `Llama-3.2-11B-Vision` should get the projector, not plain `Llama-3.2-11B`.
        try writeGGUF("v/Llama-3.2-11B.gguf", .llama())
        try writeGGUF("v/Llama-3.2-11B-Vision.gguf", .llama())
        try writeGGUF("v/mmproj-Llama-3.2-11B-Vision.gguf", .clip())

        let result = scan()

        let vision = result.models.first { $0.model.filename.contains("Vision") }
        let plain = result.models.first { $0.model.filename == "Llama-3.2-11B.gguf" }

        XCTAssertTrue(vision?.hasVision ?? false, "the Vision model should have been paired")
        XCTAssertFalse(plain?.hasVision ?? true, "the plain model should not have been")
    }

    func testOneProjectorIsNotSharedBetweenTwoModels() throws {
        try writeGGUF("share/Model-7B.gguf", .llama())
        try writeGGUF("share/Model-7B-Instruct.gguf", .llama())
        try writeGGUF("share/mmproj-Model-7B.gguf", .clip())

        let result = scan()

        let paired = result.models.filter(\.hasVision)
        XCTAssertEqual(paired.count, 1, "a projector can only belong to one model")
    }

    // MARK: Metadata-free scanning

    func testScanWithoutMetadataStillPairsByFilename() throws {
        try writeGGUF("n/Ornith-1.5 9B Q8_0.gguf", .llama(architecture: "qwen35"))
        try writeGGUF("n/Ornith-1.5 9B Q8_0 mmproj.gguf", .clip())

        let result = scan(readMetadata: false)

        XCTAssertEqual(result.models.count, 1)
        // With no metadata, the filename has to carry the classification.
        XCTAssertTrue(result.models.first?.hasVision ?? false)
    }

    func testScanReportsItsRootsAndDuration() throws {
        try writeGGUF("r/Model.gguf", .llama())

        let result = scan()

        XCTAssertEqual(result.roots, [root])
        XCTAssertGreaterThanOrEqual(result.duration, 0)
    }

    func testUnreadableGGUFIsListedWithAnError() throws {
        // A file with the right extension but a corrupt body should surface as
        // unreadable rather than crashing the scan or vanishing.
        let url = root.appendingPathComponent("corrupt.gguf")
        try Data(repeating: 0x00, count: 64).write(to: url)

        let result = scan()

        XCTAssertEqual(result.models.count, 1)
        XCTAssertNotNil(result.models.first?.model.readError)
        XCTAssertNil(result.models.first?.model.info)
    }

    func testTotalsAndVisionCount() throws {
        try writeGGUF("t/A.gguf", .llama())
        try writeGGUF("t/B.gguf", .llama())
        try writeGGUF("t/mmproj-A.gguf", .clip())

        let result = scan()

        XCTAssertEqual(result.totalModels, 2)
        XCTAssertEqual(result.visionModels, 1)
    }
}
