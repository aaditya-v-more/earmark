import AVFoundation
import Foundation

/// Plays silently while still timing words, for testing next to a running copy (`defaults write <id> mute -bool true`).
private var muted: Bool { UserDefaults.standard.bool(forKey: "mute") }

/// Speaks one sentence at a time and reports which word is being spoken.
protocol SpeechEngine: AnyObject {
    var onWord: ((NSRange) -> Void)? { get set }
    var onFinish: (() -> Void)? { get set }
    var onError: ((String) -> Void)? { get set }
    func speak(_ text: String, speed: Double)
    func prepare(_ text: String, speed: Double)
    func pause()
    func resume()
    func stop()
}

// MARK: - System voices (includes third-party voice extensions)

final class SystemEngine: NSObject, SpeechEngine, AVSpeechSynthesizerDelegate {
    var onWord: ((NSRange) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((String) -> Void)?
    private let synth = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?
    private var current: AVSpeechUtterance?

    init(voiceIdentifier: String) {
        voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, speed: Double) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Self.rate(for: speed)
        if muted { utterance.volume = 0 }
        current = utterance
        synth.stopSpeaking(at: .immediate)
        synth.speak(utterance)
    }

    func prepare(_ text: String, speed: Double) {}
    func pause() { synth.pauseSpeaking(at: .immediate) }
    func resume() { synth.continueSpeaking() }

    func stop() {
        current = nil
        synth.stopSpeaking(at: .immediate)
    }

    /// AVSpeechUtterance's rate is 0...1 with 0.5 as normal speech; 1.0 is roughly 3x.
    static func rate(for speed: Double) -> Float {
        let r = speed >= 1 ? 0.5 + (speed - 1) * 0.25 : 0.5 * speed
        return Float(min(max(r, Double(AVSpeechUtteranceMinimumSpeechRate)), Double(AVSpeechUtteranceMaximumSpeechRate)))
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        onWord?(range)
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === current else { return }
        current = nil
        onFinish?()
    }
}

// MARK: - Plugin engines

/// An external TTS defined in engines.json: an HTTP endpoint or a command that writes a WAV file.
struct PluginConfig: Codable {
    var name: String
    var url: String?
    var body: [String: AnyCodable]?
    var command: [String]?
    /// A URL that lists the plugin's voices as JSON: [{"id", "name", "language", "gender"}].
    var voices: String?
    /// "engine": the plugin receives the speed. "player": Earmark speeds up playback (up to 2x).
    var speed: String?
    var enabled: Bool?

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(appName)/engines.json")
    }

    static let example = """
    {
      "engines": [
        {
          "name": "Google",
          "url": "http://127.0.0.1:5591/speak",
          "voices": "http://127.0.0.1:5591/voices",
          "speed": "engine"
        },
        {
          "name": "Piper (example)",
          "command": ["/opt/homebrew/bin/piper", "--model", "/path/to/voice.onnx", "--output_file", "{out}"],
          "speed": "player",
          "enabled": false
        }
      ]
    }

    """

    static func load() -> [PluginConfig] {
        if !FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? example.write(to: file, atomically: true, encoding: .utf8)
        }
        struct Root: Codable { var engines: [PluginConfig] }
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONDecoder().decode(Root.self, from: data) else { return [] }
        return root.engines.filter { $0.enabled != false }
    }
}

struct PluginVoice: Codable {
    var id: String
    var name: String
    var language: String?
    var gender: String?

    static func fetch(_ config: PluginConfig) async -> [PluginVoice]? {
        guard let url = config.voices.flatMap(URL.init(string:)) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return try? JSONDecoder().decode([PluginVoice].self, from: data)
    }
}

/// Any JSON value, so plugin request bodies can carry whatever the plugin wants.
struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v }
        else if let v = try? c.decode(Double.self) { value = v }
        else if let v = try? c.decode(String.self) { value = v }
        else if let v = try? c.decode([String: AnyCodable].self) { value = v.mapValues(\.value) }
        else if let v = try? c.decode([AnyCodable].self) { value = v.map(\.value) }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {}
}

final class PluginEngine: SpeechEngine {
    var onWord: ((NSRange) -> Void)?
    var onFinish: (() -> Void)?
    var onError: ((String) -> Void)?
    private let config: PluginConfig
    private let voice: String?
    private var cache: [String: Task<Data, Error>] = [:]
    private var player: AVAudioPlayer?
    private var words: [(range: NSRange, start: Double)] = []
    private var lastWord = -1
    private var ticker: Timer?
    private var generation = 0

    init(config: PluginConfig, voice: String?) {
        self.config = config
        self.voice = voice
    }

    private var engineSpeed: Bool { config.speed != "player" }

    func prepare(_ text: String, speed: Double) {
        _ = audio(for: text, speed: speed)
    }

    func speak(_ text: String, speed: Double) {
        stop()
        generation += 1
        let gen = generation
        let task = audio(for: text, speed: speed)
        Task { @MainActor in
            do {
                let data = try await task.value
                guard gen == self.generation else { return }
                try self.play(data, text: text, speed: speed)
            } catch {
                guard gen == self.generation else { return }
                self.cache[self.key(text, speed)] = nil
                self.onError?("\(self.config.name): \(error.localizedDescription)")
            }
        }
    }

    func pause() {
        player?.pause()
        ticker?.invalidate()
    }

    func resume() {
        guard let player else { return }
        player.play()
        startTicker()
    }

    func stop() {
        generation += 1
        ticker?.invalidate()
        player?.stop()
        player = nil
    }

    private func key(_ text: String, _ speed: Double) -> String { "\(engineSpeed ? speed : 1)|\(text)" }

    private func audio(for text: String, speed: Double) -> Task<Data, Error> {
        let k = key(text, speed)
        if let task = cache[k] { return task }
        if cache.count > 8 { cache.removeAll() }
        let config = config
        let voice = voice
        let s = engineSpeed ? speed : 1
        let task = Task.detached { try await Self.synthesize(config, voice: voice, text: text, speed: s) }
        cache[k] = task
        return task
    }

    private func play(_ data: Data, text: String, speed: Double) throws {
        let player = try AVAudioPlayer(data: data)
        if !engineSpeed {
            player.enableRate = true
            player.rate = Float(min(speed, 2))
        }
        if muted { player.volume = 0 }
        self.player = player
        words = WordTiming.align(text, audio: data)
        lastWord = -1
        player.prepareToPlay()
        player.play()
        startTicker()
    }

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let player else { return }
        if !player.isPlaying {
            ticker?.invalidate()
            self.player = nil
            onFinish?()
            return
        }
        let t = player.currentTime
        var i = lastWord
        while i + 1 < words.count && words[i + 1].start <= t { i += 1 }
        if i != lastWord, i >= 0 {
            lastWord = i
            onWord?(words[i].range)
        }
    }

    static func synthesize(_ config: PluginConfig, voice: String?, text: String, speed: Double) async throws -> Data {
        if let url = config.url.flatMap(URL.init(string:)) {
            var body = (config.body ?? [:]).mapValues(\.value)
            body["text"] = text
            if let voice { body["voice"] = voice }
            body["rate"] = speed
            var request = URLRequest(url: url, timeoutInterval: 120)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw NSError(domain: "Earmark", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    String(decoding: data.prefix(300), as: UTF8.self)])
            }
            return data
        }
        guard let command = config.command, !command.isEmpty else {
            throw NSError(domain: "Earmark", code: 2, userInfo: [NSLocalizedDescriptionKey: "needs a url or a command"])
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: out) }
        let args = command.map {
            $0.replacingOccurrences(of: "{out}", with: out.path)
                .replacingOccurrences(of: "{rate}", with: String(speed))
                .replacingOccurrences(of: "{voice}", with: voice ?? "")
                .replacingOccurrences(of: "{text}", with: text)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data(text.utf8))
        try input.fileHandleForWriting.close()
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                process.waitUntilExit()
                cont.resume()
            }
        }
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Earmark", code: 3, userInfo: [NSLocalizedDescriptionKey: "command exited with \(process.terminationStatus)"])
        }
        return try Data(contentsOf: out)
    }
}
