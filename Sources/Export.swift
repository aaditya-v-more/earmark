import AVFoundation
import Foundation

/// Saves chapters as M4A files with the chosen voice, speed, pronunciations, skipped lines and pauses.
final class AudioExporter {
    var onProgress: ((String) -> Void)?
    private(set) var cancelled = false
    func cancel() { cancelled = true }

    enum Voice {
        case system(String)
        case plugin(PluginConfig, String?)
    }

    struct Job {
        let titles: [String]          // one per chapter, for file names
        let speed: Double
        let voice: Voice
        let rules: TextRules
    }

    /// `sentences(i)` gives chapter i's sentences and whether each ends a paragraph.
    func run(_ job: Job, chapters: [Int], folder: URL,
             sentences: @escaping (Int) async -> [(String, Bool)]) async throws -> Int {
        var written = 0
        for (n, chapter) in chapters.enumerated() where !cancelled {
            let title = job.titles.indices.contains(chapter) ? job.titles[chapter] : "Chapter \(chapter + 1)"
            onProgress?("Exporting \(n + 1) of \(chapters.count): \(title)")
            let list = await sentences(chapter).filter { !job.rules.shouldSkip($0.0) }
            guard !list.isEmpty else { continue }
            let safe = title.replacingOccurrences(of: #"[/:\\?%*|"<>]"#, with: "-", options: .regularExpression).prefix(80)
            let url = folder.appendingPathComponent(String(format: "%04d ", chapter + 1) + safe + ".m4a")
            let writer = Writer(url: url)
            for (i, (text, paragraphEnd)) in list.enumerated() where !cancelled {
                let spoken = job.rules.spoken(text).text
                switch job.voice {
                case .plugin(let config, let voice):
                    let speed = config.speed == "player" ? 1 : job.speed
                    let data = try await PluginEngine.synthesize(config, voice: voice, text: spoken, speed: speed)
                    if let (samples, rate) = WordTiming.decode(data) { try writer.append(samples, rate: rate) }
                case .system(let id):
                    try await Self.systemSpeech(spoken, voice: id, speed: job.speed) { samples, rate in try writer.append(samples, rate: rate) }
                }
                let ms = i == list.count - 1 ? 0 : (paragraphEnd ? Prefs.pauseParagraph : Prefs.pauseSentence)
                if ms > 0 { try writer.silence(ms) }
            }
            writer.close()
            if !cancelled { written += 1 } else { try? FileManager.default.removeItem(at: url) }
        }
        return written
    }

    /// System voices render into buffers instead of the speakers; the delegate says when a sentence is done.
    private static func systemSpeech(_ text: String, voice: String, speed: Double,
                                     sink: @escaping ([Float], Double) throws -> Void) async throws {
        let synth = AVSpeechSynthesizer()
        let watcher = FinishWatcher()
        synth.delegate = watcher
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voice)
        utterance.rate = SystemEngine.rate(for: speed)
        var failure: Error?
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            watcher.onFinish = { done.resume() }
            synth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
                let n = Int(pcm.frameLength)
                let samples: [Float]
                if let f = pcm.floatChannelData?[0] {
                    samples = Array(UnsafeBufferPointer(start: f, count: n))
                } else if let i = pcm.int16ChannelData?[0] {
                    samples = UnsafeBufferPointer(start: i, count: n).map { Float($0) / 32768 }
                } else {
                    samples = []
                }
                do { try sink(samples, pcm.format.sampleRate) } catch { failure = error }
            }
        }
        _ = synth
        if let failure { throw failure }
    }

    private final class FinishWatcher: NSObject, AVSpeechSynthesizerDelegate {
        var onFinish: (() -> Void)?
        private let lock = NSLock()

        private func finish() {
            lock.lock()
            let f = onFinish
            onFinish = nil
            lock.unlock()
            f?()
        }

        func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { finish() }
        func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { finish() }
    }

    /// One AAC file, opened at the first chunk's sample rate; later chunks at another rate are converted.
    private final class Writer {
        let url: URL
        private var file: AVAudioFile?
        private var rate: Double = 0

        init(url: URL) { self.url = url }

        func append(_ samples: [Float], rate inRate: Double) throws {
            guard !samples.isEmpty else { return }
            if file == nil {
                rate = inRate
                let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate,
                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000]
                file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            let data = inRate == rate ? samples : Self.resample(samples, from: inRate, to: rate)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(data.count)) else { return }
            buffer.frameLength = AVAudioFrameCount(data.count)
            data.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: data.count) }
            try file?.write(from: buffer)
        }

        func silence(_ ms: Int) throws {
            guard rate > 0 else { return }
            try append(Array(repeating: 0, count: Int(rate * Double(ms) / 1000)), rate: rate)
        }

        func close() { file = nil }

        /// Linear resampling; enough for speech.
        private static func resample(_ x: [Float], from a: Double, to b: Double) -> [Float] {
            let count = Int(Double(x.count) * b / a)
            guard count > 1, x.count > 1 else { return x }
            return (0..<count).map { i in
                let pos = Double(i) * a / b
                let j = min(Int(pos), x.count - 2)
                let t = Float(pos - Double(j))
                return x[j] * (1 - t) + x[j + 1] * t
            }
        }
    }
}
