import XCTest
@testable import JXCodeCore

/// Scans the real model directory on this machine, when there is one.
///
/// The synthetic fixtures in `ModelLibraryTests` encode the naming conventions
/// that were *observed* on disk, but a fixture can only ever confirm what its
/// author already believed. This test runs the same code against the actual
/// files, so a change that breaks the real corpus fails here rather than in the
/// app. It skips cleanly on a machine with no models.
final class RealModelCorpusTests: XCTestCase {

    private static let modelsRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Models")

    /// Scanning reads every model header, which costs a few seconds. All the
    /// tests in this class share one scan rather than repeating it.
    private static let sharedScan: ModelLibraryScan? = {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: modelsRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return ModelScanner().scan(roots: [modelsRoot])
    }()

    private func requireCorpus() throws -> ModelLibraryScan {
        guard let scan = Self.sharedScan else {
            throw XCTSkip("no ~/Models on this machine")
        }
        return scan
    }

    /// The two models known to have a projector beside them on this machine.
    private let knownVisionModels = ["Ornith-1.5 9B", "Qwen3.5-4B"]

    func testRealCorpusScansWithoutError() throws {
        let scan = try requireCorpus()

        XCTAssertFalse(scan.models.isEmpty, "expected to find models in ~/Models")

        // Every model must have resolved to a readable file, and any model whose
        // metadata was read must have a plausible context length. A nil context
        // here would mean the architecture-scoped key lookup silently failed.
        for model in scan.models {
            XCTAssertNotNil(model.model.resolvedURL, "\(model.model.filename) has no resolved path")
            if let info = model.model.info {
                XCTAssertNotNil(
                    info.contextLength,
                    "\(model.model.filename) parsed but reported no context length — "
                        + "architecture was \(info.architecture ?? "nil")"
                )
                XCTAssertNotNil(info.blockCount, "\(model.model.filename) reported no layer count")
            }
        }
    }

    func testKnownVisionModelsArePaired() throws {
        let scan = try requireCorpus()
        let vision = scan.models.filter(\.hasVision)

        for name in knownVisionModels {
            let match = vision.first { $0.model.filename.contains(name) }
            XCTAssertNotNil(match, "\(name) should have been paired with its mmproj")

            // Pairing is not enough — both halves have to be openable, or the
            // model will fail to start with a confusing error later.
            if let match {
                XCTAssertNotNil(match.modelPath, "\(name) has no usable model path")
                XCTAssertNotNil(match.mmprojPath, "\(name) has no usable projector path")
                XCTAssertNil(match.projectorProblem, "\(name): \(match.projectorProblem ?? "")")
            }
        }
    }

    func testTheProjectorDimensionVetoDoesNotBreakRealPairs() throws {
        // The veto added to the matcher rejects a projector whose projection
        // dimension differs from the model's hidden size. This is the test that
        // proves the real files agree — if llama.cpp ever changed how it writes
        // `clip.vision.projection_dim`, this is where it would surface.
        let scan = try requireCorpus()

        for model in scan.models where model.hasVision {
            guard let projected = model.projector?.info?.vision?.projectionDim,
                  let hidden = model.model.info?.embeddingLength else { continue }
            XCTAssertEqual(
                projected,
                hidden,
                "\(model.model.filename) paired with a projector of the wrong dimension"
            )
        }
    }

    func testEveryDiscoveredModelHasUsableMetadata() throws {
        // Metadata is what the optimiser needs. A model that scans but yields no
        // metadata would be served with llama.cpp's defaults instead of the
        // computed plan, so it is worth failing loudly.
        let scan = try requireCorpus()

        for model in scan.models {
            XCTAssertNotNil(
                model.model.info,
                "\(model.model.filename) could not be read: \(model.model.readError ?? "no error recorded")"
            )
        }
    }

    func testDuplicatePathsAreCollapsed() throws {
        let scan = try requireCorpus()

        // The HuggingFace cache layout on this machine points several paths at
        // one file. No two entries in the library may share a resolved path.
        let paths = scan.models.compactMap { $0.model.resolvedURL?.path }
        XCTAssertEqual(paths.count, Set(paths).count, "the same file was listed more than once")
    }

    func testRealCorpusWarningsNameTheFileTheyAreAbout() throws {
        let scan = try requireCorpus()

        // This machine's corpus genuinely contains broken symlinks, so warnings
        // are expected. Each one must name the file it concerns — a warning that
        // does not say which file is a warning nobody can act on.
        let knownNames = Set(
            scan.unreadable.map(\.filename)
                + scan.orphanProjectors.map(\.filename)
                + scan.models.compactMap { $0.projector?.filename }
        )

        for warning in scan.warnings {
            XCTAssertFalse(warning.isEmpty)
            XCTAssertTrue(
                knownNames.contains { warning.contains($0) },
                "warning does not name a known file: \(warning)"
            )
        }
    }
}
