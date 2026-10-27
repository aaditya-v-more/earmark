import AppKit
import UniformTypeIdentifiers

/// The bundle's name, so a development build keeps its own settings and caches.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Earmark"

final class AppDelegate: NSObject, NSApplicationDelegate {
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
        panel.allowedContentTypes = [UTType(filenameExtension: "epub") ?? .data]
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.reader.open(url) }
        }
    }

    @objc func reloadPlugins(_ sender: Any?) { reader.reloadPlugins() }

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
            item("About \(appName)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide \(appName)", #selector(NSApplication.hide(_:)), "h"),
            item("Quit \(appName)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            item("Open…", #selector(openDocument(_:)), "o", target: self),
            .separator(),
            item("Reload Plugins", #selector(reloadPlugins(_:)), "r", target: self),
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
            .separator(),
            item("Faster", #selector(ReaderController.faster), "=", target: r),
            item("Slower", #selector(ReaderController.slower), "-", target: r),
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
