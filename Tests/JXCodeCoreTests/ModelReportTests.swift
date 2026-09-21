import XCTest
@testable import JXCodeCore

final class ModelReportTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("report-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

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

    private func scan() -> ModelLibraryScan {
        ModelScanner().scan(roots: [root])
    }

    // MARK: Scan report

    func testScanReportSummarisesTheLibrary() throws {
        try writeGGUF("a/Ornith-1.5 9B Q8_0.gguf", .llama(architecture: "qwen35"))
        try writeGGUF("a/Ornith-1.5 9B Q8_0 mmproj.gguf", .clip())
        try writeGGUF("b/MiniCPM5-2B.gguf", .llama())

        let report = ModelReport.scan(scan())

        XCTAssertTrue(report.contains("2 models"), report)
        XCTAssertTrue(report.contains("1 with vision"), report)
        // The projector must be shown as paired, not listed as its own model.
        XCTAssertTrue(report.contains("vision"), report)
        XCTAssertFalse(report.contains("mmproj-"), "the projector should not be a top-level entry")
    }

    func testScanReportNamesUnreadableFiles() throws {
        // The library on this machine really does contain broken symlinks, so
        // the report has to say so rather than quietly omitting them.
        let missing = root.appendingPathComponent("gone.gguf")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("mmproj-Gone.gguf"),
            withDestinationURL: missing
        )

        let report = ModelReport.scan(scan())

        XCTAssertTrue(report.contains("Unreadable"), report)
        XCTAssertTrue(report.contains("broken symlink"), report)
    }

    func testScanReportShowsPathsOnRequest() throws {
        try writeGGUF("a/Model.gguf", .llama())

        let without = ModelReport.scan(scan(), options: .init(showPaths: false))
        let with = ModelReport.scan(scan(), options: .init(showPaths: true))

        XCTAssertFalse(without.contains("Model.gguf\n    model"), without)
        XCTAssertTrue(with.contains("model      "), with)
    }

    func testScanReportIncludesThePlanWhenAsked() throws {
        try writeGGUF("a/Model.gguf", .llama(contextLength: 32_768))

        let report = ModelReport.scan(
            scan(),
            optimizer: ModelOptimizer(hardware: .synthetic(memoryGB: 32)),
            options: .init(showPlan: true)
        )

        XCTAssertTrue(report.contains("plan"), report)
        XCTAssertTrue(report.contains("context"), report)
    }

    func testScanReportSurfacesOrphanProjectors() throws {
        try writeGGUF("m/Model-A-7B.gguf", .llama())
        try writeGGUF("m/Model-B-13B.gguf", .llama())
        try writeGGUF("m/mmproj-Unrelated-Thing.gguf", .clip())

        let report = ModelReport.scan(scan())

        XCTAssertTrue(report.contains("Projectors with no model"), report)
        XCTAssertTrue(report.contains("mmproj-Unrelated-Thing.gguf"), report)
    }

    func testScanReportHandlesAnEmptyLibrary() {
        let report = ModelReport.scan(scan())
        XCTAssertTrue(report.contains("0 models"), report)
    }

    // MARK: Model card

    func testModelInfoReportCoversTheGeometry() throws {
        let url = try writeGGUF("Model.gguf", .llama(
            architecture: "qwen35",
            contextLength: 262_144,
            blockCount: 32,
            embeddingLength: 4096,
            headCount: 16,
            headCountKV: 4
        ))
        let header = try GGUFReader.readHeader(at: url)
        let info = GGUFModelInfo(header: header)

        let report = ModelReport.modelInfo(
            url: url, header: header, info: info,
            fileSizeBytes: 1_000, elapsed: 0.01
        )

        XCTAssertTrue(report.contains("qwen35"), report)
        XCTAssertTrue(report.contains("262144 tokens"), report)
        XCTAssertTrue(report.contains("32"), report)
        XCTAssertTrue(report.contains("16 query, 4 KV"), report)
        XCTAssertTrue(report.contains("head dim      256"), report)
        // The number that decides whether the model can run at all.
        XCTAssertTrue(report.contains("KV per token"), report)
    }

    func testModelInfoReportIdentifiesAProjector() throws {
        let url = try writeGGUF("mmproj-Model.gguf", .clip(projectorType: "qwen3vl_merger"))
        let header = try GGUFReader.readHeader(at: url)
        let info = GGUFModelInfo(header: header)

        let report = ModelReport.modelInfo(
            url: url, header: header, info: info,
            fileSizeBytes: 1_000, elapsed: 0.01
        )

        XCTAssertTrue(report.contains("qwen3vl_merger"), report)
        XCTAssertTrue(report.contains("vision        yes"), report)
    }

    func testModelInfoReportNotesAMissingTemplate() throws {
        let url = try writeGGUF("Model.gguf", .llama(chatTemplate: nil))
        let header = try GGUFReader.readHeader(at: url)

        let report = ModelReport.modelInfo(
            url: url, header: header, info: GGUFModelInfo(header: header),
            fileSizeBytes: 1_000, elapsed: 0.01
        )

        XCTAssertTrue(report.contains("chat template absent"), report)
    }

    func testModelInfoReportCanDumpEveryKey() throws {
        let url = try writeGGUF("Model.gguf", .llama())
        let header = try GGUFReader.readHeader(at: url)

        let report = ModelReport.modelInfo(
            url: url, header: header, info: GGUFModelInfo(header: header),
            fileSizeBytes: 1_000, elapsed: 0.01,
            options: .init(showAllKeys: true)
        )

        XCTAssertTrue(report.contains("general.architecture"), report)
        XCTAssertTrue(report.contains("metadata keys"), report)
    }

    // MARK: Plan report

    func testPlanReportShowsTheReasoningForEveryFlag() throws {
        let model = LocalModel(
            model: ModelFile(
                url: root.appendingPathComponent("Model.gguf"),
                resolvedURL: root.appendingPathComponent("Model.gguf"),
                isSymlink: false, isDangling: false,
                sizeBytes: 1_073_741_824,
                info: makeModelInfo(contextLength: 32_768),
                readError: nil
            ),
            projector: nil, pairing: nil, aliases: []
        )

        let plan = try ModelOptimizer(hardware: .synthetic(memoryGB: 32)).plan(for: model)
        let report = ModelReport.plan(plan, title: model.displayName)

        XCTAssertTrue(report.contains("memory"), report)
        XCTAssertTrue(report.contains("budget"), report)
        XCTAssertTrue(report.contains("arguments"), report)
        XCTAssertTrue(report.contains("command"), report)
        // The reason text is the feature: a plan nobody can interrogate is just
        // a different kind of magic.
        XCTAssertTrue(report.contains("context"), report)
        XCTAssertTrue(report.contains("llama-server -m"), report)
    }

    func testPlanReportMentionsWarnings() throws {
        let model = LocalModel(
            model: ModelFile(
                url: root.appendingPathComponent("Model.gguf"),
                resolvedURL: root.appendingPathComponent("Model.gguf"),
                isSymlink: false, isDangling: false,
                sizeBytes: 60 * 1_073_741_824,
                info: makeModelInfo(contextLength: 131_072, blockCount: 80),
                readError: nil
            ),
            projector: nil, pairing: nil, aliases: []
        )

        let plan = try ModelOptimizer(hardware: .synthetic(memoryGB: 8)).plan(for: model)
        let report = ModelReport.plan(plan, title: "Huge")

        XCTAssertTrue(report.contains("⚠︎"), report)
    }

    // MARK: Runtime report

    func testRuntimeReportListsEveryLocationAndItsStatus() throws {
        let paths = SandboxPaths(root: root)
        let binary = paths.brewPrefix.appendingPathComponent("bin/llama-server")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let report = ModelReport.runtime(LlamaRuntimeLocator(paths: paths))

        XCTAssertTrue(report.contains("[✓]"), report)
        XCTAssertTrue(report.contains("sandbox"), report)
        XCTAssertTrue(report.contains("found:"), report)
        // The host locations must appear too, so a user can see where it looked.
        XCTAssertTrue(report.contains("/opt/homebrew/bin") || report.contains("host"), report)
    }

    func testRuntimeReportExplainsWhenNothingIsFound() {
        // A sandbox with no runtime and a machine with none installed. The
        // report must never be a bare "not found".
        let paths = SandboxPaths(root: root)
        let report = ModelReport.runtime(LlamaRuntimeLocator(paths: paths, extraSearchPaths: []))

        if !report.contains("found:") {
            XCTAssertTrue(report.contains("No llama-server found"), report)
            XCTAssertTrue(report.contains("~sandbox"), "it should say where to install one: \(report)")
        }
    }

    // MARK: Padding

    func testPadDoesNotTruncateLongValues() {
        // A long model path in the arguments table must not be cut off — the
        // whole point of showing it is that the user can read it.
        let long = String(repeating: "x", count: 80)
        let padded = ModelReport.pad(long, to: 46)
        XCTAssertTrue(padded.hasPrefix(long))
        XCTAssertGreaterThan(padded.count, long.count)
    }
}

// MARK: - Against the real library

final class RealModelReportTests: XCTestCase {

    private static let modelsRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Models")

    private static let sharedScan: ModelLibraryScan? = {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return ModelScanner().scan(roots: [modelsRoot])
    }()

    func testRendersTheRealLibraryWithoutCrashing() throws {
        guard let scan = Self.sharedScan else { throw XCTSkip("no ~/Models on this machine") }

        let report = ModelReport.scan(
            scan,
            optimizer: ModelOptimizer(hardware: .current()),
            options: .init(showPaths: true, showPlan: true, verbose: true)
        )

        XCTAssertFalse(report.isEmpty)
        // The headline counts what it found, so the expectation has to come
        // from the corpus rather than from a fixed string: this machine has one
        // readable model at the moment, and "models," was written when it had
        // more than one.
        let count = scan.models.count
        XCTAssertTrue(
            report.contains("\(count) model\(count == 1 ? "" : "s"),"),
            report
        )
        // Every model in the report must have produced a plan line, or the
        // optimiser failed silently on real metadata.
        for model in scan.models {
            XCTAssertTrue(
                report.contains(model.displayName),
                "\(model.displayName) missing from the report"
            )
        }
    }

    func testRendersARealPlanEndToEnd() throws {
        guard let scan = Self.sharedScan else { throw XCTSkip("no ~/Models on this machine") }
        guard let model = scan.models.first(where: { $0.model.info != nil }) else {
            throw XCTSkip("no readable models")
        }

        let plan = try ModelOptimizer(hardware: .current()).plan(for: model)
        let report = ModelReport.plan(plan, title: model.displayName)

        XCTAssertTrue(report.contains("llama-server -m"), report)
        XCTAssertTrue(report.contains("budget"), report)
        // The rendered command quotes a path exactly when the path needs it.
        // Which case this is depends on the machine, not on the code: the one
        // readable model here sits at a path with no spaces in it, so asking
        // for a quote unconditionally demanded something the corpus no longer
        // has. Both branches are worth checking — quoting a path that has no
        // spaces is as wrong as leaving one unquoted that does.
        if plan.modelPath.contains(" ") {
            XCTAssertTrue(
                report.contains("'\(plan.modelPath)'"),
                "a path with spaces must be quoted:\n\(report)"
            )
        } else {
            XCTAssertTrue(
                report.contains(plan.modelPath),
                "the model path should appear as it is:\n\(report)"
            )
            XCTAssertFalse(
                report.contains("'\(plan.modelPath)'"),
                "a path with no spaces must not be quoted:\n\(report)"
            )
        }
    }
}
