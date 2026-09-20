import Foundation

/// The palette values a contrast rule governs, and the rule itself.
///
/// These live in `JXCodeCore` rather than in the SwiftUI layer for one reason:
/// **a rule you cannot test is a comment.** The app target has no test target —
/// `JXCodeCoreTests` depends on `JXCodeCore` only — so a palette defined in
/// `Theme.swift` could only ever be checked by looking at it. Here
/// `PaletteTests` asserts the rules directly, so adding a seventh dot or
/// lightening a status colour fails the suite instead of shipping.
///
/// `Theme` in the app target owns no governed values; it turns these into
/// `Color`s and supplies the view components.
///
/// The values themselves were sampled from two reference screenshots, one light
/// and one dark. They are one design in two modes — the same warm neutral base,
/// the same amber accent, the same six dot colours — so the governed half is
/// written out per mode rather than as two palettes.
public enum Palette {

    // MARK: - The rule

    /// WCAG AA for body text.
    public static let minimumTextContrast = 4.5
    /// WCAG AA for a non-text graphic — a glyph, a chart segment.
    public static let minimumGraphicContrast = 3.0

    /// WCAG relative luminance of `0xRRGGBB`, 0…1.
    public static func relativeLuminance(_ rgb: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let v = Double(value) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((rgb >> 16) & 0xFF)
             + 0.7152 * channel((rgb >> 8) & 0xFF)
             + 0.0722 * channel(rgb & 0xFF)
    }

    /// WCAG contrast ratio between two `0xRRGGBB` values, 1…21.
    public static func contrastRatio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = relativeLuminance(a), lb = relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// `foreground` at `alpha` composited over `background`, as `0xRRGGBB`.
    ///
    /// The app draws status text on a wash of its own colour rather than on a
    /// bare surface, so the wash is part of what the rule has to cover: a
    /// colour can pass on the card and fail on its own 18% tint.
    public static func composite(_ foreground: UInt32, over background: UInt32,
                                 alpha: Double) -> UInt32 {
        func mix(_ shift: UInt32) -> UInt32 {
            let f = Double((foreground >> shift) & 0xFF)
            let b = Double((background >> shift) & 0xFF)
            return UInt32((f * alpha + b * (1 - alpha)).rounded())
        }
        return (mix(16) << 16) | (mix(8) << 8) | mix(0)
    }

    // MARK: - Light surfaces

    /// Every light surface the app draws status text on. `page` is the darkest,
    /// so it is the binding constraint for dark text.
    public enum LightSurface {
        public static let card: UInt32     = 0xFEFEFE
        public static let elevated: UInt32 = 0xF3F0EA
        public static let page: UInt32     = 0xEAE7E1

        public static let all: [UInt32] = [card, elevated, page]
    }

    /// The same three surfaces in dark mode.
    public enum DarkSurface {
        public static let card: UInt32     = 0x191919
        public static let elevated: UInt32 = 0x242427
        public static let page: UInt32     = 0x141319

        public static let all: [UInt32] = [card, elevated, page]
    }

    /// The alphas the app actually uses for a status wash behind its own text.
    /// Read off the call sites, not invented — if a new alpha appears there, it
    /// belongs here too or the rule stops covering it.
    public static let statusWashes: [Double] = [0.10, 0.14, 0.18]

    // MARK: - Status

    /// Light-mode status colours.
    ///
    /// Each is the sampled hue darkened by the smallest factor that clears
    /// `minimumTextContrast` on **every** `LightSurface` and on **every**
    /// `statusWash` over a card: 0.78× `warning`, 0.80× `success`, 0.89×
    /// `danger`. The palette therefore stays as close to the reference as
    /// legibility allows.
    ///
    /// The sampled `warning` was the worst offender — `#B07511` was 3.86:1 on a
    /// card, 3.29:1 on its own 14% wash and 3.15:1 on the page. The dark values
    /// already passed, so only the light half moved.
    public enum StatusLight {
        public static let success: UInt32 = 0x26723E
        public static let warning: UInt32 = 0x8A5B0D
        public static let danger:  UInt32 = 0xAE3D34
        /// Informational — the one status colour that is not a verdict, for the
        /// capability chips that need a fourth hue which is neither "fine" nor
        /// "wrong". Teal-family, derived from `Tile.teal` by the same rule.
        public static let info:    UInt32 = 0x2F6D73

        public static let all: [UInt32] = [success, warning, danger, info]
    }

    // MARK: - Accent

    /// The accent foreground — what icon tints, link text and selection state
    /// are drawn in.
    ///
    /// Held to `minimumTextContrast` on **every** `LightSurface` and on the
    /// accent's own wash (`composite(accent, over: surface, alpha: 0.14)`) over
    /// every surface. The wash case is what the "installing / retry / ready"
    /// badges test against, and it is the binding constraint here: a tint of
    /// the foreground colour is necessarily close to the foreground in
    /// luminance, so the only way to clear 4.5 on a wash is to darken the
    /// foreground itself. Lightening the wash only makes it worse.
    public enum AccentLight {
        public static let foreground: UInt32 = 0x805100
    }

    /// The dark accent already clears both rules.
    public enum AccentDark {
        public static let foreground: UInt32 = 0xFEB43B
    }

    // MARK: - Chart segments

    /// The alpha a proportional-bar segment is drawn at.
    ///
    /// The rule governs what is *rendered*, and a segment is rendered at 75%
    /// over its surface — so the governed colour is the composite, not the
    /// constant. Naming the alpha here keeps the view and the test from drifting
    /// apart, which is the only way a rule about a composite can hold.
    public static let chartSegmentAlpha = 0.75

    /// The floor adjacent segments are held apart by.
    ///
    /// Not WCAG — 1.4.11 governs a graphic against its *background*, not against
    /// its neighbour. This is the practical rule that keeps a four-colour bar
    /// readable when hue is unavailable: greyscale, a monochrome display, or
    /// any of the common colour-vision deficiencies.
    public static let minimumSegmentSeparation = 1.30

    /// Light-mode bar segments, in draw order.
    ///
    /// These were the four `Tile` colours — `blue`, `teal`, `purple`, `orange` —
    /// reused directly as chart fills. At `chartSegmentAlpha` they land at
    /// **1.78–2.99:1** against every light surface, all under the 3:1 graphic
    /// floor. An identity dot carries its own ink, so it can afford to be faint;
    /// a bar segment has only the surface behind it, so it cannot.
    ///
    /// Each is the sampled hue scaled by the smallest factor that clears
    /// `minimumGraphicContrast` on every `LightSurface` *and* keeps adjacent
    /// segments apart. Solving for the floor alone is not enough: it drives all
    /// four to the same luminance, because the floor is what sets luminance —
    /// separation collapses to 1.00, and the bar becomes four identical greys
    /// with a hue difference no one can use.
    public enum ChartLight {
        public static let weights:   UInt32 = 0x2A476F
        public static let kvCache:   UInt32 = 0x2E696E
        public static let projector: UInt32 = 0x4C3774
        public static let compute:   UInt32 = 0x954A3C

        /// Draw order. The separation guarantee is a property of *adjacent*
        /// pairs, so the order is part of the rule, not an accident of the view.
        public static let all: [UInt32] = [weights, kvCache, projector, compute]
    }

    /// Dark-mode bar segments. Only `purple` had to move: at 2.43:1 on
    /// `elevated` it was the one segment failing in *both* modes, and it is the
    /// only reason the dark half of this ramp is not simply the sampled tiles.
    public enum ChartDark {
        public static let weights:   UInt32 = 0x538EDE
        public static let kvCache:   UInt32 = 0x50B8C0
        public static let projector: UInt32 = 0xA274F6
        public static let compute:   UInt32 = 0xFF846C

        public static let all: [UInt32] = [weights, kvCache, projector, compute]
    }

    // MARK: - Text

    /// Text colours, light mode, per tier with the floor each is held to.
    public enum TextLight {
        public static let primary: UInt32 = 0x1F1E1C

        /// 4.65:1 at worst (on `page`).
        ///
        /// The sampled value was **4.4996** — one ten-thousandth under AA — so it
        /// was darkened by 0.98× to sit *off* the boundary rather than on it. A
        /// value that passes by 0.0004 fails the moment any surface moves, and a
        /// test asserting `>= 4.5` would not tell you which side you are on.
        public static let secondary: UInt32 = 0x686660

        /// The inactive tier: held to the **graphic** floor (3.18:1 at worst),
        /// not the text floor, because this is what unselected icons, placeholder
        /// glyphs and idle dots are drawn in.
        ///
        /// It is **not** for informational body text — use `secondary`. The
        /// sampled `#9A968E` was 2.92:1 on a card, failing even the graphic
        /// floor, which is why it moved to `#84807A`.
        public static let tertiary: UInt32 = 0x84807A

        public static let all: [UInt32] = [primary, secondary, tertiary]
    }

    /// Text colours, dark mode. All three already cleared their floors, so these
    /// are unchanged from the sampled values — except `tertiary`, which sat at
    /// 3.05 against a 3.0 floor and was nudged to 3.19.
    public enum TextDark {
        public static let primary:   UInt32 = 0xEDEBE8
        public static let secondary: UInt32 = 0x9C9C9C
        public static let tertiary:  UInt32 = 0x717176

        public static let all: [UInt32] = [primary, secondary, tertiary]
    }

    // MARK: - Identity dots

    /// The six identity colours, sampled from the reference sidebar, plus the
    /// reference's coral kept distinct from the amber. Identical in both modes —
    /// a workspace keeps its colour when the user switches appearance, which is
    /// the point of an identity colour.
    ///
    /// Not for use as a chart fill: see `ChartLight` for why.
    public enum Tile {
        public static let amber:  UInt32 = 0xF5B549
        public static let blue:   UInt32 = 0x538EDE
        public static let green:  UInt32 = 0x44AB62
        public static let teal:   UInt32 = 0x41969D
        public static let purple: UInt32 = 0x845FC9
        public static let pink:   UInt32 = 0xAA5BD0
        public static let orange: UInt32 = 0xF97B64

        public static let all: [UInt32] = [amber, blue, green, teal, purple, pink, orange]
    }

    /// The two inks available to a glyph on a tile.
    public static let inkLight: UInt32 = 0xFFFFFF
    public static let inkDark:  UInt32 = 0x1F1E1C

    /// Ink for a glyph drawn on `fill`.
    ///
    /// The ramp is hashed, so any key can land on any dot and every dot has to
    /// carry a readable glyph. White does not: 1.81:1 on `amber`, 2.61:1 on
    /// `orange` and 2.90:1 on `green`, all below the 3:1 floor for a non-text
    /// graphic, while the other four are 3.34:1 or better and want white.
    ///
    /// Thresholding on luminance would be the obvious shortcut and it is wrong
    /// here: the gap between `green` (0.3124) and `blue` (0.2646) is narrow and
    /// sits between two dots needing *opposite* inks, so a luminance cutoff
    /// would have to be tuned. Testing the ratio tests the thing.
    public static func ink(on fill: UInt32) -> UInt32 {
        contrastRatio(inkLight, fill) >= minimumGraphicContrast ? inkLight : inkDark
    }
}
