#!/usr/bin/env swift
//
//  make-bolt-icon.swift
//  Renders the JXCode app icon: the app's own lightning bolt, per size.
//
//  Run:  swift scripts/make-bolt-icon.swift <output.png>
//
//  Why per size and not one canvas downsampled:
//  at 16 px a downsampled icon is mush — the bolt's waist disappears and what is
//  left is a smudge. Each size is redrawn with the inset and glyph proportion
//  chosen for that size, so the silhouette survives all the way down.
//
//  The bolt path is lifted verbatim from `MXIcons.swift` (`.bolt`), so the Dock
//  icon is the same glyph the sidebar draws rather than a lookalike. Two marks
//  that merely resemble each other is how a product ends up with two logos.
//
//  The colours come from `Palette.DenseDark` — the tokens the app ships.

import AppKit
import Foundation

// MARK: - The bolt, verbatim from MXIcons.swift

/// The `.bolt` path from `MXIcons.swift`, authored in a 24×24 box.
///
/// Commands used: `M` moveto, `L` lineto, `C` curveto, `V` vertical lineto,
/// `Z` closepath. That subset is parsed below rather than pulled in as a
/// dependency — `NSBezierPath(svgPath:)` does not exist, and adding an SVG
/// library to draw one glyph is not a trade worth making.
let boltPath = """
M5.66953 9.91436 L8.73167 5.77133
C10.711 3.09327 11.7007 1.75425 12.6241 2.03721
C13.5474 2.32018 13.5474 3.96249 13.5474 7.24712
V7.55682
C13.5474 8.74151 13.5474 9.33386 13.926 9.70541
L13.946 9.72466
C14.3327 10.0884 14.9492 10.0884 16.1822 10.0884
C18.4011 10.0884 19.5106 10.0884 19.8855 10.7613
C19.8917 10.7724 19.8977 10.7837 19.9036 10.795
C20.2576 11.4784 19.6152 12.3475 18.3304 14.0857
L15.2683 18.2287
C13.2889 20.9067 12.2992 22.2458 11.3758 21.9628
C10.4525 21.6798 10.4525 20.0375 10.4525 16.7528
L10.4526 16.4433
C10.4526 15.2585 10.4526 14.6662 10.074 14.2946
L10.054 14.2754
C9.6673 13.9117 9.05079 13.9117 7.81775 13.9117
C5.59888 13.9117 4.48945 13.9117 4.1145 13.2387
C4.10829 13.2276 4.10225 13.2164 4.09639 13.205
C3.74244 12.5217 4.3848 11.6526 5.66953 9.91436
Z
"""

/// Build a CGPath from the path data above.
///
/// - parameter box: the view box the data is authored in. SVG's y grows
///   downward; CoreGraphics's does too once the context is flipped, so the
///   numbers are copied across unchanged and only the transform flips.
func makeBoltPath(box: CGFloat) -> CGPath {
    let path = CGMutablePath()

    // Tokenise into letters and numbers. The data has no implicit repeats and
    // no negative-number shorthand, so a flat split is enough and anything
    // richer would be untested code.
    var tokens: [String] = []
    var current = ""
    for character in boltPath {
        if character.isLetter {
            if !current.isEmpty { tokens.append(current) }
            tokens.append(String(character))
            current = ""
        } else if character.isWhitespace || character == "," {
            if !current.isEmpty { tokens.append(current) }
            current = ""
        } else {
            current.append(character)
        }
    }
    if !current.isEmpty { tokens.append(current) }

    var index = 0
    func next() -> Double {
        guard index < tokens.count, let value = Double(tokens[index]) else { return 0 }
        index += 1
        return value
    }
    func command() -> String {
        guard index < tokens.count else { return "" }
        let token = tokens[index]
        index += 1
        return token
    }

    var cursor = CGPoint.zero
    while index < tokens.count {
        switch command() {
        case "M":
            cursor = CGPoint(x: next(), y: next())
            path.move(to: cursor)
        case "L":
            cursor = CGPoint(x: next(), y: next())
            path.addLine(to: cursor)
        case "V":
            let y = next()
            cursor = CGPoint(x: cursor.x, y: y)
            path.addLine(to: cursor)
        case "C":
            let c1 = CGPoint(x: next(), y: next())
            let c2 = CGPoint(x: next(), y: next())
            let end = CGPoint(x: next(), y: next())
            path.addCurve(to: end, control1: c1, control2: c2)
            cursor = end
        case "Z", "z":
            path.closeSubpath()
        default:
            // An unrecognised letter means the data grew a command this parser
            // does not know. Stop rather than draw a partial bolt that looks
            // deliberate.
            return path
        }
    }
    _ = box
    return path
}

// MARK: - Tokens (Palette.DenseDark)

func rgb(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let base       = rgb(0x0E1116)   // DenseDark.base
let layer2     = rgb(0x1B222B)   // DenseDark.layer2
let accent     = rgb(0x38BDF8)   // DenseDark.accent
let accentTop  = rgb(0x7DD3FC)   // DenseDark.accentHover

// MARK: - Drawing

/// Render one icon, `size` pixels square.
///
/// - parameter inset: the gap between the canvas edge and the tile. macOS
///   leaves roughly 10% so the shape reads as an object on the Dock rather than
///   as a tile filling it.
/// - parameter boltScale: the glyph's size as a fraction of the tile. Larger at
///   small sizes, where a proportional glyph is a few grey pixels.
func renderIcon(size: CGFloat, inset: CGFloat, boltScale: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // AppKit's focus context is y-up; SVG is y-down. Flip once here so the
    // path data can be copied across unmodified.
    ctx.translateBy(x: 0, y: size)
    ctx.scaleBy(x: 1, y: -1)

    let tileInset = size * inset
    let tile = CGRect(
        x: tileInset, y: tileInset,
        width: size - tileInset * 2,
        height: size - tileInset * 2
    )
    let radius = tile.width * 0.2237   // Apple's continuous-corner proportion

    // The tile: a vertical lift from layer2 down to base, so it reads as lit
    // from above rather than as one flat swatch.
    ctx.saveGState()
    let tileShape = CGPath(
        roundedRect: tile,
        cornerWidth: radius, cornerHeight: radius,
        transform: nil
    )
    ctx.addPath(tileShape)
    ctx.clip()
    let fill = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [layer2.cgColor, base.cgColor] as CFArray,
        locations: [0, 1]
    )
    if let fill {
        ctx.drawLinearGradient(
            fill,
            start: CGPoint(x: tile.midX, y: tile.minY),
            end: CGPoint(x: tile.midX, y: tile.maxY),
            options: []
        )
    }
    ctx.restoreGState()

    // The bolt, centred.
    //
    // The outer flip above already put this context into SVG's y-down space, so
    // the path data is placed with a plain positive scale. A second `y: -scale`
    // here would mirror the bolt about its own horizontal axis — which still
    // reads as a bolt at a glance but is the wrong silhouette, and the reason an
    // earlier draft of this script came out looking melted.
    let draw = tile.width * boltScale
    let origin = CGPoint(
        x: tile.midX - draw / 2,
        y: tile.midY - draw / 2
    )
    let scale = draw / 24

    ctx.saveGState()
    ctx.translateBy(x: origin.x, y: origin.y)
    ctx.scaleBy(x: scale, y: scale)

    let bolt = makeBoltPath(box: 24)
    ctx.addPath(bolt)
    ctx.setFillColor(accent.cgColor)
    ctx.fillPath()

    // A lighter pass over the lower half, clipped to the bolt: at 32 px a flat
    // fill reads as a sticker, and a full gradient on a glyph this small turns
    // to mud. A hard split keeps both the shape and the light.
    ctx.saveGState()
    ctx.addPath(bolt)
    ctx.clip()
    let bounds = bolt.boundingBox
    ctx.setFillColor(accentTop.withAlphaComponent(0.5).cgColor)
    ctx.fill(CGRect(
        x: bounds.minX, y: bounds.minY,
        width: bounds.width, height: bounds.height / 2
    ))
    ctx.restoreGState()

    ctx.restoreGState()
    return image
}

/// Write `image` to `url` as PNG.
func writePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:])
    else { return }
    try? png.write(to: url)
}

// MARK: - Entry

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write(Data("usage: make-bolt-icon.swift <output.png>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: arguments[1])

/// size, tile inset, bolt scale.
let sizes: [(CGFloat, CGFloat, CGFloat)] = [
    (16,   0.00, 0.88),
    (32,   0.00, 0.76),
    (64,   0.02, 0.66),
    (128,  0.06, 0.60),
    (256,  0.08, 0.56),
    (512,  0.10, 0.54),
    (1024, 0.10, 0.54),
]

// The master is 1024 — the file `build-app.sh` reads.
if let (_, inset, scale) = sizes.last {
    writePNG(renderIcon(size: 1024, inset: inset, boltScale: scale), to: output)
    print("wrote \(output.path) — 1024 master")
}

// The per-size renders, so an iconset can be assembled from real artwork at
// each size rather than from a downscaled master.
let dir = output.deletingLastPathComponent()
    .appendingPathComponent("bolt-iconset", isDirectory: true)
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

for (size, inset, scale) in sizes {
    let name: String
    switch size {
    case 16:   name = "icon_16x16.png"
    case 32:   name = "icon_16x16@2x.png"
    case 64:   name = "icon_32x32.png"
    case 128:  name = "icon_32x32@2x.png"
    case 256:  name = "icon_128x128.png"
    case 512:  name = "icon_128x128@2x.png"
    default:   name = "icon_256x256.png"
    }
    writePNG(renderIcon(size: size, inset: inset, boltScale: scale),
             to: dir.appendingPathComponent(name))
}
print("wrote \(sizes.count) per-size renders to \(dir.path)")
