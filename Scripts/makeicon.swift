// Generates AppIcon.icns without needing an asset catalog.
// Run via: swift Scripts/makeicon.swift <output.icns>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("DevSweep.iconset")

try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

/// Everything is drawn from hand-built paths on a 1024-unit canvas and scaled
/// to each size. No SF Symbols: Apple's licence does not allow them in app icons.
///
/// A broom mid-sweep, leaving sparkles where the dust was. The artwork is
/// full-bleed — the gradient covers the entire square canvas with no transparent
/// margin and no pre-rounded corners. macOS 26 re-renders legacy icons: anything
/// that does not fill the canvas is shrunk onto a system backing plate, which is
/// near-black in dark mode. Full-bleed art gets masked into the system's own icon
/// shape instead, so the colour reaches every edge.

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

/// A four-pointed sparkle with concave sides.
func sparkle(at c: NSPoint, radius r: CGFloat, pinch: CGFloat = 0.22) -> NSBezierPath {
    let p = NSBezierPath()
    let tips = [NSPoint(x: c.x, y: c.y + r), NSPoint(x: c.x + r, y: c.y),
                NSPoint(x: c.x, y: c.y - r), NSPoint(x: c.x - r, y: c.y)]
    p.move(to: tips[0])
    for i in 0..<4 {
        p.curve(to: tips[(i + 1) % 4],
                controlPoint1: NSPoint(x: c.x + (tips[i].x - c.x) * pinch, y: c.y + (tips[i].y - c.y) * pinch),
                controlPoint2: NSPoint(x: c.x + (tips[(i + 1) % 4].x - c.x) * pinch, y: c.y + (tips[(i + 1) % 4].y - c.y) * pinch))
    }
    p.close()
    return p
}

func drawArtwork() {
    let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)

    // Background: deep blue to teal, lit from the top left.
    NSGradient(colors: [rgb(0x2B5BF0), rgb(0x1E8FD8), rgb(0x12B49A)],
               atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
        .draw(in: NSBezierPath(rect: canvas), angle: -55)
    NSGradient(colors: [rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)])!
        .draw(in: NSBezierPath(rect: canvas), relativeCenterPosition: NSPoint(x: -0.55, y: 0.6))
    NSGradient(colors: [rgb(0x06203A, 0), rgb(0x06203A, 0.30)])!
        .draw(in: NSBezierPath(rect: canvas), relativeCenterPosition: NSPoint(x: 0.3, y: -0.3))

    // Swoosh: the arc the bristles just swept.
    let swoosh = NSBezierPath()
    swoosh.move(to: NSPoint(x: 250, y: 250))
    swoosh.curve(to: NSPoint(x: 880, y: 350), controlPoint1: NSPoint(x: 470, y: 160), controlPoint2: NSPoint(x: 740, y: 195))
    swoosh.curve(to: NSPoint(x: 280, y: 298), controlPoint1: NSPoint(x: 730, y: 250), controlPoint2: NSPoint(x: 470, y: 225))
    swoosh.close()
    rgb(0xFFFFFF, 0.22).setFill(); swoosh.fill()

    // Sparkles where the dust was.
    rgb(0xFFFFFF).setFill()
    sparkle(at: NSPoint(x: 770, y: 480), radius: 96).fill()
    sparkle(at: NSPoint(x: 872, y: 625), radius: 48).fill()
    sparkle(at: NSPoint(x: 652, y: 360), radius: 40).fill()

    // The broom, built upright around its binding then leaned into the sweep.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = rgb(0x041A33, 0.35)
    shadow.shadowBlurRadius = 34
    shadow.shadowOffset = NSSize(width: 10, height: -22)
    shadow.set()
    let lean = NSAffineTransform()
    lean.translateX(by: 470, yBy: 520)
    lean.rotate(byDegrees: -34)
    lean.concat()

    // Handle.
    let handle = NSBezierPath(roundedRect: NSRect(x: -30, y: 40, width: 60, height: 410), xRadius: 30, yRadius: 30)
    NSGradient(colors: [rgb(0xFFFFFF), rgb(0xD9E4F2)])!.draw(in: handle, angle: 0)

    // Bristles: a fan flaring downwards with a gently curved, ragged edge.
    let bristles = NSBezierPath()
    bristles.move(to: NSPoint(x: -88, y: 0))
    bristles.line(to: NSPoint(x: 88, y: 0))
    bristles.curve(to: NSPoint(x: 178, y: -300), controlPoint1: NSPoint(x: 120, y: -90), controlPoint2: NSPoint(x: 170, y: -200))
    let teeth = 9
    for i in 0..<teeth {
        let x0 = 178 - CGFloat(i) * 356 / CGFloat(teeth)
        let x1 = 178 - CGFloat(i + 1) * 356 / CGFloat(teeth)
        let mid = (x0 + x1) / 2
        let sag = -300 - 14 * (1 - pow(mid / 178, 2))
        bristles.curve(to: NSPoint(x: x1, y: -300 - 10 * (1 - pow(x1 / 178, 2))),
                       controlPoint1: NSPoint(x: mid + 8, y: sag - 26),
                       controlPoint2: NSPoint(x: mid - 8, y: sag - 26))
    }
    bristles.curve(to: NSPoint(x: -88, y: 0), controlPoint1: NSPoint(x: -170, y: -200), controlPoint2: NSPoint(x: -120, y: -90))
    bristles.close()
    NSGradient(colors: [rgb(0xFFD25A), rgb(0xF59E1B)])!.draw(in: bristles, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    lean.concat()
    // Bristle grain, clipped to the fan.
    NSGraphicsContext.saveGraphicsState()
    bristles.addClip()
    rgb(0xB8650A, 0.45).setStroke()
    for i in -3...3 {
        let line = NSBezierPath()
        line.lineWidth = 9
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: CGFloat(i) * 22, y: -40))
        line.line(to: NSPoint(x: CGFloat(i) * 52, y: -330))
        line.stroke()
    }
    NSGradient(colors: [rgb(0xFFFFFF, 0.35), rgb(0xFFFFFF, 0)])!
        .draw(in: NSRect(x: -200, y: -120, width: 400, height: 120), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Binding: where handle meets bristles.
    let band = NSBezierPath(roundedRect: NSRect(x: -100, y: -26, width: 200, height: 84), xRadius: 26, yRadius: 26)
    NSGradient(colors: [rgb(0xFFFFFF), rgb(0xDCE6F3)])!.draw(in: band, angle: -90)
    let stripe = NSBezierPath(roundedRect: NSRect(x: -100, y: 6, width: 200, height: 20), xRadius: 0, yRadius: 0)
    NSGraphicsContext.saveGraphicsState()
    band.addClip()
    rgb(0x1E8FD8).setFill(); stripe.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.restoreGraphicsState()
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(px) / 1024)
    scale.concat()
    drawArtwork()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for (px, name) in [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
] {
    try! render(px).write(to: tmp.appendingPathComponent("\(name).png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try! p.run()
p.waitUntilExit()
exit(p.terminationStatus)
