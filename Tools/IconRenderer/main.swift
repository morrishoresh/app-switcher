import AppKit

// Usage:
//   icon-renderer appicon <output.iconset>
//   icon-renderer preview <output-dir>   (1024px PNG, for review)
//
// A switcher bar with three app tiles, each holding a small window, the middle one selected.
// A fourth slot, empty and dashed, stands for an app without windows that the switcher leaves out.

func renderPNG(pixels: Int, to url: URL, draw: () -> Void) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// A small window: colored body, lighter title bar and three traffic-light dots.
func drawWindow(in rect: NSRect, body: (NSColor, NSColor)) {
    let radius = rect.width * 0.14
    let outline = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGradient(starting: body.0, ending: body.1)?.draw(in: outline, angle: 90)

    NSGraphicsContext.saveGraphicsState()
    outline.addClip()
    let barHeight = rect.height * 0.24
    NSColor(white: 1, alpha: 0.85).setFill()
    NSRect(x: rect.minX, y: rect.maxY - barHeight, width: rect.width, height: barHeight).fill()
    let dot = barHeight * 0.42
    let colors = [rgb(1, 0.37, 0.34), rgb(1, 0.74, 0.18), rgb(0.16, 0.79, 0.25)]
    for (i, color) in colors.enumerated() {
        color.setFill()
        let x = rect.minX + barHeight * 0.45 + CGFloat(i) * dot * 1.55
        NSBezierPath(ovalIn: NSRect(x: x, y: rect.maxY - barHeight / 2 - dot / 2, width: dot, height: dot)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
}

func drawAppIcon(side: CGFloat) {
    let scale = NSAffineTransform()
    scale.scale(by: side / 1024)
    scale.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: rgb(0.13, 0.12, 0.38), ending: rgb(0.47, 0.36, 0.96))?.draw(in: tile, angle: 90)

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()

    // Soft light from the top-left.
    NSGradient(starting: NSColor(white: 1, alpha: 0.2), ending: NSColor(white: 1, alpha: 0))?
        .draw(fromCenter: NSPoint(x: 260, y: 860), radius: 0, toCenter: NSPoint(x: 260, y: 860), radius: 640, options: [])

    // Switcher bar.
    let bar = NSRect(x: 150, y: 372, width: 724, height: 280)
    let barPath = NSBezierPath(roundedRect: bar, xRadius: 64, yRadius: 64)
    let barShadow = NSShadow()
    barShadow.shadowColor = NSColor(white: 0, alpha: 0.4)
    barShadow.shadowBlurRadius = 40
    barShadow.shadowOffset = NSSize(width: 0, height: -16)
    NSGraphicsContext.saveGraphicsState()
    barShadow.set()
    rgb(0.10, 0.10, 0.16, 0.82).setFill()
    barPath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 1, alpha: 0.14).setStroke()
    barPath.lineWidth = 4
    barPath.stroke()

    let slot: CGFloat = 166
    let gap: CGFloat = 4
    let startX = bar.midX - (4 * slot + 3 * gap) / 2
    let slotY = bar.midY - slot / 2 + 24

    // Selection highlight behind the second tile.
    NSColor(white: 1, alpha: 0.22).setFill()
    NSBezierPath(roundedRect: NSRect(x: startX + slot + gap, y: slotY, width: slot, height: slot),
                 xRadius: 34, yRadius: 34).fill()

    let bodies: [(NSColor, NSColor)] = [
        (rgb(0.18, 0.62, 0.98), rgb(0.10, 0.42, 0.86)),
        (rgb(1.0, 0.62, 0.20), rgb(0.95, 0.40, 0.16)),
        (rgb(0.24, 0.84, 0.56), rgb(0.10, 0.62, 0.42)),
    ]
    for (i, body) in bodies.enumerated() {
        let x = startX + CGFloat(i) * (slot + gap)
        drawWindow(in: NSRect(x: x + 26, y: slotY + 34, width: slot - 52, height: slot - 68), body: body)
    }

    // Empty slot: an app without windows, left out.
    let empty = NSBezierPath(roundedRect: NSRect(x: startX + 3 * (slot + gap) + 30, y: slotY + 38,
                                                 width: slot - 60, height: slot - 76), xRadius: 16, yRadius: 16)
    empty.lineWidth = 7
    empty.setLineDash([18, 14], count: 2, phase: 0)
    NSColor(white: 1, alpha: 0.35).setStroke()
    empty.stroke()

    // Selected-app name under the tiles.
    NSColor(white: 1, alpha: 0.75).setFill()
    NSBezierPath(roundedRect: NSRect(x: startX + slot + gap + 28, y: bar.minY + 24, width: slot - 56, height: 22),
                 xRadius: 11, yRadius: 11).fill()

    NSGraphicsContext.restoreGraphicsState()
}

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: icon-renderer appicon|preview <output>\n".data(using: .utf8)!)
    exit(2)
}
let out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

switch args[1] {
case "appicon":
    for points in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let pixels = points * factor
            let name = factor == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try renderPNG(pixels: pixels, to: out.appendingPathComponent(name)) { drawAppIcon(side: CGFloat(pixels)) }
        }
    }
case "preview":
    try renderPNG(pixels: 1024, to: out.appendingPathComponent("appicon.png")) { drawAppIcon(side: 1024) }
default:
    exit(2)
}
