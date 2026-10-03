import Foundation

// MARK: - Why the UI icons are described rather than drawn
//
// `AgentIcons` holds the marks for the agents themselves, transcribed from the
// icon files the user supplied. This is the other set: the interface's own
// chrome — add, close, refresh, warning — vendored from mx-icons
// (https://github.com/ig-imanish/mx-icons).
//
// Both sets use the same vocabulary on purpose. `IconViewBox`, `IconStrokeCap`
// and `IconStrokeJoin` are shared, and every layer is a path string that
// `SVGPathParser` reads, so there is one parser and one renderer for both.
// A second parser written for this set would have been a second place for arc
// flattening to be subtly wrong.

/// How to resolve a filled path whose subpaths overlap.
///
/// Icons that cut a hole with a second subpath — a plug inside a circle, a
/// glyph inside a tile — need `evenOdd`; the rest rely on the default
/// non-zero winding rule, where an inner subpath must run the other way round.
public enum MXIconFillRule: String, Equatable, Sendable {
    case nonzero
    case evenodd
}

/// One drawing instruction of a UI icon.
///
/// Both cases are drawn in the caller's own colour rather than a baked-in one,
/// because these are interface glyphs: they take the tint of the row they sit
/// in, and a disabled control greys them out without a second definition.
public enum MXIconLayer: Equatable, Sendable {
    case fill(path: String, rule: MXIconFillRule = .nonzero)
    case stroke(
        path: String,
        width: Double,
        cap: IconStrokeCap = .butt,
        join: IconStrokeJoin = .miter
    )
}

/// One UI icon: a view box and the layers that draw it.
public struct MXIconDefinition: Equatable, Sendable {
    public let viewBox: IconViewBox
    public let layers: [MXIconLayer]

    /// The view box defaults to 24×24 because every mx-icons component is
    /// authored in it — the upstream `Icon` wrapper hardcodes
    /// `viewBox="0 0 24 24"` and none of the vendored icons override it.
    /// `MXIconTests` asserts the geometry stays inside it, so a future
    /// upstream change that breaks the assumption fails loudly rather than
    /// silently cropping the artwork.
    public init(
        viewBox: IconViewBox = IconViewBox(x: 0, y: 0, width: 24, height: 24),
        layers: [MXIconLayer]
    ) {
        self.viewBox = viewBox
        self.layers = layers
    }
}

/// The vendored UI icon set.
public enum MXIcon {

    /// The definition for an icon. Every `MXIconName` has one —
    /// `MXIconTests` asserts it, because a missing entry would render as an
    /// empty frame rather than as an error.
    public static func definition(for name: MXIconName) -> MXIconDefinition {
        MXIconCatalog.definitions[name]
            ?? MXIconDefinition(layers: [])
    }

    /// Every icon whose layer list is empty. Empty in a healthy build.
    public static var missingDefinitions: [MXIconName] {
        MXIconName.allCases.filter { MXIconCatalog.definitions[$0]?.layers.isEmpty ?? true }
    }
}
