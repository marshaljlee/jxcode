import AppKit

// make-logo-mark.swift <input.png> <output.png>
//
// The source artwork is a white mark on an opaque black square. For the in-app
// mark we want just the mark: cropped to its bounding box (plus a little
// padding), with alpha taken from luminance, so SwiftUI can render it as a
// template and ink it however the theme wants. The full art keeps serving as
// the Dock icon.

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: make-logo-mark <in.png> <out.png>\n".utf8))
    exit(2)
}

let inURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard let image = NSImage(contentsOf: inURL),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let data = cg.dataProvider?.data,
      let base = CFDataGetBytePtr(data) else {
    FileHandle.standardError.write(Data("cannot read \(inURL.path)\n".utf8))
    exit(1)
}

let bpr = cg.bytesPerRow
let bpp = cg.bitsPerPixel / 8
let w = cg.width, h = cg.height
guard bpp >= 3 else {
    FileHandle.standardError.write(Data("need RGB input\n".utf8))
    exit(1)
}

func alphaAt(_ x: Int, _ y: Int) -> UInt8 {
    let i = y * bpr + x * bpp
    return max(base[i], base[i + 1], base[i + 2])
}

// Content bounding box of the mark.
var minX = w, minY = h, maxX = 0, maxY = 0
for y in stride(from: 0, to: h, by: 2) {
    for x in stride(from: 0, to: w, by: 2) where alphaAt(x, y) > 16 {
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX > minX, maxY > minY else {
    FileHandle.standardError.write(Data("artwork has no mark (all black?)\n".utf8))
    exit(1)
}

// ~5% padding, clamped to the canvas.
let padX = max(1, (maxX - minX) / 20), padY = max(1, (maxY - minY) / 20)
minX = max(0, minX - padX); minY = max(0, minY - padY)
maxX = min(w - 1, maxX + padX); maxY = min(h - 1, maxY + padY)
let cw = maxX - minX + 1, ch = maxY - minY + 1

var out = [UInt8](repeating: 0, count: cw * ch * 4)
for y in 0..<ch {
    for x in 0..<cw {
        let a = alphaAt(minX + x, minY + y)
        let o = (y * cw + x) * 4
        // White ink, premultiplied: channel = alpha.
        out[o] = a; out[o + 1] = a; out[o + 2] = a; out[o + 3] = a
    }
}

let ctx = CGContext(data: &out, width: cw, height: ch,
                    bitsPerComponent: 8, bytesPerRow: cw * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let rendered = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: rendered)
guard let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("png encode failed\n".utf8))
    exit(1)
}
try png.write(to: outURL)
print("mark: \(cw)x\(ch) from \(w)x\(h) → \(outURL.path)")
