import JXCodeCore
import SwiftUI

/// The visual language: one design in two modes.
///
/// The references are **one design in two modes** — the same warm neutral base,
/// the same amber accent, the same six dot colours — so this is one palette with
/// two sets of stops rather than two palettes. `Theme` previously pinned a single
/// dark set of constants, which meant a light-mode user got a dark app; the
/// colours here follow the system appearance instead.
///
/// What was sampled, and what it is for:
///
/// - **The base is warm, not blue-grey.** The light page is cream (`#EAE7E1`)
///   under white cards; the dark page is `#141319` under `#191919`. Nothing here
///   is a neutral grey — every surface carries a little red and yellow.
/// - **There is one accent, and it is amber (`#FEB43B`).** It is used as a
///   *fill* with dark text on top, never as coloured text on a light surface,
///   where it would be unreadable. That distinction is why `accent` and
///   `accentFill` are separate: `accent` is the foreground-readable amber (dark
///   in light mode, bright in dark mode) and is what every existing tint call
///   site wants, while `accentFill` is the button colour from the reference.
/// - **The dots are six evenly spaced hues**, sampled from the sidebar: amber,
///   blue, green, teal, purple, violet. They are the same in both modes, because
///   they are identity colours rather than surfaces.
///
/// This file owns the **rendering**; it does not own the values a contrast rule
/// governs. Surfaces, status colours and dots come from `Palette` in
/// `JXCodeCore`, which is where the rule and its tests live — see `Palette` for
/// why the numbers are not here.
enum Theme {

    // MARK: - Surfaces

    /// The page behind everything: the window, the sidebar, the area between
    /// cards. Deepest of the three in both modes.
    static let surfaceDeepest  = adaptive(light: Palette.LightSurface.page,
                                          dark: 0x141319)
    /// Cards and panels — the workhorse surface.
    static let surface         = adaptive(light: Palette.LightSurface.card,
                                          dark: 0x191919)
    /// The selected or hovered fill. Note the direction differs by mode, which
    /// is normal for elevation: in light mode it reads as a pressed tint against
    /// white, in dark mode as a raised panel.
    static let surfaceElevated = adaptive(light: Palette.LightSurface.elevated,
                                          dark: 0x242427)
    /// A well — code, terminal, any area that should read as inset rather than
    /// raised. Dark in **both** modes, which is deliberate and is why the
    /// terminal does not follow the appearance either.
    static let surfaceSunken   = adaptive(light: 0x1F1E1C, dark: 0x0F0E13)

    // MARK: - Lines

    /// Kept as low-alpha inks so they read as a hint, not a stroke, and so the
    /// same constant works on every surface in its mode.
    static let border       = adaptive(light: 0x1F1E1C, dark: 0xFFFFFF,
                                       lightAlpha: 0.10, darkAlpha: 0.08)
    static let borderStrong = adaptive(light: 0x1F1E1C, dark: 0xFFFFFF,
                                       lightAlpha: 0.22, darkAlpha: 0.15)

    // MARK: - Text

    static let textPrimary   = adaptive(light: Palette.TextLight.primary,
                                        dark: Palette.TextDark.primary)
    static let textSecondary = adaptive(light: Palette.TextLight.secondary,
                                        dark: Palette.TextDark.secondary)
    static let textTertiary  = adaptive(light: Palette.TextLight.tertiary,
                                        dark: Palette.TextDark.tertiary)

    // MARK: - Accent

    /// The amber, as a **foreground**: dark enough to read on a light surface,
    /// bright enough to read on a dark one. This is what icon tints and
    /// `.foregroundStyle` want, and it is deliberately not the reference's
    /// button colour.
    static let accent      = adaptive(light: 0x805100, dark: 0xFEB43B)
    /// The amber as a **fill** — the reference's send button and pill. Always
    /// pair with `accentOn`; amber with white text fails contrast in both modes.
    static let accentFill  = adaptive(light: 0xFEB43B, dark: 0xFEB43B)
    static let accentHover = adaptive(light: 0xE89F2C, dark: 0xFFC55E)
    /// Text and glyphs drawn *on* `accentFill`. Also the dark ink for a tile.
    static let accentOn    = adaptive(light: Palette.inkDark, dark: Palette.inkDark)
    // MARK: - Chart segments

    /// Segments of a proportional bar, in draw order.
    ///
    /// These are **not** `tile*` — an identity dot carries its own ink and can
    /// be faint, a bar segment has only the surface behind it and cannot. The
    /// `Palette.Chart*` values are pinned to clear the graphic floor at the
    /// alpha the bar actually draws them at, and to stay far enough apart in
    /// luminance that the bar still reads without hue.
    static let chartWeights   = adaptive(light: Palette.ChartLight.weights,
                                         dark:  Palette.ChartDark.weights)
    static let chartKVCache   = adaptive(light: Palette.ChartLight.kvCache,
                                         dark:  Palette.ChartDark.kvCache)
    static let chartProjector = adaptive(light: Palette.ChartLight.projector,
                                         dark:  Palette.ChartDark.projector)
    static let chartCompute   = adaptive(light: Palette.ChartLight.compute,
                                         dark:  Palette.ChartDark.compute)

    // MARK: - Status

    /// Light values come from `Palette.StatusLight`, where each one is pinned to
    /// clear 4.5:1 on every light surface *and* on its own wash. The dark values
    /// already passed and are kept as sampled.
    static let success = adaptive(light: Palette.StatusLight.success, dark: 0x4BAC65)
    static let warning = adaptive(light: Palette.StatusLight.warning, dark: 0xF5B549)
    static let danger  = adaptive(light: Palette.StatusLight.danger,  dark: 0xF45F59)
    static let info    = adaptive(light: Palette.StatusLight.info,    dark: 0x40C8E0)

    // MARK: - Dots

    static let tileAmber  = solid(Palette.Tile.amber)
    static let tileBlue   = solid(Palette.Tile.blue)
    static let tileGreen  = solid(Palette.Tile.green)
    static let tileTeal   = solid(Palette.Tile.teal)
    static let tilePurple = solid(Palette.Tile.purple)
    static let tilePink   = solid(Palette.Tile.pink)
    static let tileOrange = solid(Palette.Tile.orange)

    /// Deterministic accent for a key. The same workspace always gets the same
    /// dot color so the eye learns where it lives.
    ///
    /// `hashValue` was the obvious choice here and it was wrong: Swift seeds
    /// `String.hashValue` per process, so every relaunch reshuffled the dots
    /// and the promise in the line above held only within a single run. FNV-1a
    /// is stable across processes, which is the entire requirement.
    static func tile(for key: String) -> Color {
        switch stableHash(key) % 6 {
        case 0: return tilePurple
        case 1: return tileOrange
        case 2: return tileTeal
        case 3: return tilePink
        case 4: return tileGreen
        default: return tileAmber
        }
    }

    /// Ink for a glyph drawn on `fill`.
    ///
    /// The rule lives in `Palette.ink(on:)`; this is only the bridge from a
    /// `Color` back to the `0xRRGGBB` it was built from, so there is exactly one
    /// implementation of the decision. A colour that cannot be converted falls
    /// back to white, which is what every tile used to be.
    ///
    /// The ramp is hashed, so any key can land on any dot and every dot has to
    /// carry a readable glyph — white is 1.81:1 on `tileAmber`, which is the
    /// whole reason this is not a constant.
    static func ink(on fill: Color) -> Color {
        guard let rgb = fill.rgbHex else { return .white }
        return solid(Palette.ink(on: rgb))
    }

    /// FNV-1a, 64-bit. Chosen for being short enough to read and stable enough
    /// to depend on — not for distribution quality.
    static func stableHash(_ value: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}

// MARK: - Building the colours

/// `0xRRGGBB`, sRGB.
extension NSColor {
    convenience init(rgb: UInt32, alpha: Double = 1) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green:   CGFloat((rgb >> 8) & 0xFF) / 255,
            blue:    CGFloat(rgb & 0xFF) / 255,
            alpha:   CGFloat(alpha)
        )
    }
}

extension Color {
    /// The `0xRRGGBB` this colour was built from, in sRGB.
    ///
    /// `nil` when the colour cannot be converted to sRGB, which is the honest
    /// answer for a dynamic colour resolved outside an appearance context. Only
    /// the identity dots are read back, and those are the same in both modes.
    var rgbHex: UInt32? {
        guard let srgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> UInt32 {
            UInt32((Double(value) * 255).rounded())
        }
        return (channel(srgb.redComponent) << 16)
             | (channel(srgb.greenComponent) << 8)
             | channel(srgb.blueComponent)
    }
}

/// A colour that resolves per appearance.
///
/// `NSColor(name:dynamicProvider:)` is the mechanism rather than
/// `Color(light:dark:)`-style asset colours because the palette is defined in
/// code, next to the comments that explain where each value came from. A
/// dynamic provider keeps that true and still follows the system appearance.
private func adaptive(light: UInt32, dark: UInt32,
                      lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(rgb: dark, alpha: darkAlpha)
            : NSColor(rgb: light, alpha: lightAlpha)
    })
}

/// A colour that is the same in both appearances.
private func solid(_ rgb: UInt32) -> Color {
    Color(nsColor: NSColor(rgb: rgb))
}

// MARK: - Building blocks

/// A rounded card with a subtle border — the workhorse surface in the sidebar
/// and the action grid. Defaults match `Theme.surface` + `Theme.border`.
struct Card: ViewModifier {
    var padding: CGFloat = 14
    var radius: CGFloat = 10
    var background: Color = Theme.surface
    var border: Color = Theme.border
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(border, lineWidth: 1)
            )
    }
}

extension View {
    func card(padding: CGFloat = 14, radius: CGFloat = 10,
              background: Color = Theme.surface,
              border: Color = Theme.border) -> some View {
        modifier(Card(padding: padding, radius: radius,
                      background: background, border: border))
    }
}

/// Pill-shaped badge for the count chips and the "Free" indicator in the
/// reference. Background defaults to the elevated surface so it reads against
/// both the sidebar and the cards.
struct Badge: View {
    let text: String
    var color: Color = Theme.textSecondary
    var background: Color = Theme.surfaceElevated
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
    }
}

/// Icon tile — a small square with a glyph over a colored background.
/// Used by the workspace list and any future action grid.
///
/// The glyph's ink is **derived from the fill** rather than fixed at white, so a
/// tile stays legible whichever dot the hash picks — see `Theme.ink(on:)`.
///
/// The glyph is an `MXIconName` rather than an SF Symbol string: the app's own
/// chrome is drawn from the vendored mx-icons set, so a typo is a compile error
/// rather than a blank square at runtime.
struct IconTile: View {
    let icon: MXIconName
    var color: Color
    var size: CGFloat = 32
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color)
            MXIconView(name: icon, size: size * 0.5, tint: Theme.ink(on: color))
        }
        .frame(width: size, height: size)
    }
}

/// A dot of an identity colour — the reference's sidebar markers, and the
/// smallest unit of the tile palette.
struct ColorDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// The reference's amber primary button: an amber fill with dark text on it.
///
/// Deliberately not `.borderedProminent` with a `.tint`. That style paints its
/// label white, and white on amber fails contrast in both modes — the reference
/// pairs the amber with near-black for exactly this reason. Owning the label
/// colour is the whole reason this exists rather than being a one-line tint.
struct PrimaryButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Theme.accentOn)
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 3 : 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(configuration.isPressed ? Theme.accentHover : Theme.accentFill)
            )
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryCompact: PrimaryButtonStyle { PrimaryButtonStyle(compact: true) }
}
