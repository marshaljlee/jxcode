import XCTest
@testable import JXCodeCore

/// Guards the vendored UI icon set.
///
/// The geometry is generated from a third-party library, so the failure this
/// suite exists to catch is not a typo — it is a *silent* one. A path that
/// fails to parse, or a view box that no longer matches the artwork, renders as
/// a blank frame or a cropped glyph, and neither looks like a bug in a test
/// report. These assertions turn both into failures.
final class MXIconTests: XCTestCase {

    // MARK: - Coverage

    func testDefinitionsCoverEveryCase() {
        XCTAssertEqual(
            MXIconCatalog.definitions.count,
            MXIconName.allCases.count,
            "an icon has no definition, so it would draw as an empty frame"
        )
    }

    func testEveryIconHasAtLeastOneLayer() {
        XCTAssertTrue(
            MXIcon.missingDefinitions.isEmpty,
            "these icons have no layers: \(MXIcon.missingDefinitions.map(\.rawValue))"
        )
    }

    func testSourcesAreRecordedForEveryIcon() {
        for name in MXIconName.allCases {
            let source = MXIconCatalog.sources[name]
            XCTAssertNotNil(source, "\(name.rawValue) does not record its upstream name")
            XCTAssertFalse(source?.isEmpty ?? true, "\(name.rawValue) has an empty source")
        }
    }

    // MARK: - Geometry

    func testEveryLayerParsesToGeometry() {
        for name in MXIconName.allCases {
            let icon = MXIcon.definition(for: name)
            for (index, layer) in icon.layers.enumerated() {
                let nodes = SVGPathParser.parse(path(of: layer))
                // A bare `move` is the parser's way of saying "I understood
                // nothing" — every real icon draws something.
                XCTAssertGreaterThan(
                    nodes.count, 1,
                    "\(name.rawValue) layer \(index) produced no geometry"
                )
            }
        }
    }

    /// Every coordinate must land in the icon's own view box.
    ///
    /// This is the assertion that catches a wrong view box, and the reason the
    /// generator is allowed to assume the upstream 24×24 canvas: if mx-icons
    /// ever re-authors an icon on a different grid, the artwork would be
    /// silently cropped and this fails instead.
    ///
    /// The tolerance is for cubic control points, which are allowed to sit
    /// outside the artwork — an arc's handles do — so this is a sanity bound
    /// rather than an exact one.
    func testGeometryStaysInsideTheViewBox() {
        let tolerance = 1.5

        for name in MXIconName.allCases {
            let icon = MXIcon.definition(for: name)
            let box = icon.viewBox

            for (index, layer) in icon.layers.enumerated() {
                for node in SVGPathParser.parse(path(of: layer)) {
                    for point in Self.points(of: node) {
                        XCTAssertTrue(
                            point.x.isFinite && point.y.isFinite,
                            "\(name.rawValue) layer \(index): non-finite point \(point)"
                        )
                        XCTAssertGreaterThan(
                            point.x, box.x - tolerance,
                            "\(name.rawValue) layer \(index): \(point) is left of the view box"
                        )
                        XCTAssertLessThan(
                            point.x, box.x + box.width + tolerance,
                            "\(name.rawValue) layer \(index): \(point) is right of the view box"
                        )
                        XCTAssertGreaterThan(
                            point.y, box.y - tolerance,
                            "\(name.rawValue) layer \(index): \(point) is above the view box"
                        )
                        XCTAssertLessThan(
                            point.y, box.y + box.height + tolerance,
                            "\(name.rawValue) layer \(index): \(point) is below the view box"
                        )
                    }
                }
            }
        }
    }

    // MARK: - The primitives the generator has to translate

    /// `people` is the only vendored icon drawn with `<circle>` and `<ellipse>`
    /// rather than `<path>`, so it is the only end-to-end check that the
    /// generator's primitive conversion produces the right geometry.
    ///
    /// Upstream: `<circle cx="9.00098" cy="6" r="4">`.
    ///
    /// The accuracy is loose because the arc is a cubic approximation sampled
    /// at 256 points, not an exact circle; it is tight enough that a wrong
    /// radius or centre still fails.
    func testCirclePrimitiveBecomesACircle() {
        let icon = MXIcon.definition(for: .people)
        let nodes = SVGPathParser.parse(path(of: icon.layers[0]))
        let bounds = Self.bounds(of: nodes)

        XCTAssertEqual(bounds.minX, 9.00098 - 4, accuracy: 1e-2)
        XCTAssertEqual(bounds.maxX, 9.00098 + 4, accuracy: 1e-2)
        XCTAssertEqual(bounds.minY, 6 - 4, accuracy: 1e-2)
        XCTAssertEqual(bounds.maxY, 6 + 4, accuracy: 1e-2)
    }

    /// Upstream: `<ellipse cx="9.00098" cy="17.001" rx="7" ry="4">`.
    func testEllipsePrimitiveBecomesAnEllipse() {
        let icon = MXIcon.definition(for: .people)
        let nodes = SVGPathParser.parse(path(of: icon.layers[1]))
        let bounds = Self.bounds(of: nodes)

        XCTAssertEqual(bounds.minX, 9.00098 - 7, accuracy: 1e-2)
        XCTAssertEqual(bounds.maxX, 9.00098 + 7, accuracy: 1e-2)
        XCTAssertEqual(bounds.minY, 17.001 - 4, accuracy: 1e-2)
        XCTAssertEqual(bounds.maxY, 17.001 + 4, accuracy: 1e-2)
    }

    // MARK: - Facts about the vendored set
    //
    // These are not requirements so much as tripwires. Each one records
    // something surprising that was true when the set was generated, so that a
    // future regeneration which changes it is noticed rather than absorbed.

    /// Every vendored icon is a filled shape — including `shield`, which comes
    /// from the library's `Outline` variant.
    ///
    /// That is not a mistake in the generator. mx-icons' "Outline" style is an
    /// *outline rendered as a filled shape*, not a stroked path: the upstream
    /// file carries `fill="currentColor"` and no `stroke` at all. Reading the
    /// variant name instead of the attributes would have produced a stroke
    /// layer with no width and drawn the shield as nothing.
    ///
    /// If this ever fails, the set now contains strokes, which means
    /// `MXIconView`'s stroke branch has become live and wants looking at.
    func testTheVendoredSetIsEntirelyFilled() {
        for name in MXIconName.allCases {
            for (index, layer) in MXIcon.definition(for: name).layers.enumerated() {
                guard case .stroke = layer else { continue }
                XCTFail("\(name.rawValue) layer \(index) is stroked; "
                    + "the renderer's stroke branch is now in use and untested")
            }
        }
    }

    /// `shield` is the only icon with no Bold variant upstream, so it is the
    /// only one taken from a fallback. It is the icon the user was told would
    /// fall back to Outline.
    func testTheOnlyNonBoldVariantIsShield() {
        let fallbacks = MXIconName.allCases.filter {
            MXIconCatalog.variants[$0] != "Bold"
        }
        XCTAssertEqual(fallbacks, [.shield])
        XCTAssertEqual(MXIconCatalog.variants[.shield], "Outline")
    }

    /// The fill rule has to survive the trip, or the shapes that cut holes in
    /// themselves render as solid blobs.
    func testEvenOddIsPreservedWhereUpstreamUsesIt() {
        let evenOdd = MXIconName.allCases.filter { name in
            MXIcon.definition(for: name).layers.contains {
                if case .fill(_, let rule) = $0 { return rule == .evenodd }
                return false
            }
        }

        XCTAssertFalse(evenOdd.isEmpty, "no icon preserved its even-odd fill rule")
        XCTAssertTrue(
            evenOdd.contains(.sparkle),
            "sparkle is known to use even-odd; got \(evenOdd.map(\.rawValue))"
        )
    }

    // MARK: - Helpers

    private func path(of layer: MXIconLayer) -> String {
        switch layer {
        case .fill(let path, _):              return path
        case .stroke(let path, _, _, _):      return path
        }
    }

    private static func points(of node: SVGPathNode) -> [SVGPoint] {
        switch node {
        case .move(let point), .line(let point):  return [point]
        case .cubic(let end, let c1, let c2):     return [end, c1, c2]
        case .quad(let end, let control):         return [end, control]
        case .close:                              return []
        }
    }

    /// Points on the curve itself, sampled along each segment.
    ///
    /// Control points are deliberately *excluded*: a cubic's control points sit
    /// outside the arc it approximates, so measuring them overstates the
    /// artwork. The ellipse in `people` is the case that shows this — the
    /// parser splits its 180° arc into three 60° segments, and the middle
    /// segment's handles reach y = 21.18 against an ellipse that ends at
    /// 21.00. That is correct geometry, not a mis-parse, so a bounding-box
    /// assertion has to measure the curve rather than its handles.
    private static func curvePoints(
        of nodes: [SVGPathNode],
        steps: Int = 256
    ) -> [SVGPoint] {
        var points: [SVGPoint] = []
        var current = SVGPoint.zero
        var subpathStart = SVGPoint.zero

        func sample(_ evaluate: (Double) -> SVGPoint) {
            for step in 0...steps {
                points.append(evaluate(Double(step) / Double(steps)))
            }
        }

        for node in nodes {
            switch node {
            case .move(let point):
                points.append(point)
                current = point
                subpathStart = point

            case .line(let point):
                points.append(point)
                current = point

            case .cubic(let end, let control1, let control2):
                let start = current
                sample { t in
                    let u = 1 - t
                    let a = u * u * u
                    let b = 3 * u * u * t
                    let c = 3 * u * t * t
                    let d = t * t * t
                    return SVGPoint(
                        x: a * start.x + b * control1.x + c * control2.x + d * end.x,
                        y: a * start.y + b * control1.y + c * control2.y + d * end.y
                    )
                }
                current = end

            case .quad(let end, let control):
                let start = current
                sample { t in
                    let u = 1 - t
                    let a = u * u
                    let b = 2 * u * t
                    let c = t * t
                    return SVGPoint(
                        x: a * start.x + b * control.x + c * end.x,
                        y: a * start.y + b * control.y + c * end.y
                    )
                }
                current = end

            case .close:
                current = subpathStart
            }
        }

        return points
    }

    private static func bounds(of nodes: [SVGPathNode]) -> (
        minX: Double, minY: Double, maxX: Double, maxY: Double
    ) {
        let all = curvePoints(of: nodes)
        return (
            all.map(\.x).min() ?? .nan,
            all.map(\.y).min() ?? .nan,
            all.map(\.x).max() ?? .nan,
            all.map(\.y).max() ?? .nan
        )
    }
}
