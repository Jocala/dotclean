// dotclean app icon generator.
// Renders on a 512 grid: dark rounded square, blue "menu bar" band at the top
// (it is a menu-bar app), and a large white "._" — the thing it removes.
//
//   swift icon/make-icon.swift <out.png> [size]

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: swift make-icon.swift <out.png> [size]\n", stderr)
    exit(2)
}

let outPath = args[1]
let size = CGFloat(args.count > 2 ? (Int(args[2]) ?? 1024) : 1024)
let s = size / 512.0

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil,
                          width: Int(size),
                          height: Int(size),
                          bitsPerComponent: 8,
                          bytesPerRow: 0,
                          space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("cannot create context\n", stderr)
    exit(1)
}

ctx.setShouldAntialias(true)
ctx.interpolationQuality = .high

let radius = 0.22 * size
let square = CGRect(x: 0, y: 0, width: size, height: size)
let rounded = CGPath(roundedRect: square, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Background gradient, clipped to the rounded square.
ctx.saveGState()
ctx.addPath(rounded)
ctx.clip()

let colors = [
    CGColor(srgbRed: 0.043, green: 0.071, blue: 0.125, alpha: 1),
    CGColor(srgbRed: 0.075, green: 0.157, blue: 0.271, alpha: 1),
] as CFArray

if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: size),
                           end: CGPoint(x: 0, y: 0),
                           options: [])
}

// Menu-bar band.
ctx.setFillColor(CGColor(srgbRed: 0, green: 122.0 / 255.0, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: size - 46 * s, width: size, height: 46 * s))

ctx.restoreGState()

// Broom: handle up to the right, bristle head down to the left.
let white = CGColor(gray: 1, alpha: 1)
let navy = CGColor(srgbRed: 0.043, green: 0.071, blue: 0.125, alpha: 1)

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

let headCenter = p(170, 188)

// Handle (drawn first so the head covers its foot).
ctx.setStrokeColor(white)
ctx.setLineWidth(36 * s)
ctx.setLineCap(.round)
ctx.move(to: headCenter)
ctx.addLine(to: p(348, 366))
ctx.strokePath()

// Bristle head in its own rotated frame.
ctx.saveGState()
ctx.translateBy(x: headCenter.x, y: headCenter.y)
ctx.rotate(by: .pi / 4)
let head = CGRect(x: -74 * s, y: -92 * s, width: 148 * s, height: 184 * s)
ctx.addPath(CGPath(roundedRect: head,
                   cornerWidth: 18 * s,
                   cornerHeight: 18 * s,
                   transform: nil))
ctx.setFillColor(white)
ctx.fillPath()

// Gaps between the bristles.
ctx.setFillColor(navy)
for offset in stride(from: -54.0, through: 54.0, by: 36.0) {
    ctx.fill(CGRect(x: CGFloat(offset) * s - 6 * s,
                    y: -92 * s,
                    width: 12 * s,
                    height: 54 * s))
}
ctx.restoreGState()

guard let image = ctx.makeImage() else {
    fputs("cannot render image\n", stderr)
    exit(1)
}

let url = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)

guard let destination = CGImageDestinationCreateWithURL(
    url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fputs("cannot create \(outPath)\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("cannot write \(outPath)\n", stderr)
    exit(1)
}

print("wrote \(outPath) (\(Int(size))x\(Int(size)))")
