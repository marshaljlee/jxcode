import JXCodeCore
import SwiftUI

/// The visual language: the app's hero illustration, carried through the chrome.
///
/// The hero illustration — a night scene on near-black charcoal (`#0C0E0F`–
/// `#16181B`) lit by a glowing periwinkle-and-amber sky — is the design's source
/// of truth. The governed half of the palette (surfaces, accent, text, status,
/// dots, charts) lives in `JXCodeCore.Palette`, where `PaletteTests` holds it to
/// the contrast rules; this file owns the **rendering**: the `Color` bridge, the
/// adaptive mechanism, and the view components every pane consumes.
///
/// Two consequences of that sampling shape everything here:
///
/// - **The app is a dark room with one light in it.** Surfaces are charcoal, not
///   grey — every stop carries a little blue — and the accent is the
///   illustration's periwinkle glow, not a corporate blue. Amber survives as a
///   *secondary* colour (`sunlit`), the way it appears in the illustration's
///   sky, and is never the accent.
/// - **Light mode keeps its own design.** The illustration is a dark-mode
///   object; the light stops are the earlier reference screenshots' warm cream
///   and white with the periwinkle accent darkened for contrast, and
///   `adaptive(light:dark:)` follows the system appearance between the two.
enum Theme {

    // MARK: - Surfaces

    /// The page behind everything: the window, the sidebar, the area between
    /// cards. Deepest of the three in both modes.
    static let surfaceDeepest  = adaptive(light: Palette.LightSurface.page,
                                          dark:  Palette.DarkSurface.page)
    /// Cards and panels — the workhorse surface.
    static let surface         = adaptive(light: Palette.LightSurface.card,
                                          dark:  Palette.DarkSurface.card)
    /// The selected or hovered fill.
    static let surfaceElevated = adaptive(light: Palette.LightSurface.elevated,
                                          dark:  Palette.DarkSurface.elevated)
    /// A well — code, terminal, any area that should read as inset rather than
    /// raised. Dark in **both** modes, which is deliberate: the terminal is the
    /// illustration's ground, the one surface that never follows the appearance.
    static let surfaceSunken   = adaptive(light: 0x15181C, dark: 0x0C0E10)

    // MARK: - Lines

    /// Kept as low-alpha inks so they read as a hint, not a stroke, and so the
    /// same constant works on every surface in its mode.
    static let border       = adaptive(light: 0x1F1E1C, dark: 0xB9C2FF,
                                       lightAlpha: 0.10, darkAlpha: 0.10)
    static let borderStrong = adaptive(light: 0x1F1E1C, dark: 0xB9C2FF,
                                       lightAlpha: 0.22, darkAlpha: 0.22)

    // MARK: - Text

    static let textPrimary   = adaptive(light: Palette.TextLight.primary,
                                        dark: Palette.TextDark.primary)
    static let textSecondary = adaptive(light: Palette.TextLight.secondary,
                                        dark: Palette.TextDark.secondary)
    static let textTertiary  = adaptive(light: Palette.TextLight.tertiary,
                                        dark: Palette.TextDark.tertiary)

    // MARK: - Accent — the illustration's glow

    /// The periwinkle, as a **foreground** on any surface. Governed in
    /// `Palette.Accent{Light,Dark}`; see there for the contrast arithmetic.
    static let accent      = adaptive(light: Palette.AccentLight.foreground,
                                      dark:  Palette.AccentDark.foreground)
    /// The glow as a **fill**: a button, a selected tab. Always pair with
    /// `accentOn`. Dark ink on the fill clears 5.6:1 in both modes.
    static let accentFill  = adaptive(light: 0x5A6AF2, dark: 0x96A5FF)
    /// Hover stop for a fill. Pairs with the same ink as `accentFill`.
    static let accentHover = adaptive(light: 0x4E5DE0, dark: 0xAAB6FF)
    /// Text and glyphs drawn *on* `accentFill`.
    static let accentOn    = adaptive(light: Palette.inkDark, dark: Palette.inkDark)

    /// The illustration's amber — the second light in the sky, and deliberately
    /// **not** the accent. Waiting states use it (amber = needs you, the one
    /// convention every coding-agent terminal shares), which keeps "the glow"
    /// meaning *working* and amber meaning *you*.
    static let sunlit      = adaptive(light: 0x8A5B0D, dark: 0xF5B549)
    /// `sunlit` at the wash alphas the badges draw at. Governed by the same
    /// rules as the status colours, and passes them by the same margins.
    static let sunlitWash  = sunlit.opacity(0.14)

    /// A translucent glow tint for hover fills and active rows — the accent at
    /// low alpha. Prefer `glowBorder` for outlines and this for fills.
    static let glow        = accent.opacity(0.14)

    // MARK: - Chart segments

    /// Segments of a proportional bar, in draw order. Governed in
    /// `Palette.Chart{Light,Dark}`.
    static let chartWeights   = adaptive(light: Palette.ChartLight.weights,
                                         dark:  Palette.ChartDark.weights)
    static let chartKVCache   = adaptive(light: Palette.ChartLight.kvCache,
                                         dark:  Palette.ChartDark.kvCache)
    static let chartProjector = adaptive(light: Palette.ChartLight.projector,
                                         dark:  Palette.ChartDark.projector)
    static let chartCompute   = adaptive(light: Palette.ChartLight.compute,
                                         dark:  Palette.ChartDark.compute)

    // MARK: - Status

    /// Light values come from `Palette.StatusLight`; the dark values already
    /// cleared their floors on the new charcoal, so they are unchanged.
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

    // MARK: - Terminal ANSI

    /// The terminal is the illustration's ground: near-black charcoal, with a
    /// selection in the accent and a block cursor in the glow.
    ///
    /// `TerminalView` wants plain `NSColor`s at construction and will not
    /// re-resolve a dynamic provider when the appearance changes, so these are
    /// the **dark** stops unconditionally — which is correct, because the
    /// terminal surface is dark in both modes by design.
    enum Terminal {
        static let background  = NSColor(rgb: 0x0C0E10)
        static let foreground  = NSColor(rgb: 0xE8EAF2)
        static let cursor      = NSColor(rgb: 0x96A5FF)
        static let selection   = NSColor(rgb: 0x96A5FF, alpha: 0.30)

        /// ANSI-16 as `0xRRGGBB`, tuned to the illustration: the two lights in
        /// its sky (periwinkle blue, warm amber), the scene's green, and red
        /// reserved for failures. Bright variants are lifted just enough to
        /// stay readable on `background` at small sizes.
        ///
        /// Held as hex rather than `NSColor` because SwiftTerm's
        /// `installColors` takes its own `Color` class; `TerminalPane` maps
        /// them over.
        static let ansi: [UInt32] = [
            0x3A3F4B,  // black
            0xF2635F,  // red
            0x7BC98A,  // green
            0xF5B549,  // yellow
            0x7E90FF,  // blue
            0xC09BFF,  // magenta
            0x5BC0C9,  // cyan
            0xC8CCE0,  // white
            0x4A5160,  // bright black
            0xFF8A80,  // bright red
            0x9FE2AC,  // bright green
            0xFFD27E,  // bright yellow
            0xAAB8FF,  // bright blue
            0xD9BEFF,  // bright magenta
            0x8AD8E0,  // bright cyan
            0xEDEFF8,  // bright white
        ]
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

// MARK: - Mainframe primitives
//
// kooky's chrome is a stack of quiet surfaces with one glow running through it.
// These are the pieces every pane shares.

/// A soft accent glow under a rounded surface — the illustration's light
/// leaking around the edges of the focused thing. `intensity` 0…1 scales the
/// blur radius and spread; small values read as a halo, not a neon sign.
private struct GlowModifier: ViewModifier {
    var color: Color
    var radius: CGFloat
    var intensity: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(color.opacity(0.45 * intensity))
                    .blur(radius: radius * intensity)
                    .padding(-radius * 0.45 * intensity)
            )
    }
}

extension View {
    /// A soft outer glow in `color`. Used by the focused pane, the selected
    /// workspace and the primary action — nowhere else, or nothing reads as
    /// focused any more.
    func glow(_ color: Color = Theme.accent, radius: CGFloat = 10,
              intensity: CGFloat = 1) -> some View {
        modifier(GlowModifier(color: color, radius: radius, intensity: intensity))
    }
}

/// The dashboard's backdrop: the hero illustration's night sky, redrawn as two
/// faint fields of colour rising from the bottom edge — periwinkle into amber,
/// like the horizon in the picture. Purely decorative, sits behind content,
/// ignores every event.
struct AuroraBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Theme.accent.opacity(0.16), Color.clear],
                startPoint: .bottom, endPoint: .center
            )
            LinearGradient(
                colors: [Theme.sunlit.opacity(0.07), Color.clear],
                startPoint: .bottomTrailing, endPoint: .center
            )
        }
        .allowsHitTesting(false)
    }
}

/// A top-bar (or sidebar-header) icon button in the kooky idiom: a quiet glyph
/// that lights up on hover. `isActive` keeps it lit while the thing it toggles
/// is open.
struct TopBarButton: View {
    let icon: MXIconName
    var isActive = false
    var help: String = ""
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            MXIconView(
                name: icon,
                size: 13,
                tint: isActive || isHovering ? Theme.accent : Theme.textSecondary
            )
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Theme.glow
                        : isHovering ? Theme.surfaceElevated : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

/// A small status readout for the bottom bar: a coloured dot, a label, and an
/// optional detail string, all inside a single quiet click target.
struct StatusPill: View {
    var color: Color
    var label: String
    var detail: String? = nil
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(Theme.surfaceElevated.opacity(0.6))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Building blocks

/// The app's own mark — the user's "X2" logo, white on transparent.
///
/// The source artwork (`JX2.png`) is a white mark on an opaque black square,
/// and a black square is exactly the wrong thing to draw at 26 pt on a dark
/// sidebar: the square swallows the page and the mark reads as a smudge. It
/// was then tried on the accent tile; that hid the artwork behind the app's
/// chrome and the user rejected it — the mark is the brand, not a button.
/// So `build-app.sh` bundles `logo-mark.png` — the mark **cropped to its
/// bounding box** and converted to white-on-transparent by
/// `scripts/make-logo-mark.swift` — and this view draws it as-is: white ink
/// floating on the charcoal, which is both the highest-contrast rendering
/// available and the one that matches the illustration's own look — bright
/// marks glowing against near-black. No tile, no backdrop: the mark is the
/// brand, not a button. The full art keeps serving as the Dock icon, where
/// the black square is fine.
///
/// Under `swift run` the bundle resource does not exist and the view falls
/// back to the bolt glyph — honest about being a stand-in rather than blank.
struct AppLogoView: View {
    var size: CGFloat

    var body: some View {
        Group {
            if let mark = AppLogo.mark {
                Image(nsImage: mark)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                MXIconView(name: .bolt, size: size * 0.54, tint: Theme.accent)
            }
        }
        .frame(width: size, height: size)
    }

    /// Loaded once; re-decoding per layout pass is waste.
    private enum AppLogo {
        static let mark: NSImage? = {
            guard let url = Bundle.main.url(forResource: "logo-mark", withExtension: "png") else {
                return nil
            }
            return NSImage(contentsOf: url)
        }()
    }
}

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

/// Pill-shaped badge for the count chips and the state markers. Background
/// defaults to the elevated surface so it reads against both the sidebar and
/// the cards.
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

/// A dot of an identity colour — the smallest unit of the tile palette.
struct ColorDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
    }
}

/// The primary button: the periwinkle fill with dark ink on it.
///
/// Deliberately not `.borderedProminent` with a `.tint`. That style paints its
/// label white, and white on the glow fails contrast in both modes — the
/// illustration pairs the glow with near-black for exactly this reason. Owning
/// the label colour is the whole reason this exists rather than being a one-line
/// tint. Pressed and hover states come from `accentHover`; the resting state
/// carries the faint glow that marks it as the main action.
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
            .modifier(GlowModifier(color: Theme.accent, radius: 8,
                                   intensity: configuration.isPressed ? 0 : 0.55))
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
    static var primaryCompact: PrimaryButtonStyle { PrimaryButtonStyle(compact: true) }
}
