import AVFoundation
import Foundation

/// Plugins return audio only, so word timings are worked out from the audio itself:
/// pauses in the audio are matched to the sentence's punctuation, and the words between
/// two pauses share that stretch of speech by their syllable count.
enum WordTiming {
    typealias Timing = (range: NSRange, start: Double)

    static func align(_ text: String, audio data: Data) -> [Timing] {
        let words = Self.words(text)
        guard !words.isEmpty else { return [] }
        guard let (envelope, step) = Self.envelope(data), let peak = envelope.max(), peak > 0 else {
            return spread(words, from: 0, to: 0)
        }
        let voiced = envelope.map { $0 > peak * 0.05 }
        guard let first = voiced.firstIndex(of: true), let last = voiced.lastIndex(of: true) else {
            return spread(words, from: 0, to: Double(envelope.count) * step)
        }

        // Pauses inside the speech, at least 40 ms long.
        var pauses: [(start: Int, end: Int)] = []
        var i = first
        while i <= last {
            if voiced[i] { i += 1; continue }
            var j = i
            while j <= last && !voiced[j] { j += 1 }
            if Double(j - i) * step >= 0.04 { pauses.append((i, j)) }
            i = j
        }

        // Places where the text should pause: after a word followed by punctuation,
        // with the time each would fall at if speech were spread evenly.
        let breaks = words.indices.dropLast().filter { words[$0].pause > 0 }
        let speechStart = Double(first) * step, speechEnd = Double(last + 1) * step
        let total = words.reduce(0) { $0 + $1.weight }
        var expected: [Int: Double] = [:]
        var acc = 0.0
        for (k, w) in words.enumerated() {
            acc += w.weight
            expected[k] = speechStart + acc / total * (speechEnd - speechStart)
        }

        // Match breaks to pauses in order, favouring long pauses close to where
        // they are expected (dynamic programming over both lists).
        let span = max(speechEnd - speechStart, 0.1)
        func score(_ b: Int, _ p: (start: Int, end: Int)) -> Double {
            let length = Double(p.end - p.start) * step
            let mid = Double(p.start + p.end) / 2 * step
            let distance = abs(mid - expected[breaks[b]]!) / span
            return length * 10 * Double(words[breaks[b]].pause) - distance * 4
        }
        let nb = breaks.count, np = pauses.count
        var best = Array(repeating: Array(repeating: 0.0, count: np + 1), count: nb + 1)
        for b in stride(from: nb - 1, through: 0, by: -1) {
            for p in stride(from: np - 1, through: 0, by: -1) {
                best[b][p] = max(best[b + 1][p], best[b][p + 1], score(b, pauses[p]) + best[b + 1][p + 1])
            }
        }
        var chosenBreaks: [Int] = [], chosenPauses: [(start: Int, end: Int)] = []
        var b = 0, p = 0
        while b < nb && p < np {
            let take = score(b, pauses[p]) + best[b + 1][p + 1]
            if take >= best[b + 1][p] && take >= best[b][p + 1] && score(b, pauses[p]) > 0 {
                chosenBreaks.append(breaks[b]); chosenPauses.append(pauses[p]); b += 1; p += 1
            } else if best[b + 1][p] >= best[b][p + 1] {
                b += 1
            } else {
                p += 1
            }
        }

        var result: [Timing] = []
        var segmentStart = 0
        var time = Double(first) * step
        for (b, p) in zip(chosenBreaks, chosenPauses) {
            result += spread(Array(words[segmentStart...b]), from: time, to: Double(p.start) * step)
            segmentStart = b + 1
            time = Double(p.end) * step
        }
        result += spread(Array(words[segmentStart...]), from: time, to: Double(last + 1) * step)
        return result
    }

    private struct Word {
        let range: NSRange
        let weight: Double
        /// 0 = none, 1 = comma-like, 2 = sentence end.
        let pause: Int
    }

    private static func words(_ text: String) -> [Word] {
        let ns = text as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, r, _, _ in
            ranges.append(r)
        }
        return ranges.enumerated().map { i, r in
            let word = ns.substring(with: r)
            let gapEnd = i + 1 < ranges.count ? ranges[i + 1].location : ns.length
            let gap = ns.substring(with: NSRange(location: r.upperBound, length: gapEnd - r.upperBound))
            let pause = gap.contains(where: { ".!?…".contains($0) }) ? 2 : gap.contains(where: { ",;:—–()".contains($0) }) ? 1 : 0
            return Word(range: r, weight: syllables(word) + 0.4, pause: pause)
        }
    }

    /// Roughly how long a word takes to say: vowel groups, or one per digit for numbers.
    private static func syllables(_ word: String) -> Double {
        let lower = word.lowercased()
        let digits = lower.filter(\.isNumber).count
        if digits > 0 { return Double(digits) }
        var groups = 0
        var inVowel = false
        for ch in lower {
            let vowel = "aeiouyàáâäèéêëìíîïòóôöùúûü".contains(ch)
            if vowel && !inVowel { groups += 1 }
            inVowel = vowel
        }
        if lower.hasSuffix("e") && !lower.hasSuffix("le") && groups > 1 { groups -= 1 }
        // Scripts without Latin vowels (Japanese, Hindi): go by length.
        return Double(groups > 0 ? groups : max(1, lower.count / 2))
    }

    private static func spread(_ words: [Word], from start: Double, to end: Double) -> [Timing] {
        let total = words.reduce(0) { $0 + $1.weight }
        var t = start
        return words.map { w in
            defer { t += total > 0 ? w.weight / total * max(end - start, 0) : 0 }
            return (w.range, t)
        }
    }

    /// RMS loudness in 10 ms steps, and the step length in seconds.
    private static func envelope(_ data: Data) -> ([Float], Double)? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil,
              let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let samples = buffer.floatChannelData?[0] else { return nil }
        let rate = file.processingFormat.sampleRate
        let hop = max(1, Int(rate / 100))
        let count = Int(buffer.frameLength)
        var env: [Float] = []
        env.reserveCapacity(count / hop + 1)
        var i = 0
        while i < count {
            let n = min(hop, count - i)
            var sum: Float = 0
            for k in 0..<n { sum += samples[i + k] * samples[i + k] }
            env.append((sum / Float(n)).squareRoot())
            i += hop
        }
        return (env, Double(hop) / rate)
    }
}
