// Places a window capture under a headline on a 2560×1600 App Store canvas,
// in the app icon's colours. Used by Scripts/app-store-screenshots.sh.
//
//   compose-screenshot <window.png> <headline> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let window = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: compose-screenshot <window.png> <headline> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let headline = args[2]
let W = 2560, H = 1600

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
NSGraphicsContext.current!.imageInterpolation = .high
let canvas = NSRect(x: 0, y: 0, width: W, height: H)

// Background: the icon's gradient and lighting.
NSGradient(colors: [rgb(0x2B5BF0), rgb(0x1E8FD8), rgb(0x12B49A)], atLocations: [0, 0.5, 1], colorSpace: .sRGB)!
    .draw(in: NSBezierPath(rect: canvas), angle: -30)
NSGradient(colors: [rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)])!
    .draw(in: NSBezierPath(rect: canvas), relativeCenterPosition: NSPoint(x: -0.6, y: 0.7))

// Window: as large as fits under the headline band, anchored near the bottom.
let band: CGFloat = 330, bottom: CGFloat = 70, side: CGFloat = 160
let px = window.representations.first.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? window.size
let scale = min((CGFloat(W) - 2 * side) / px.width, (CGFloat(H) - band - bottom) / px.height)
let size = NSSize(width: px.width * scale, height: px.height * scale)
let frame = NSRect(x: (CGFloat(W) - size.width) / 2, y: bottom, width: size.width, height: size.height)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = rgb(0x041A33, 0.45)
shadow.shadowBlurRadius = 60
shadow.shadowOffset = NSSize(width: 0, height: -24)
shadow.set()
window.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1)
NSGraphicsContext.restoreGraphicsState()

// Headline: one line, centred in the band, shrunk until it fits.
var pt: CGFloat = 96
var text: NSAttributedString
repeat {
    let style = NSMutableParagraphStyle(); style.alignment = .center
    text = NSAttributedString(string: headline, attributes: [
        .font: NSFont.systemFont(ofSize: pt, weight: .bold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: style,
    ])
    pt -= 4
} while text.size().width > CGFloat(W) - 2 * side && pt > 40
let th = text.size().height
let bandMid = CGFloat(H) - (CGFloat(H) - frame.maxY) / 2
text.draw(in: NSRect(x: side, y: bandMid - th / 2, width: CGFloat(W) - 2 * side, height: th))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
