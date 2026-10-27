import AppKit
import UniformTypeIdentifiers

/// The bundle's name, so a development build keeps its own settings and caches.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Earmark"

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private lazy var reader = ReaderController()
    private var openedAtLaunch = false

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
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
        for (title, tag) in [("Off", 0), ("15 Minutes", 15), ("30 Minutes", 30), ("45 Minutes", 45), ("1 Hour", 60), ("End of Chapter", -1)] {
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
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        recentMenu.delegate = self
        let recent = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        submenu("File", [
            item("Open…", #selector(openDocument(_:)), "o", target: self),
            recent,
            .separator(),
            item("Reload Settings", #selector(reloadPlugins(_:)), "r", target: self),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ])
        submenu("Edit", [
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ])
        let r = reader
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
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
        ])
        NSApp.mainMenu = main
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
