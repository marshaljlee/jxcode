import XCTest
@testable import JXCodeCore

// MARK: - The agent marks
//
// The path data in `AgentIcons` is transcribed from real icon files, which is
// exactly the kind of thing that fails silently: a dropped character produces a
// mark that renders as nothing, or as a shape nobody looks at closely enough to
// question. `SVGPathParser` was written to be testable for this reason, so these
// tests parse every layer rather than trusting that it looks right.

final class AgentIconsTests: XCTestCase {

    /// No built-in agent is allowed to be iconless by accident. A new agent
    /// added to the registry without a mark is a gap, not a design decision.
    func testEveryBuiltInAgentHasAMark() {
        for agent in AgentRegistry.builtIns {
            XCTAssertNotNil(
                AgentIcons.icon(for: agent.id),
                "\(agent.name) (\(agent.id)) has no mark in AgentIcons"
            )
        }
        XCTAssertEqual(
            Set(AgentIcons.knownAgentIDs),
            Set(AgentRegistry.builtIns.map(\.id)),
            "AgentIcons and AgentRegistry disagree about which agents exist"
        )
    }

    func testAnUnknownAgentHasNoMarkRatherThanABorrowedOne() {
        XCTAssertNil(AgentIcons.icon(for: "some-custom-cli"))
    }

    /// Five of the six supplied files match an agent by name. Recording which
    /// ones are stand-ins means the UI — and a reader of this diff — can tell
    /// the difference between a supplied icon and a chosen replacement.
    func testTheSuppliedFilesAreAttributedAndTheReplacementsAreMarked() {
        let supplied = [
            "claude": "claudecode.svg",
            "codex": "codex-color.svg",
            "gemini": "gemini-color.svg",
            "opencode": "opencode-dark.svg",
            "jules": "google-jules.svg",
        ]
        for (agentID, file) in supplied {
            XCTAssertEqual(
                AgentIcons.icon(for: agentID)?.provenance,
                .provided(file: file),
                "\(agentID) should come from \(file)"
            )
        }

        XCTAssertEqual(Set(AgentIcons.substituteIDs), ["omp", "shell"])
        for agentID in AgentIcons.substituteIDs {
            guard case .substitute(let source)? = AgentIcons.icon(for: agentID)?.provenance else {
                return XCTFail("\(agentID) is listed as a substitute but is not marked as one")
            }
            XCTAssertFalse(source.isEmpty, "\(agentID) does not say where its substitute came from")
        }
    }

    /// The test that would have caught a bad transcription. Every layer has to
    /// produce geometry, because a mark with no geometry is a blank tile.
    func testEveryLayerParsesToRealGeometry() {
        for agentID in AgentIcons.knownAgentIDs {
            let icon = AgentIcons.icon(for: agentID)!
            XCTAssertFalse(icon.layers.isEmpty, "\(agentID) has no layers")

            for (index, layer) in icon.layers.enumerated() {
                let nodes = SVGPathParser.parse(path(of: layer))
                XCTAssertFalse(nodes.isEmpty, "\(agentID) layer \(index) parsed to nothing")

                let drawsSomething = nodes.contains {
                    if case .move = $0 { return false }
                    return true
                }
                XCTAssertTrue(
                    drawsSomething,
                    "\(agentID) layer \(index) is all move commands, so it draws nothing"
                )
            }
        }
    }

    /// Geometry is authored in the icon's own box. A zero-sized box would make
    /// every scale factor infinite.
    func testEveryViewBoxIsUsable() {
        for agentID in AgentIcons.knownAgentIDs {
            let box = AgentIcons.icon(for: agentID)!.viewBox
            XCTAssertGreaterThan(box.width, 0, "\(agentID) has a zero-width view box")
            XCTAssertGreaterThan(box.height, 0, "\(agentID) has a zero-height view box")
        }
    }

    /// `userSpaceOnUse` gradients are authored in the same coordinates as the
    /// artwork, and SwiftUI wants unit points. If a gradient endpoint fell
    /// outside its view box the conversion would still "work" and quietly place
    /// the gradient somewhere the file never asked for.
    func testGradientEndpointsSitInsideTheirViewBox() {
        for agentID in AgentIcons.knownAgentIDs {
            let icon = AgentIcons.icon(for: agentID)!
            for layer in icon.layers {
                guard case .fill(_, .gradient(let gradient)) = layer else { continue }

                for point in [gradient.start, gradient.end] {
                    let unit = icon.viewBox.unit(x: point.x, y: point.y)
                    XCTAssertTrue(
                        (0...1).contains(unit.x) && (0...1).contains(unit.y),
                        "\(agentID) has a gradient endpoint at (\(point.x), \(point.y)) "
                            + "which is outside its view box"
                    )
                }
            }
        }
    }

    /// Stops are a gradient's whole content. Out of order, or outside 0…1, they
    /// render as something the icon file does not contain.
    ///
    /// The last stop is *not* required to sit at 1: Gemini's third overlay ends
    /// at 0.46, and both SVG and SwiftUI extend the final stop's colour over the
    /// remainder. Requiring 1 here would have meant editing the file's data to
    /// satisfy a test.
    func testGradientStopsAreOrderedAndInRange() {
        for agentID in AgentIcons.knownAgentIDs {
            let icon = AgentIcons.icon(for: agentID)!
            for layer in icon.layers {
                guard case .fill(_, .gradient(let gradient)) = layer else { continue }

                XCTAssertGreaterThanOrEqual(gradient.stops.count, 2, "\(agentID) has a one-stop gradient")
                XCTAssertEqual(gradient.stops.first?.offset, 0, "\(agentID) does not start at 0")

                let offsets = gradient.stops.map(\.offset)
                XCTAssertEqual(offsets, offsets.sorted(), "\(agentID) has unordered gradient stops")
                for offset in offsets {
                    XCTAssertTrue((0...1).contains(offset), "\(agentID) has a stop at \(offset)")
                }
            }
        }
    }

    /// Colours are parsed by hand in the app, so they have to arrive in the one
    /// shape that parser understands.
    func testEveryColourIsAWellFormedHexLiteral() {
        let hex = try! NSRegularExpression(pattern: "^#([0-9A-F]{3}|[0-9A-F]{6}|[0-9A-F]{8})$")

        func check(_ color: IconColor, _ context: String) {
            let range = NSRange(color.hex.startIndex..., in: color.hex)
            XCTAssertNotNil(
                hex.firstMatch(in: color.hex, range: range),
                "\(context) is not a hex colour: \(color.hex)"
            )
            XCTAssertTrue((0...1).contains(color.opacity), "\(context) has opacity \(color.opacity)")
        }

        for agentID in AgentIcons.knownAgentIDs {
            let icon = AgentIcons.icon(for: agentID)!
            for (index, layer) in icon.layers.enumerated() {
                switch layer {
                case .fill(_, let paint):
                    switch paint {
                    case .solid(let color):
                        check(color, "\(agentID) layer \(index)")
                    case .gradient(let gradient):
                        for stop in gradient.stops {
                            check(stop.color, "\(agentID) layer \(index) stop \(stop.offset)")
                        }
                    }
                case .stroke(_, let color, let width, _, _):
                    check(color, "\(agentID) layer \(index)")
                    XCTAssertGreaterThan(width, 0, "\(agentID) layer \(index) has a zero stroke width")
                }
            }
        }
    }

    /// A mark that paints its own background is drawn edge to edge; one that
    /// does not gets a tile behind it. Getting this wrong is visible: Codex's
    /// white rounded square would sit inside a second rounded square.
    func testMarksThatPaintTheirOwnBackgroundAreFlaggedAsSuch() {
        XCTAssertTrue(AgentIcons.icon(for: "codex")!.fillsTile, "Codex draws its own white square")
        XCTAssertTrue(AgentIcons.icon(for: "omp")!.fillsTile, "oh-my-pi draws its own dark square")
        XCTAssertTrue(AgentIcons.icon(for: "opencode")!.fillsTile, "opencode is a light frame, edge to edge")

        for agentID in ["claude", "gemini", "jules", "shell"] {
            XCTAssertFalse(
                AgentIcons.icon(for: agentID)!.fillsTile,
                "\(agentID) is transparent artwork and needs a tile behind it"
            )
        }
    }

    /// Gemini is four layers of the same path. If the layers were ever collapsed
    /// into one, the spark would lose the green, red and yellow edges that make
    /// it the Gemini mark rather than a blue star.
    func testGeminiKeepsItsColourOverlays() {
        let icon = AgentIcons.icon(for: "gemini")!
        XCTAssertEqual(icon.layers.count, 4)

        let paths = Set(icon.layers.map { self.path(of: $0) })
        XCTAssertEqual(paths.count, 1, "the four layers should be the same shape")

        let gradients = icon.layers.filter {
            if case .fill(_, .gradient) = $0 { return true }
            return false
        }
        XCTAssertEqual(gradients.count, 3, "the three colour overlays are missing")
    }

    // MARK: - Helpers

    private func path(of layer: IconLayer) -> String {
        switch layer {
        case .fill(let path, _): return path
        case .stroke(let path, _, _, _, _): return path
        }
    }
}
