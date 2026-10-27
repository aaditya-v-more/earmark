import AppKit
import AVFoundation
import CoreAudio
import MediaPlayer

/// The single reading window: the book on top, a slim control bar below.
final class ReaderController: NSWindowController, NSSearchFieldDelegate {
    private let webSurface = WebSurface()
    private let pdfSurface = PDFSurface()
    private var surface: Surface
    private let page = NSView()
    private let chapterMenu = NSPopUpButton()
    private let voiceMenu = NSPopUpButton()
    private let speedMenu = NSPopUpButton()
    private let playButton = NSButton()
    private let status = NSTextField(labelWithString: "")
    private let findField = NSSearchField()
    private weak var titleLabel: NSTextField?

    private var book: Book?
    private var chapter = 0
    private var sentences: [String] = []
    private var skipped: Set<Int> = []
    private var sentence = 0
    private var pendingSentence: Int?
    private var pendingAnchor: String?
    private var pendingFragment: String?
    private var playing = false
    private var paused = false
    private var pausedAt: Date?
    private var engine: SpeechEngine?
    private var engineKey: String?
    /// Set while a plugin is unreachable and a system voice stands in for it.
    private var fallbackNote: String?
    private var plugins: [PluginConfig] = []
    private var pluginVoices: [String: [PluginVoice]] = [:]
    private var rules = TextRules.load()
    /// Maps the word range the voice reports back to the page, after pronunciation fixes.
    private var toPage: (NSRange) -> NSRange = { $0 }
    private var messageUntil = Date.distantPast
    private var lastManualScroll = Date.distantPast
    private var sleepTimer: DispatchWorkItem?
    private var sleepDeadline: Date?
    private var stopAtChapterEnd = false
    /// The gap before the next sentence (pause settings); paused mid-gap means "advance on resume".
    private var gap: DispatchWorkItem?
    private var advanceOnResume = false
    /// A web import or audio export running in the background, and its progress line.
    private var importer: WebImporter?
    private var exporter: AudioExporter?
    private var taskNote: String?
    /// A search to run once another chapter has loaded: (text, backwards).
    private var pendingFind: (String, Bool)?

    private let defaults = UserDefaults.standard
    private static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3, 3.5, 4]

    private var speed: Double {
        get { defaults.object(forKey: "speed") as? Double ?? 1 }
        set { defaults.set(newValue, forKey: "speed") }
    }

    private var textSize: Int {
        get { defaults.object(forKey: "textSize") as? Int ?? 19 }
        set { defaults.set(newValue, forKey: "textSize") }
    }

    private var columnWidth: Int {
        get { defaults.object(forKey: "columnWidth") as? Int ?? 36 }
        set { defaults.set(newValue, forKey: "columnWidth") }
    }

    private var voiceKey: String? {
        get { defaults.string(forKey: "voice") }
        set { defaults.set(newValue, forKey: "voice") }
    }

    init() {
        surface = webSurface
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 420, height: 320)
        window.title = appName
        // The title is drawn in the drag strip instead, so grabbing it moves the window.
        window.titleVisibility = .hidden
        super.init(window: window)
        for s in [webSurface, pdfSurface] as [Surface] {
            s.onReady = { [weak self] texts in self?.chapterReady(texts) }
            s.onSeek = { [weak self] chapter, index in self?.seek(chapter: chapter, sentence: index) }
        }
        webSurface.onLink = { [weak self] url in
            guard let self, let index = self.book?.spineIndex(of: url) else { return }
            self.load(chapter: index, at: 0, autoplay: self.playing && !self.paused)
        }
        buildLayout()
        window.setFrameAutosaveName("Reader")
        if !window.setFrameUsingName("Reader") { window.center() }
        reloadPlugins()
        rebuildSpeedMenu()
        setUpMediaKeys()
        watchOutputDevice()
        applyPrefs()
        NotificationCenter.default.addObserver(forName: Prefs.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyPrefs() }
        }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            // Reading back up: let the page stay where the reader put it for a few seconds.
            self?.lastManualScroll = Date()
            return event
        }
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
        // When space runs out, the status line gives way first, then the chapter title.
        chapterMenu.setContentCompressionResistancePriority(.init(240), for: .horizontal)
        voiceMenu.setContentCompressionResistancePriority(.init(260), for: .horizontal)
        voiceMenu.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        chapterMenu.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.init(100), for: .horizontal)

        let controls = NSStackView(views: [
            icon("backward.fill", "Previous sentence", #selector(previousSentence)),
            playButton,
            icon("forward.fill", "Next sentence", #selector(nextSentence)),
        ])
        controls.spacing = 14
        findField.placeholderString = "Find in book"
        findField.controlSize = .small
        findField.font = .systemFont(ofSize: 12)
        findField.delegate = self
        findField.sendsSearchStringImmediately = false
        findField.isHidden = true
        findField.target = self
        findField.action = #selector(findFieldReturned)
        findField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let bar = DragStack(views: [chapterMenu, status, findField, NSView(), controls, NSView(), voiceMenu, speedMenu])
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
        // An invisible strip along the top moves the window, where the title bar would be.
        let grip = DragStrip()
        grip.title.stringValue = appName
        titleLabel = grip.title
        // A blurred band behind the title, like the control bar, so text scrolls under it cleanly.
        let topBand = NSVisualEffectView()
        topBand.material = .titlebar

        for v in [page, effect, line, bar, grip, topBand] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        content.addSubview(page)
        content.addSubview(line)
        content.addSubview(effect)
        content.addSubview(topBand)
        content.addSubview(grip)
        NSLayoutConstraint.activate([
            page.topAnchor.constraint(equalTo: content.topAnchor),
            page.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: line.topAnchor),
            grip.topAnchor.constraint(equalTo: content.topAnchor),
            grip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 80),
            grip.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            grip.heightAnchor.constraint(equalToConstant: 28),
            topBand.topAnchor.constraint(equalTo: content.topAnchor),
            topBand.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBand.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topBand.heightAnchor.constraint(equalToConstant: 28),
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
        install(surface)
        addDonateButton()
    }

    /// A small Ko-fi link in the top-right corner of the title bar.
    private func addDonateButton() {
        let button = NSButton(title: " Donate", image: NSImage(systemSymbolName: "heart.fill", accessibilityDescription: nil)!,
                              target: NSApp.delegate, action: NSSelectorFromString("openKofi:"))
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.contentTintColor = NSColor(red: 1, green: 0.37, blue: 0.36, alpha: 1)
        button.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        button.toolTip = "Support Earmark on Ko-fi"
        button.sizeToFit()
        // Centred on the title bar's height, with the same right margin as the bar below.
        let barHeight = max(28, (window?.frame.height ?? 0) - (window?.contentLayoutRect.height ?? 0))
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: button.frame.width + 14, height: barHeight))
        button.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -14),
        ])
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = holder
        accessory.layoutAttribute = .trailing
        window?.addTitlebarAccessoryViewController(accessory)
    }

    private func install(_ new: Surface) {
        page.subviews.forEach { $0.removeFromSuperview() }
        let v = new.view
        v.translatesAutoresizingMaskIntoConstraints = false
        page.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: page.topAnchor),
            v.bottomAnchor.constraint(equalTo: page.bottomAnchor),
            v.leadingAnchor.constraint(equalTo: page.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: page.trailingAnchor),
        ])
        surface = new
    }

    // MARK: - Status line

    /// Shows a message for a few seconds, then progress again.
    private func say(_ message: String) {
        status.stringValue = message
        messageUntil = Date().addingTimeInterval(5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.1) { [weak self] in self?.showProgress() }
    }

    private func showProgress() {
        guard Date() >= messageUntil, let book else { return }
        var parts: [String] = []
        let total = book.chapterCount
        let unit = book.pdf != nil ? "p." : "ch."
        parts.append("\(unit) \(chapter + 1)/\(total)")
        let within = sentences.isEmpty ? 0 : Double(sentence) / Double(sentences.count)
        parts.append("\(Int(((Double(chapter) + within) / Double(max(total, 1)) * 100).rounded()))%")
        if let fallbackNote { parts.append(fallbackNote) }
        if let taskNote { parts.append(taskNote) }
        if stopAtChapterEnd { parts.append("stops at chapter end") }
        if let sleepDeadline { parts.append("sleep in \(max(1, Int(sleepDeadline.timeIntervalSinceNow / 60)))m") }
        status.stringValue = parts.joined(separator: " · ")
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
        let lang = String((book?.language ?? Locale.current.language.languageCode?.identifier ?? "en").prefix(2)).lowercased()
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(lang) || "system:" + $0.identifier == voiceKey }
            .sorted { $0.quality.rawValue != $1.quality.rawValue ? $0.quality.rawValue > $1.quality.rawValue : $0.name < $1.name }
        func add(_ title: String, _ key: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = key
            menu.addItem(item)
        }
        for p in plugins {
            menu.addItem(.sectionHeader(title: p.name))
            guard p.voices != nil else { add(p.name, "plugin:" + p.name); continue }
            let prefix = "plugin:" + p.name + "|"
            // The book's language, plus the chosen voice even if it speaks another one.
            let listed = (pluginVoices[p.name] ?? []).filter {
                ($0.language ?? lang).lowercased().hasPrefix(lang) || prefix + $0.id == voiceKey
            }
            for v in listed {
                let detail = [v.language, v.gender].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                add(detail.isEmpty ? v.name : "\(v.name) — \(detail)", prefix + v.id)
            }
            // Keep the chosen voice on the menu while the list is still loading.
            if let key = voiceKey, key.hasPrefix(prefix), pluginVoices[p.name] == nil {
                add(String(key.dropFirst(prefix.count)).components(separatedBy: "/").last ?? key, key)
            }
            if pluginVoices[p.name]?.isEmpty ?? true, !(voiceKey?.hasPrefix(prefix) ?? false) {
                let off = NSMenuItem(title: pluginVoices[p.name] == nil ? "Not running" : "No voices", action: nil, keyEquivalent: "")
                off.isEnabled = false
                menu.addItem(off)
            }
        }
        menu.addItem(.sectionHeader(title: "System voices"))
        for v in voices { add("\(v.name) — \(v.language)", "system:" + v.identifier) }
        menu.addItem(.separator())
        for (title, key) in [("Edit Plugins…", "edit-plugins"), ("Edit Skipped Lines…", "edit-skip"),
                             ("Edit Pronunciations…", "edit-replacements")] {
            add(title, key)
        }
        voiceMenu.menu = menu
        let selectable = menu.items.filter { ($0.representedObject as? String)?.contains(":") == true }
        let chosen = selectable.first { $0.representedObject as? String == voiceKey } ?? selectable.first { ($0.representedObject as? String)?.hasPrefix("system:") == true }
        voiceMenu.autoenablesItems = false
        if let chosen { voiceMenu.select(chosen) }
        // The engine follows the menu; the saved choice changes only when the reader picks a voice.
        if engine != nil && fallbackNote == nil && currentVoiceKey != engineKey { restartSentenceIfPlaying() }
    }

    private var currentVoiceKey: String? { voiceMenu.selectedItem?.representedObject as? String }

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
        defer { showProgress(); updateNowPlaying() }
        guard let toc = book?.toc, !toc.isEmpty else { return }
        let here = toc.indices.filter { toc[$0].spineIndex == chapter }
        guard let first = here.first else {
            if let before = toc.indices.last(where: { toc[$0].spineIndex < chapter }) { chapterMenu.selectItem(withTag: before) }
            return
        }
        chapterMenu.selectItem(withTag: first)
        let ids = here.compactMap { toc[$0].fragment }
        guard here.count > 1, ids.count == here.count, !sentences.isEmpty, surface === webSurface else { return }
        webSurface.section(ids) { [weak self] i in
            if let i { self?.chapterMenu.selectItem(withTag: here[i]); self?.updateNowPlaying() }
        }
    }

    @objc private func chapterChosen() {
        guard let toc = book?.toc, let tag = chapterMenu.selectedItem?.tag, toc.indices.contains(tag) else { return }
        go(toTocEntry: tag)
    }

    private func go(toTocEntry tag: Int) {
        guard let toc = book?.toc, toc.indices.contains(tag) else { return }
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
        webSurface.sentence(after: id) { [weak self] index in
            guard let self else { return }
            self.engine?.stop()
            self.sentence = self.firstReadable(from: index)
            self.highlight(word: nil)
            self.savePosition()
            if autoplay { self.playing = true; self.paused = false; self.updatePlayButton(); self.speakCurrent() }
        }
    }

    @objc private func voiceChosen() {
        let key = voiceMenu.selectedItem?.representedObject as? String
        let files = ["edit-plugins": PluginConfig.file, "edit-skip": TextRules.skipFile, "edit-replacements": TextRules.replacementsFile]
        if let key, let file = files[key] {
            _ = PluginConfig.load()
            rules = TextRules.load()
            NSWorkspace.shared.open(file)
            rebuildVoiceMenu()
            return
        }
        voiceKey = key
        fallbackNote = nil
        restartSentenceIfPlaying()
    }

    @objc private func speedChosen() {
        speed = speedMenu.selectedItem?.representedObject as? Double ?? 1
        restartSentenceIfPlaying()
    }

    /// Reloads plugins, skipped lines and pronunciations from their files.
    func reloadPlugins() {
        plugins = PluginConfig.load()
        rules = TextRules.load()
        pluginVoices = [:]
        fallbackNote = nil
        if !sentences.isEmpty { skipped = Set(sentences.indices.filter { rules.shouldSkip(sentences[$0]) }) }
        rebuildVoiceMenu()
        for p in plugins where p.voices != nil {
            Task { @MainActor in
                if let list = await PluginVoice.fetch(p) { self.pluginVoices[p.name] = list }
                else { self.pluginVoices[p.name] = nil }
                self.rebuildVoiceMenu()
            }
        }
    }

    // MARK: - Book

    func open(_ url: URL) {
        stopSpeaking()
        do {
            let book = try Book(file: url)
            self.book = book
            window?.title = book.title
            titleLabel?.stringValue = book.title
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            defaults.set(url.path, forKey: "lastBook")
            install(book.pdf != nil ? pdfSurface : webSurface)
            rebuildChapterMenu()
            rebuildVoiceMenu()
            // Positions are kept by a stable id now; older versions keyed them by file.
            let saved = defaults.dictionary(forKey: "pos." + book.positionID) ?? defaults.dictionary(forKey: "pos." + book.id)
            pendingAnchor = saved?["text"] as? String
            load(chapter: saved?["chapter"] as? Int ?? 0, at: saved?["sentence"] as? Int ?? 0, autoplay: false)
        } catch {
            say(error.localizedDescription)
        }
    }

    private func load(chapter index: Int, at start: Int?, autoplay: Bool) {
        guard let book, (0..<book.chapterCount).contains(index) else { return }
        cancelGap()
        engine?.stop()
        chapter = index
        sentences = []
        pendingSentence = start
        playing = autoplay
        paused = false
        updatePlayButton()
        syncChapterMenu()
        surface.show(book, chapter: index)
    }

    private func savePosition() {
        guard let book else { return }
        var pos: [String: Any] = ["chapter": chapter, "sentence": sentence]
        if sentences.indices.contains(sentence) { pos["text"] = String(sentences[sentence].prefix(40)) }
        defaults.set(pos, forKey: "pos." + book.positionID)
    }

    private func chapterReady(_ texts: [String]) {
        sentences = texts
        skipped = Set(texts.indices.filter { rules.shouldSkip(texts[$0]) })
        let readable = sentences.indices.filter { !skipped.contains($0) }
        if readable.isEmpty {
            // A cover, an image, or only skipped lines: go on if playing.
            if playing, let book, chapter + 1 < book.chapterCount { load(chapter: chapter + 1, at: 0, autoplay: true) }
            return
        }
        var start = pendingSentence ?? 0
        start = start < 0 ? sentences.count - 1 : min(start, sentences.count - 1)
        // If the saved sentence's text has moved a little (new splitting rules), find it again.
        if let anchor = pendingAnchor, !anchor.isEmpty, !sentences[start].hasPrefix(anchor) {
            let window = max(0, start - 10)...min(sentences.count - 1, start + 10)
            if let found = window.first(where: { sentences[$0].hasPrefix(anchor) }) { start = found }
        }
        pendingAnchor = nil
        sentence = firstReadable(from: start)
        pendingSentence = nil
        if let id = pendingFragment, surface === webSurface {
            pendingFragment = nil
            jump(toFragment: id, autoplay: playing)
            return
        }
        pendingFragment = nil
        highlight(word: nil)
        syncChapterMenu()
        if playing { speakCurrent() }
        if let (text, backwards) = pendingFind {
            pendingFind = nil
            webSurface.find(text, backwards: backwards, wraps: false) { _ in }
        }
    }

    private func seek(chapter target: Int, sentence index: Int) {
        cancelGap()
        if target != chapter {
            load(chapter: target, at: index, autoplay: playing && !paused)
            return
        }
        engine?.stop()
        sentence = index
        highlight(word: nil)
        savePosition()
        showProgress()
        if playing && !paused { speakCurrent() }
    }

    private func firstReadable(from index: Int, step: Int = 1) -> Int {
        var i = index
        while sentences.indices.contains(i) && skipped.contains(i) { i += step }
        return sentences.indices.contains(i) ? i : index
    }

    private func highlight(word: NSRange?) {
        let follow = Date().timeIntervalSince(lastManualScroll) > 4
        surface.highlight(sentence: sentence, word: word.map(toPage), follow: follow)
    }

    // MARK: - Playback

    private func makeEngine() -> SpeechEngine {
        if let engine { return engine }
        let key = currentVoiceKey ?? ""
        let made: SpeechEngine
        if key.hasPrefix("plugin:") {
            let rest = key.dropFirst("plugin:".count)
            let parts = rest.split(separator: "|", maxSplits: 1).map(String.init)
            if let config = plugins.first(where: { $0.name == parts[0] }) {
                made = PluginEngine(config: config, voice: parts.count > 1 ? parts[1] : nil)
            } else {
                made = SystemEngine(voiceIdentifier: "")
            }
        } else {
            made = SystemEngine(voiceIdentifier: String(key.dropFirst("system:".count)))
        }
        engineKey = key
        wire(made)
        return made
    }

    private func wire(_ made: SpeechEngine) {
        made.onWord = { [weak self] range in self?.highlight(word: range) }
        made.onFinish = { [weak self] in self?.advance() }
        made.onStatus = { [weak self] message in self?.say(message) }
        made.onError = { [weak self] message in self?.engineFailed(message) }
        engine = made
    }

    /// A plugin voice failed (its server is down): carry on with a system voice for now.
    private func engineFailed(_ message: String) {
        guard engine is PluginEngine, fallbackNote == nil else {
            say(message)
            stopSpeaking()
            return
        }
        let lang = String((book?.language ?? "en").prefix(2)).lowercased()
        let voice = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(lang) }
            .max { $0.quality.rawValue < $1.quality.rawValue }
        let pluginName = currentVoiceKey?.dropFirst("plugin:".count).split(separator: "|").first.map(String.init) ?? "Plugin"
        fallbackNote = "\(pluginName) not running, using \(voice?.name ?? "system voice")"
        say(message)
        wire(SystemEngine(voiceIdentifier: voice?.identifier ?? ""))
        if playing && !paused { speakCurrent() }
    }

    private func speakCurrent() {
        guard sentences.indices.contains(sentence) else { return }
        let engine = makeEngine()
        highlight(word: nil)
        let spoken = rules.spoken(sentences[sentence])
        toPage = spoken.toPage
        engine.speak(spoken.text, speed: speed)
        syncChapterMenu()
        prepareAhead(engine)
        savePosition()
    }

    /// Asks the voice for the next two sentences now, including the next chapter's first ones.
    private func prepareAhead(_ engine: SpeechEngine) {
        var ahead: [String] = []
        var i = sentence + 1
        while ahead.count < 2 && i < sentences.count {
            if !skipped.contains(i) { ahead.append(sentences[i]) }
            i += 1
        }
        for s in ahead { engine.prepare(rules.spoken(s).text, speed: speed) }
        guard ahead.count < 2, let book, chapter + 1 < book.chapterCount, !stopAtChapterEnd else { return }
        let speed = speed, rules = rules
        surface.upcoming(book, chapter: chapter + 1, count: 4) { [weak engine] texts in
            for s in texts.filter({ !rules.shouldSkip($0) }).prefix(2 - ahead.count) {
                engine?.prepare(rules.spoken(s).text, speed: speed)
            }
        }
    }

    private func advance() {
        guard playing, !paused else { return }
        var next = sentence + 1
        while next < sentences.count && skipped.contains(next) { next += 1 }
        let ms = next < sentences.count
            ? (surface.paragraphEnds.contains(sentence) ? Prefs.pauseParagraph : Prefs.pauseSentence)
            : Prefs.pauseChapter
        guard ms > 0 else { return advanceNow() }
        let work = DispatchWorkItem { [weak self] in
            self?.gap = nil
            self?.advanceNow()
        }
        gap = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ms), execute: work)
    }

    private func cancelGap() {
        gap?.cancel()
        gap = nil
        advanceOnResume = false
    }

    private func advanceNow() {
        guard playing, !paused else { return }
        var next = sentence + 1
        while next < sentences.count && skipped.contains(next) { next += 1 }
        if next < sentences.count {
            sentence = next
            speakCurrent()
        } else if stopAtChapterEnd {
            stopAtChapterEnd = false
            stopSpeaking()
            if let book, chapter + 1 < book.chapterCount { load(chapter: chapter + 1, at: 0, autoplay: false) }
        } else if let book, chapter + 1 < book.chapterCount {
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
        cancelGap()
        engine?.stop()
        playing = false
        paused = false
        cancelSleepTimer()
        updatePlayButton()
    }

    private func updatePlayButton() {
        let on = playing && !paused
        playButton.image = NSImage(systemSymbolName: on ? "pause.fill" : "play.fill", accessibilityDescription: on ? "Pause" : "Play")
        MPNowPlayingInfoCenter.default().playbackState = on ? .playing : (playing ? .paused : .stopped)
    }

    @objc func togglePlay() {
        guard let book else { return }
        if sentences.indices.allSatisfy({ skipped.contains($0) }) {
            // Nothing to read here (a cover, an image): start from the next page.
            if chapter + 1 < book.chapterCount { load(chapter: chapter + 1, at: 0, autoplay: true) }
            return
        }
        if playing && !paused {
            paused = true
            pausedAt = Date()
            if gap != nil {
                // Paused between sentences: pick up with the next one on resume.
                gap?.cancel()
                gap = nil
                advanceOnResume = true
            }
            engine?.pause()
        } else if playing && paused {
            paused = false
            if advanceOnResume {
                advanceOnResume = false
                advanceNow()
            } else if let pausedAt, Date().timeIntervalSince(pausedAt) > 30 {
                // After a long break, start the sentence again rather than mid-word.
                speakCurrent()
            } else {
                engine?.resume()
            }
        } else {
            playing = true
            paused = false
            guard Prefs.startFromVisible else { speakCurrent(); return updatePlayButton() }
            // Start where the reader is looking if the last sentence has scrolled out of view.
            surface.visibleStart(current: sentence) { [weak self] start, shown in
                guard let self, self.playing else { return }
                if !shown, let start {
                    if start.chapter != self.chapter { return self.load(chapter: start.chapter, at: start.sentence, autoplay: true) }
                    self.sentence = self.firstReadable(from: start.sentence)
                }
                self.speakCurrent()
            }
        }
        updatePlayButton()
    }

    @objc func nextSentence() { step(1) }
    @objc func previousSentence() { step(-1) }

    private func step(_ delta: Int) {
        cancelGap()
        // Settings → Jump by: how many sentences one step moves.
        var target = sentence
        for _ in 0..<Prefs.jump {
            var t = target + delta
            while sentences.indices.contains(t) && skipped.contains(t) { t += delta }
            guard sentences.indices.contains(t) else { break }
            target = t
        }
        if target != sentence {
            engine?.stop()
            sentence = target
            highlight(word: nil)
            savePosition()
            showProgress()
            if playing { paused = false; updatePlayButton(); speakCurrent() }
        } else if let book {
            let next = chapter + delta
            if (0..<book.chapterCount).contains(next) { load(chapter: next, at: delta > 0 ? 0 : -1, autoplay: playing) }
        }
    }

    @objc func nextChapter() { jumpChapter(1) }
    @objc func previousChapter() { jumpChapter(-1) }

    private func jumpChapter(_ delta: Int) {
        let current = chapterMenu.selectedItem?.tag ?? 0
        guard let toc = book?.toc, toc.indices.contains(current + delta) else { return }
        chapterMenu.selectItem(withTag: current + delta)
        go(toTocEntry: current + delta)
    }

    /// Asks for a chapter number (or a page number in a PDF) and goes there.
    @objc func goToChapter() {
        guard let book, let window else { return }
        let alert = NSAlert()
        alert.messageText = book.pdf != nil ? "Go to Page" : "Go to Chapter"
        alert.informativeText = book.pdf != nil ? "Page number, 1 to \(book.chapterCount)." : "Chapter number, or words from its title."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let query = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !query.isEmpty else { return }
            if book.pdf != nil, let n = Int(query) {
                self.load(chapter: max(0, min(book.chapterCount - 1, n - 1)), at: 0, autoplay: self.playing && !self.paused)
                return
            }
            let toc = book.toc
            let match: Int?
            if let n = Int(query) {
                let number = try? NSRegularExpression(pattern: "(?<![0-9])\(n)(?![0-9])")
                match = toc.indices.first { i in
                    number?.firstMatch(in: toc[i].title, range: NSRange(toc[i].title.startIndex..., in: toc[i].title)) != nil
                } ?? (toc.indices.contains(n - 1) ? n - 1 : nil)
            } else {
                match = toc.indices.first { toc[$0].title.localizedCaseInsensitiveContains(query) }
            }
            if let match {
                self.chapterMenu.selectItem(withTag: match)
                self.go(toTocEntry: match)
            } else {
                self.say("No chapter matches “\(query)”")
            }
        }
    }

    @objc func faster() { nudgeSpeed(1) }
    @objc func slower() { nudgeSpeed(-1) }

    private func nudgeSpeed(_ delta: Int) {
        let i = max(0, min(Self.speeds.count - 1, speedMenu.indexOfSelectedItem + delta))
        speedMenu.selectItem(at: i)
        speedChosen()
    }

    // MARK: - Sleep timer

    @objc func sleepTimerChosen(_ sender: NSMenuItem) {
        cancelSleepTimer()
        stopAtChapterEnd = false
        if sender.tag == -1 {
            stopAtChapterEnd = true
        } else if sender.tag > 0 {
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.playing, !self.paused else { return }
                self.togglePlay()
                self.sleepDeadline = nil
                self.showProgress()
            }
            sleepTimer = work
            sleepDeadline = Date().addingTimeInterval(TimeInterval(sender.tag * 60))
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(sender.tag * 60), execute: work)
            // Keep the minutes left on the status line current.
            Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] timer in
                guard let self, self.sleepDeadline != nil else { return timer.invalidate() }
                self.showProgress()
            }
        }
        showProgress()
    }

    private func cancelSleepTimer() {
        sleepTimer?.cancel()
        sleepTimer = nil
        sleepDeadline = nil
    }

    // MARK: - Settings

    private func applyPrefs() {
        webSurface.setLayout(size: textSize, width: columnWidth)
        let appearance: NSAppearance.Name? = ["light": .aqua, "sepia": .aqua, "dark": .darkAqua][Prefs.theme]
        window?.appearance = appearance.flatMap(NSAppearance.init(named:))
    }

    @objc func copySentence() {
        guard sentences.indices.contains(sentence) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sentences[sentence], forType: .string)
        say("Sentence copied")
    }

    // MARK: - Text size and column width

    @objc func biggerText() { setText(size: textSize + 2) }
    @objc func smallerText() { setText(size: textSize - 2) }
    @objc func widerColumn() { setText(width: columnWidth + 4) }
    @objc func narrowerColumn() { setText(width: columnWidth - 4) }

    @objc func actualSize() {
        if surface === pdfSurface { return pdfSurface.zoom(0) }
        setText(size: 19, width: 36)
    }

    private func setText(size: Int? = nil, width: Int? = nil) {
        if surface === pdfSurface {
            // A PDF's layout is fixed: size zooms it instead.
            if let size { pdfSurface.zoom(size > textSize ? 1 : -1) }
            return
        }
        textSize = min(max(size ?? textSize, 13), 40)
        columnWidth = min(max(width ?? columnWidth, 20), 80)
        webSurface.setLayout(size: textSize, width: columnWidth)
    }

    // MARK: - Find

    @objc func showFind() {
        findField.isHidden = false
        status.isHidden = true
        window?.makeFirstResponder(findField)
    }

    private func hideFind() {
        findField.isHidden = true
        status.isHidden = false
        window?.makeFirstResponder(surface.view)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return finds the next match, Shift-Return the previous one.
            find(backwards: NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hideFind()
            return true
        default:
            return false
        }
    }

    @objc private func findFieldReturned() { find(backwards: false) }

    func debugFind(_ text: String) {
        findField.stringValue = text
        showFind()
        find(backwards: false)
    }

    private func find(backwards: Bool) {
        let text = findField.stringValue
        guard !text.isEmpty else { return }
        if surface === pdfSurface {
            if !pdfSurface.find(text, backwards: backwards) { NSSound.beep() }
            return
        }
        // This chapter first; past its last match, go on to the next chapter that has one.
        webSurface.find(text, backwards: backwards, wraps: false) { [weak self] found in
            guard let self, !found, let book = self.book else { return }
            let n = book.chapterCount
            let order = (1..<max(n, 1)).map { backwards ? (self.chapter - $0 + n) % n : (self.chapter + $0) % n }
            guard let target = order.first(where: { Self.chapter(book, $0, contains: text) }) else {
                // Only this chapter has it (or nothing does): wrap around within it.
                return self.webSurface.find(text, backwards: backwards) { found in if !found { NSSound.beep() } }
            }
            if self.playing && !self.paused { self.togglePlay() }
            self.pendingFind = (text, backwards)
            self.load(chapter: target, at: 0, autoplay: false)
        }
    }

    private static func chapter(_ book: Book, _ index: Int, contains text: String) -> Bool {
        guard book.spine.indices.contains(index),
              let markup = try? String(contentsOf: book.spine[index], encoding: .utf8) else { return false }
        let plain = markup.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return plain.range(of: text, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    // MARK: - Clipboard, web pages and audio export

    /// Opens what's on the clipboard: a link as a web page, text as a saved, temporary book.
    @objc func readClipboard() {
        let board = NSPasteboard.general
        let string = board.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let url = URL(string: string), url.scheme?.hasPrefix("http") == true, !string.contains(" ") {
            return importWeb(url, follow: false, limit: 1, folder: Pasted.folder)
        }
        if let file = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])?.first as? URL {
            return open(file)
        }
        guard !string.isEmpty else { return say("The clipboard has no text") }
        Pasted.prune()
        do { open(try Pasted.save(string)) } catch { say(error.localizedDescription) }
    }

    @objc func openWebPage() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Open Web Page"
        alert.informativeText = "Paste a chapter's address. Earmark saves the text as a book in Documents/Earmark."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "https://"
        if let s = NSPasteboard.general.string(forType: .string), s.hasPrefix("http") { field.stringValue = s }
        let follow = NSButton(checkboxWithTitle: "Follow “Next” links, up to \(Prefs.webChapterLimit) chapters", target: nil, action: nil)
        follow.state = .on
        let stack = NSStackView(views: [field, follow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 54)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            guard let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
                return self.say("That isn’t a web address")
            }
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(appName)
            self.importWeb(url, follow: follow.state == .on, limit: follow.state == .on ? Prefs.webChapterLimit : 1, folder: folder)
        }
    }

    private func importWeb(_ url: URL, follow: Bool, limit: Int, folder: URL) {
        guard importer == nil else { return say("Already downloading; Stop (⌘.) first") }
        let job = WebImporter()
        importer = job
        job.onProgress = { [weak self] note in
            DispatchQueue.main.async { self?.taskNote = note + " · ⌘. stops"; self?.showProgress() }
        }
        Task { @MainActor in
            defer { self.importer = nil; self.taskNote = nil; self.showProgress() }
            do {
                let file = try await job.run(from: url, follow: follow, limit: limit, into: folder)
                self.open(file)
            } catch {
                self.say(error.localizedDescription)
            }
        }
    }

    @objc func exportAudio() {
        guard let book, let window, exporter == nil else { return }
        let titles = (0..<book.chapterCount).map { i in book.toc.last { $0.spineIndex <= i }?.title ?? "Chapter \(i + 1)" }
        let from = NSPopUpButton(), to = NSPopUpButton()
        for p in [from, to] {
            for (i, t) in titles.enumerated() { p.addItem(withTitle: "\(i + 1). \(t)"); p.lastItem?.tag = i }
            p.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        from.selectItem(withTag: chapter)
        to.selectItem(withTag: chapter)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "From:"), from], [NSTextField(labelWithString: "To:"), to]])
        grid.frame = NSRect(x: 0, y: 0, width: 360, height: 60)
        let alert = NSAlert()
        alert.messageText = "Export Audio"
        alert.informativeText = "Saves each chapter as an M4A file, with the current voice, speed, pronunciations and pauses."
        alert.accessoryView = grid
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let first = min(from.selectedTag(), to.selectedTag()), last = max(from.selectedTag(), to.selectedTag())
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Export Here"
            panel.directoryURL = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            panel.beginSheetModal(for: window) { result in
                guard result == .OK, let folder = panel.url else { return }
                self.runExport(book: book, titles: titles, chapters: Array(first...last), folder: folder)
            }
        }
    }

    private func runExport(book: Book, titles: [String], chapters: [Int], folder: URL) {
        let key = currentVoiceKey ?? ""
        let voice: AudioExporter.Voice
        if key.hasPrefix("plugin:") {
            let parts = key.dropFirst("plugin:".count).split(separator: "|", maxSplits: 1).map(String.init)
            guard let config = plugins.first(where: { $0.name == parts[0] }) else { return say("Choose a voice first") }
            voice = .plugin(config, parts.count > 1 ? parts[1] : nil)
        } else {
            voice = .system(String(key.dropFirst("system:".count)))
        }
        let job = AudioExporter()
        exporter = job
        job.onProgress = { [weak self] note in
            DispatchQueue.main.async { self?.taskNote = note + " · ⌘. stops"; self?.showProgress() }
        }
        let surface = surface
        Task { @MainActor in
            defer { self.exporter = nil; self.taskNote = nil; self.showProgress() }
            do {
                let count = try await job.run(.init(titles: titles, speed: self.speed, voice: voice, rules: self.rules),
                                              chapters: chapters, folder: folder) { i in
                    await withCheckedContinuation { done in
                        DispatchQueue.main.async { surface.allSentences(book, chapter: i) { done.resume(returning: $0) } }
                    }
                }
                self.say(job.cancelled ? "Export stopped after \(count) file\(count == 1 ? "" : "s")" : "Exported \(count) file\(count == 1 ? "" : "s")")
                if count > 0 { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            } catch {
                self.say("Export failed: \(error.localizedDescription)")
            }
        }
    }

    /// Stops a running download or export; what's done so far is kept.
    @objc func stopTask() {
        importer?.cancel()
        exporter?.cancel()
    }

    // MARK: - Bookmarks

    private var bookmarkKey: String? { book.map { "bookmarks." + $0.positionID } }

    /// This book's bookmarks, newest first: title, chapter, sentence.
    func bookmarks() -> [(title: String, chapter: Int, sentence: Int)] {
        guard let key = bookmarkKey, let list = defaults.array(forKey: key) as? [[String: Any]] else { return [] }
        return list.compactMap { b in
            guard let c = b["chapter"] as? Int, let s = b["sentence"] as? Int else { return nil }
            return (b["title"] as? String ?? "Bookmark", c, s)
        }
    }

    @objc func addBookmark() {
        guard let key = bookmarkKey, sentences.indices.contains(sentence) else { return }
        let place = chapterMenu.selectedItem?.title ?? "\(chapter + 1)"
        let snippet = sentences[sentence].prefix(50)
        var list = defaults.array(forKey: key) as? [[String: Any]] ?? []
        let title = snippet.hasPrefix(place) || place.hasPrefix(snippet) ? String(snippet) : "\(place): \(snippet)…"
        list.insert(["title": title, "chapter": chapter, "sentence": sentence], at: 0)
        defaults.set(Array(list.prefix(50)), forKey: key)
        say("Bookmarked")
    }

    func openBookmark(chapter target: Int, sentence index: Int) {
        seek(chapter: target, sentence: index)
    }

    @objc func clearBookmarks() {
        if let key = bookmarkKey { defaults.removeObject(forKey: key) }
    }

    // MARK: - Headphones

    /// Pauses when the sound would switch to the built-in speakers, as when headphones are unplugged.
    private func watchOutputDevice() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            guard let self, self.playing, !self.paused, Self.outputIsBuiltIn() else { return }
            self.togglePlay()
            self.say("Paused: headphones disconnected")
        }
    }

    private static func outputIsBuiltIn() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return false }
        var transport = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyTransportType
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBuiltIn
    }

    // MARK: - Media keys and Now Playing

    private func setUpMediaKeys() {
        let center = MPRemoteCommandCenter.shared()
        center.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlay(); return .success }
        center.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if !(self.playing && !self.paused) { self.togglePlay() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            if self.playing && !self.paused { self.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in self?.nextSentence(); return .success }
        center.previousTrackCommand.addTarget { [weak self] _ in self?.previousSentence(); return .success }
    }

    private func updateNowPlaying() {
        guard let book else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: chapterMenu.selectedItem?.title ?? book.title,
            MPMediaItemPropertyArtist: book.title,
        ]
    }

    func debugSnapshot(_ name: String) {
        if surface === webSurface { Debug.snapshot(window, webSurface.web, name: name) }
    }

    func shutdown() {
        savePosition()
        engine?.stop()
    }
}

/// The control bar: clicks on its empty parts move the window.
private final class DragStack: NSStackView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// A transparent strip that moves the window (and zooms it on double-click) instead of selecting text.
private final class DragStrip: NSView {
    let title = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(title)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -90),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    // The title is part of the strip: clicks on it move the window too.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.performZoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
