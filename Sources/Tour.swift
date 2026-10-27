import AppKit

/// A short guided tour: one popover at a time, pointing at the control it explains.
/// Shown once on first launch; Help → Show Tutorial replays it.
final class Tour: NSObject, NSPopoverDelegate {
    private struct Step {
        let anchor: String
        let title: String
        let text: String
    }

    private let steps = [
        Step(anchor: "page", title: "Welcome to Earmark",
             text: "Earmark reads your books aloud and highlights each sentence and the word being spoken. This quick tour shows where everything is."),
        Step(anchor: "play", title: "Play and pause",
             text: "Press Play or the Space bar. Media keys and headphone buttons work too. Earmark remembers where you stop in every book."),
        Step(anchor: "steps", title: "Move around",
             text: "Step back or forward a sentence (⌘← and ⌘→). You can also click any sentence in the text to start reading there."),
        Step(anchor: "chapter", title: "Chapters",
             text: "Pick a chapter here, or press ⌘G to jump to one by number or title. Next to it you can see how far through the book you are."),
        Step(anchor: "voice", title: "Voices",
             text: "Choose a voice: any voice installed on your Mac, plus plugin voices. The bottom of this menu lets you fix pronunciations and skip repeated lines."),
        Step(anchor: "speed", title: "Speed",
             text: "Listen at 0.75× to 4×. ⌘= and ⌘- change the speed while it reads."),
        Step(anchor: "title", title: "Books from anywhere",
             text: "Open EPUB, PDF and text files with ⌘O. Use ⌘L for a web serial, ⌘⇧V to read the clipboard, ⌘⇧E to save chapters as audio, and ⌘F to search the book."),
        Step(anchor: "page", title: "Make it yours",
             text: "Themes, fonts, pauses and more are in Settings (⌘,). You can replay this tour any time from Help → Show Tutorial."),
    ]

    private let anchors: () -> [String: NSView]
    private var popover: NSPopover?
    private var index = 0
    var onEnd: (() -> Void)?

    init(anchors: @escaping () -> [String: NSView]) {
        self.anchors = anchors
    }

    func start() {
        index = 0
        show()
    }

    private func show() {
        popover?.close()
        let step = steps[index]
        let views = anchors()
        guard let anchor = views[step.anchor] ?? views["page"] else { return }
        let card = TourCard(title: step.title, text: step.text, position: "\(index + 1) of \(steps.count)",
                            isFirst: index == 0, isLast: index == steps.count - 1)
        card.onNext = { [weak self] in self?.next() }
        card.onBack = { [weak self] in self?.back() }
        card.onSkip = { [weak self] in self?.skip() }
        let p = NSPopover()
        p.contentViewController = card
        p.behavior = .applicationDefined
        p.animates = true
        p.delegate = self
        popover = p
        // Steps about the whole window point at its middle; the rest point at their control.
        if step.anchor == "page" {
            let r = anchor.bounds
            p.show(relativeTo: NSRect(x: r.midX - 1, y: r.midY + r.height * 0.15, width: 2, height: 2), of: anchor, preferredEdge: .maxY)
        } else {
            // Controls in the bottom bar get the card above them; the title strip, below it.
            // "Above" is maxY in normal coordinates and minY in flipped ones.
            let wantAbove = step.anchor != "title"
            let edge: NSRectEdge = wantAbove == anchor.isFlipped ? .minY : .maxY
            p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: edge)
        }
    }

    /// Development aid: walks the tour (or skips it) and reports where each card appeared.
    func debugWalk(skip: Bool, log: @escaping (String) -> Void) {
        start()
        func report(_ label: String) {
            guard let card = popover?.contentViewController?.view.window, let main = NSApp.windows.first(where: { $0.title != "" && $0.isVisible && $0 !== card }) else {
                return log("\(label): no card")
            }
            let c = card.frame, w = main.frame
            let inside = w.insetBy(dx: -40, dy: -40).contains(c)
            log("\(label): card \(Int(c.minX - w.minX)),\(Int(w.maxY - c.maxY)) size \(Int(c.width))x\(Int(c.height)) inside window: \(inside)")
        }
        var step = 0
        func tick() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                report(skip && step == 1 ? "skip note" : "step \(step + 1) \(self.steps[min(step, self.steps.count - 1)].anchor)")
                if skip && step == 0 { self.skip(); step = 1; return tick() }
                if skip { return self.finish() }
                step += 1
                if step < self.steps.count { self.next(); tick() } else { self.finish(); log("done") }
            }
        }
        tick()
    }

    private func next() {
        if index + 1 < steps.count {
            index += 1
            show()
        } else {
            finish()
        }
    }

    private func back() {
        guard index > 0 else { return }
        index -= 1
        show()
    }

    private func finish() {
        popover?.close()
        popover = nil
        onEnd?()
    }

    /// Skipping ends the tour with a note on where to find it again.
    private func skip() {
        popover?.close()
        let views = anchors()
        guard let anchor = views["title"] ?? views["page"] else { return finish() }
        let card = TourCard(title: "Tour skipped", text: "Replay it any time from Help → Show Tutorial.",
                            position: nil, isFirst: true, isLast: true)
        card.onNext = { [weak self] in self?.finish() }
        let p = NSPopover()
        p.contentViewController = card
        p.behavior = .transient
        p.delegate = self
        popover = p
        p.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: anchor.isFlipped ? .maxY : .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        // A transient note closed by clicking elsewhere still ends the tour.
        if (notification.object as? NSPopover) === popover, popover?.behavior == .transient {
            popover = nil
            onEnd?()
        }
    }
}

/// The content of one tour step: title, text, and Skip / Back / Next buttons.
private final class TourCard: NSViewController {
    var onNext: (() -> Void)?
    var onBack: (() -> Void)?
    var onSkip: (() -> Void)?
    private let titleText: String, bodyText: String, position: String?
    private let isFirst: Bool, isLast: Bool

    init(title: String, text: String, position: String?, isFirst: Bool, isLast: Bool) {
        titleText = title
        bodyText = text
        self.position = position
        self.isFirst = isFirst
        self.isLast = isLast
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = NSTextField(labelWithString: titleText)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let body = NSTextField(wrappingLabelWithString: bodyText)
        body.font = .systemFont(ofSize: 12)
        body.preferredMaxLayoutWidth = 260
        body.widthAnchor.constraint(equalToConstant: 260).isActive = true

        var buttons: [NSView] = []
        if position != nil {
            let skip = NSButton(title: "Skip Tour", target: self, action: #selector(skipped))
            skip.isBordered = false
            skip.contentTintColor = .secondaryLabelColor
            skip.font = .systemFont(ofSize: 11)
            buttons.append(skip)
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        buttons.append(spacer)
        if let position {
            let count = NSTextField(labelWithString: position)
            count.font = .systemFont(ofSize: 11)
            count.textColor = .tertiaryLabelColor
            buttons.append(count)
        }
        if !isFirst {
            buttons.append(NSButton(title: "Back", target: self, action: #selector(backed)))
        }
        let next = NSButton(title: position == nil ? "OK" : (isLast ? "Done" : "Next"), target: self, action: #selector(nexted))
        next.keyEquivalent = "\r"
        buttons.append(next)
        let row = NSStackView(views: buttons)
        row.spacing = 8

        let stack = NSStackView(views: [title, body, row])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        row.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        // Explicit margins: a popover sizes to its root view and ignores a stack view's own insets.
        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
        ])
        view = container
        preferredContentSize = container.fittingSize
    }

    @objc private func nexted() { onNext?() }
    @objc private func backed() { onBack?() }
    @objc private func skipped() { onSkip?() }
}
