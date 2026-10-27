import AppKit

/// Reader options kept in UserDefaults. Every default matches how Earmark behaves without them.
enum Prefs {
    static let changed = Notification.Name("EarmarkSettingsChanged")
    private static var d: UserDefaults { .standard }

    static var theme: String { d.string(forKey: "theme") ?? "system" }
    static var font: String { d.string(forKey: "font") ?? "default" }
    static var lineSpacing: Double { d.object(forKey: "lineSpacing") as? Double ?? 1.65 }
    static var startFromVisible: Bool { d.bool(forKey: "startFromVisible") }
    static var jump: Int { max(1, d.object(forKey: "jump") as? Int ?? 1) }
    static var pauseSentence: Int { d.integer(forKey: "pauseSentence") }
    static var pauseParagraph: Int { d.integer(forKey: "pauseParagraph") }
    static var pauseChapter: Int { d.integer(forKey: "pauseChapter") }
    static var pasteDays: Int { max(1, d.object(forKey: "pasteDays") as? Int ?? 30) }
    static var webChapterLimit: Int { max(1, d.object(forKey: "webChapterLimit") as? Int ?? 100) }

    static let themes = [("system", "Match System"), ("light", "Light"), ("sepia", "Sepia"), ("dark", "Dark")]
    static let fonts: [(String, String, String)] = [
        ("default", "Iowan Old Style", "\"Iowan Old Style\", Palatino, Georgia, serif"),
        ("georgia", "Georgia", "Georgia, serif"),
        ("palatino", "Palatino", "Palatino, serif"),
        ("charter", "Charter", "Charter, Georgia, serif"),
        ("newyork", "New York", "ui-serif, Georgia, serif"),
        ("system", "San Francisco", "system-ui, -apple-system, sans-serif"),
        ("avenir", "Avenir Next", "\"Avenir Next\", Avenir, sans-serif"),
        ("helvetica", "Helvetica Neue", "\"Helvetica Neue\", Helvetica, sans-serif"),
        ("rounded", "SF Rounded", "ui-rounded, system-ui, sans-serif"),
    ]

    static var fontStack: String { fonts.first { $0.0 == font }?.2 ?? fonts[0].2 }
}

/// One small window of options, grouped as Reading, Playback and Sources.
final class SettingsController: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        super.init(window: window)
        build()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError() }

    private let d = UserDefaults.standard

    private func build() {
        guard let content = window?.contentView else { return }
        var rows: [[NSView]] = []
        func header(_ title: String) {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            rows.append([label, NSGridCell.emptyContentView])
        }
        func row(_ title: String, _ control: NSView) {
            rows.append([NSTextField(labelWithString: title), control])
        }

        header("Reading")
        row("Theme:", popup(Prefs.themes.map { ($0.0, $0.1) }, key: "theme", current: Prefs.theme))
        row("Font:", popup(Prefs.fonts.map { ($0.0, $0.1) }, key: "font", current: Prefs.font))
        let spacings: [(String, String)] = [1.4, 1.5, 1.65, 1.8, 2.0].map { (String($0), $0 == 1.65 ? "\($0) (default)" : String($0)) }
        row("Line spacing:", popup(spacings, key: "lineSpacing", current: String(Prefs.lineSpacing), asDouble: true))

        header("Playback")
        let visible = NSButton(checkboxWithTitle: "Start from the first sentence on screen", target: self, action: #selector(toggled(_:)))
        visible.identifier = NSUserInterfaceItemIdentifier("startFromVisible")
        visible.state = Prefs.startFromVisible ? .on : .off
        row("Play:", visible)
        row("Jump by:", stepper(key: "jump", value: Prefs.jump, range: 1...20, unit: "sentences"))
        row("Pause after sentence:", stepper(key: "pauseSentence", value: Prefs.pauseSentence, range: 0...3000, unit: "ms", step: 50))
        row("Pause after paragraph:", stepper(key: "pauseParagraph", value: Prefs.pauseParagraph, range: 0...5000, unit: "ms", step: 100))
        row("Pause after chapter:", stepper(key: "pauseChapter", value: Prefs.pauseChapter, range: 0...10000, unit: "ms", step: 250))

        header("Sources")
        row("Keep pasted text for:", stepper(key: "pasteDays", value: Prefs.pasteDays, range: 1...365, unit: "days"))
        row("Web serials, up to:", stepper(key: "webChapterLimit", value: Prefs.webChapterLimit, range: 1...5000, unit: "chapters", step: 10))

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 9
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        for (i, r) in rows.enumerated() where r[1] === NSGridCell.emptyContentView {
            grid.row(at: i).topPadding = i == 0 ? 0 : 10
            grid.cell(atColumnIndex: 0, rowIndex: i).xPlacement = .leading
            grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: i, length: 1))
        }
        grid.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -24),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    private func popup(_ items: [(String, String)], key: String, current: String, asDouble: Bool = false) -> NSPopUpButton {
        let p = NSPopUpButton()
        for (value, title) in items {
            p.addItem(withTitle: title)
            p.lastItem?.representedObject = value
        }
        p.selectItem(at: items.firstIndex { $0.0 == current } ?? 0)
        p.identifier = NSUserInterfaceItemIdentifier(key + (asDouble ? "#double" : ""))
        p.target = self
        p.action = #selector(picked(_:))
        return p
    }

    private func stepper(key: String, value: Int, range: ClosedRange<Int>, unit: String, step: Int = 1) -> NSView {
        let field = NSTextField(string: String(value))
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let formatter = NumberFormatter()
        formatter.minimum = range.lowerBound as NSNumber
        formatter.maximum = range.upperBound as NSNumber
        formatter.allowsFloats = false
        field.formatter = formatter
        let stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = Double(step)
        stepper.integerValue = value
        stepper.valueWraps = false
        // Field and stepper edit the same setting.
        let link = StepperLink(key: key, field: field, stepper: stepper)
        links.append(link)
        let stack = NSStackView(views: [field, stepper, NSTextField(labelWithString: unit)])
        stack.spacing = 6
        return stack
    }

    private var links: [StepperLink] = []

    @objc private func picked(_ sender: NSPopUpButton) {
        guard let raw = sender.identifier?.rawValue, let value = sender.selectedItem?.representedObject as? String else { return }
        if raw.hasSuffix("#double") {
            d.set(Double(value), forKey: String(raw.dropLast("#double".count)))
        } else {
            d.set(value, forKey: raw)
        }
        NotificationCenter.default.post(name: Prefs.changed, object: nil)
    }

    @objc private func toggled(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        d.set(sender.state == .on, forKey: key)
        NotificationCenter.default.post(name: Prefs.changed, object: nil)
    }
}

/// Keeps a number field and its stepper in step, and saves the value.
private final class StepperLink: NSObject, NSTextFieldDelegate {
    let key: String
    let field: NSTextField
    let stepper: NSStepper

    init(key: String, field: NSTextField, stepper: NSStepper) {
        self.key = key
        self.field = field
        self.stepper = stepper
        super.init()
        field.delegate = self
        stepper.target = self
        stepper.action = #selector(stepped)
    }

    @objc func stepped() {
        field.integerValue = stepper.integerValue
        save(stepper.integerValue)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let v = Int(min(max(Double(field.integerValue), stepper.minValue), stepper.maxValue))
        field.integerValue = v
        stepper.integerValue = v
        save(v)
    }

    private func save(_ v: Int) {
        UserDefaults.standard.set(v, forKey: key)
        NotificationCenter.default.post(name: Prefs.changed, object: nil)
    }
}
