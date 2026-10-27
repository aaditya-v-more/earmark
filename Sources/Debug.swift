import AppKit
import WebKit

/// Development aid, active only when EARMARK_DEBUG_DIR is set: logs highlights and saves window snapshots.
enum Debug {
    static let dir = ProcessInfo.processInfo.environment["EARMARK_DEBUG_DIR"].map { URL(fileURLWithPath: $0) }

    static func logHighlight(_ web: WKWebView) {
        guard dir != nil else { return }
        let js = "[...(CSS.highlights.get('em-sentence') || [])].map(String).join('') + ' || ' + [...(CSS.highlights.get('em-word') || [])].map(String).join('')"
        web.evaluateJavaScript(js) { result, _ in
            FileHandle.standardError.write(Data("highlight: \(result ?? "")\n".utf8))
        }
    }

    static func snapshot(_ window: NSWindow?, _ web: WKWebView, name: String) {
        guard let dir, let content = window?.contentView else { return }
        web.takeSnapshot(with: nil) { image, _ in
            guard let image, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
            content.cacheDisplay(in: content.bounds, to: rep)
            let canvas = NSImage(size: content.bounds.size)
            canvas.lockFocus()
            NSImage(cgImage: rep.cgImage!, size: content.bounds.size).draw(in: content.bounds)
            image.draw(in: web.frame)
            canvas.unlockFocus()
            if let tiff = canvas.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(name + ".png"))
            }
        }
    }
}
