// Draws the app icon: a page with a highlighted line and an earmarked corner.
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s).fill()

    // Page with the top-right corner folded down.
    let fold: CGFloat = 150 * s
    let page = NSRect(x: 262 * s, y: 212 * s, width: 500 * s, height: 600 * s)
    let paper = NSBezierPath()
    paper.move(to: NSPoint(x: page.minX, y: page.minY))
    paper.line(to: NSPoint(x: page.maxX, y: page.minY))
    paper.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    paper.line(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    paper.line(to: NSPoint(x: page.minX, y: page.maxY))
    paper.close()
    NSColor(calibratedRed: 0.98, green: 0.97, blue: 0.95, alpha: 1).setFill()
    paper.fill()
    let corner = NSBezierPath()
    corner.move(to: NSPoint(x: page.maxX - fold, y: page.maxY))
    corner.line(to: NSPoint(x: page.maxX - fold, y: page.maxY - fold))
    corner.line(to: NSPoint(x: page.maxX, y: page.maxY - fold))
    corner.close()
    NSColor(calibratedRed: 0.82, green: 0.80, blue: 0.76, alpha: 1).setFill()
    corner.fill()

    // Lines of text; the third is highlighted, with one word picked out.
    let lineColor = NSColor(calibratedRed: 0.55, green: 0.54, blue: 0.52, alpha: 1)
    let widths: [CGFloat] = [250, 380, 380, 330, 380, 230]
    for (i, w) in widths.enumerated() {
        let y = page.maxY - (175 + CGFloat(i) * 68) * s
        if i == 2 {
            NSColor(calibratedRed: 0.98, green: 0.80, blue: 0.08, alpha: 0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: page.minX + 46 * s, y: y - 18 * s, width: (w + 28) * s, height: 52 * s), xRadius: 10 * s, yRadius: 10 * s).fill()
            NSColor(calibratedRed: 0.92, green: 0.47, blue: 0.08, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: page.minX + 150 * s, y: y - 18 * s, width: 120 * s, height: 52 * s), xRadius: 10 * s, yRadius: 10 * s).fill()
        }
        lineColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: page.minX + 60 * s, y: y, width: w * s, height: 16 * s), xRadius: 8 * s, yRadius: 8 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(CGFloat(px)).representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
}
