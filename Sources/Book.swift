import CryptoKit
import Foundation

struct TocEntry {
    let title: String
    let spineIndex: Int
    /// The anchor inside the chapter file, when several entries share one file.
    let fragment: String?
}

enum BookError: LocalizedError {
    case unzip(String), missing(String)

    var errorDescription: String? {
        switch self {
        case .unzip(let msg): "Couldn't open the EPUB: \(msg)"
        case .missing(let what): "This EPUB has no \(what)."
        }
    }
}

/// An unpacked EPUB: its reading order (spine) and table of contents.
final class Book {
    let file: URL
    let id: String
    let root: URL
    let title: String
    let language: String
    let spine: [URL]
    let toc: [TocEntry]

    init(file: URL) throws {
        self.file = file
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let stamp = "\(file.path)|\(attrs[.size] ?? 0)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
        id = SHA256.hash(data: Data(stamp.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
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
        title = text("//*[local-name()='metadata']/*[local-name()='title']") ?? file.deletingPathExtension().lastPathComponent
        language = text("//*[local-name()='metadata']/*[local-name()='language']") ?? "en"

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

    func spineIndex(of url: URL) -> Int? {
        let target = url.standardizedFileURL.path
        return spine.firstIndex { $0.standardizedFileURL.path == target }
    }

    // MARK: - helpers

    private static func unpack(_ file: URL, id: String) throws -> URL {
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(appName)/books", isDirectory: true)
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
