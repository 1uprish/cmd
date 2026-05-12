import AppKit
import ClipLogCore

final class CursorPiPSuggestionPanel: NSPanel {
    var onOpen: (() -> Void)?
    var onDismiss: (() -> Void)?

    convenience init(candidate: CursorPiPVideoCandidate) {
        self.init(
            title: "Open YouTube PiP?",
            subtitle: candidate.videoID,
            openTitle: "Open"
        )
    }

    init(title: String, subtitle: String, openTitle: String = "Open") {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 72),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        contentView = CursorPiPSuggestionView(title: title, subtitle: subtitle, openTitle: openTitle, panel: self)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CursorPiPSuggestionView: NSView {
    private weak var panel: CursorPiPSuggestionPanel?
    private let title: NSTextField
    private let subtitle: NSTextField
    private let openButton: NSButton
    private let dismissButton = NSButton(title: "Dismiss", target: nil, action: nil)

    init(title: String, subtitle: String, openTitle: String, panel: CursorPiPSuggestionPanel) {
        self.panel = panel
        self.title = NSTextField(labelWithString: title)
        self.subtitle = NSTextField(labelWithString: subtitle)
        self.openButton = NSButton(title: openTitle, target: nil, action: nil)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        self.title = NSTextField(labelWithString: "")
        self.subtitle = NSTextField(labelWithString: "")
        self.openButton = NSButton(title: "Open", target: nil, action: nil)
        super.init(coder: coder)
        setup()
    }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 14, y: 42, width: bounds.width - 28, height: 18)
        subtitle.frame = NSRect(x: 14, y: 24, width: bounds.width - 28, height: 16)
        openButton.frame = NSRect(x: bounds.width - 118, y: 6, width: 52, height: 22)
        dismissButton.frame = NSRect(x: bounds.width - 62, y: 6, width: 54, height: 22)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        title.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitle.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        subtitle.textColor = .secondaryLabelColor

        openButton.target = self
        openButton.action = #selector(open)
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small

        dismissButton.target = self
        dismissButton.action = #selector(dismiss)
        dismissButton.bezelStyle = .rounded
        dismissButton.controlSize = .small

        [title, subtitle, openButton, dismissButton].forEach(addSubview)
    }

    @objc private func open() {
        panel?.onOpen?()
    }

    @objc private func dismiss() {
        panel?.onDismiss?()
    }
}
