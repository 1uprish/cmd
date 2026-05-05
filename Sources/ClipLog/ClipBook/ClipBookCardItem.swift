import AppKit
import ClipLogCore

// MARK: - ClipBookCardItem
//
// NSCollectionViewItem rendering one clipboard entry as an iOS-style card.
//
// Anatomy (~100pt tall):
//
//  ┌──────────────────────────────────────────────────────┐
//  │  [icon 36×36]  AppName (bold 13pt)      2m ago       │  ← header row, 44pt
//  │   circular     domain.com (11pt muted)               │
//  ├ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┤
//  │  Preview text up to 2 lines, 13pt, numbers underlined │  ← content, 48pt
//  └──────────────────────────────────────────────────────┘
//                                  [⎘ Copy] [📌 Pin]  ← on hover only

final class ClipBookCardItem: NSCollectionViewItem {

    // MARK: - Reuse identifier

    static let reuseIdentifier = NSUserInterfaceItemIdentifier("ClipBookCardItem")

    // MARK: - Callbacks (set by window controller after dequeue)

    var onCopy:   ((ClipEntry) -> Void)?
    var onPin:    ((ClipEntry, Bool) -> Void)?
    var onPaste:  ((ClipEntry) -> Void)?
    var onDelete: ((UUID) -> Void)?

    // MARK: - State

    private(set) var entry: ClipEntry?
    private var isHovered = false
    private var dragStarted = false
    private var mouseDownLocation = NSPoint.zero

    // MARK: - Card chrome

    private let cardEffect  = NSVisualEffectView()
    private let borderLayer = CALayer()

    // MARK: - Header row subviews

    private let appIconView   = NSImageView()
    private let appNameLabel  = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let timestampLabel = NSTextField(labelWithString: "")

    // MARK: - Content area subviews (text path)

    private let previewLabel  = NSTextField(labelWithString: "")

    // Content area — colour path
    private let colorSwatch   = NSView()
    private let colorHexLabel = NSTextField(labelWithString: "")

    // Content area — image path
    private let thumbnailView = NSImageView()

    // MARK: - Hover-only action buttons

    private let copyButton = NSButton()
    private let pinButton  = NSButton()

    // MARK: - Lifecycle

    override func loadView() {
        // NSCollectionViewItem needs self.view set when not loaded from a nib.
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 100))
        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildCard()
    }

    // MARK: - Card construction

    private func buildCard() {
        let root = view
        root.wantsLayer = true

        // ── Visual-effect background ──────────────────────────────────────
        cardEffect.material         = .menu
        cardEffect.blendingMode     = .behindWindow
        cardEffect.state            = .active
        cardEffect.wantsLayer       = true
        cardEffect.layer?.cornerRadius  = CmdVisualStyle.cardCornerRadius
        cardEffect.layer?.masksToBounds = true
        cardEffect.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(cardEffect)

        NSLayoutConstraint.activate([
            cardEffect.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            cardEffect.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            cardEffect.topAnchor.constraint(equalTo: root.topAnchor),
            cardEffect.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        // ── Subtle border ring ────────────────────────────────────────────
        borderLayer.borderWidth   = CmdVisualStyle.hairline
        borderLayer.cornerRadius  = CmdVisualStyle.cardCornerRadius
        borderLayer.borderColor   = CmdVisualStyle.cardBorder.cgColor
        borderLayer.frame         = root.bounds
        borderLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.layer?.addSublayer(borderLayer)

        // ── Drop shadow ───────────────────────────────────────────────────
        root.shadow = NSShadow()
        if let layer = root.layer {
            layer.shadowColor   = NSColor.black.withAlphaComponent(0.22).cgColor
            layer.shadowOpacity = 1
            layer.shadowRadius  = 8
            layer.shadowOffset  = CGSize(width: 0, height: -2)
            layer.masksToBounds = false
        }

        // ── App icon (circular, 36×36) ────────────────────────────────────
        appIconView.wantsLayer         = true
        appIconView.layer?.cornerRadius = 18
        appIconView.layer?.masksToBounds = true
        appIconView.imageScaling       = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        cardEffect.addSubview(appIconView)

        // ── App name (bold 13pt) ──────────────────────────────────────────
        appNameLabel.font      = .systemFont(ofSize: 14, weight: .bold)
        appNameLabel.textColor = .labelColor
        appNameLabel.lineBreakMode = .byTruncatingTail
        appNameLabel.translatesAutoresizingMaskIntoConstraints = false
        cardEffect.addSubview(appNameLabel)

        // ── Subtitle / domain (11pt tertiary) ────────────────────────────
        subtitleLabel.font      = .systemFont(ofSize: 11, weight: .semibold)
        subtitleLabel.textColor = .tertiaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        cardEffect.addSubview(subtitleLabel)

        // ── Timestamp (11pt secondary, pinned top-right) ──────────────────
        timestampLabel.font      = .systemFont(ofSize: 11, weight: .semibold)
        timestampLabel.textColor = .secondaryLabelColor
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        cardEffect.addSubview(timestampLabel)

        // ── Preview label (13pt, max 2 lines) ─────────────────────────────
        previewLabel.font              = .systemFont(ofSize: 13, weight: .medium)
        previewLabel.textColor         = .labelColor
        previewLabel.maximumNumberOfLines = 2
        previewLabel.lineBreakMode     = .byTruncatingTail
        previewLabel.cell?.truncatesLastVisibleLine = true
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        cardEffect.addSubview(previewLabel)

        // ── Color swatch + hex label ──────────────────────────────────────
        colorSwatch.wantsLayer          = true
        colorSwatch.layer?.cornerRadius = 6
        colorSwatch.isHidden            = true
        colorSwatch.translatesAutoresizingMaskIntoConstraints = false
        cardEffect.addSubview(colorSwatch)

        colorHexLabel.font      = .systemFont(ofSize: 13)
        colorHexLabel.textColor = .labelColor
        colorHexLabel.isHidden  = true
        colorHexLabel.translatesAutoresizingMaskIntoConstraints = false
        cardEffect.addSubview(colorHexLabel)

        // ── Image thumbnail ───────────────────────────────────────────────
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer   = true
        thumbnailView.layer?.cornerRadius  = 8
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.16).cgColor
        thumbnailView.isHidden     = true
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        cardEffect.addSubview(thumbnailView)

        // ── Action buttons (hover-only) ───────────────────────────────────
        configureActionButton(copyButton,
                              symbol: "doc.on.doc",
                              accessibilityLabel: "Copy",
                              action: #selector(copyTapped))
        copyButton.alphaValue = 0
        cardEffect.addSubview(copyButton)

        configureActionButton(pinButton,
                              symbol: "pin",
                              accessibilityLabel: "Pin",
                              action: #selector(pinTapped))
        pinButton.alphaValue = 0
        cardEffect.addSubview(pinButton)

        // ── Layout ────────────────────────────────────────────────────────
        let lm: CGFloat = 12   // left margin
        let rm: CGFloat = 12   // right margin
        let iconSize: CGFloat = 36
        let iconLabelGap: CGFloat = 8
        let contentTopGap: CGFloat = 8

        NSLayoutConstraint.activate([

            // App icon — top-left, inset 12pt each side
            appIconView.widthAnchor.constraint(equalToConstant: iconSize),
            appIconView.heightAnchor.constraint(equalToConstant: iconSize),
            appIconView.leadingAnchor.constraint(equalTo: cardEffect.leadingAnchor, constant: lm),
            appIconView.topAnchor.constraint(equalTo: cardEffect.topAnchor, constant: lm - 2),

            // Timestamp — pinned to top-right
            timestampLabel.trailingAnchor.constraint(equalTo: cardEffect.trailingAnchor, constant: -rm),
            timestampLabel.topAnchor.constraint(equalTo: cardEffect.topAnchor, constant: lm - 1),

            // App name — right of icon, top-aligned with icon top
            appNameLabel.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: iconLabelGap),
            appNameLabel.topAnchor.constraint(equalTo: appIconView.topAnchor),
            appNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timestampLabel.leadingAnchor, constant: -6),

            // Subtitle — below app name, left-aligned
            subtitleLabel.leadingAnchor.constraint(equalTo: appNameLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: appNameLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timestampLabel.leadingAnchor, constant: -6),

            // Preview label — below icon + name block, left-aligned with app name
            previewLabel.leadingAnchor.constraint(equalTo: appNameLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            previewLabel.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: contentTopGap),
            previewLabel.bottomAnchor.constraint(lessThanOrEqualTo: cardEffect.bottomAnchor, constant: -contentTopGap),

            // Color swatch (28×28) — same left anchor as preview, vertically centred in content area
            colorSwatch.widthAnchor.constraint(equalToConstant: 28),
            colorSwatch.heightAnchor.constraint(equalToConstant: 28),
            colorSwatch.leadingAnchor.constraint(equalTo: appNameLabel.leadingAnchor),
            colorSwatch.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: contentTopGap),

            // Hex label — right of swatch
            colorHexLabel.leadingAnchor.constraint(equalTo: colorSwatch.trailingAnchor, constant: 8),
            colorHexLabel.centerYAnchor.constraint(equalTo: colorSwatch.centerYAnchor),
            colorHexLabel.trailingAnchor.constraint(lessThanOrEqualTo: copyButton.leadingAnchor, constant: -8),

            // Image thumbnail — large enough to inspect at a glance.
            thumbnailView.widthAnchor.constraint(greaterThanOrEqualToConstant: 132),
            thumbnailView.heightAnchor.constraint(equalToConstant: 52),
            thumbnailView.leadingAnchor.constraint(equalTo: appNameLabel.leadingAnchor),
            thumbnailView.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            thumbnailView.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: contentTopGap),
            thumbnailView.bottomAnchor.constraint(lessThanOrEqualTo: cardEffect.bottomAnchor, constant: -contentTopGap),

            // Action buttons — bottom-right, 8pt margin
            pinButton.widthAnchor.constraint(equalToConstant: 24),
            pinButton.heightAnchor.constraint(equalToConstant: 24),
            pinButton.trailingAnchor.constraint(equalTo: cardEffect.trailingAnchor, constant: -8),
            pinButton.bottomAnchor.constraint(equalTo: cardEffect.bottomAnchor, constant: -8),

            copyButton.widthAnchor.constraint(equalToConstant: 24),
            copyButton.heightAnchor.constraint(equalToConstant: 24),
            copyButton.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -6),
            copyButton.bottomAnchor.constraint(equalTo: pinButton.bottomAnchor),
        ])

        // ── Tracking area ─────────────────────────────────────────────────
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        view.addTrackingArea(area)
    }

    // MARK: - Button factory

    private func configureActionButton(_ button: NSButton,
                                       symbol: String,
                                       accessibilityLabel: String,
                                       action: Selector) {
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered    = false
        button.bezelStyle    = .regularSquare
        button.imageScaling  = .scaleProportionallyDown
        button.image         = NSImage(systemSymbolName: symbol,
                                       accessibilityDescription: accessibilityLabel)
        button.contentTintColor = .secondaryLabelColor
        button.target        = self
        button.action        = action
    }

    // MARK: - Public configuration

    func configure(with newEntry: ClipEntry) {
        self.entry = newEntry

        // Timestamp
        timestampLabel.stringValue = relativeTime(for: newEntry.copiedAt)

        // App icon
        let runningIcon = NSRunningApplication
            .runningApplications(withBundleIdentifier: newEntry.sourceBundleID)
            .first?.icon
        if let icon = runningIcon {
            appIconView.image = icon
        } else {
            appIconView.image = NSImage(systemSymbolName: "app.fill",
                                        accessibilityDescription: "App icon")
            appIconView.contentTintColor = .secondaryLabelColor
        }

        // App name
        appNameLabel.stringValue = newEntry.sourceAppName

        // Subtitle: domain for URL entries, else content type label; empty for sensitive/plain text
        if newEntry.isSensitive {
            subtitleLabel.stringValue = ""
        } else if let domain = domainFromEntry(newEntry) {
            subtitleLabel.stringValue = domain
        } else {
            subtitleLabel.stringValue = contentTypeLabel(for: newEntry.contentType)
        }

        // Content area visibility
        let isColor    = newEntry.contentType == .color
        let isImage    = newEntry.contentType == .image
        let isMixed    = newEntry.contentType == .rich
        let isSensitive = newEntry.isSensitive

        previewLabel.isHidden  = isColor || isImage
        colorSwatch.isHidden   = !isColor
        colorHexLabel.isHidden = !isColor
        thumbnailView.isHidden = !isImage

        if isSensitive {
            // Redacted text, no colour/image handling
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            previewLabel.attributedStringValue = NSAttributedString(string: newEntry.previewText, attributes: attrs)
            previewLabel.isHidden  = false
            colorSwatch.isHidden   = true
            colorHexLabel.isHidden = true
            thumbnailView.isHidden = true
        } else if isColor {
            let hex = String(data: newEntry.contentData, encoding: .utf8) ?? ""
            colorSwatch.layer?.backgroundColor = color(fromHex: hex)?.cgColor
                ?? NSColor.systemGray.cgColor
            colorHexLabel.stringValue = hex.hasPrefix("#") ? hex : "#\(hex)"
        } else if isImage {
            thumbnailView.image = NSImage(data: newEntry.contentData)
        } else if isMixed {
            let raw = String(data: newEntry.contentData, encoding: .utf8) ?? newEntry.previewText
            previewLabel.attributedStringValue = attributedPreview(for: raw, type: newEntry.contentType)
        } else {
            let raw = String(data: newEntry.contentData, encoding: .utf8) ?? newEntry.previewText
            previewLabel.attributedStringValue = attributedPreview(for: raw, type: newEntry.contentType)
        }

        // Pin button glyph
        let pinSymbol = newEntry.isPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: pinSymbol,
                                  accessibilityDescription: newEntry.isPinned ? "Unpin" : "Pin")
        pinButton.contentTintColor = newEntry.isPinned ? .systemYellow : .secondaryLabelColor

        copyButton.isHidden = false
        pinButton.isHidden  = false
    }

    // MARK: - Attributed preview

    private func attributedPreview(for raw: String,
                                   type: ClipContentType) -> NSAttributedString {
        let cleaned: String
        switch type {
        case .text, .code, .url, .rich:
            let s = raw.replacingOccurrences(of: "\n", with: " ")
            cleaned = s.count > 160 ? String(s.prefix(160)) + "…" : s
        default:
            cleaned = raw
        }

        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ]
        let result = NSMutableAttributedString(string: cleaned, attributes: base)

        let pattern = try? NSRegularExpression(pattern: "\\d+")
        let range   = NSRange(cleaned.startIndex..., in: cleaned)
        pattern?.enumerateMatches(in: cleaned, range: range) { match, _, _ in
            guard let r = match?.range else { return }
            result.addAttribute(.underlineStyle,
                                value: NSUnderlineStyle.single.rawValue,
                                range: r)
        }
        return result
    }

    // MARK: - Helpers

    private func relativeTime(for date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<10:    return "just now"
        case ..<3600:  return "\(seconds / 60)m ago"
        case ..<86400: return "\(seconds / 3600)h ago"
        default:       return "\(seconds / 86400)d ago"
        }
    }

    private func domainFromEntry(_ entry: ClipEntry) -> String? {
        guard entry.contentType == .url,
              let str  = String(data: entry.contentData, encoding: .utf8),
              let url  = URL(string: str),
              let host = url.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func contentTypeLabel(for type: ClipContentType) -> String {
        switch type {
        case .text:  return ""
        default:     return CmdVisualStyle.label(for: type)
        }
    }

    private func color(fromHex hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        let r = CGFloat((val >> 16) & 0xFF) / 255
        let g = CGFloat((val >>  8) & 0xFF) / 255
        let b = CGFloat( val        & 0xFF) / 255
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }

    // MARK: - Actions

    @objc private func copyTapped() {
        guard let entry else { return }
        onCopy?(entry)
        let original = copyButton.image
        copyButton.image = NSImage(systemSymbolName: "checkmark",
                                   accessibilityDescription: "Copied")
        copyButton.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.copyButton.image = original
            self?.copyButton.contentTintColor = .secondaryLabelColor
        }
    }

    @objc private func pinTapped() {
        guard let entry else { return }
        let newPinned = !entry.isPinned
        onPin?(entry, newPinned)
        let sym = newPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        pinButton.contentTintColor = newPinned ? .systemYellow : .secondaryLabelColor
    }

    // MARK: - Hover / selection

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyHoverState(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyHoverState(false)
    }

    private func applyHoverState(_ hovered: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            borderLayer.borderColor = hovered
                ? CmdVisualStyle.cardBorderHover.cgColor
                : CmdVisualStyle.cardBorder.cgColor
            view.layer?.shadowRadius = hovered ? 12 : 8
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            copyButton.animator().alphaValue = hovered ? 1 : 0
            pinButton.animator().alphaValue  = hovered ? 1 : 0
        }
    }

    override var isSelected: Bool {
        didSet { applySelectionState(isSelected) }
    }

    private func applySelectionState(_ selected: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            borderLayer.borderColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.80).cgColor
                : (isHovered
                   ? CmdVisualStyle.cardBorderHover.cgColor
                   : CmdVisualStyle.cardBorder.cgColor)
            borderLayer.borderWidth = selected ? 1.5 : 0.5
        }
    }

    // Double-click to paste
    override func mouseDown(with event: NSEvent) {
        dragStarted = false
        mouseDownLocation = view.convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        if event.clickCount == 2, let entry {
            onPaste?(entry)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted, entry != nil else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let dx = point.x - mouseDownLocation.x
        let dy = point.y - mouseDownLocation.y
        guard dx * dx + dy * dy > 16 else { return }
        dragStarted = true
        beginDrag(from: event)
    }

    // MARK: - Right-click context menu

    override func rightMouseDown(with event: NSEvent) {
        guard let entry else { return }
        let menu = buildContextMenu(for: entry)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func buildContextMenu(for entry: ClipEntry) -> NSMenu {
        let menu = NSMenu()

        // 1. Copy
        let copyItem = NSMenuItem(title: "Copy", action: #selector(contextCopy), keyEquivalent: "")
        copyItem.target = self
        menu.addItem(copyItem)

        // 2. Paste
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(contextPaste), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        menu.addItem(.separator())

        // 3. Transform & Paste submenu
        let transformMenu = NSMenu()
        let transformItem = NSMenuItem(title: "Transform & Paste", action: nil, keyEquivalent: "")

        let isTextType = [ClipContentType.text, .url, .code, .rich].contains(entry.contentType)
        if isTextType {
            for section in ClipTransform.menuSections {
                // Section header (disabled)
                let header = NSMenuItem(title: section.title, action: nil, keyEquivalent: "")
                header.isEnabled = false
                transformMenu.addItem(header)

                for transform in section.transforms {
                    let item = NSMenuItem(
                        title: transform.rawValue,
                        action: #selector(transformAndPaste(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = transform
                    transformMenu.addItem(item)
                }

                if section.title != ClipTransform.menuSections.last?.title {
                    transformMenu.addItem(.separator())
                }
            }
        } else {
            let unavailable = NSMenuItem(title: "Not available for this type", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            transformMenu.addItem(unavailable)
        }

        transformItem.submenu = transformMenu
        menu.addItem(transformItem)

        menu.addItem(.separator())

        // 4. Pin / Unpin
        let pinTitle = entry.isPinned ? "Unpin" : "Pin"
        let pinItem = NSMenuItem(title: pinTitle, action: #selector(contextTogglePin), keyEquivalent: "")
        pinItem.target = self
        menu.addItem(pinItem)

        // 5. Delete
        let deleteItem = NSMenuItem(title: "Delete", action: #selector(contextDelete), keyEquivalent: "")
        deleteItem.target = self
        menu.addItem(deleteItem)

        return menu
    }

    // MARK: - Context menu actions

    @objc private func contextCopy() {
        guard let entry else { return }
        onCopy?(entry)
        flashCopySuccess()
    }

    @objc private func contextPaste() {
        guard let entry else { return }
        onPaste?(entry)
    }

    @objc private func transformAndPaste(_ sender: NSMenuItem) {
        guard let entry,
              let transform = sender.representedObject as? ClipTransform else { return }

        let rawText = String(data: entry.contentData, encoding: .utf8) ?? entry.previewText
        guard let result = transform.apply(to: rawText) else { return }

        // Build a mutated ClipEntry with the transformed text so that
        // onPaste can go through ClipBookWindowController.paste(entry:) which
        // correctly dismisses the window, re-activates the previous app, and
        // synthesizes ⌘V. Synthesizing from inside the card item would paste
        // into ClipLog itself (wrong app).
        let transformed = ClipEntry(
            id: entry.id,
            copiedAt: entry.copiedAt,
            contentType: entry.contentType,
            contentData: Data(result.utf8),
            contentHash: entry.contentHash,
            sourceBundleID: entry.sourceBundleID,
            charCount: result.count,
            isPinned: entry.isPinned,
            isSensitive: entry.isSensitive,
            ocrText: entry.ocrText,
            mediaPath: entry.mediaPath,
            sourceWindowTitle: entry.sourceWindowTitle
        )
        onPaste?(transformed)
        flashCopySuccess()
    }

    @objc private func contextTogglePin() {
        guard let entry else { return }
        let newPinned = !entry.isPinned
        onPin?(entry, newPinned)
        let sym = newPinned ? "pin.fill" : "pin"
        pinButton.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
        pinButton.contentTintColor = newPinned ? .systemYellow : .secondaryLabelColor
    }

    @objc private func contextDelete() {
        guard let entry else { return }
        onDelete?(entry.id)
    }

    // MARK: - Helpers

    private func flashCopySuccess() {
        let original = copyButton.image
        copyButton.image = NSImage(systemSymbolName: "checkmark",
                                   accessibilityDescription: "Transformed")
        copyButton.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.copyButton.image = original
            self?.copyButton.contentTintColor = .secondaryLabelColor
        }
    }

    private func synthesiseCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgSessionEventTap)
    }
}

// MARK: - NSDraggingSource

extension ClipBookCardItem: NSDraggingSource {

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }

    func beginDrag(from event: NSEvent) {
        guard let entry else { return }
        let writers = ClipPasteboardWriter.dragPasteboardWriters(for: entry)
        guard !writers.isEmpty else { return }
        let image = view.snapshot()

        let items = writers.enumerated().map { offset, writer -> NSDraggingItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            draggingItem.setDraggingFrame(view.bounds, contents: offset == 0 ? image : nil)
            return draggingItem
        }
        view.beginDraggingSession(with: items, event: event, source: self)
    }
}

// MARK: - NSView snapshot helper

private extension NSView {
    func snapshot() -> NSImage {
        let img = NSImage(size: bounds.size)
        img.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            layer?.render(in: ctx)
        }
        img.unlockFocus()
        return img
    }
}
