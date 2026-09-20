import JXCodeCore
import SwiftUI

// MARK: - Drawing a mark
//
// `AgentIcons` describes an agent's mark as layers of path data with the paint
// the icon file gave each one. This is the other half: turning those values
// into SwiftUI, without the app having to know anything about SVG.

/// One layer, scaled from the icon's own coordinate space into the rect it is
/// handed.
///
/// The mapping is **view box → rect**, not bounding box → rect. That is what
/// makes a `userSpaceOnUse` gradient land where the file says it should:
/// SwiftUI resolves a shape's gradient against the shape's frame, and this
/// frame is the view box.
///
/// Shared with `MXIconView`: the UI icons vendored from mx-icons are described
/// in the same `IconViewBox` coordinates, so they scale through the same code
/// rather than a second copy of it.
struct IconLayerShape: Shape {
    let pathData: String
    let viewBox: IconViewBox

    func path(in rect: CGRect) -> Path {
        let path = Path(parsingSVGPath: pathData)
        // `min` rather than a separate scale per axis: a mark is artwork, and
        // stretching it to fill a non-matching rect would distort it.
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let centreX = viewBox.x + viewBox.width / 2
        let centreY = viewBox.y + viewBox.height / 2
        return path.applying(CGAffineTransform(
            a: scale, b: 0, c: 0, d: scale,
            tx: rect.midX - centreX * scale,
            ty: rect.midY - centreY * scale
        ))
    }
}

extension Path {
    /// Builds a path from SVG `d` data.
    ///
    /// Arcs are already flattened to cubics by the parser, so there is nothing
    /// here but a direct translation of each node.
    init(parsingSVGPath data: String) {
        self.init()
        for node in SVGPathParser.parse(data) {
            switch node {
            case .move(let point):
                move(to: CGPoint(x: point.x, y: point.y))
            case .line(let point):
                addLine(to: CGPoint(x: point.x, y: point.y))
            case .cubic(let end, let control1, let control2):
                addCurve(
                    to: CGPoint(x: end.x, y: end.y),
                    control1: CGPoint(x: control1.x, y: control1.y),
                    control2: CGPoint(x: control2.x, y: control2.y)
                )
            case .quad(let end, let control):
                addQuadCurve(
                    to: CGPoint(x: end.x, y: end.y),
                    control: CGPoint(x: control.x, y: control.y)
                )
            case .close:
                closeSubpath()
            }
        }
    }
}

// MARK: - Colour

extension Color {
    /// `#RRGGBB`, `#RGB` or `#RRGGBBAA`.
    ///
    /// A hand-written parse rather than `NSColor(hex:)`-style helpers, because
    /// those live in AppKit and this has to work wherever the view does.
    init(hex: String) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        var value: UInt64 = 0
        Scanner(string: digits).scanHexInt64(&value)

        let hasAlpha = digits.count == 8
        self.init(
            .sRGB,
            red: Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255,
            green: Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255,
            blue: Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255,
            opacity: hasAlpha ? Double(value & 0xFF) / 255 : 1
        )
    }
}

extension IconColor {
    var swiftUIColor: Color {
        Color(hex: hex).opacity(opacity)
    }
}

extension IconPoint {
    var unitPoint: UnitPoint { UnitPoint(x: x, y: y) }
}

extension IconStrokeCap {
    var swiftUI: CGLineCap {
        switch self {
        case .butt:   return .butt
        case .round:  return .round
        case .square: return .square
        }
    }
}

extension IconStrokeJoin {
    var swiftUI: CGLineJoin {
        switch self {
        case .miter: return .miter
        case .round: return .round
        case .bevel: return .bevel
        }
    }
}

extension IconPaint {
    /// A fill style, with gradient endpoints resolved through the view box.
    func style(in viewBox: IconViewBox) -> AnyShapeStyle {
        switch self {
        case .solid(let color):
            return AnyShapeStyle(color.swiftUIColor)
        case .gradient(let gradient):
            return AnyShapeStyle(LinearGradient(
                stops: gradient.stops.map {
                    Gradient.Stop(color: $0.color.swiftUIColor, location: $0.offset)
                },
                startPoint: viewBox.unit(x: gradient.start.x, y: gradient.start.y).unitPoint,
                endPoint: viewBox.unit(x: gradient.end.x, y: gradient.end.y).unitPoint
            ))
        }
    }
}

// MARK: - The mark

/// An agent's mark, drawn from the icon file's own layers.
///
/// `size` is needed because a stroked layer's width is authored in view box
/// units, and SwiftUI does not scale a stroke with the path it is applied to.
struct AgentIconView: View {
    let icon: AgentIcon
    let size: CGFloat

    private var scale: CGFloat {
        size / max(icon.viewBox.width, icon.viewBox.height)
    }

    var body: some View {
        ZStack {
            // `enumerated` rather than `id: \.self`: a mark may legitimately
            // draw the same path twice with different paint, as Gemini does.
            ForEach(Array(icon.layers.enumerated()), id: \.offset) { _, layer in
                layerView(layer)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func layerView(_ layer: IconLayer) -> some View {
        switch layer {
        case .fill(let pathData, let paint):
            IconLayerShape(pathData: pathData, viewBox: icon.viewBox)
                .fill(paint.style(in: icon.viewBox))

        case .stroke(let pathData, let color, let width, let cap, let join):
            IconLayerShape(pathData: pathData, viewBox: icon.viewBox)
                .stroke(
                    color.swiftUIColor,
                    style: StrokeStyle(
                        lineWidth: width * scale,
                        lineCap: cap.swiftUI,
                        lineJoin: join.swiftUI
                    )
                )
        }
    }
}

/// An agent's mark on a tile, sized for the launcher and the agent menu.
struct AgentIconTile: View {
    let agentID: String
    var size: CGFloat = 32

    /// Every tile rounds the same way, so a column of them reads as a set.
    private static let cornerRatio: CGFloat = 0.22
    /// Transparent artwork is inset so it does not touch the tile edge.
    /// A mark that brings its own background is not: it *is* the background.
    private static let insetRatio: CGFloat = 0.66

    var body: some View {
        if let icon = AgentIcons.icon(for: agentID) {
            let radius = size * Self.cornerRatio
            ZStack {
                if !icon.fillsTile {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(Theme.surfaceElevated)
                }
                AgentIconView(
                    icon: icon,
                    size: icon.fillsTile ? size : size * Self.insetRatio
                )
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.borderStrong, lineWidth: 1)
            )
        } else {
            // No mark — a custom agent, or one the icon set has nothing for.
            // The generated tile is honest about being generic, which is better
            // than drawing a near-miss of someone else's logo.
            IconTile(
                icon: AgentPresentation.icon(for: agentID),
                color: Theme.tile(for: agentID),
                size: size
            )
        }
    }
}
