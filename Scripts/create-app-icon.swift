import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: create-app-icon.swift <iconset-directory>\n", stderr)
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: red, green: green, blue: blue, alpha: alpha)
}

/// Draws the EchoFlow icon on a 1024-point canvas: a navy rounded square (lighter at the top)
/// on the standard macOS icon grid, a cyan-to-blue waveform, and a white text cursor.
func drawIcon() {
    // macOS icon grid: an 824-point body centered on the 1024 canvas, with a soft drop shadow.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0, 0, 0, 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    color(0.07, 0.09, 0.16).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Slate at the top fading to near-black navy by the middle.
    let background = NSGradient(
        colors: [color(0.05, 0.07, 0.13), color(0.08, 0.11, 0.19), color(0.30, 0.36, 0.49)],
        atLocations: [0, 0.55, 1],
        colorSpace: .deviceRGB
    )
    background?.draw(in: bodyPath, angle: 90)
    color(1, 1, 1, 0.08).setStroke()
    let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
    rim.lineWidth = 3
    rim.stroke()

    // Waveform: seven rounded bars centered vertically, blue at the bottom to cyan at the top.
    let barGradient = NSGradient(
        colors: [color(0.17, 0.49, 0.94), color(0.35, 0.72, 1.0), color(0.55, 0.88, 1.0)],
        atLocations: [0, 0.5, 1],
        colorSpace: .deviceRGB
    )
    let barWidth: CGFloat = 34
    let barCenters: [CGFloat] = [237, 301, 365, 429, 493, 557, 621]
    let barHeights: [CGFloat] = [104, 196, 316, 188, 380, 268, 166]
    for (centerX, height) in zip(barCenters, barHeights) {
        let rect = NSRect(x: centerX - barWidth / 2, y: 512 - height / 2, width: barWidth, height: height)
        let bar = NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        barGradient?.draw(in: bar, angle: 90)
    }

    // Text cursor (I-beam) to the right of the waveform.
    color(0.97, 0.98, 1.0).setFill()
    let cursorX: CGFloat = 755
    let stem: CGFloat = 24
    let cursorHeight: CGFloat = 408
    let serifWidth: CGFloat = 96
    NSBezierPath(
        roundedRect: NSRect(x: cursorX - stem / 2, y: 512 - cursorHeight / 2, width: stem, height: cursorHeight),
        xRadius: stem / 2,
        yRadius: stem / 2
    ).fill()
    for y in [512 + cursorHeight / 2 - stem, 512 - cursorHeight / 2] {
        NSBezierPath(
            roundedRect: NSRect(x: cursorX - serifWidth / 2, y: y, width: serifWidth, height: stem),
            xRadius: stem / 2,
            yRadius: stem / 2
        ).fill()
    }
}

func renderIcon(pixelSize: Int, fileName: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "EchoFlowIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create icon bitmap"])
    }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "EchoFlowIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create icon graphics context"])
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.scaleBy(x: CGFloat(pixelSize) / 1024, y: CGFloat(pixelSize) / 1024)

    drawIcon()

    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "EchoFlowIcon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not encode icon PNG"])
    }
    try data.write(to: iconsetURL.appendingPathComponent(fileName), options: .atomic)
}

let icons: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]
for (size, name) in icons {
    try renderIcon(pixelSize: size, fileName: name)
}
