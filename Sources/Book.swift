import CryptoKit
import Foundation
import PDFKit

struct TocEntry {
    let title: String
    let spineIndex: Int
    /// The anchor inside the chapter file, when several entries share one file.
    let fragment: String?
}

enum BookError: LocalizedError {
    case unzip(String), missing(String), unreadable

    var errorDescription: String? {
        switch self {
        case .unzip(let msg): "Couldn't open the EPUB: \(msg)"
        case .missing(let what): "This book has no \(what)."
        case .unreadable: "Couldn't read this file."
        }
    }
}

/// A book ready to read: its chapters in reading order and its table of contents.
/// EPUB, HTML and plain text are shown as web pages (`spine`); a PDF is read page by page.
final class Book {
    let file: URL
    /// Keys the unpacked copy; changes when the file changes.
    let id: String
    /// Keys the reading position; survives moving or re-downloading the file.
    let positionID: String
    let root: URL
    let title: String
    let language: String
    let spine: [URL]
    let pdf: PDFDocument?
    let toc: [TocEntry]

    static let fileExtensions = ["epub", "pdf", "txt", "text", "md", "html", "htm", "xhtml"]

    var chapterCount: Int { pdf?.pageCount ?? spine.count }

    init(file: URL) throws {
        self.file = file
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let stamp = "\(file.path)|\(attrs[.size] ?? 0)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        id = Book.hash(stamp)
        let name = file.deletingPathExtension().lastPathComponent

        switch file.pathExtension.lowercased() {
        case "pdf":
            guard let doc = PDFDocument(url: file), doc.pageCount > 0 else { throw BookError.unreadable }
            pdf = doc
            root = file.deletingLastPathComponent()
            spine = []
            let attrs = doc.documentAttributes ?? [:]
            let embedded = (attrs[PDFDocumentAttribute.titleAttribute] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            title = embedded.isEmpty || embedded.lowercased() == "untitled" ? name : embedded
            language = Locale.current.language.languageCode?.identifier ?? "en"
            toc = Book.pdfToc(doc)
            positionID = Book.hash("pdf|\(title)|\(doc.pageCount)")
        case "txt", "text", "md":
            pdf = nil
            let text = try Book.readText(file)
            (root, spine, toc) = try Book.importText(text, id: id)
            title = name
            language = Locale.current.language.languageCode?.identifier ?? "en"
            positionID = Book.hash("text|\(name)|\(text.count)")
        case "html", "htm", "xhtml":
            pdf = nil
            root = file.deletingLastPathComponent()
            spine = [file]
            toc = [TocEntry(title: name, spineIndex: 0, fragment: nil)]
            title = name
            language = Locale.current.language.languageCode?.identifier ?? "en"
            positionID = id
        default:
            pdf = nil
            root = try Book.unpack(file, id: id)
            let container = try XMLDocument(contentsOf: root.appendingPathComponent("META-INF/container.xml"))
            guard let opfPath = try container.nodes(forXPath: "//*[local-name()='rootfile']/@full-path").first?.stringValue
            else { throw BookError.missing("package file") }
            let opfURL = root.appendingPathComponent(opfPath)
            let opf = try XMLDocument(contentsOf: opfURL)
            let base = opfURL.deletingLastPathComponent()

            func text(_ xpath: String) -> String? {
                (try? opf.nodes(forXPath: xpath))?.first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            title = text("//*[local-name()='metadata']/*[local-name()='title']") ?? name
            language = text("//*[local-name()='metadata']/*[local-name()='language']") ?? "en"
            let identifier = text("//*[local-name()='metadata']/*[local-name()='identifier']") ?? ""
            positionID = identifier.isEmpty ? id : Book.hash("epub|\(identifier)|\(title)")

            var hrefs: [String: URL] = [:]
            var navURL: URL?
            for case let item as XMLElement in try opf.nodes(forXPath: "//*[local-name()='manifest']/*[local-name()='item']") {
                guard let id = item.attribute(forName: "id")?.stringValue,
                      let href = item.attribute(forName: "href")?.stringValue,
                      let url = Book.resolve(href, against: base) else { continue }
                hrefs[id] = url
                if item.attribute(forName: "properties")?.stringValue?.split(separator: " ").contains("nav") == true {
                    navURL = url
                }
            }
            spine = try opf.nodes(forXPath: "//*[local-name()='spine']/*[local-name()='itemref']/@idref")
                .compactMap { $0.stringValue.flatMap { hrefs[$0] } }
            if spine.isEmpty { throw BookError.missing("chapters") }

            let ncxURL = text("//*[local-name()='spine']/@toc").flatMap { hrefs[$0] }
            toc = Book.readToc(nav: navURL, ncx: ncxURL, spine: spine)
        }
    }

    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(appName)/books", isDirectory: true)
    }

    // MARK: - PDF

    private static func pdfToc(_ doc: PDFDocument) -> [TocEntry] {
        var entries: [TocEntry] = []
        func walk(_ node: PDFOutline) {
            for i in 0..<node.numberOfChildren {
                guard let child = node.child(at: i) else { continue }
                if let page = child.destination?.page, let label = child.label, !label.isEmpty {
                    entries.append(TocEntry(title: label, spineIndex: doc.index(for: page), fragment: nil))
                }
                walk(child)
            }
        }
        if let outline = doc.outlineRoot { walk(outline) }
        if entries.isEmpty {
            entries = (0..<doc.pageCount).map { TocEntry(title: "Page \($0 + 1)", spineIndex: $0, fragment: nil) }
        }
        return entries
    }

    // MARK: - Plain text

    private static func readText(_ file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252, .isoLatin1] {
            if let s = String(data: data, encoding: encoding) { return s }
        }
        throw BookError.unreadable
    }

    /// Splits plain text into chapters at lines like "Chapter 12" (or every 300 paragraphs)
    /// and writes each as a small XHTML page in the cache.
    private static func importText(_ text: String, id: String) throws -> (URL, [URL], [TocEntry]) {
        let dest = cacheFolder.appendingPathComponent(id, isDirectory: true)
        let heading = try NSRegularExpression(pattern: #"^\s*((chapter|ch\.|part|book|volume)\s*([0-9]+|[ivxlcdm]+)\b|prologue\b|epilogue\b|第)"#,
                                              options: [.caseInsensitive])
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        // Files that separate paragraphs with blank lines usually wrap lines too: join them.
        let blank = lines.filter(\.isEmpty).count
        var paragraphs: [String] = []
        if blank > lines.count / 8 {
            var current: [String] = []
            for line in lines + [""] {
                if line.isEmpty {
                    if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                    current = []
                } else {
                    current.append(line)
                }
            }
        } else {
            paragraphs = lines
        }
        var chapters: [(title: String, lines: [String])] = [("Beginning", [])]
        for line in paragraphs where !line.isEmpty {
            let isHeading = line.count < 90 && heading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            if isHeading || chapters[chapters.count - 1].lines.count >= 300 {
                chapters.append((isHeading ? line : "Part \(chapters.count + 1)", []))
            }
            chapters[chapters.count - 1].lines.append(line)
        }
        chapters.removeAll { $0.lines.isEmpty }
        if chapters.isEmpty { throw BookError.missing("text") }

        let ready = dest.appendingPathComponent("ready")
        if !FileManager.default.fileExists(atPath: ready.path) {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
            for (i, chapter) in chapters.enumerated() {
                func escape(_ s: String) -> String {
                    s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                        .replacingOccurrences(of: ">", with: "&gt;")
                }
                let body = chapter.lines.enumerated().map { j, line in
                    j == 0 && line == chapter.title ? "<h2>\(escape(line))</h2>" : "<p>\(escape(line))</p>"
                }.joined(separator: "\n")
                let page = """
                <?xml version="1.0" encoding="utf-8"?>
                <html xmlns="http://www.w3.org/1999/xhtml"><head><meta charset="utf-8"/><title>\(escape(chapter.title))</title></head>
                <body>
                \(body)
                </body></html>
                """
                try page.write(to: dest.appendingPathComponent(String(format: "%05d.xhtml", i)), atomically: true, encoding: .utf8)
            }
            try Data().write(to: ready)
        }
        let spine = chapters.indices.map { dest.appendingPathComponent(String(format: "%05d.xhtml", $0)) }
        let toc = chapters.enumerated().map { TocEntry(title: $1.title, spineIndex: $0, fragment: nil) }
        return (dest, spine, toc)
    }

    // MARK: - EPUB

    func spineIndex(of url: URL) -> Int? {
        let target = url.standardizedFileURL.path
        return spine.firstIndex { $0.standardizedFileURL.path == target }
    }

    // MARK: - helpers

    private static func unpack(_ file: URL, id: String) throws -> URL {
        let cache = cacheFolder
        let dest = cache.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: dest.appendingPathComponent("META-INF/container.xml").path) {
            return dest
        }
        let tmp = cache.appendingPathComponent(id + ".part", isDirectory: true)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-qq", "-o", file.path, "-d", tmp.path]
        let err = Pipe()
        unzip.standardError = err
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw BookError.unzip(msg.isEmpty ? "unzip failed" : msg)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    private static func resolve(_ href: String, against base: URL) -> URL? {
        let path = href.split(separator: "#", maxSplits: 1).first.map(String.init) ?? href
        guard !path.isEmpty, let decoded = path.removingPercentEncoding else { return nil }
        return URL(fileURLWithPath: decoded, relativeTo: base).standardizedFileURL
    }

    private static func readToc(nav: URL?, ncx: URL?, spine: [URL]) -> [TocEntry] {
        let index = Dictionary(spine.enumerated().map { ($1.path, $0) }, uniquingKeysWith: { a, _ in a })
        var entries: [TocEntry] = []
        func add(_ title: String?, _ href: String?, _ base: URL) {
            guard let href, let url = resolve(href, against: base), let i = index[url.path] else { return }
            let name = (title ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let fragment = href.split(separator: "#", maxSplits: 1).dropFirst().first.map(String.init)
            entries.append(TocEntry(title: name.isEmpty ? "Section \(i + 1)" : name, spineIndex: i, fragment: fragment))
        }
        if let nav, let doc = (try? XMLDocument(contentsOf: nav)) ?? (try? XMLDocument(contentsOf: nav, options: [.documentTidyHTML])) {
            let links = (try? doc.nodes(forXPath: "//*[local-name()='nav'][@*[local-name()='type']='toc']//*[local-name()='a']")) ?? []
            for case let a as XMLElement in links {
                add(a.stringValue, a.attribute(forName: "href")?.stringValue, nav.deletingLastPathComponent())
            }
        }
        if entries.isEmpty, let ncx, let doc = try? XMLDocument(contentsOf: ncx) {
            for case let point as XMLElement in (try? doc.nodes(forXPath: "//*[local-name()='navPoint']")) ?? [] {
                let label = (try? point.nodes(forXPath: "*[local-name()='navLabel']/*[local-name()='text']"))?.first?.stringValue
                let src = (try? point.nodes(forXPath: "*[local-name()='content']/@src"))?.first?.stringValue
                add(label, src, ncx.deletingLastPathComponent())
            }
        }
        if entries.isEmpty {
            entries = spine.indices.map { TocEntry(title: "Section \($0 + 1)", spineIndex: $0, fragment: nil) }
        }
        return entries
    }
}
