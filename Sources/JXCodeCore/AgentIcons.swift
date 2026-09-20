import Foundation

// MARK: - Why the marks are described rather than drawn
//
// These are the icon files themselves, transcribed. A mark is stored as the
// drawing instructions the file actually contains — every layer, in order, with
// the colour each layer was given — rather than as a single flattened
// silhouette.
//
// That distinction is the whole point of this file. The previous arrangement
// (`BrandMarks`) held three monochrome 24×24 outlines and drew them white on a
// coloured tile, because a white glyph was all it could express. Four of the
// six marks here are not monochrome outlines:
//
//   - Codex is a gradient glyph on its own white rounded square.
//   - Gemini is a blue spark with three colour overlays that fade out.
//   - opencode is a light frame around a dark inner square.
//   - oh-my-pi is a gradient glyph on its own near-black rounded square.
//
// Rendering any of those as a white-on-colour glyph would discard the icon.
// So a mark carries its own paint, its own view box, and a flag saying whether
// it brings its own background — and the tile adapts to that instead of
// imposing a colour on it.
//
// `JXCodeCore` still owns no graphics types: paths, colours and gradients are
// plain values here, and `AgentIconView` in the app turns them into SwiftUI.

/// A point in an icon's own coordinate space.
public struct IconPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The rectangle an icon's coordinates are authored in.
///
/// Three of these files are not `0 0 24 24`: Jules is authored on a tight box
/// around its own artwork, and opencode is on a 240×300 canvas. Keeping the
/// view box means the marks can be scaled without re-deriving their geometry.
public struct IconViewBox: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// A point in this space expressed as 0…1 across the view box.
    ///
    /// SwiftUI's `LinearGradient` is specified in unit points, while an SVG
    /// gradient with `gradientUnits="userSpaceOnUse"` is specified in the same
    /// coordinates as the artwork. This is the conversion between the two.
    public func unit(x: Double, y: Double) -> IconPoint {
        IconPoint(
            x: (x - self.x) / max(width, .ulpOfOne),
            y: (y - self.y) / max(height, .ulpOfOne)
        )
    }
}

/// A colour exactly as the icon file wrote it.
public struct IconColor: Equatable, Sendable {
    public let hex: String
    public let opacity: Double

    public init(_ hex: String, opacity: Double = 1) {
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        // `#fff` and `#ffffff` mean the same thing, and only one of them should
        // have to be understood downstream.
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        self.hex = "#" + digits.uppercased()
        self.opacity = opacity
    }
}

/// A linear gradient, in the icon's own coordinate space.
public struct IconGradient: Equatable, Sendable {
    public struct Stop: Equatable, Sendable {
        public let offset: Double
        public let color: IconColor

        public init(offset: Double, color: IconColor) {
            self.offset = offset
            self.color = color
        }
    }

    public let start: IconPoint
    public let end: IconPoint
    public let stops: [Stop]

    public init(start: IconPoint, end: IconPoint, stops: [Stop]) {
        self.start = start
        self.end = end
        self.stops = stops
    }
}

public enum IconPaint: Equatable, Sendable {
    case solid(IconColor)
    case gradient(IconGradient)
}

public enum IconStrokeCap: String, Equatable, Sendable {
    case butt, round, square
}

public enum IconStrokeJoin: String, Equatable, Sendable {
    case miter, round, bevel
}

/// One drawing instruction of a mark.
public enum IconLayer: Equatable, Sendable {
    /// A closed shape, filled. This is what all five supplied files use.
    case fill(path: String, paint: IconPaint)
    /// An open path, stroked. Only the shell substitute needs it — the supplied
    /// files are all filled shapes.
    case stroke(path: String, color: IconColor, width: Double, cap: IconStrokeCap, join: IconStrokeJoin)
}

/// Where a mark came from, so the app can be honest about which are stand-ins.
public enum IconProvenance: Equatable, Sendable {
    /// Transcribed from a file in the icon set the user supplied.
    case provided(file: String)
    /// No file in the set matched this agent, so this is the closest equivalent
    /// mark that could be found for it.
    case substitute(source: String)
}

/// One agent's mark.
public struct AgentIcon: Equatable, Sendable {
    public let viewBox: IconViewBox
    /// True when the mark paints its own background across the whole view box —
    /// a white rounded square for Codex, a near-black one for oh-my-pi, a light
    /// frame for opencode.
    ///
    /// Those marks are drawn edge to edge and *are* the tile. The rest are
    /// transparent artwork and get a neutral tile behind them, because a
    /// transparent orange mark on the window's own background is unreadable.
    public let fillsTile: Bool
    public let provenance: IconProvenance
    public let layers: [IconLayer]

    public init(
        viewBox: IconViewBox,
        fillsTile: Bool,
        provenance: IconProvenance,
        layers: [IconLayer]
    ) {
        self.viewBox = viewBox
        self.fillsTile = fillsTile
        self.provenance = provenance
        self.layers = layers
    }
}

// MARK: - The set

/// The mark for each built-in agent.
///
/// Five come from the supplied icon set and match by name. Two agents had no
/// file in it — oh-my-pi and the plain shell — and are marked `.substitute`
/// below with the source of the replacement.
public enum AgentIcons {

    /// The mark to draw for an agent, or `nil` if there is none.
    ///
    /// A custom agent added through the UI has no mark, and falls back to an SF
    /// Symbol. That is deliberate rather than an omission: inventing a logo for
    /// a tool the app has never heard of would be presenting a guess as a fact.
    public static func icon(for agentID: String) -> AgentIcon? {
        switch agentID {
        case "claude":   return claudeCode
        case "codex":    return codex
        case "gemini":   return gemini
        case "opencode": return opencode
        case "omp":      return ohMyPi
        case "jules":    return jules
        case "shell":    return shell
        default:         return nil
        }
    }

    /// Every agent the app ships a mark for.
    public static var knownAgentIDs: [String] {
        ["claude", "codex", "gemini", "opencode", "omp", "jules", "shell"]
    }

    /// Agents whose mark is a stand-in rather than a file from the icon set.
    public static var substituteIDs: [String] {
        knownAgentIDs.filter {
            if case .substitute = icon(for: $0)?.provenance { return true }
            return false
        }
    }

    // MARK: Claude Code

    /// `claudecode.svg`. The fill sits on the `<svg>` element rather than the
    /// path, so it is inherited — `#D97757`, Claude's own orange.
    public static let claudeCode = AgentIcon(
        viewBox: IconViewBox(x: 0, y: 0, width: 24, height: 24),
        fillsTile: false,
        provenance: .provided(file: "claudecode.svg"),
        layers: [
            .fill(path: #"M21 10.5h3v3h-3v3h-1.5v3H18v-3h-1.5v3H15v-3H9v3H7.5v-3H6v3H4.5v-3H3v-3H0v-3h3v-6h18Zm-15 0h1.5v-3H6Zm10.5 0H18v-3h-1.5z"#, paint: .solid(IconColor("#D97757"))),
        ]
    )

    // MARK: Codex

    /// `codex-color.svg`. Two layers: the white rounded square that is the
    /// app icon's background, then the glyph in a vertical gradient.
    ///
    /// The gradient is `userSpaceOnUse` from (12, 3) to (12, 21) — exactly the
    /// glyph's own bounding box, so the top of the mark is pale lavender and
    /// the bottom is deep blue.
    public static let codex = AgentIcon(
        viewBox: IconViewBox(x: 0, y: 0, width: 24, height: 24),
        fillsTile: true,
        provenance: .provided(file: "codex-color.svg"),
        layers: [
            .fill(path: #"M19.503 0H4.496A4.496 4.496 0 000 4.496v15.007A4.496 4.496 0 004.496 24h15.007A4.496 4.496 0 0024 19.503V4.496A4.496 4.496 0 0019.503 0z"#, paint: .solid(IconColor("#FFFFFF"))),
            .fill(
                path: #"M9.064 3.344a4.578 4.578 0 012.285-.312c1 .115 1.891.54 2.673 1.275.01.01.024.017.037.021a.09.09 0 00.043 0 4.55 4.55 0 013.046.275l.047.022.116.057a4.581 4.581 0 012.188 2.399c.209.51.313 1.041.315 1.595a4.24 4.24 0 01-.134 1.223.123.123 0 00.03.115c.594.607.988 1.33 1.183 2.17.289 1.425-.007 2.71-.887 3.854l-.136.166a4.548 4.548 0 01-2.201 1.388.123.123 0 00-.081.076c-.191.551-.383 1.023-.74 1.494-.9 1.187-2.222 1.846-3.711 1.838-1.187-.006-2.239-.44-3.157-1.302a.107.107 0 00-.105-.024c-.388.125-.78.143-1.204.138a4.441 4.441 0 01-1.945-.466 4.544 4.544 0 01-1.61-1.335c-.152-.202-.303-.392-.414-.617a5.81 5.81 0 01-.37-.961 4.582 4.582 0 01-.014-2.298.124.124 0 00.006-.056.085.085 0 00-.027-.048 4.467 4.467 0 01-1.034-1.651 3.896 3.896 0 01-.251-1.192 5.189 5.189 0 01.141-1.6c.337-1.112.982-1.985 1.933-2.618.212-.141.413-.251.601-.33.215-.089.43-.164.646-.227a.098.098 0 00.065-.066 4.51 4.51 0 01.829-1.615 4.535 4.535 0 011.837-1.388zm3.482 10.565a.637.637 0 000 1.272h3.636a.637.637 0 100-1.272h-3.636zM8.462 9.23a.637.637 0 00-1.106.631l1.272 2.224-1.266 2.136a.636.636 0 101.095.649l1.454-2.455a.636.636 0 00.005-.64L8.462 9.23z"#,
                paint: .gradient(IconGradient(
                    start: IconPoint(x: 12, y: 3),
                    end: IconPoint(x: 12, y: 21),
                    stops: [
                        .init(offset: 0, color: IconColor("#B1A7FF")),
                        .init(offset: 0.5, color: IconColor("#7A9DFF")),
                        .init(offset: 1, color: IconColor("#3941FF")),
                    ]
                ))
            ),
        ]
    )

    // MARK: Gemini

    /// `gemini-color.svg`. Four layers of the *same* path: a flat blue base,
    /// then three gradients that fade to transparent over it.
    ///
    /// The overlays are what give the spark its green, red and yellow edges.
    /// Dropping them — or flattening them into one colour — would leave a plain
    /// blue star that is not the Gemini mark.
    public static let gemini = AgentIcon(
        viewBox: IconViewBox(x: 0, y: 0, width: 24, height: 24),
        fillsTile: false,
        provenance: .provided(file: "gemini-color.svg"),
        layers: [
            .fill(path: geminiSpark, paint: .solid(IconColor("#3186FF"))),
            .fill(path: geminiSpark, paint: .gradient(IconGradient(
                start: IconPoint(x: 7, y: 15.5),
                end: IconPoint(x: 11, y: 12),
                stops: [
                    .init(offset: 0, color: IconColor("#08B962")),
                    .init(offset: 1, color: IconColor("#08B962", opacity: 0)),
                ]
            ))),
            .fill(path: geminiSpark, paint: .gradient(IconGradient(
                start: IconPoint(x: 8, y: 5.5),
                end: IconPoint(x: 11.5, y: 11),
                stops: [
                    .init(offset: 0, color: IconColor("#F94543")),
                    .init(offset: 1, color: IconColor("#F94543", opacity: 0)),
                ]
            ))),
            .fill(path: geminiSpark, paint: .gradient(IconGradient(
                start: IconPoint(x: 3.5, y: 13.5),
                end: IconPoint(x: 17.5, y: 12),
                stops: [
                    .init(offset: 0, color: IconColor("#FABC12")),
                    .init(offset: 0.46, color: IconColor("#FABC12", opacity: 0)),
                ]
            ))),
        ]
    )

    private static let geminiSpark = #"M20.616 10.835a14.147 14.147 0 01-4.45-3.001 14.111 14.111 0 01-3.678-6.452.503.503 0 00-.975 0 14.134 14.134 0 01-3.679 6.452 14.155 14.155 0 01-4.45 3.001c-.65.28-1.318.505-2.002.678a.502.502 0 000 .975c.684.172 1.35.397 2.002.677a14.147 14.147 0 014.45 3.001 14.112 14.112 0 013.679 6.453.502.502 0 00.975 0c.172-.685.397-1.351.677-2.003a14.145 14.145 0 013.001-4.45 14.113 14.113 0 016.453-3.678.503.503 0 000-.975 13.245 13.245 0 01-2.003-.678z"#

    // MARK: opencode

    /// `opencode-dark.svg`. A dark inner square, then a light frame whose
    /// second subpath is the hole that reveals it.
    ///
    /// The file's own `<mask>` and `<clipPath>` cover the full canvas and do
    /// nothing, so they are not reproduced — a mask that hides nothing is not
    /// part of the mark.
    public static let opencode = AgentIcon(
        viewBox: IconViewBox(x: 0, y: 0, width: 240, height: 300),
        fillsTile: true,
        provenance: .provided(file: "opencode-dark.svg"),
        layers: [
            .fill(path: #"M180 240H60V120H180V240Z"#, paint: .solid(IconColor("#4B4646"))),
            .fill(path: #"M180 60H60V240H180V60ZM240 300H0V0H240V300Z"#, paint: .solid(IconColor("#F1ECEC"))),
        ]
    )

    // MARK: oh-my-pi

    /// A substitute. The icon set had no file for oh-my-pi.
    ///
    /// This is the project's own mark, taken from the `<link rel="icon">` on
    /// omp.sh: a near-black rounded square with a gradient glyph. The gradient
    /// is `objectBoundingBox` in the original, which is the same thing as the
    /// glyph's own bounding box — (14, 16) to (50, 56) on the 64×64 canvas.
    ///
    /// The previous arrangement drew this agent as an SF Symbol of ⌥, which is
    /// the glyph the project titles itself with; the real mark is used here
    /// because it exists.
    public static let ohMyPi = AgentIcon(
        viewBox: IconViewBox(x: 0, y: 0, width: 64, height: 64),
        fillsTile: true,
        provenance: .substitute(source: "omp.sh favicon.svg (oh-my-pi's own mark)"),
        layers: [
            .fill(path: #"M12 0H52A12 12 0 0 1 64 12V52A12 12 0 0 1 52 64H12A12 12 0 0 1 0 52V12A12 12 0 0 1 12 0Z"#, paint: .solid(IconColor("#0F0A14"))),
            .fill(
                path: #"M14 16h36v8H40v32h-8V24h-6v22h-8V24h-4z"#,
                paint: .gradient(IconGradient(
                    start: IconPoint(x: 14, y: 16),
                    end: IconPoint(x: 50, y: 56),
                    stops: [
                        .init(offset: 0, color: IconColor("#ED4ABF")),
                        .init(offset: 0.5, color: IconColor("#9B4DFF")),
                        .init(offset: 1, color: IconColor("#5AD8E6")),
                    ]
                ))
            ),
        ]
    )

    // MARK: Google Jules

    /// `google-jules.svg`. The file carries three CSS classes; two of them are
    /// `display:none` on their own rects, so only the visible path survives.
    public static let jules = AgentIcon(
        viewBox: IconViewBox(x: 4.67, y: 1.67, width: 16.69, height: 17.61),
        fillsTile: false,
        provenance: .provided(file: "google-jules.svg"),
        layers: [
            .fill(path: #"M20.57,15.91c-0.46,0-0.84,0.38-0.84,0.84c0,0.46-0.38,0.84-0.84,0.84c-0.46,0-0.84-0.38-0.84-0.84v-4.21 c0.08-0.23,0.15-0.46,0.15-0.69c0,0,0-4.74,0-4.9c0-2.91-2.3-5.28-5.2-5.28S7.72,4.05,7.72,6.96c0,0.15,0,4.9,0,4.9 c0,0.31,0.08,0.61,0.31,0.92v3.98c0,0.46-0.38,0.84-0.84,0.84c-0.46,0-0.84-0.38-0.84-0.84c0-0.46-0.38-0.84-0.84-0.84 c-0.46,0-0.84,0.38-0.84,0.84c0,1.3,1.07,2.37,2.37,2.52c0.08,0,0.08,0,0.15,0c0.08,0,0.08,0,0.15,0c1.3-0.08,2.37-1.15,2.37-2.52 v-3.29c0,0-0.08-0.69,0.54-0.69c0.61,0,0.54,0.69,0.54,0.69v3.29c0,0.46,0.38,0.84,0.84,0.84c0.46,0,0.84-0.38,0.84-0.84v-3.29 c0,0-0.15-0.69,0.54-0.69c0.69,0,0.54,0.69,0.54,0.69v3.29c0,0.46,0.38,0.84,0.84,0.84c0.46,0,0.84-0.38,0.84-0.84v-3.29 c0,0-0.08-0.69,0.54-0.69c0.61,0,0.54,0.69,0.54,0.69v3.29c0,1.3,1.07,2.37,2.37,2.52c0.08,0,0.08,0,0.15,0s0.08,0,0.15,0 c1.3-0.08,2.37-1.15,2.37-2.52C21.41,16.29,21.03,15.91,20.57,15.91z M10.24,11.16c-0.46,0-0.84-0.46-0.84-1.07 c0-0.61,0.38-1.07,0.84-1.07c0.46,0,0.84,0.46,0.84,1.07C11.08,10.7,10.7,11.16,10.24,11.16z M15.83,11.16 c-0.46,0-0.84-0.46-0.84-1.07c0-0.61,0.38-1.07,0.84-1.07c0.46,0,0.84,0.46,0.84,1.07C16.67,10.7,16.29,11.16,15.83,11.16z"#, paint: .solid(IconColor("#B2A3FF"))),
        ]
    )

    // MARK: Plain shell

    /// A substitute. The icon set had no file for the shell either, and there
    /// is no brand to match: `Plain shell` is this app's own entry for `/bin/zsh`
    /// inside the sandbox.
    ///
    /// Lucide's `terminal` is the closest equivalent mark — a terminal prompt
    /// glyph, on the same 24×24 grid the other marks use, under a licence that
    /// permits it. The stroke is `currentColor` in the original, resolved here
    /// to a near-white so it reads on the dark tile like every other mark.
    public static let shell = AgentIcon(
        viewBox: IconViewBox(x: 0, y: 0, width: 24, height: 24),
        fillsTile: false,
        provenance: .substitute(source: "Lucide \"terminal\" (ISC licence)"),
        layers: [
            .stroke(
                path: "m4 17 6-6-6-6",
                color: IconColor("#E6E8EB"),
                width: 2,
                cap: .round,
                join: .round
            ),
            .stroke(
                path: "M12 19h8",
                color: IconColor("#E6E8EB"),
                width: 2,
                cap: .round,
                join: .round
            ),
        ]
    )
}
