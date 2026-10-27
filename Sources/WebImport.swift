import Foundation

/// Turns a web page (and, optionally, the chapters its "Next" links lead to) into an EPUB.
final class WebImporter {
    var onProgress: ((String) -> Void)?
    private(set) var cancelled = false

    func cancel() { cancelled = true }

    struct Chapter {
        let title: String
        let paragraphs: [String]
        /// The page's <title>, used to work out the book's name.
        var pageTitle = ""
    }

    /// Downloads from `start`, following "Next" links up to `limit` chapters, and writes `<folder>/<title>.epub`.
    /// Stopping early keeps what was downloaded.
    func run(from start: URL, follow: Bool, limit: Int, into folder: URL) async throws -> URL {
        var chapters: [Chapter] = []
        var url: URL? = start
        var seen: Set<String> = []
        while let current = url, chapters.count < limit, !cancelled {
            seen.insert(current.absoluteString)
            onProgress?(follow ? "Downloading chapter \(chapters.count + 1)…" : "Downloading page…")
            let page = try await Self.fetch(current)
            if Self.isBrowserCheck(page) {
                if chapters.isEmpty { throw ImportError.browserCheck }
                break
            }
            guard let parsed = Self.parse(page, url: current) else {
                if chapters.isEmpty { throw ImportError.noText }
                break
            }
            chapters.append(parsed.chapter)
            url = follow ? parsed.next.flatMap { seen.contains($0.absoluteString) ? nil : $0 } : nil
            if url != nil { try? await Task.sleep(for: .milliseconds(400)) }  // be gentle with the site
        }
        if chapters.isEmpty { throw ImportError.noText }
        onProgress?("Building the book…")
        return try Self.writeEPUB(chapters, title: Self.bookTitle(chapters), source: start, folder: folder)
    }

    enum ImportError: LocalizedError {
        case noText, zip, browserCheck
        var errorDescription: String? {
            switch self {
            case .noText: "Couldn't find the text on that page."
            case .browserCheck: "That site shows a browser check instead of the page. Save the page from your browser and open the file instead."
            case .zip: "Couldn't build the book file."
            }
        }
    }

    // MARK: - Fetching and extracting

    private static func fetch(_ url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let encoding = (response as? HTTPURLResponse)?.textEncodingName
            .map { CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding($0 as CFString)) }
            .map { String.Encoding(rawValue: $0) } ?? .utf8
        return String(data: data, encoding: encoding) ?? String(decoding: data, as: UTF8.self)
    }

    /// Pages that ask for a human or a JavaScript check instead of showing content.
    private static func isBrowserCheck(_ html: String) -> Bool {
        let head = html.prefix(20_000).lowercased()
        return ["not a bot", "just a moment...", "attention required", "verify you are human", "cf-challenge", "captcha"]
            .contains(where: head.contains)
    }

    private static let nextWords = try! NSRegularExpression(
        pattern: #"^\W*(next(\s+(chapter|chap|ch\.?|page|part))?|下一章|下一页|siguiente|suivant)\W*$"#, options: [.caseInsensitive])

    static func parse(_ html: String, url: URL) -> (chapter: Chapter, next: URL?)? {
        guard let doc = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]) else { return nil }
        for junk in (try? doc.nodes(forXPath: "//script|//style|//noscript|//iframe|//ins")) ?? [] { junk.detach() }
        let next = nextLink(doc, url: url)
        // Page furniture goes only after the "Next" link is found, since it usually lives there.
        for junk in (try? doc.nodes(forXPath: "//nav|//footer|//header|//form")) ?? [] { junk.detach() }

        // The block with the most paragraph text is the chapter.
        var best: (XMLElement, Int)?
        for case let el as XMLElement in (try? doc.nodes(forXPath: "//div|//article|//section|//main|//td")) ?? [] {
            let paragraphs = el.children?.compactMap { ($0 as? XMLElement)?.name == "p" ? $0.stringValue?.count : nil }.reduce(0, +) ?? 0
            let brs = el.children?.filter { ($0 as? XMLElement)?.name == "br" }.count ?? 0
            let loose = brs > 3 ? (el.children?.filter { $0.kind == .text }.compactMap { $0.stringValue?.count }.reduce(0, +) ?? 0) : 0
            var score = paragraphs + loose
            let tag = ((el.attribute(forName: "id")?.stringValue ?? "") + " " + (el.attribute(forName: "class")?.stringValue ?? "")).lowercased()
            if ["chapter-content", "chapter_content", "chr-content", "chapter-c", "novel_content", "entry-content", "reading-content", "text-left", "content"]
                .contains(where: tag.contains) { score += score / 4 }
            if score > (best?.1 ?? 0) { best = (el, score) }
        }
        guard let (content, score) = best, score > 200 else { return nil }

        var paragraphs: [String] = []
        var line = ""
        func flush() {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            if !t.isEmpty { paragraphs.append(t) }
            line = ""
        }
        for child in content.children ?? [] {
            let name = (child as? XMLElement)?.name ?? ""
            if name == "br" { flush(); continue }
            if ["p", "div", "h1", "h2", "h3", "h4", "blockquote", "li"].contains(name) {
                flush(); line = child.stringValue ?? ""; flush()
            } else {
                line += child.stringValue ?? ""
            }
        }
        flush()

        // Chapter title: a heading inside the text, else a short first line that looks like one,
        // else the page title without the site's name.
        let pageTitle = (try? doc.nodes(forXPath: "//title"))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let inner = (try? content.nodes(forXPath: ".//h1|.//h2|.//h3|.//h4"))?.lazy
            .compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty && $0.count < 150 }
        var title = inner ?? ""
        if title.isEmpty, let first = paragraphs.first, first.count < 100,
           first.range(of: #"(?i)\b(chapter|ch\.|episode|part|prologue|epilogue)\b|^\d+"#, options: .regularExpression) != nil {
            title = first
        }
        if title.isEmpty {
            let parts = pageTitle.components(separatedBy: CharacterSet(charactersIn: "|–—")).map { $0.trimmingCharacters(in: .whitespaces) }
            title = parts.first { !$0.isEmpty } ?? url.lastPathComponent
        }
        if paragraphs.first == title { paragraphs.removeFirst() }

        return (Chapter(title: title, paragraphs: paragraphs, pageTitle: pageTitle), next)
    }

    private static func nextLink(_ doc: XMLDocument, url: URL) -> URL? {
        for case let a as XMLElement in (try? doc.nodes(forXPath: "//a[@href]")) ?? [] {
            guard let href = a.attribute(forName: "href")?.stringValue, !href.hasPrefix("#"),
                  !href.lowercased().hasPrefix("javascript") else { continue }
            let text = (a.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let rel = a.attribute(forName: "rel")?.stringValue?.lowercased() ?? ""
            let tag = ((a.attribute(forName: "id")?.stringValue ?? "") + " " + (a.attribute(forName: "class")?.stringValue ?? "")).lowercased()
            let looksNext = rel.split(separator: " ").contains("next")
                || nextWords.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
                || (tag.contains("next") && !tag.contains("prev"))
            if looksNext, let target = URL(string: href, relativeTo: url)?.absoluteURL, target != url,
               target.scheme?.hasPrefix("http") == true {
                return target
            }
        }
        return nil
    }

    /// The book's name: what the first two page titles share, else the first page title's leading part.
    private static func bookTitle(_ chapters: [Chapter]) -> String {
        let clean = #"(?i)[\s\-–—:|,]*(chapter|ch\.?|episode|part|vol\.?|volume)?\s*\d*\s*$"#
        if chapters.count > 1 {
            let a = Array(chapters[0].pageTitle), b = Array(chapters[1].pageTitle)
            var n = 0
            while n < min(a.count, b.count) && a[n] == b[n] { n += 1 }
            let shared = String(a.prefix(n)).replacingOccurrences(of: clean, with: "", options: .regularExpression)
            if shared.count >= 4 { return shared }
        }
        let first = chapters[0].pageTitle.components(separatedBy: CharacterSet(charactersIn: "|–—-:"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.count >= 3 }
        return first ?? chapters[0].title
    }

    // MARK: - Writing the EPUB

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func writeEPUB(_ chapters: [Chapter], title: String, source: URL, folder: URL) throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: work.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        try "application/epub+zip".write(to: work.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
          <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """.write(to: work.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)

        var manifest = "", spine = "", nav = ""
        for (i, ch) in chapters.enumerated() {
            let name = String(format: "ch%04d.xhtml", i + 1)
            let body = ch.paragraphs.map { "<p>\(escape($0))</p>" }.joined(separator: "\n")
            try """
            <?xml version="1.0" encoding="UTF-8"?>
            <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(escape(ch.title))</title></head>
            <body><h2>\(escape(ch.title))</h2>
            \(body)
            </body></html>
            """.write(to: work.appendingPathComponent("OEBPS/" + name), atomically: true, encoding: .utf8)
            manifest += "<item id=\"c\(i + 1)\" href=\"\(name)\" media-type=\"application/xhtml+xml\"/>\n"
            spine += "<itemref idref=\"c\(i + 1)\"/>\n"
            nav += "<li><a href=\"\(name)\">\(escape(ch.title))</a></li>\n"
        }
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>Contents</title></head>
        <body><nav epub:type="toc"><ol>
        \(nav)</ol></nav></body></html>
        """.write(to: work.appendingPathComponent("OEBPS/nav.xhtml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
          <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
            <dc:identifier id="id">\(escape(source.absoluteString))</dc:identifier>
            <dc:title>\(escape(title))</dc:title>
            <dc:language>en</dc:language>
            <dc:source>\(escape(source.absoluteString))</dc:source>
          </metadata>
          <manifest>
            <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
            \(manifest)</manifest>
          <spine>
            \(spine)</spine>
        </package>
        """.write(to: work.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = title.replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "-", options: .regularExpression).prefix(80)
        var out = folder.appendingPathComponent("\(safe).epub")
        var n = 2
        while fm.fileExists(atPath: out.path) {
            out = folder.appendingPathComponent("\(safe) \(n).epub")
            n += 1
        }
        // The mimetype entry must come first and uncompressed.
        for args in [["-X0q", out.path, "mimetype"], ["-Xr9qD", out.path, "META-INF", "OEBPS"]] {
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
            zip.arguments = args
            zip.currentDirectoryURL = work
            try zip.run()
            zip.waitUntilExit()
            if zip.terminationStatus != 0 { throw ImportError.zip }
        }
        return out
    }
}

/// Text and links read from the clipboard, kept for a while so they can be reopened.
enum Pasted {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(appName)/Pasted", isDirectory: true)
    }

    /// Saves pasted text as a .txt file named after its first words.
    static func save(_ text: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let stamp = formatter.string(from: Date())
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
            .replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "", options: .regularExpression)
        let url = folder.appendingPathComponent("\(stamp) \(words.prefix(50)).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Deletes pasted items older than the limit in Settings.
    static func prune() {
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-Double(Prefs.pasteDays) * 86_400)
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if date < cutoff { try? fm.removeItem(at: url) }
        }
    }
}
