import AppKit
import PDFKit
import WebKit

/// Where the book is shown: it splits a chapter into sentences and paints the highlights.
protocol Surface: AnyObject {
    var view: NSView { get }
    /// The chapter's sentences, once it is shown.
    var onReady: (([String]) -> Void)? { get set }
    /// The reader clicked a sentence: (chapter, sentence).
    var onSeek: ((Int, Int) -> Void)? { get set }
    func show(_ book: Book, chapter: Int)
    func highlight(sentence: Int, word: NSRange?, follow: Bool)
    /// The first sentences of another chapter, to prepare its audio ahead of time.
    func upcoming(_ book: Book, chapter: Int, count: Int, done: @escaping ([String]) -> Void)
}

// MARK: - EPUB, HTML and text, in a web view

final class WebSurface: NSObject, Surface, WKScriptMessageHandler, WKNavigationDelegate {
    let web: WKWebView
    var view: NSView { web }
    var onReady: (([String]) -> Void)?
    var onSeek: ((Int, Int) -> Void)?
    /// A link to another chapter of the book was clicked.
    var onLink: ((URL) -> Void)?
    private var chapter = 0

    private let styleScript: String
    private let readerScript: String
    private var layoutScript = ""

    override init() {
        let config = WKWebViewConfiguration()
        let bundle = Bundle.main
        readerScript = (try? String(contentsOf: bundle.url(forResource: "reader", withExtension: "js")!, encoding: .utf8)) ?? ""
        let css = (try? String(contentsOf: bundle.url(forResource: "reader", withExtension: "css")!, encoding: .utf8)) ?? ""
        let cssLiteral = String(data: try! JSONSerialization.data(withJSONObject: [css], options: [.fragmentsAllowed]), encoding: .utf8)!
        styleScript = """
        (() => { const s = document.createElementNS('http://www.w3.org/1999/xhtml', 'style');
          s.textContent = \(cssLiteral)[0];
          (document.head || document.documentElement).appendChild(s); })();
        """
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        installScripts()
        config.userContentController.add(self, name: "earmark")
        web.navigationDelegate = self
    }

    private func installScripts() {
        let controller = web.configuration.userContentController
        controller.removeAllUserScripts()
        for source in [styleScript, layoutScript, readerScript] where !source.isEmpty {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
    }

    /// Text size in points and column width in ems: for this page now, and every page after.
    func setLayout(size: Int, width: Int) {
        layoutScript = """
        document.documentElement.style.setProperty('--em-size', '\(size)px');
        document.documentElement.style.setProperty('--em-width', '\(width)em');
        """
        installScripts()
        web.evaluateJavaScript(layoutScript + "window.earmark && earmark.repaint();")
    }

    /// Finds text in this chapter, wrapping around; false if it isn't there.
    func find(_ text: String, backwards: Bool, done: @escaping (Bool) -> Void) {
        let config = WKFindConfiguration()
        config.backwards = backwards
        config.wraps = true
        web.find(text, configuration: config) { result in done(result.matchFound) }
    }

    func show(_ book: Book, chapter: Int) {
        self.chapter = chapter
        web.loadFileURL(book.spine[chapter], allowingReadAccessTo: book.root)
    }

    func highlight(sentence: Int, word: NSRange?, follow: Bool) {
        let w = word ?? NSRange(location: 0, length: 0)
        web.evaluateJavaScript("window.earmark && earmark.highlight(\(sentence), \(w.location), \(w.length), \(follow))") { [weak self] _, _ in
            if let self, word != nil { Debug.logHighlight(self.web) }
        }
    }

    func upcoming(_ book: Book, chapter: Int, count: Int, done: @escaping ([String]) -> Void) {
        guard book.spine.indices.contains(chapter),
              let markup = try? String(contentsOf: book.spine[chapter], encoding: .utf8) else { return done([]) }
        let literal = String(data: try! JSONSerialization.data(withJSONObject: [markup]), encoding: .utf8)!
        web.evaluateJavaScript("earmark.firstSentences(\(literal)[0], \(count))") { result, _ in
            done(result as? [String] ?? [])
        }
    }

    /// Index of the last of these anchors that comes before the current sentence.
    func section(_ ids: [String], done: @escaping (Int?) -> Void) {
        let json = String(data: try! JSONSerialization.data(withJSONObject: ids), encoding: .utf8)!
        web.evaluateJavaScript("earmark.section(\(json))") { result, _ in
            done((result as? Int).flatMap { $0 >= 0 ? $0 : nil })
        }
    }

    func sentence(after id: String, done: @escaping (Int) -> Void) {
        let literal = String(data: try! JSONSerialization.data(withJSONObject: [id]), encoding: .utf8)!
        web.evaluateJavaScript("earmark.sentenceAfter(\(literal)[0])") { result, _ in
            done(result as? Int ?? 0)
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready": onReady?(body["sentences"] as? [String] ?? [])
        case "seek": if let index = body["index"] as? Int { onSeek?(chapter, index) }
        default: break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        if url.isFileURL {
            onLink?(url)
        } else if url.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - PDF, page by page

final class PDFSurface: Surface {
    private let pdfView = ClickablePDFView()
    var view: NSView { pdfView }
    var onReady: (([String]) -> Void)?
    var onSeek: ((Int, Int) -> Void)?
    private var page: PDFPage?
    private var ranges: [NSRange] = []

    init() {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .windowBackgroundColor
        pdfView.onClick = { [weak self] page, index in self?.clicked(page, index) }
    }

    func show(_ book: Book, chapter: Int) {
        guard let doc = book.pdf, let page = doc.page(at: chapter) else { return }
        if pdfView.document !== doc { pdfView.document = doc }
        self.page = page
        let (ranges, texts) = Self.sentences(on: page)
        self.ranges = ranges
        pdfView.highlightedSelections = nil
        DispatchQueue.main.async { self.onReady?(texts) }
    }

    func highlight(sentence: Int, word: NSRange?, follow: Bool) {
        guard let page, ranges.indices.contains(sentence), let whole = page.selection(for: ranges[sentence]) else { return }
        // One box per line, so a sentence over several lines isn't drawn as one big block.
        var shown = whole.selectionsByLine()
        for line in shown { line.color = NSColor.systemYellow.withAlphaComponent(0.35) }
        var focus = whole
        if let word, word.length > 0,
           let part = page.selection(for: NSRange(location: ranges[sentence].location + word.location, length: word.length)) {
            part.color = NSColor.systemOrange.withAlphaComponent(0.6)
            shown.append(part)
            focus = part
        }
        pdfView.highlightedSelections = shown
        guard follow else { return }
        let rect = pdfView.convert(focus.bounds(for: page), from: page)
        if !pdfView.bounds.insetBy(dx: 0, dy: pdfView.bounds.height * 0.15).contains(rect) {
            var target = focus.bounds(for: page)
            target.origin.y += pdfView.bounds.height * 0.3 / max(pdfView.scaleFactor, 0.1)
            pdfView.go(to: target, on: page)
        }
    }

    /// Zooms the page in or out; zero goes back to fitting the window.
    func zoom(_ step: Int) {
        if step == 0 {
            pdfView.autoScales = true
        } else {
            pdfView.autoScales = false
            pdfView.scaleFactor *= step > 0 ? 1.1 : 1 / 1.1
        }
    }

    /// Finds text anywhere in the PDF after the current match, wrapping around.
    func find(_ text: String, backwards: Bool) -> Bool {
        guard let doc = pdfView.document else { return false }
        var options: NSString.CompareOptions = [.caseInsensitive]
        if backwards { options.insert(.backwards) }
        let found = doc.findString(text, fromSelection: lastFound, withOptions: options)
            ?? doc.findString(text, fromSelection: nil, withOptions: options)
        lastFound = found
        guard let found else { return false }
        pdfView.setCurrentSelection(found, animate: true)
        pdfView.scrollSelectionToVisible(nil)
        return true
    }

    private var lastFound: PDFSelection?

    func upcoming(_ book: Book, chapter: Int, count: Int, done: @escaping ([String]) -> Void) {
        guard let page = book.pdf?.page(at: chapter) else { return done([]) }
        done(Array(Self.sentences(on: page).1.prefix(count)))
    }

    private func clicked(_ clickedPage: PDFPage, _ index: Int) {
        guard let doc = clickedPage.document else { return }
        let (ranges, _) = Self.sentences(on: clickedPage)
        guard let i = ranges.firstIndex(where: { index < $0.upperBound }) else { return }
        onSeek?(doc.index(for: clickedPage), i)
    }

    private static func sentences(on page: PDFPage) -> ([NSRange], [String]) {
        let text = page.string ?? ""
        let ranges = Sentences.split(text)
        let ns = text as NSString
        return (ranges, ranges.map { ns.substring(with: $0).replacingOccurrences(of: "\n", with: " ") })
    }
}

/// A PDF view that reports a plain click (not a drag or a text selection) as a page and character.
final class ClickablePDFView: PDFView {
    var onClick: ((PDFPage, Int) -> Void)?
    private var downAt: NSPoint?

    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard let start = downAt, event.clickCount == 1,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) < 4,
              (currentSelection?.string ?? "").isEmpty else { return }
        downAt = nil
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return }
        let index = page.characterIndex(at: convert(point, to: page))
        if index >= 0 { onClick?(page, index) }
    }
}
