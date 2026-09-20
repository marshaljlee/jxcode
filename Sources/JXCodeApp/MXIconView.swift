import JXCodeCore
import SwiftUI

// MARK: - The interface's own icons
//
// `AgentIcons` and `AgentIconView` draw the marks for the agents themselves,
// from the icon files the user supplied. This draws everything else: the add,
// close, refresh and warning glyphs that used to be SF Symbols.
//
// They share a renderer on purpose. Both icon sets are described as path
// strings in a 24×24 view box, so both go through `IconLayerShape` and
// `SVGPathParser`. The only real difference is the paint: an agent's mark
// carries its own colours, while these are `currentColor` — they take the tint
// of whatever row they sit in, so a disabled control greys out for free.

/// One UI icon, drawn at `size` points.
///
/// `size` is required rather than inferred because a stroked layer's width is
/// authored in view box units and SwiftUI does not scale a stroke with the
/// path it is applied to. The stroke has to be scaled by hand.
struct MXIconView: View {
    let name: MXIconName
    var size: CGFloat = 14
    /// `nil` means `currentColor`: inherit the ambient foreground style, which
    /// is what lets one definition serve a bright row and a dimmed one.
    var tint: Color?

    private var icon: MXIconDefinition { MXIcon.definition(for: name) }

    private var scale: CGFloat {
        size / max(icon.viewBox.width, icon.viewBox.height)
    }

    private var style: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint) }
        return AnyShapeStyle(.foreground)
    }

    var body: some View {
        ZStack {
            // `enumerated` rather than `id: \.self`: an icon may draw the same
            // path twice with different paint, and two layers can legitimately
            // be identical.
            ForEach(Array(icon.layers.enumerated()), id: \.offset) { _, layer in
                layerView(layer)
            }
        }
        .frame(width: size, height: size)
        // Decorative: every icon in this app sits beside a label or inside a
        // button that already names itself, so announcing the glyph again would
        // only make VoiceOver more repetitive.
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func layerView(_ layer: MXIconLayer) -> some View {
        switch layer {
        case .fill(let pathData, let rule):
            IconLayerShape(pathData: pathData, viewBox: icon.viewBox)
                .fill(style, style: FillStyle(eoFill: rule == .evenodd))

        case .stroke(let pathData, let width, let cap, let join):
            IconLayerShape(pathData: pathData, viewBox: icon.viewBox)
                .stroke(
                    style,
                    style: StrokeStyle(
                        lineWidth: width * scale,
                        lineCap: cap.swiftUI,
                        lineJoin: join.swiftUI
                    )
                )
        }
    }
}

extension MXIconName {
    /// The icon as a view, for the common case of a fixed size and an
    /// inherited tint.
    func view(size: CGFloat = 14, tint: Color? = nil) -> MXIconView {
        MXIconView(name: self, size: size, tint: tint)
    }
}
