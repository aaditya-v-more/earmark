import AppKit
import UniformTypeIdentifiers

/// The bundle's name, so a development build keeps its own settings and caches.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Earmark"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private lazy var reader = ReaderController()
    private lazy var settings = SettingsController()
    private lazy var tour = Tour { [weak self] in self?.reader.tourAnchors ?? [:] }

    @objc func showTutorial(_ sender: Any?) {
        reader.showWindow(nil)
        tour.start()
    }

    @objc func openHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/aaditya-v-more/earmark#reading")!)
    }

    @objc func showSettings(_ sender: Any?) {
        settings.showWindow(nil)
        settings.window?.makeKeyAndOrderFront(nil)
    }
    private var openedAtLaunch = false

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        Pasted.prune()
        reader.showWindow(nil)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Space plays and pauses, unless a menu or text field wants it.
            if event.charactersIgnoringModifiers == " ", event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
               !(NSApp.keyWindow?.firstResponder is NSText) {
                self?.reader.togglePlay()
                return nil
            }
            return event
        }
        if Debug.dir != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.reader.debugSnapshot("1-loaded"); self.reader.togglePlay() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.reader.debugSnapshot("2-playing") }
            if let text = ProcessInfo.processInfo.environment["EARMARK_DEBUG_FIND"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.reader.debugFind(text) }
            }
        }
        // The tour runs once, the first time Earmark opens; Help → Show Tutorial replays it.
        tour.onEnd = { UserDefaults.standard.set(true, forKey: "tourShown") }
        if let mode = ProcessInfo.processInfo.environment["EARMARK_DEBUG_TOUR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.tour.debugWalk(skip: mode == "skip") { FileHandle.standardError.write(Data(("tour " + $0 + "\n").utf8)) }
            }
        } else if !UserDefaults.standard.bool(forKey: "tourShown") && Debug.dir == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.tour.start() }
        }
        if !openedAtLaunch, let last = UserDefaults.standard.string(forKey: "lastBook"),
           FileManager.default.fileExists(atPath: last) {
            reader.open(URL(fileURLWithPath: last))
        } else if !openedAtLaunch {
            openDocument(nil)
        }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        openedAtLaunch = true
        reader.open(url)
        reader.showWindow(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ note: Notification) { reader.shutdown() }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Book.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.reader.open(url) }
        }
    }

    @objc func reloadPlugins(_ sender: Any?) { reader.reloadPlugins() }

    // Open Recent: filled from the system's recent documents each time it opens.
    private let recentMenu = NSMenu(title: "Open Recent")

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === bookmarksMenu { return fillBookmarks(menu) }
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs where FileManager.default.fileExists(atPath: url.path) {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.representedObject = url
            item.target = self
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if menu.items.isEmpty {
            let none = NSMenuItem(title: "No Recent Books", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)), keyEquivalent: "")
        clear.target = NSDocumentController.shared
        menu.addItem(clear)
    }

    // Bookmarks: the current book's, filled each time the menu opens.
    private let bookmarksMenu = NSMenu(title: "Bookmarks")

    private func fillBookmarks(_ menu: NSMenu) {
        menu.removeAllItems()
        let add = NSMenuItem(title: "Add Bookmark", action: #selector(ReaderController.addBookmark), keyEquivalent: "d")
        add.target = reader
        menu.addItem(add)
        menu.addItem(.separator())
        let marks = reader.bookmarks()
        for (i, b) in marks.enumerated() {
            let item = NSMenuItem(title: b.title, action: #selector(openBookmark(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            menu.addItem(item)
        }
        if marks.isEmpty {
            let none = NSMenuItem(title: "No Bookmarks", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            menu.addItem(.separator())
            let clear = NSMenuItem(title: "Clear Bookmarks for This Book", action: #selector(ReaderController.clearBookmarks), keyEquivalent: "")
            clear.target = reader
            menu.addItem(clear)
        }
    }

    @objc func openBookmark(_ sender: NSMenuItem) {
        let marks = reader.bookmarks()
        guard marks.indices.contains(sender.tag) else { return }
        reader.openBookmark(chapter: marks[sender.tag].chapter, sentence: marks[sender.tag].sentence)
    }

    @objc func openRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { reader.open(url) }
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(string: "Free and open source. If it gets you through a long series, ",
                                                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(string: "buy me a coffee on Ko-fi", attributes: [
            .font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://ko-fi.com/aadityavmore")!]))
        credits.append(NSAttributedString(string: ".", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centered, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    @objc func openKofi(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/aadityavmore")!)
    }

    private func sleepMenu(_ r: ReaderController) -> NSMenuItem {
        let holder = NSMenuItem(title: "Sleep Timer", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Sleep Timer")
        for (tag, title) in Prefs.sleepChoices {
            let i = NSMenuItem(title: title, action: #selector(ReaderController.sleepTimerChosen(_:)), keyEquivalent: "")
            i.tag = tag
            i.target = r
            menu.addItem(i)
        }
        holder.submenu = menu
        return holder
    }

    private func buildMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let holder = NSMenuItem()
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            holder.submenu = menu
            main.addItem(holder)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target
            return i
        }
        submenu(appName, [
            item("About \(appName)", #selector(showAbout(_:)), "", target: self),
            item("Support Earmark on Ko-fi…", #selector(openKofi(_:)), "", target: self),
            .separator(),
            item("Settings…", #selector(showSettings(_:)), ",", target: self),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        recentMenu.delegate = self
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        submenu("File", [
            item("Open…", #selector(openDocument(_:)), "o", target: self),
            recent,
            item("Open Web Page…", #selector(ReaderController.openWebPage), "l", target: reader),
            item("Read Clipboard", #selector(ReaderController.readClipboard), "v", [.command, .shift], target: reader),
            .separator(),
            item("Export Audio…", #selector(ReaderController.exportAudio), "e", [.command, .shift], target: reader),
            item("Stop Download or Export", #selector(ReaderController.stopTask), ".", target: reader),
            .separator(),
            item("Reload Settings", #selector(reloadPlugins(_:)), "r", target: self),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        let r = reader
        submenu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            item("Copy Sentence", #selector(ReaderController.copySentence), "c", [.command, .option], target: r),
            .separator(),
            item("Find…", #selector(ReaderController.showFind), "f", target: r),
        ])
        submenu("View", [
            item("Bigger Text", #selector(ReaderController.biggerText), "=", [.command, .option], target: r),
            item("Smaller Text", #selector(ReaderController.smallerText), "-", [.command, .option], target: r),
            item("Wider Column", #selector(ReaderController.widerColumn), "]", [.command, .option], target: r),
            item("Narrower Column", #selector(ReaderController.narrowerColumn), "[", [.command, .option], target: r),
            item("Actual Size", #selector(ReaderController.actualSize), "0", [.command, .option], target: r),
        ])
        submenu("Playback", [
            item("Play / Pause", #selector(ReaderController.togglePlay), "p", target: r),
            .separator(),
            item("Next Sentence", #selector(ReaderController.nextSentence), String(UnicodeScalar(NSRightArrowFunctionKey)!), target: r),
            item("Previous Sentence", #selector(ReaderController.previousSentence), String(UnicodeScalar(NSLeftArrowFunctionKey)!), target: r),
            item("Next Chapter", #selector(ReaderController.nextChapter), "]", target: r),
            item("Previous Chapter", #selector(ReaderController.previousChapter), "[", target: r),
            item("Go to Chapter…", #selector(ReaderController.goToChapter), "g", target: r),
            .separator(),
            item("Faster", #selector(ReaderController.faster), "=", target: r),
            item("Slower", #selector(ReaderController.slower), "-", target: r),
            .separator(),
            sleepMenu(r),
        ])
        bookmarksMenu.delegate = self
        fillBookmarks(bookmarksMenu)
        let marks = NSMenuItem(title: "Bookmarks", action: nil, keyEquivalent: "")
        marks.submenu = bookmarksMenu
        main.addItem(marks)
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
        ])
        submenu("Help", [
            item("Show Tutorial", #selector(showTutorial(_:)), "", target: self),
            item("\(appName) Help", #selector(openHelp(_:)), "?", target: self),
        ])
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
