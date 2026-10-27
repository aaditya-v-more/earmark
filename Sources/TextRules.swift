import Foundation
import NaturalLanguage

/// Lines to skip and words to say differently, from two small files next to engines.json.
struct TextRules {
    private var skip: [NSRegularExpression] = []
    private var replacements: [(pattern: NSRegularExpression, template: String)] = []

    static var folder: URL { PluginConfig.file.deletingLastPathComponent() }
    static var skipFile: URL { folder.appendingPathComponent("skip.txt") }
    static var replacementsFile: URL { folder.appendingPathComponent("replacements.txt") }

    static let skipExample = """
    # Sentences matching any of these patterns are not read aloud (one regular
    # expression per line, case-insensitive). Lines starting with # are ignored.
    ^(translator|editor|tl|tlc|proofreader|pr|edited by|translated by)\\b.{0,80}$
    ^(previous|next) chapter\\b
    ^table of contents$
    ^sponsored\\b

    """

    static let replacementsExample = """
    # Say words differently: "from => to", one per line. Plain words match whole
    # words, case-insensitive; /pattern/ => text uses a regular expression.
    # Lines starting with # are ignored. Examples:
    # Lv. => level
    # Mt. => Mount
    # /\\bQi\\b/ => chee

    """

    static func load() -> TextRules {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, text) in [(skipFile, skipExample), (replacementsFile, replacementsExample)]
        where !FileManager.default.fileExists(atPath: file.path) {
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        var rules = TextRules()
        for line in lines(skipFile) {
            if let re = try? NSRegularExpression(pattern: line, options: [.caseInsensitive]) { rules.skip.append(re) }
        }
        for line in lines(replacementsFile) {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let from = parts[0].trimmingCharacters(in: .whitespaces)
            let to = parts[1].trimmingCharacters(in: .whitespaces)
            let pattern = from.count > 2 && from.hasPrefix("/") && from.hasSuffix("/")
                ? String(from.dropFirst().dropLast())
                : "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\p{L}\\p{N}])"
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                rules.replacements.append((re, NSRegularExpression.escapedTemplate(for: to)))
            }
        }
        return rules
    }

    private static func lines(_ file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func shouldSkip(_ sentence: String) -> Bool {
        let s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(s.startIndex..., in: s)
        return skip.contains { $0.firstMatch(in: s, range: range) != nil }
    }

    /// The text to send to the voice, and a way to map a word range in it back to the page text.
    func spoken(_ text: String) -> (text: String, toPage: (NSRange) -> NSRange) {
        guard !replacements.isEmpty else { return (text, { $0 }) }
        var current = text as NSString
        // For each UTF-16 unit of the current text: where it starts and ends in the original.
        var starts = Array(0..<current.length)
        var ends = (0..<current.length).map { $0 + 1 }
        for (re, template) in replacements {
            let matches = re.matches(in: current as String, range: NSRange(location: 0, length: current.length))
            guard !matches.isEmpty else { continue }
            let next = NSMutableString()
            var nextStarts: [Int] = [], nextEnds: [Int] = []
            var cursor = 0
            for m in matches {
                let before = NSRange(location: cursor, length: m.range.location - cursor)
                next.append(current.substring(with: before))
                nextStarts += starts[before.location..<before.upperBound]
                nextEnds += ends[before.location..<before.upperBound]
                let replacement = re.replacementString(for: m, in: current as String, offset: 0, template: template) as NSString
                let spanStart = m.range.length > 0 ? starts[m.range.location] : (m.range.location < starts.count ? starts[m.range.location] : text.utf16.count)
                let spanEnd = m.range.length > 0 ? ends[m.range.upperBound - 1] : spanStart
                next.append(replacement as String)
                nextStarts += Array(repeating: spanStart, count: replacement.length)
                nextEnds += Array(repeating: spanEnd, count: replacement.length)
                cursor = m.range.upperBound
            }
            let rest = NSRange(location: cursor, length: current.length - cursor)
            next.append(current.substring(with: rest))
            nextStarts += starts[rest.location..<rest.upperBound]
            nextEnds += ends[rest.location..<rest.upperBound]
            current = next
            starts = nextStarts
            ends = nextEnds
        }
        let finalStarts = starts, finalEnds = ends
        return (current as String, { r in
            guard r.length > 0, r.location < finalStarts.count else { return r }
            let last = min(r.upperBound, finalEnds.count) - 1
            let start = finalStarts[r.location]
            return NSRange(location: start, length: max(finalEnds[last] - start, 0))
        })
    }
}

enum Sentences {
    static let maxLength = 350

    /// Sentence ranges in `text` (UTF-16), trimmed, with overly long ones split at a comma or similar.
    static func split(_ text: String) -> [NSRange] {
        let ns = text as NSString
        let tokenizer = NLTokenizer(unit: .sentence)
        // Line breaks inside a PDF page are layout, not sentence ends.
        let flat = (text as NSString).replacingOccurrences(of: "\n", with: " ")
        tokenizer.string = flat
        var result: [NSRange] = []
        tokenizer.enumerateTokens(in: flat.startIndex..<flat.endIndex) { range, _ in
            var r = NSRange(range, in: flat)
            while r.length > 0, let c = Unicode.Scalar(ns.character(at: r.location)), CharacterSet.whitespacesAndNewlines.contains(c) {
                r = NSRange(location: r.location + 1, length: r.length - 1)
            }
            while r.length > 0, let c = Unicode.Scalar(ns.character(at: r.upperBound - 1)), CharacterSet.whitespacesAndNewlines.contains(c) {
                r.length -= 1
            }
            if r.length > 0, ns.substring(with: r).rangeOfCharacter(from: .alphanumerics) != nil {
                result += cap(r, in: ns)
            }
            return true
        }
        return result
    }

    private static func cap(_ r: NSRange, in ns: NSString) -> [NSRange] {
        var pieces: [NSRange] = []
        var rest = r
        while rest.length > maxLength {
            let window = NSRange(location: rest.location, length: maxLength)
            let sub = ns.substring(with: window) as NSString
            var cut = -1
            for mark in [",", ";", ":", "—", " "] {
                let found = sub.range(of: mark, options: .backwards)
                if found.location != NSNotFound, found.location > maxLength / 3 { cut = found.upperBound; break }
            }
            if cut < 0 { cut = maxLength }
            pieces.append(NSRange(location: rest.location, length: cut))
            rest = NSRange(location: rest.location + cut, length: rest.length - cut)
            while rest.length > 0, ns.character(at: rest.location) == 32 { rest = NSRange(location: rest.location + 1, length: rest.length - 1) }
        }
        if rest.length > 0 { pieces.append(rest) }
        return pieces
    }
}
