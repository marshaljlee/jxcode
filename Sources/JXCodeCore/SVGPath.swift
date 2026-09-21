import Foundation

/// A point in an SVG's own coordinate space.
///
/// Deliberately not `CGPoint`: this lives in `JXCodeCore`, which depends on
/// neither CoreGraphics nor SwiftUI. A plain struct keeps the parser testable
/// without a graphics context, and keeps the rounding behaviour explicit.
public struct SVGPoint: Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = SVGPoint(x: 0, y: 0)

    /// Whether both coordinates are finite numbers.
    ///
    /// One that is not is still a valid value — it is what a zero radius or an
    /// overflowing one produces — so a caller has to ask rather than assume.
    public var isFinite: Bool { x.isFinite && y.isFinite }
}

/// One drawing step of a parsed SVG path.
///
/// Elliptical arcs are converted to cubics *at parse time*, so a consumer only
/// ever handles these five cases. That is the whole reason this type exists
/// rather than the caller walking raw SVG commands: arc flattening is the part
/// that is easy to get subtly wrong, and it should be wrong in one place.
public enum SVGPathNode: Equatable {
    case move(SVGPoint)
    case line(SVGPoint)
    /// end point, first control, second control
    case cubic(SVGPoint, SVGPoint, SVGPoint)
    /// end point, control
    case quad(SVGPoint, SVGPoint)
    case close
}

/// Parses the `d` attribute of an SVG `<path>` into drawing steps.
///
/// Supports the full command set that real-world icon sets use — `M m L l H h
/// V v C c S s Q q T t A a Z z` — including the implicit repetition that lets
/// `L 1 1 2 2` mean two lines, and the reflected control points that `S` and
/// `T` inherit from the preceding curve.
///
/// The input is icon path data rather than a document, so `<svg>` structure,
/// transforms, and CSS are all out of scope by design.
public enum SVGPathParser {

    private static let commandCharacters = Set("MmLlHhVvCcSsQqTtAaZz")

    public static func parse(_ d: String) -> [SVGPathNode] {
        var tokens = tokenize(d)
        var nodes: [SVGPathNode] = []

        var index = 0
        var current = SVGPoint.zero
        var subpathStart = SVGPoint.zero
        var lastCubicControl: SVGPoint?
        var lastQuadControl: SVGPoint?
        var command: Character = "M"

        /// Reads one number. Does not consume a command letter, so that a
        /// repeated command can run out of arguments and hand control back.
        func number() -> Double? {
            guard index < tokens.count, let value = Double(tokens[index]) else { return nil }
            index += 1
            return value
        }

        /// Reads one arc flag.
        ///
        /// `large-arc-flag` and `sweep-flag` are defined as a *single character*
        /// rather than as numbers, which is why the grammar permits them to run
        /// into whatever follows: `a1 1 0 012.5 0` is flags 0 and 1 followed by
        /// x = 2.5. A tokeniser that does not know that reads `012.5` as one
        /// number, and the arc it produces is not the arc in the file.
        ///
        /// This is not hypothetical. Codex's mark is written
        /// `a4.578 4.578 0 012.285-.312`; without this, the parser consumed the
        /// bogus flag, then failed to read a number where a `c` command stood,
        /// and returned after the opening move — a mark that rendered as
        /// nothing. Gemini's mark failed the same way but *silently*: it kept
        /// consuming numbers and produced a star of the wrong shape.
        func flag() -> Bool? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            guard let first = token.first, first == "0" || first == "1" else { return nil }
            if token.count == 1 {
                index += 1
            } else {
                // Take one character and leave the remainder for the next read.
                tokens[index] = String(token.dropFirst())
            }
            return first == "1"
        }

        /// Two numbers, as a point, resolved against `command`'s case.
        func point(relative: Bool = false) -> SVGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return relative
                ? SVGPoint(x: current.x + x, y: current.y + y)
                : SVGPoint(x: x, y: y)
        }

        while index < tokens.count {
            let token = tokens[index]
            var isExplicit = false
            if token.count == 1, let first = token.first, Self.commandCharacters.contains(first) {
                command = first
                index += 1
                isExplicit = true
            }
            // Otherwise: repeat the previous command with fresh arguments.

            // Closepath is the only command that takes no arguments, so an
            // implicit repeat of it would consume nothing and append forever —
            // `Z 5 5` hung the parser for real. It has no implicit repeat in
            // the spec either, so stopping here is the correct reading.
            if !isExplicit, command == "Z" || command == "z" { break }

            let relative = command.isLowercase

            switch command {
            case "M", "m":
                guard let p = point(relative: relative) else { return nodes }
                nodes.append(.move(p))
                current = p
                subpathStart = p
                lastCubicControl = nil
                lastQuadControl = nil
                // A move with further argument pairs is an implicit line-to.
                command = relative ? "l" : "L"

            case "L", "l":
                guard let p = point(relative: relative) else { return nodes }
                nodes.append(.line(p))
                current = p
                lastCubicControl = nil
                lastQuadControl = nil

            case "H", "h":
                guard let x = number() else { return nodes }
                let p = SVGPoint(x: relative ? current.x + x : x, y: current.y)
                nodes.append(.line(p))
                current = p
                lastCubicControl = nil
                lastQuadControl = nil

            case "V", "v":
                guard let y = number() else { return nodes }
                let p = SVGPoint(x: current.x, y: relative ? current.y + y : y)
                nodes.append(.line(p))
                current = p
                lastCubicControl = nil
                lastQuadControl = nil

            case "C", "c":
                guard let c1 = point(relative: relative),
                      let c2 = point(relative: relative),
                      let end = point(relative: relative) else { return nodes }
                nodes.append(.cubic(end, c1, c2))
                current = end
                lastCubicControl = c2
                lastQuadControl = nil

            case "S", "s":
                guard let c2 = point(relative: relative),
                      let end = point(relative: relative) else { return nodes }
                // Reflect the previous curve's last control point through the
                // current point. With no previous curve, it degenerates to the
                // current point, which is what the spec asks for.
                let c1 = lastCubicControl.map {
                    SVGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                nodes.append(.cubic(end, c1, c2))
                current = end
                lastCubicControl = c2
                lastQuadControl = nil

            case "Q", "q":
                guard let control = point(relative: relative),
                      let end = point(relative: relative) else { return nodes }
                nodes.append(.quad(end, control))
                current = end
                lastQuadControl = control
                lastCubicControl = nil

            case "T", "t":
                guard let end = point(relative: relative) else { return nodes }
                let control = lastQuadControl.map {
                    SVGPoint(x: 2 * current.x - $0.x, y: 2 * current.y - $0.y)
                } ?? current
                nodes.append(.quad(end, control))
                current = end
                lastQuadControl = control
                lastCubicControl = nil

            case "A", "a":
                guard let rx = number(), let ry = number(), let degrees = number(),
                      let largeArc = flag(), let sweep = flag(),
                      let x = number(), let y = number() else { return nodes }
                let to = relative
                    ? SVGPoint(x: current.x + x, y: current.y + y)
                    : SVGPoint(x: x, y: y)
                nodes.append(contentsOf: arc(
                    from: current, to: to,
                    rx: rx, ry: ry,
                    rotation: degrees * .pi / 180,
                    largeArc: largeArc,
                    sweep: sweep
                ))
                current = to
                lastCubicControl = nil
                lastQuadControl = nil

            case "Z", "z":
                nodes.append(.close)
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil

            default:
                index += 1
            }
        }

        return nodes
    }

    // MARK: - Tokenising

    /// Splits path data into command letters and number literals.
    ///
    /// SVG numbers are separated by commas, whitespace, or simply the next
    /// sign — `1.5-2` is two numbers — so the separator to watch for is a
    /// command letter or an explicit delimiter, not whitespace alone.
    private static func tokenize(_ d: String) -> [String] {
        var tokens: [String] = []
        var literal = ""

        func flush() {
            if !literal.isEmpty {
                tokens.append(literal)
                literal = ""
            }
        }

        for character in d {
            if Self.commandCharacters.contains(character) {
                flush()
                tokens.append(String(character))
            } else if character == ","
                        || character == " "
                        || character == "\n"
                        || character == "\r"
                        || character == "\t" {
                flush()
            } else if character == "-", let last = literal.last, last != "e", last != "E" {
                // A sign starts a new number, so `4-1-2` is three numbers. The
                // exception is an exponent: in `1e-5` the sign belongs to the
                // number already being read.
                flush()
                literal.append(character)
            } else if character == ".", literal.contains(".") {
                // Same for a second decimal point: `1.5.5` is two numbers.
                flush()
                literal.append(character)
            } else {
                literal.append(character)
            }
        }
        flush()
        return tokens
    }

    // MARK: - Arcs

    /// Approximates one elliptical arc with cubic segments.
    ///
    /// The endpoint-to-centre parameterisation from the SVG spec, then each
    /// slice is approximated by a cubic. Slices are capped at 90° because a
    /// single cubic across a wider arc visibly bulges away from the true curve.
    private static func arc(
        from: SVGPoint, to: SVGPoint,
        rx rawRX: Double, ry rawRY: Double,
        rotation: Double, largeArc: Bool, sweep: Bool
    ) -> [SVGPathNode] {
        guard from != to else { return [] }

        var rx = abs(rawRX)
        var ry = abs(rawRY)
        // No radii at all is a straight line, which is what the spec says.
        guard rx > 0, ry > 0 else { return [.line(to)] }

        let cosPhi = cos(rotation)
        let sinPhi = sin(rotation)

        // Midpoint difference, rotated into the ellipse's own frame.
        let dx = (from.x - to.x) / 2
        let dy = (from.y - to.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy
        let y1 = -sinPhi * dx + cosPhi * dy

        // Radii too small to span the endpoints are scaled up uniformly, per
        // the spec, rather than producing an impossible ellipse.
        var rx2 = rx * rx
        var ry2 = ry * ry
        // A radius whose square overflows is not one this arithmetic can use:
        // `1e200²` is infinity. Nothing below traps on it — the two clamps eat
        // the NaN, because a comparison against NaN is false and so `max(0,
        // x)` hands back the `0` — which is what turns it into points at 1e200
        // instead of an error.
        guard rx2.isFinite, ry2.isFinite else { return [.line(to)] }

        let x12 = x1 * x1
        let y12 = y1 * y1
        let lambda = x12 / rx2 + y12 / ry2
        if lambda > 1 {
            let scale = sqrt(lambda)
            rx *= scale
            ry *= scale
            rx2 = rx * rx
            ry2 = ry * ry
        }

        let sign: Double = (largeArc != sweep) ? 1 : -1
        let numerator = max(0, rx2 * ry2 - rx2 * y12 - ry2 * x12)
        let denominator = rx2 * y12 + ry2 * x12
        let coefficient = sign * sqrt(numerator / max(denominator, 1e-12))

        let cxLocal = coefficient * (rx * y1 / ry)
        let cyLocal = coefficient * -(ry * x1 / rx)

        let cx = cosPhi * cxLocal - sinPhi * cyLocal + (from.x + to.x) / 2
        let cy = sinPhi * cxLocal + cosPhi * cyLocal + (from.y + to.y) / 2

        /// Signed angle between two vectors.
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let dot = ux * vx + uy * vy
            let lengths = sqrt(ux * ux + uy * uy) * sqrt(vx * vx + vy * vy)
            var value = acos(min(1, max(-1, dot / max(lengths, 1e-12))))
            if ux * vy - uy * vx < 0 { value = -value }
            return value
        }

        let startAngle = angle(1, 0, (x1 - cxLocal) / rx, (y1 - cyLocal) / ry)
        var sweepAngle = angle(
            (x1 - cxLocal) / rx, (y1 - cyLocal) / ry,
            (-x1 - cxLocal) / rx, (-y1 - cyLocal) / ry
        )

        if !sweep, sweepAngle > 0 { sweepAngle -= 2 * .pi }
        if sweep, sweepAngle < 0 { sweepAngle += 2 * .pi }

        // Every number the geometry below is built from, checked once. Any of
        // them can still overflow or cancel to NaN on the way here — a radius
        // of `1e-200` squares to zero, so `lambda` is infinity and the scale-up
        // makes the radius infinite; an infinite rotation makes `cos` NaN — and
        // NaN geometry renders as nothing at all while looking like valid data.
        // A degenerate arc is a straight line.
        //
        // Checked here rather than on the way in because this is where the
        // answers exist: one guard on the computed values covers every route,
        // where a guard on the arguments has to enumerate them.
        guard sweepAngle.isFinite, cx.isFinite, cy.isFinite,
              rx.isFinite, ry.isFinite
        else { return [.line(to)] }

        let slices = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2))))
        let delta = sweepAngle / Double(slices)
        // Standard cubic approximation constant for an arc of `delta` radians.
        let alpha = (4.0 / 3.0) * tan(delta / 4)

        var result: [SVGPathNode] = []
        var theta = startAngle

        for _ in 0..<slices {
            let cosStart = cos(theta)
            let sinStart = sin(theta)
            let cosEnd = cos(theta + delta)
            let sinEnd = sin(theta + delta)

            func point(at angleValue: Double) -> SVGPoint {
                SVGPoint(
                    x: cosPhi * rx * cos(angleValue) - sinPhi * ry * sin(angleValue) + cx,
                    y: sinPhi * rx * cos(angleValue) + cosPhi * ry * sin(angleValue) + cy
                )
            }

            let start = point(at: theta)
            let end = point(at: theta + delta)

            // Derivative of the ellipse parameterisation, used to place the
            // control points along the true tangent.
            let dxStart = -cosPhi * rx * sinStart - sinPhi * ry * cosStart
            let dyStart = -sinPhi * rx * sinStart + cosPhi * ry * cosStart
            let dxEnd = -cosPhi * rx * sinEnd - sinPhi * ry * cosEnd
            let dyEnd = -sinPhi * rx * sinEnd + cosPhi * ry * cosEnd

            result.append(.cubic(
                end,
                SVGPoint(x: start.x + alpha * dxStart, y: start.y + alpha * dyStart),
                SVGPoint(x: end.x - alpha * dxEnd, y: end.y - alpha * dyEnd)
            ))

            theta += delta
        }

        return result
    }
}
