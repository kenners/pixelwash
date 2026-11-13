// Draws the Pixelwash app icon and writes a 1024×1024 PNG.
// Usage: swift scripts/make-icon.swift <output.png>
// `make icon` turns the result into Resources/AppIcon.icns.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(
    data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

// Background: the standard macOS rounded square with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.3))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x1B5FBF))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(
    colorsSpace: space, colors: [color(0x46CDE6), color(0x2488D8), color(0x1A4FB0)] as CFArray,
    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])

// The document: intact at the top, breaking into pixels towards the bottom.
let cell: CGFloat = 54
let columns = 6
let docWidth = cell * CGFloat(columns)
let docLeft = (CGFloat(size) - docWidth) / 2
let docTop: CGFloat = 800
let solidBottom: CGFloat = 800 - cell * 5  // the intact part is five cells tall
let fold: CGFloat = 86

let page = CGMutablePath()
page.move(to: CGPoint(x: docLeft + 22, y: docTop))
page.addLine(to: CGPoint(x: docLeft + docWidth - fold, y: docTop))
page.addLine(to: CGPoint(x: docLeft + docWidth, y: docTop - fold))
page.addLine(to: CGPoint(x: docLeft + docWidth, y: solidBottom))
page.addLine(to: CGPoint(x: docLeft, y: solidBottom))
page.addLine(to: CGPoint(x: docLeft, y: docTop - 22))
page.addArc(
    center: CGPoint(x: docLeft + 22, y: docTop - 22), radius: 22, startAngle: .pi, endAngle: .pi / 2,
    clockwise: true)
page.closeSubpath()

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0x0A2A66, 0.35))
ctx.addPath(page)
ctx.setFillColor(color(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// Folded corner.
let corner = CGMutablePath()
corner.move(to: CGPoint(x: docLeft + docWidth - fold, y: docTop))
corner.addLine(to: CGPoint(x: docLeft + docWidth - fold, y: docTop - fold + 14))
corner.addArc(
    center: CGPoint(x: docLeft + docWidth - fold + 14, y: docTop - fold + 14), radius: 14, startAngle: .pi,
    endAngle: .pi * 1.5, clockwise: false)
corner.addLine(to: CGPoint(x: docLeft + docWidth, y: docTop - fold))
corner.closeSubpath()
ctx.addPath(corner)
ctx.setFillColor(color(0xBFE3F7))
ctx.fillPath()

// Text lines on the intact part.
ctx.setFillColor(color(0x9CC4E4))
for (index, width) in [0.42, 0.74, 0.74, 0.58].enumerated() {
    let y = docTop - 78 - CGFloat(index) * 46
    let line = CGRect(x: docLeft + 38, y: y, width: (docWidth - 76) * width, height: 18)
    ctx.addPath(CGPath(roundedRect: line, cornerWidth: 9, cornerHeight: 9, transform: nil))
}
ctx.fillPath()

// Pixels: each row down loses more cells and fades, as if washing away.
// 1 = white, 2 = pale blue, 0 = gone.
let rows: [[Int]] = [
    [1, 1, 2, 1, 1, 1],
    [1, 2, 1, 1, 0, 1],
    [2, 0, 1, 2, 1, 0],
    [0, 1, 0, 1, 0, 2],
    [1, 0, 0, 2, 0, 0],
    [0, 0, 1, 0, 0, 1],
]
let gap: CGFloat = 5
for (rowIndex, row) in rows.enumerated() {
    let fade = 1 - CGFloat(rowIndex) * 0.13
    for (columnIndex, kind) in row.enumerated() where kind != 0 {
        let rect = CGRect(
            x: docLeft + CGFloat(columnIndex) * cell + gap / 2,
            y: solidBottom - CGFloat(rowIndex + 1) * cell + gap / 2 - CGFloat(rowIndex) * 3,
            width: cell - gap, height: cell - gap)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 7, cornerHeight: 7, transform: nil))
        ctx.setFillColor(kind == 1 ? color(0xFFFFFF, fade) : color(0xBFE3F7, fade * 0.9))
        ctx.fillPath()
    }
}
ctx.restoreGState()

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(output.path)") }
