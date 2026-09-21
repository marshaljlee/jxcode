import XCTest
@testable import JXCodeCore

final class SVGPathParserTests: XCTestCase {

    // MARK: - Basic commands

    func testMoveThenLine() {
        XCTAssertEqual(
            SVGPathParser.parse("M0 0L10 10"),
            [.move(SVGPoint(x: 0, y: 0)), .line(SVGPoint(x: 10, y: 10))]
        )
    }

    /// `M x y x y` means a move followed by an implicit line-to, not two moves.
    /// Getting this wrong collapses whole glyphs onto a single point.
    func testRepeatedArgumentsAfterMoveBecomeLineTo() {
        let nodes = SVGPathParser.parse("M0 0 10 10 20 0")
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(nodes[0], .move(SVGPoint(x: 0, y: 0)))
        XCTAssertEqual(nodes[1], .line(SVGPoint(x: 10, y: 10)))
        XCTAssertEqual(nodes[2], .line(SVGPoint(x: 20, y: 0)))
    }

    func testRepeatedArgumentsAfterLineBecomeFurtherLines() {
        let nodes = SVGPathParser.parse("M0 0L1 1 2 2 3 3")
        XCTAssertEqual(nodes.count, 4)
        XCTAssertEqual(nodes[3], .line(SVGPoint(x: 3, y: 3)))
    }

    func testLowercaseCommandsAreRelativeToCurrentPoint() {
        XCTAssertEqual(
            SVGPathParser.parse("M10 10l5 5"),
            [.move(SVGPoint(x: 10, y: 10)), .line(SVGPoint(x: 15, y: 15))]
        )
    }

    func testHorizontalAndVerticalTakeOneArgumentEach() {
        let nodes = SVGPathParser.parse("M0 0H5V7")
        XCTAssertEqual(nodes[1], .line(SVGPoint(x: 5, y: 0)))
        XCTAssertEqual(nodes[2], .line(SVGPoint(x: 5, y: 7)))
    }

    func testRelativeHorizontalAndVertical() {
        let nodes = SVGPathParser.parse("M2 3h4v5")
        XCTAssertEqual(nodes[1], .line(SVGPoint(x: 6, y: 3)))
        XCTAssertEqual(nodes[2], .line(SVGPoint(x: 6, y: 8)))
    }

    /// Commas, spaces, and the sign of the next number are all valid
    /// separators, and real icon data mixes all three.
    func testSeparatorsAreInterchangeable() {
        let comma = SVGPathParser.parse("M1,2L3,4")
        let space = SVGPathParser.parse("M1 2L3 4")
        let padded = SVGPathParser.parse("M1 2 L3 4")
        let signed = SVGPathParser.parse("M1,2L3,4-1-2")
        XCTAssertEqual(comma, space)
        XCTAssertEqual(space, padded)
        XCTAssertEqual(signed.count, 3)
        XCTAssertEqual(signed[2], .line(SVGPoint(x: -1, y: -2)))
    }

    func testCloseResetsCurrentPointToSubpathStart() {
        let nodes = SVGPathParser.parse("M2 2L10 0Zm1 1")
        XCTAssertEqual(nodes[0], .move(SVGPoint(x: 2, y: 2)))
        XCTAssertEqual(nodes[1], .line(SVGPoint(x: 10, y: 0)))
        XCTAssertEqual(nodes[2], .close)
        // The relative move after closing starts from the subpath start, not
        // from wherever the line ended.
        XCTAssertEqual(nodes[3], .move(SVGPoint(x: 3, y: 3)))
    }

    /// A closepath followed by stray numbers used to loop forever: repeating a
    /// closepath consumes no arguments, so the loop never advanced.
    func testClosepathWithStrayNumbersTerminates() {
        let nodes = SVGPathParser.parse("M0 0L10 0Z 5 5")
        XCTAssertEqual(nodes.count, 3)
        XCTAssertEqual(nodes.last, .close)
    }

    // MARK: - Curves

    func testCubicKeepsBothControlPoints() {
        let nodes = SVGPathParser.parse("M0 0C1 2 3 4 5 6")
        XCTAssertEqual(nodes[1], .cubic(SVGPoint(x: 5, y: 6),
                                        SVGPoint(x: 1, y: 2),
                                        SVGPoint(x: 3, y: 4)))
    }

    /// `S` mirrors the previous curve's second control point through the
    /// current point. Without it the OpenAI mark's outline comes apart.
    func testSmoothCubicReflectsPreviousControlPoint() {
        let nodes = SVGPathParser.parse("M0 0C1 0 9 0 10 0S19 0 20 0")
        guard case .cubic(let end, let control1, let control2) = nodes[2] else {
            return XCTFail("expected a cubic, got \(nodes[2])")
        }
        XCTAssertEqual(end, SVGPoint(x: 20, y: 0))
        XCTAssertEqual(control2, SVGPoint(x: 19, y: 0))
        // Reflection of the previous control (9,0) through the current (10,0).
        XCTAssertEqual(control1, SVGPoint(x: 11, y: 0))
    }

    func testQuadraticAndSmoothQuadratic() {
        let nodes = SVGPathParser.parse("M0 0Q5 10 10 0T20 0")
        XCTAssertEqual(nodes[1], .quad(SVGPoint(x: 10, y: 0), SVGPoint(x: 5, y: 10)))
        guard case .quad(let end, let control) = nodes[2] else {
            return XCTFail("expected a quadratic, got \(nodes[2])")
        }
        XCTAssertEqual(end, SVGPoint(x: 20, y: 0))
        // Reflection of (5,10) through (10,0).
        XCTAssertEqual(control, SVGPoint(x: 15, y: -10))
    }

    // MARK: - Arcs

    func testArcIsFlattenedToCubics() {
        let nodes = SVGPathParser.parse("M0 0A10 10 0 0 1 20 0")
        XCTAssertGreaterThanOrEqual(nodes.count, 2)
        for node in nodes.dropFirst() {
            guard case .cubic = node else {
                return XCTFail("arc should produce only cubics, got \(node)")
            }
        }
    }

    /// A zero-radius arc is a straight line. It appears in real data wherever a
    /// rounded corner degenerates, and treating it as an ellipse divides by
    /// zero and produces NaN geometry.
    func testArcWithZeroRadiusBecomesALine() {
        XCTAssertEqual(
            SVGPathParser.parse("M0 0A0 0 0 0 0 5 5"),
            [.move(SVGPoint(x: 0, y: 0)), .line(SVGPoint(x: 5, y: 5))]
        )
    }

    /// Radii that overflow are not numbers the arc maths can use. Squaring
    /// `1e200` gives infinity, and the step after that is `inf - inf`, which is
    /// NaN — and `Int(ceil(NaN))` traps, taking the process with it.
    ///
    /// Nothing shipped hits this today: the only caller parses compiled-in icon
    /// data. It is here because "only internal data reaches this" is the kind of
    /// assumption that stops being true quietly, and the failure is a crash
    /// rather than a wrong-looking curve.
    func testArcWithRadiiThatOverflowBecomesALine() {
        XCTAssertEqual(
            SVGPathParser.parse("M0 0A1e200 1e200 0 0 1 5 5"),
            [.move(SVGPoint(x: 0, y: 0)), .line(SVGPoint(x: 5, y: 5))]
        )
    }

    /// The mirror case: a radius that *underflows* to zero when squared makes
    /// `lambda` infinite, and the spec's scale-up then makes the radius
    /// infinite.
    func testArcWithRadiiThatUnderflowBecomesALine() {
        XCTAssertEqual(
            SVGPathParser.parse("M0 0A1e-200 1e-200 0 0 1 5 5"),
            [.move(SVGPoint(x: 0, y: 0)), .line(SVGPoint(x: 5, y: 5))]
        )
    }

    /// An infinite rotation is the same trap by a different route: `cos(inf)` is
    /// NaN, and every value below is derived from it.
    func testArcWithANonFiniteRotationBecomesALine() {
        XCTAssertEqual(
            SVGPathParser.parse("M0 0A5 5 1e400 0 1 5 5"),
            [.move(SVGPoint(x: 0, y: 0)), .line(SVGPoint(x: 5, y: 5))]
        )
    }

    /// So is a non-finite endpoint, which reaches the same arithmetic from the
    /// other side.
    func testArcWithANonFiniteEndpointBecomesALine() {
        XCTAssertEqual(
            SVGPathParser.parse("M1e400 0A5 5 0 0 1 5 5"),
            [.move(SVGPoint(x: 1e400, y: 0)), .line(SVGPoint(x: 5, y: 5))]
        )
    }

    func testArcProducesFiniteGeometry() {
        let nodes = SVGPathParser.parse("M0 0A10 10 0 0 1 20 0")
        for node in nodes {
            for point in Self.points(of: node) {
                XCTAssertTrue(point.x.isFinite && point.y.isFinite,
                              "non-finite point in \(node)")
            }
        }
    }

    func testArcToSamePointIsDropped() {
        XCTAssertEqual(SVGPathParser.parse("M4 4A5 5 0 0 1 4 4"),
                       [.move(SVGPoint(x: 4, y: 4))])
    }

    /// `large-arc-flag` and `sweep-flag` are defined as single characters, so
    /// the grammar lets them run into whatever follows: `0 012.285` is the
    /// rotation `0`, the flags `0` and `1`, then x = 2.285.
    ///
    /// Reading `012.285` as one number does not round anything — it
    /// desynchronises the argument list. Codex's mark is written that way, and
    /// the mis-read made the parser fail on the next argument and return after
    /// the opening move, so the mark rendered as nothing at all. Gemini's mark
    /// failed the same way but silently, producing a star of the wrong shape.
    func testCompactArcFlagsAreReadAsSingleCharacters() {
        let nodes = SVGPathParser.parse("M9.064 3.344a4.578 4.578 0 012.285-.312")

        XCTAssertEqual(nodes.first, .move(SVGPoint(x: 9.064, y: 3.344)))
        XCTAssertGreaterThan(nodes.count, 1, "the arc was dropped")

        guard case .cubic(let end, _, _)? = nodes.last else {
            return XCTFail("expected the arc to be flattened to cubics, got \(nodes)")
        }
        // The arc has to land on the endpoint the file names, which is only
        // true if the two flags were consumed as flags.
        XCTAssertEqual(end.x, 9.064 + 2.285, accuracy: 1e-9)
        XCTAssertEqual(end.y, 3.344 - 0.312, accuracy: 1e-9)
    }

    /// Both spellings mean the same thing, so they must parse the same.
    func testSpacedAndCompactArcFlagsAgree() {
        XCTAssertEqual(
            SVGPathParser.parse("M0 0a5 5 0 0 1 10 0"),
            SVGPathParser.parse("M0 0a5 5 0 0110 0")
        )
    }

    /// A flag that is not `0` or `1` is not a flag. The parser should stop
    /// rather than reinterpret the rest of the path as arguments.
    func testANonFlagWhereAFlagBelongsStopsTheParse() {
        let nodes = SVGPathParser.parse("M1 1a5 5 0 9 9 10 0")
        XCTAssertEqual(nodes, [.move(SVGPoint(x: 1, y: 1))])
    }

    // MARK: - The marks actually shipped

    /// Regression guard on the real data.
    ///
    /// A parser bug that yields no geometry renders as an empty tile, which no
    /// amount of looking at the type-checker would catch. Every shipped mark
    /// must produce geometry, and that geometry must land in the icon's own
    /// coordinate box — which is no longer 24×24 for all of them: Jules is
    /// authored on a tight box around its artwork and opencode on a 240×300
    /// canvas, so the box is read from the mark rather than assumed.
    func testShippedMarksProduceGeometryInsideTheirViewBox() {
        for agentID in AgentIcons.knownAgentIDs {
            guard let icon = AgentIcons.icon(for: agentID) else {
                return XCTFail("no mark registered for \(agentID)")
            }

            for (index, layer) in icon.layers.enumerated() {
                let data: String
                switch layer {
                case .fill(let path, _):              data = path
                case .stroke(let path, _, _, _, _):   data = path
                }

                let nodes = SVGPathParser.parse(data)
                XCTAssertGreaterThan(nodes.count, 1, "\(agentID) layer \(index) produced no geometry")

                guard case .move = nodes[0] else {
                    return XCTFail("\(agentID) layer \(index) should start with a move, got \(nodes[0])")
                }

                let box = icon.viewBox
                // A control point may sit just outside the box the artwork was
                // trimmed to — Jules's path has one at 21.41 against a box that
                // ends at 21.36 — so this is a sanity bound, not an exact one.
                let tolerance = 1.5

                for node in nodes {
                    for point in Self.points(of: node) {
                        XCTAssertTrue(
                            point.x.isFinite && point.y.isFinite,
                            "\(agentID) layer \(index): non-finite point \(point)"
                        )
                        XCTAssertGreaterThan(
                            point.x, box.x - tolerance,
                            "\(agentID) layer \(index): \(point) is left of the view box"
                        )
                        XCTAssertLessThan(
                            point.x, box.x + box.width + tolerance,
                            "\(agentID) layer \(index): \(point) is right of the view box"
                        )
                        XCTAssertGreaterThan(
                            point.y, box.y - tolerance,
                            "\(agentID) layer \(index): \(point) is above the view box"
                        )
                        XCTAssertLessThan(
                            point.y, box.y + box.height + tolerance,
                            "\(agentID) layer \(index): \(point) is below the view box"
                        )
                    }
                }
            }
        }
    }

    /// An agent the app has never heard of has no mark, so it falls back to an
    /// SF Symbol rather than rendering a blank tile.
    func testUnknownAgentHasNoMark() {
        XCTAssertNil(AgentIcons.icon(for: "definitely-not-an-agent"))
    }

    // MARK: - Malformed input

    func testEmptyStringProducesNothing() {
        XCTAssertTrue(SVGPathParser.parse("").isEmpty)
    }

    /// Truncated data must stop cleanly rather than loop or trap.
    func testTruncatedDataStopsAtTheLastCompleteCommand() {
        let nodes = SVGPathParser.parse("M0 0L10")
        XCTAssertEqual(nodes, [.move(SVGPoint(x: 0, y: 0))])
    }

    // MARK: - Helpers

    private static func points(of node: SVGPathNode) -> [SVGPoint] {
        switch node {
        case .move(let p), .line(let p):        return [p]
        case .cubic(let end, let c1, let c2):   return [end, c1, c2]
        case .quad(let end, let control):       return [end, control]
        case .close:                            return []
        }
    }
}
