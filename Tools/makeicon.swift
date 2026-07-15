// Generates AppIcon.icns without needing an asset catalog.
// Run via: swift Tools/makeicon.swift <output.icns>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("DevSweep.iconset")

try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

/// A white symbol, because SF Symbols render in black by default.
func tinted(_ symbolName: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return nil }
    let img = NSImage(size: symbol.size)
    img.lockFocus()
    NSColor.white.set()
    NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
    symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
    img.unlockFocus()
    return img
}

/// A disk with a sparkle: freed disk space. The artwork is full-bleed — the
/// gradient covers the entire square canvas with no transparent margin and no
/// pre-rounded corners. macOS 26 re-renders legacy icons: anything that does
/// not fill the canvas is shrunk onto a system backing plate, which is
/// near-black in dark mode. Full-bleed art gets masked into the system's own
/// icon shape instead, so the colour reaches every edge.
func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let path = NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size))

    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.72, blue: 0.55, alpha: 1),
    ])!.draw(in: path, angle: -60)

    if let drive = tinted("internaldrive.fill", pointSize: size * 0.42, weight: .regular) {
        let s = drive.size
        drive.draw(in: NSRect(x: (size - s.width) / 2,
                              y: (size - s.height) / 2 - size * 0.03,
                              width: s.width, height: s.height))
    }
    if let sparkle = tinted("sparkles", pointSize: size * 0.17, weight: .semibold) {
        let s = sparkle.size
        sparkle.draw(in: NSRect(x: size * 0.70 - s.width / 2,
                                y: size * 0.70 - s.height / 2,
                                width: s.width, height: s.height))
    }

    image.unlockFocus()

    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    rep.size = NSSize(width: size, height: size)
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
