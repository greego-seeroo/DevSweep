// Generates AppIcon.icns without needing an asset catalog.
// Run via: swift Tools/makeicon.swift <output.icns>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.icns"
let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("DevSweep.iconset")

try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let inset = size * 0.06
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22)

    NSGradient(colors: [
        NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.72, blue: 0.55, alpha: 1),
    ])!.draw(in: path, angle: -60)

    let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.46, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        NSColor.white.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
        symbol.draw(at: .zero, from: .zero, operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()

        let s = tinted.size
        tinted.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2,
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
