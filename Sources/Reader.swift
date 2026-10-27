import AppKit
import AVFoundation
import WebKit

/// The single reading window: the chapter on top, a slim control bar below.
final class ReaderController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate {
    private let web: WKWebView
    private let chapterMenu = NSPopUpButton()
    private let voiceMenu = NSPopUpButton()
    private let speedMenu = NSPopUpButton()
    private let playButton = NSButton()
    private let status = NSTextField(labelWithString: "")

    private var book: Book?
    private var chapter = 0
    private var sentences: [String] = []
    private var sentence = 0
    private var pendingSentence: Int?
    private var pendingFragment: String?
    private var playing = false
    private var paused = false
    private var engine: SpeechEngine?
    private var plugins: [PluginConfig] = []

    private let defaults = UserDefaults.standard
    private static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3, 3.5, 4]

    private var speed: Double {
        get { defaults.object(forKey: "speed") as? Double ?? 1 }
        set { defaults.set(newValue, forKey: "speed") }
    }

    private var voiceKey: String? {
        get { defaults.string(forKey: "voice") }
        set { defaults.set(newValue, forKey: "voice") }
    }

    init() {
        let config = WKWebViewConfiguration()
        let bundle = Bundle.main
        let js = (try? String(contentsOf: bundle.url(forResource: "reader", withExtension: "js")!, encoding: .utf8)) ?? ""
        let css = (try? String(contentsOf: bundle.url(forResource: "reader", withExtension: "css")!, encoding: .utf8)) ?? ""
        let cssLiteral = String(data: try! JSONSerialization.data(withJSONObject: [css], options: [.fragmentsAllowed]), encoding: .utf8)!
        let style = """
        (() => { const s = document.createElementNS('http://www.w3.org/1999/xhtml', 'style');
          s.textContent = \(cssLiteral)[0];
          (document.head || document.documentElement).appendChild(s); })();
        """
        config.userContentController.addUserScript(WKUserScript(source: style, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: config)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 420, height: 320)
        window.title = "Earmark"
        super.init(window: window)
        config.userContentController.add(self, name: "earmark")
        web.navigationDelegate = self
        buildLayout()
        window.setFrameAutosaveName("Reader")
        if !window.setFrameUsingName("Reader") { window.center() }
        plugins = PluginConfig.load()
        rebuildVoiceMenu()
        rebuildSpeedMenu()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        func icon(_ name: String, _ label: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: name, accessibilityDescription: label)!, target: self, action: action)
            b.isBordered = false
            b.toolTip = label
            b.symbolConfiguration = .init(pointSize: 15, weight: .medium)
            return b
        }
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")
        playButton.isBordered = false
        playButton.symbolConfiguration = .init(pointSize: 19, weight: .semibold)
        playButton.target = self
        playButton.action = #selector(togglePlay)
        playButton.toolTip = "Play / Pause (Space)"

        for menu in [chapterMenu, voiceMenu, speedMenu] {
            menu.isBordered = false
            menu.controlSize = .small
            menu.font = .systemFont(ofSize: 12)
            menu.target = self
        }
        chapterMenu.action = #selector(chapterChosen)
        voiceMenu.action = #selector(voiceChosen)
        speedMenu.action = #selector(speedChosen)
        chapterMenu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        voiceMenu.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controls = NSStackView(views: [
            icon("backward.fill", "Previous sentence", #selector(previousSentence)),
            playButton,
            icon("forward.fill", "Next sentence", #selector(nextSentence)),
        ])
        controls.spacing = 14
        let bar = NSStackView(views: [chapterMenu, status, NSView(), controls, NSView(), voiceMenu, speedMenu])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)
        bar.setHuggingPriority(.defaultHigh, for: .vertical)
        let spacers = bar.arrangedSubviews.filter { type(of: $0) == NSView.self }
        spacers[0].widthAnchor.constraint(equalTo: spacers[1].widthAnchor).isActive = true

        let effect = NSVisualEffectView()
        effect.material = .titlebar
        effect.addSubview(bar)
        let line = NSBox()
        line.boxType = .separator

        for v in [web, effect, line, bar] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        content.addSubview(web)
        content.addSubview(line)
        content.addSubview(effect)
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo: content.topAnchor),
            web.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            web.bottomAnchor.constraint(equalTo: line.topAnchor),
            line.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: effect.topAnchor),
            effect.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            effect.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.topAnchor.constraint(equalTo: effect.topAnchor),
            bar.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            effect.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    // MARK: - Menus

    private func rebuildSpeedMenu() {
        speedMenu.removeAllItems()
        for s in Self.speeds {
            speedMenu.addItem(withTitle: s.formatted(.number.precision(.fractionLength(0...2))) + "×")
            speedMenu.lastItem?.representedObject = s
        }
        let closest = Self.speeds.min { abs($0 - speed) < abs($1 - speed) } ?? 1
        speedMenu.selectItem(at: Self.speeds.firstIndex(of: closest) ?? 1)
    }

    private func rebuildVoiceMenu() {
        let menu = NSMenu()
        let lang = String((book?.language ?? Locale.current.language.languageCode?.identifier ?? "en").prefix(2))
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(lang) }
            .sorted { $0.quality.rawValue != $1.quality.rawValue ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name }
        if !plugins.isEmpty {
            menu.addItem(.sectionHeader(title: "Plugins"))
            for p in plugins {
                let item = NSMenuItem(title: p.name, action: nil, keyEquivalent: "")
                item.representedObject = "plugin:" + p.name
                menu.addItem(item)
            }
        }
        menu.addItem(.sectionHeader(title: "System voices"))
        for v in voices {
            let item = NSMenuItem(title: "\(v.name) — \(v.language)", action: nil, keyEquivalent: "")
            item.representedObject = "system:" + v.identifier
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit Plugins…", action: nil, keyEquivalent: "")
        edit.representedObject = "edit-plugins"
        menu.addItem(edit)
        voiceMenu.menu = menu
        let selectable = menu.items.filter { ($0.representedObject as? String)?.contains(":") == true }
        let chosen = selectable.first { $0.representedObject as? String == voiceKey } ?? selectable.first { ($0.representedObject as? String)?.hasPrefix("system:") == true }
        if let chosen { voiceMenu.select(chosen); voiceKey = chosen.representedObject as? String }
        engine = nil
    }

    private func rebuildChapterMenu() {
        let menu = NSMenu()
        for (i, entry) in (book?.toc ?? []).enumerated() {
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.tag = i
            menu.addItem(item)
        }
        chapterMenu.menu = menu
        syncChapterMenu()
    }

    private func syncChapterMenu() {
        guard let toc = book?.toc, !toc.isEmpty else { return }
        let here = toc.indices.filter { toc[$0].spineIndex == chapter }
        guard let first = here.first else {
            if let before = toc.indices.last(where: { toc[$0].spineIndex < chapter }) { chapterMenu.selectItem(withTag: before) }
            return
        }
        chapterMenu.selectItem(withTag: first)
        let ids = here.compactMap { toc[$0].fragment }
        guard here.count > 1, ids.count == here.count, !sentences.isEmpty else { return }
        let json = String(data: try! JSONSerialization.data(withJSONObject: ids), encoding: .utf8)!
        web.evaluateJavaScript("earmark.section(\(json))") { [weak self] result, _ in
            if let i = result as? Int, i >= 0 { self?.chapterMenu.selectItem(withTag: here[i]) }
        }
    }

    @objc private func chapterChosen() {
        guard let toc = book?.toc, let tag = chapterMenu.selectedItem?.tag, toc.indices.contains(tag) else { return }
        let entry = toc[tag]
        let autoplay = playing && !paused
        if entry.spineIndex == chapter, let id = entry.fragment, !sentences.isEmpty {
            jump(toFragment: id, autoplay: autoplay)
        } else {
            pendingFragment = entry.fragment
            load(chapter: entry.spineIndex, at: 0, autoplay: autoplay)
        }
    }

    private func jump(toFragment id: String, autoplay: Bool) {
        let literal = String(data: try! JSONSerialization.data(withJSONObject: [id]), encoding: .utf8)!
        web.evaluateJavaScript("earmark.sentenceAfter(\(literal)[0])") { [weak self] result, _ in
            guard let self, let index = result as? Int else { return }
            self.engine?.stop()
            self.sentence = index
            self.highlight(word: nil)
            self.savePosition()
            if autoplay { self.playing = true; self.paused = false; self.updatePlayButton(); self.speakCurrent() }
        }
    }

    @objc private func voiceChosen() {
        let key = voiceMenu.selectedItem?.representedObject as? String
        if key == "edit-plugins" {
            _ = PluginConfig.load()
            NSWorkspace.shared.open(PluginConfig.file)
            rebuildVoiceMenu()
            return
        }
        voiceKey = key
        restartSentenceIfPlaying()
    }

    @objc private func speedChosen() {
        speed = speedMenu.selectedItem?.representedObject as? Double ?? 1
        restartSentenceIfPlaying()
    }

    func reloadPlugins() {
        plugins = PluginConfig.load()
        rebuildVoiceMenu()
    }

    // MARK: - Book

    func open(_ url: URL) {
        stopSpeaking()
        do {
            let book = try Book(file: url)
            self.book = book
            window?.title = book.title
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            defaults.set(url.path, forKey: "lastBook")
            rebuildChapterMenu()
            rebuildVoiceMenu()
            let saved = defaults.dictionary(forKey: "pos." + book.id) as? [String: Int]
            load(chapter: saved?["chapter"] ?? 0, at: saved?["sentence"] ?? 0, autoplay: false)
            status.stringValue = ""
        } catch {
            status.stringValue = error.localizedDescription
        }
    }

    private func load(chapter index: Int, at start: Int?, autoplay: Bool) {
        guard let book, book.spine.indices.contains(index) else { return }
        engine?.stop()
        chapter = index
        sentences = []
        pendingSentence = start
        playing = autoplay
        paused = false
        updatePlayButton()
        syncChapterMenu()
        web.loadFileURL(book.spine[index], allowingReadAccessTo: book.root)
    }

    private func savePosition() {
        guard let book else { return }
        defaults.set(["chapter": chapter, "sentence": sentence], forKey: "pos." + book.id)
    }

    // MARK: - Page messages

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            sentences = body["sentences"] as? [String] ?? []
            if sentences.isEmpty {
                if playing, let book, chapter + 1 < book.spine.count { load(chapter: chapter + 1, at: 0, autoplay: true) }
                return
            }
            let start = pendingSentence ?? 0
            sentence = start < 0 ? sentences.count - 1 : min(start, sentences.count - 1)
            pendingSentence = nil
            if let id = pendingFragment {
                pendingFragment = nil
                jump(toFragment: id, autoplay: playing)
                return
            }
            highlight(word: nil)
            syncChapterMenu()
            if playing { speakCurrent() }
        case "seek":
            guard let index = body["index"] as? Int else { return }
            sentence = index
            highlight(word: nil)
            savePosition()
            if playing && !paused { speakCurrent() }
        default:
            break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        if url.isFileURL, let index = book?.spineIndex(of: url) {
            load(chapter: index, at: 0, autoplay: playing && !paused)
        } else if url.scheme?.hasPrefix("http") == true {
            NSWorkspace.shared.open(url)
        }
    }

    private func highlight(word: NSRange?) {
        let w = word ?? NSRange(location: 0, length: 0)
        web.evaluateJavaScript("window.earmark && earmark.highlight(\(sentence), \(w.location), \(w.length))") { [weak self] _, _ in
            if let self, word != nil { Debug.logHighlight(self.web) }
        }
    }

    // MARK: - Playback

    private func makeEngine() -> SpeechEngine {
        if let engine { return engine }
        let key = voiceKey ?? ""
        let made: SpeechEngine
        if key.hasPrefix("plugin:"), let config = plugins.first(where: { "plugin:" + $0.name == key }) {
            made = PluginEngine(config: config)
        } else {
            made = SystemEngine(voiceIdentifier: String(key.dropFirst("system:".count)))
        }
        made.onWord = { [weak self] range in self?.highlight(word: range) }
        made.onFinish = { [weak self] in self?.advance() }
        made.onError = { [weak self] message in
            self?.status.stringValue = message
            self?.stopSpeaking()
        }
        engine = made
        return made
    }

    private func speakCurrent() {
        guard sentences.indices.contains(sentence) else { return }
        status.stringValue = ""
        let engine = makeEngine()
        highlight(word: nil)
        engine.speak(sentences[sentence], speed: speed)
        syncChapterMenu()
        if sentence + 1 < sentences.count { engine.prepare(sentences[sentence + 1], speed: speed) }
        savePosition()
    }

    private func advance() {
        guard playing, !paused else { return }
        if sentence + 1 < sentences.count {
            sentence += 1
            speakCurrent()
        } else if let book, chapter + 1 < book.spine.count {
            load(chapter: chapter + 1, at: 0, autoplay: true)
        } else {
            stopSpeaking()
        }
    }

    private func restartSentenceIfPlaying() {
        engine?.stop()
        engine = nil
        if playing && !paused { speakCurrent() }
    }

    private func stopSpeaking() {
        engine?.stop()
        playing = false
        paused = false
        updatePlayButton()
    }

    private func updatePlayButton() {
        let on = playing && !paused
        playButton.image = NSImage(systemSymbolName: on ? "pause.fill" : "play.fill", accessibilityDescription: on ? "Pause" : "Play")
    }

    @objc func togglePlay() {
        guard let book else { return }
        if sentences.isEmpty {
            // A page with nothing to read (a cover, an image): start from the next one.
            if chapter + 1 < book.spine.count { load(chapter: chapter + 1, at: 0, autoplay: true) }
            return
        }
        if playing && !paused {
            paused = true
            engine?.pause()
        } else if playing && paused {
            paused = false
            engine?.resume()
        } else {
            playing = true
            paused = false
            speakCurrent()
        }
        updatePlayButton()
    }

    @objc func nextSentence() { step(1) }
    @objc func previousSentence() { step(-1) }

    private func step(_ delta: Int) {
        let target = sentence + delta
        if sentences.indices.contains(target) {
            sentence = target
            highlight(word: nil)
            savePosition()
            if playing { paused = false; updatePlayButton(); speakCurrent() }
        } else if let book {
            let next = chapter + delta
            if book.spine.indices.contains(next) { load(chapter: next, at: delta > 0 ? 0 : -1, autoplay: playing) }
        }
    }

    @objc func nextChapter() { jumpChapter(1) }
    @objc func previousChapter() { jumpChapter(-1) }

    private func jumpChapter(_ delta: Int) {
        let current = chapterMenu.selectedItem?.tag ?? 0
        guard let toc = book?.toc, toc.indices.contains(current + delta) else { return }
        chapterMenu.selectItem(withTag: current + delta)
        chapterChosen()
    }

    @objc func faster() { nudgeSpeed(1) }
    @objc func slower() { nudgeSpeed(-1) }

    private func nudgeSpeed(_ delta: Int) {
        let i = max(0, min(Self.speeds.count - 1, speedMenu.indexOfSelectedItem + delta))
        speedMenu.selectItem(at: i)
        speedChosen()
    }

    func debugSnapshot(_ name: String) { Debug.snapshot(window, web, name: name) }

    func shutdown() {
        savePosition()
        engine?.stop()
    }
}
