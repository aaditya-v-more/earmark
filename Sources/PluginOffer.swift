import AppKit

/// Optional plugins that live outside Earmark. Each is installed by a script bundled in
/// Resources/plugins/<id>/install.sh, which also adds the plugin to engines.json.
struct PluginOffer {
    let id: String
    let title: String
    let summary: String
    /// Tells whether an engines.json entry belongs to this plugin.
    let matches: (PluginConfig) -> Bool

    static let googleVoices = PluginOffer(
        id: "google-voices",
        title: "Google voices",
        summary: """
            Earmark can read with Google's on-device voices, such as the US English voice sfg, \
            which stays clear at high speeds. Installing them adds google-tts-local with Homebrew \
            and downloads about 110 MB of voice data from Google. It needs a Mac with Apple silicon.

            You can do this later from Help → Install Google Voices.
            """,
        matches: { $0.start?.first?.hasSuffix("/gtts-service") ?? false })

    var script: URL? { Bundle.main.url(forResource: "install", withExtension: "sh", subdirectory: "plugins/\(id)") }
    var isInstalled: Bool { PluginConfig.load().contains(where: matches) }
    private var offeredKey: String { "offered.\(id)" }

    /// Asks once, the first time Earmark opens, unless the plugin is already set up.
    func offerOnce(in window: NSWindow?, install: @escaping () -> Void) {
        guard !UserDefaults.standard.bool(forKey: offeredKey) else { return }
        UserDefaults.standard.set(true, forKey: offeredKey)
        guard !isInstalled, script != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Install \(title)?"
        alert.informativeText = summary
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Not Now")
        let handle = { (response: NSApplication.ModalResponse) in if response == .alertFirstButtonReturn { install() } }
        if let window { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    /// Runs the install script, reporting each line it prints; `done` gets the error output on failure.
    func install(progress: @escaping (String) -> Void, done: @escaping (Bool, String) -> Void) {
        guard let script else { return done(false, "The installer is missing from \(appName).") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["EARMARK_APP_NAME"] = appName
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        out.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let line = text.split(whereSeparator: \.isNewline).last.map(String.init), !line.isEmpty else { return }
            DispatchQueue.main.async { progress(line) }
        }
        var errors = Data()
        let lock = NSLock()
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            lock.lock(); errors.append(data); if errors.count > 8192 { errors = errors.suffix(4096) }; lock.unlock()
        }
        process.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            lock.lock(); let message = String(decoding: errors, as: UTF8.self); lock.unlock()
            DispatchQueue.main.async { done(p.terminationStatus == 0, message) }
        }
        do { try process.run() } catch { done(false, error.localizedDescription) }
    }
}
