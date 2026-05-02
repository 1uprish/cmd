import AppKit
import ClipLogCore

// MARK: - HUDSlotView
//
// A fully self-contained floating card.
// Primary interactions: click to paste, drag to drop.
//
//  ╭──────────────────────────────────────────────╮
//  │  [icon 36×36]  AppName (bold 13pt)    time  │  ← header
//  │                subtitle (11pt)               │
//  │  Preview text up to 2 lines (13pt)           │  ← content
//  ╰──────────────────────────────────────────────╯

final class HUDSlotView: NSView {

    // MARK: - Chrome

    private let cardBlur    = NSVisualEffectView()
    private let borderLayer = CALayer()

    // MARK: - Header

    private let appIconView    = NSImageView()
    private let appNameLabel   = NSTextField(labelWithString: "")
    private let subtitleLabel  = NSTextField(labelWithString: "")
    private let timestampLabel = NSTextField(labelWithString: "")
    private let shortcutLabel  = NSTextField(labelWithString: "")

    // MARK: - Content

    private let previewLabel  = NSTextField(labelWithString: "")
    private let colorSwatch   = NSView()
    private let colorHexLabel = NSTextField(labelWithString: "")
    private let thumbnailView = NSImageView()

    // MARK: - Actions

    private let copyButton    = NSButton()
    private var copyRevertTimer: Timer?

    // MARK: - State

    var onSelect:    ((ClipEntry) -> Void)?  // click → paste
    var onDragStart: (() -> Void)?           // drag  → dismiss instantly

    private var entry: ClipEntry?
    private var dragStarted        = false
    private var mouseDownLocation  = NSPoint.zero

    // Pre-built at configure() time so mouseDragged has zero work to do.
    private var cachedWriter:     NSPasteboardWriting?
    private var cachedFileURLs:   [NSURL]?        // non-nil only for .file with multiple URLs
    private var cachedDragImage:  NSImage?

    // MARK: - Init

    override init(frame: NSRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        buildCard()
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Card construction

    private func buildCard() {
        wantsLayer = true

        // ── Independent glass background ──────────────────────────────────
        cardBlur.material        = .hudWindow
        cardBlur.blendingMode    = .withinWindow
        cardBlur.state           = .active
        cardBlur.wantsLayer      = true
        cardBlur.layer?.cornerRadius  = 14
        cardBlur.layer?.masksToBounds = true
        cardBlur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(cardBlur)

        NSLayoutConstraint.activate([
            cardBlur.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardBlur.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardBlur.topAnchor.constraint(equalTo: topAnchor),
            cardBlur.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // ── Subtle border ring ────────────────────────────────────────────
        borderLayer.borderWidth      = 0.5
        borderLayer.cornerRadius     = 14
        borderLayer.borderColor      = NSColor.white.withAlphaComponent(0.13).cgColor
        borderLayer.frame            = CGRect(x: 0, y: 0, width: 1, height: 1)
        borderLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(borderLayer)

        // ── Drop shadow (each card has its own) ───────────────────────────
        if let l = layer {
            l.masksToBounds = false
            l.shadowColor   = NSColor.black.withAlphaComponent(0.28).cgColor
            l.shadowOpacity = 1
            l.shadowRadius  = 16
            l.shadowOffset  = CGSize(width: 0, height: -4)
        }

        // ── App icon (circular 36×36) ─────────────────────────────────────
        appIconView.wantsLayer           = true
        appIconView.layer?.cornerRadius  = 10
        appIconView.layer?.masksToBounds = true
        appIconView.imageScaling         = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        cardBlur.addSubview(appIconView)

        // ── App name ──────────────────────────────────────────────────────
        appNameLabel.font          = .boldSystemFont(ofSize: 13)
        appNameLabel.textColor     = .white
        appNameLabel.lineBreakMode = .byTruncatingTail
        appNameLabel.translatesAutoresizingMaskIntoConstraints = false
        cardBlur.addSubview(appNameLabel)

        // ── Subtitle ──────────────────────────────────────────────────────
        subtitleLabel.font          = .systemFont(ofSize: 11)
        subtitleLabel.textColor     = NSColor.white.withAlphaComponent(0.58)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        cardBlur.addSubview(subtitleLabel)

        // ── Timestamp ─────────────────────────────────────────────────────
        timestampLabel.font      = .systemFont(ofSize: 11)
        timestampLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        cardBlur.addSubview(timestampLabel)

        // ── Keyboard shortcut badge ───────────────────────────────────────
        shortcutLabel.font            = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        shortcutLabel.textColor       = NSColor.white.withAlphaComponent(0.78)
        shortcutLabel.alignment       = .center
        shortcutLabel.isBordered      = false
        shortcutLabel.isEditable      = false
        shortcutLabel.isSelectable    = false
        shortcutLabel.drawsBackground = true
        shortcutLabel.backgroundColor = NSColor.white.withAlphaComponent(0.11)
        shortcutLabel.wantsLayer      = true
        shortcutLabel.layer?.cornerRadius = 6
        shortcutLabel.layer?.masksToBounds = true
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        cardBlur.addSubview(shortcutLabel)

        // ── Preview label ─────────────────────────────────────────────────
        previewLabel.font                = .systemFont(ofSize: 13)
        previewLabel.textColor           = NSColor.white.withAlphaComponent(0.72)
        previewLabel.maximumNumberOfLines = 2
        previewLabel.lineBreakMode       = .byTruncatingTail
        previewLabel.cell?.truncatesLastVisibleLine = true
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        cardBlur.addSubview(previewLabel)

        // ── Color swatch + hex ────────────────────────────────────────────
        colorSwatch.wantsLayer          = true
        colorSwatch.layer?.cornerRadius = 6
        colorSwatch.isHidden            = true
        colorSwatch.translatesAutoresizingMaskIntoConstraints = false
        cardBlur.addSubview(colorSwatch)

        colorHexLabel.font      = .systemFont(ofSize: 13)
        colorHexLabel.textColor = .white
        colorHexLabel.isHidden  = true
        colorHexLabel.translatesAutoresizingMaskIntoConstraints = false
        cardBlur.addSubview(colorHexLabel)

        // ── Thumbnail ─────────────────────────────────────────────────────
        thumbnailView.imageScaling        = .scaleProportionallyUpOrDown
        thumbnailView.wantsLayer          = true
        thumbnailView.layer?.cornerRadius = 8
        thumbnailView.layer?.masksToBounds = true
        thumbnailView.isHidden            = true
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        cardBlur.addSubview(thumbnailView)

        // ── Copy button (hover reveal) ────────────────────────────────────
        copyButton.isBordered   = false
        copyButton.bezelStyle   = .regularSquare
        copyButton.imageScaling = .scaleProportionallyDown
        copyButton.image        = NSImage(systemSymbolName: "doc.on.doc",
                                          accessibilityDescription: "Copy")
        copyButton.contentTintColor = .tertiaryLabelColor
        copyButton.target       = self
        copyButton.action       = #selector(copyTapped)
        copyButton.alphaValue   = 0
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        cardBlur.addSubview(copyButton)

        // ── Constraints ───────────────────────────────────────────────────
        let lm: CGFloat      = 14   // left margin
        let rm: CGFloat      = 14   // right margin
        let iconSize: CGFloat = 36
        let iconGap: CGFloat  = 10

        NSLayoutConstraint.activate([

            // Icon — left side, vertically centred in header zone
            appIconView.widthAnchor.constraint(equalToConstant: iconSize),
            appIconView.heightAnchor.constraint(equalToConstant: iconSize),
            appIconView.leadingAnchor.constraint(equalTo: cardBlur.leadingAnchor, constant: lm),
            appIconView.topAnchor.constraint(equalTo: cardBlur.topAnchor, constant: 12),

            // Shortcut — top-right corner
            shortcutLabel.widthAnchor.constraint(equalToConstant: 38),
            shortcutLabel.heightAnchor.constraint(equalToConstant: 22),
            shortcutLabel.trailingAnchor.constraint(equalTo: cardBlur.trailingAnchor, constant: -rm),
            shortcutLabel.topAnchor.constraint(equalTo: cardBlur.topAnchor, constant: 12),

            // Timestamp — before shortcut
            timestampLabel.trailingAnchor.constraint(equalTo: shortcutLabel.leadingAnchor, constant: -8),
            timestampLabel.topAnchor.constraint(equalTo: cardBlur.topAnchor, constant: 14),

            // App name — right of icon, top
            appNameLabel.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: iconGap),
            appNameLabel.topAnchor.constraint(equalTo: appIconView.topAnchor, constant: 1),
            appNameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timestampLabel.leadingAnchor, constant: -8),

            // Subtitle — below app name
            subtitleLabel.leadingAnchor.constraint(equalTo: appNameLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: appNameLabel.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: timestampLabel.leadingAnchor, constant: -8),

            // Preview — below the icon, full width
            previewLabel.leadingAnchor.constraint(equalTo: appNameLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: cardBlur.trailingAnchor, constant: -rm),
            previewLabel.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: 7),
            previewLabel.bottomAnchor.constraint(lessThanOrEqualTo: cardBlur.bottomAnchor, constant: -12),

            // Color swatch
            colorSwatch.widthAnchor.constraint(equalToConstant: 28),
            colorSwatch.heightAnchor.constraint(equalToConstant: 28),
            colorSwatch.leadingAnchor.constraint(equalTo: appNameLabel.leadingAnchor),
            colorSwatch.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: 7),
            colorSwatch.bottomAnchor.constraint(lessThanOrEqualTo: cardBlur.bottomAnchor, constant: -12),

            // Hex label
            colorHexLabel.leadingAnchor.constraint(equalTo: colorSwatch.trailingAnchor, constant: 8),
            colorHexLabel.centerYAnchor.constraint(equalTo: colorSwatch.centerYAnchor),
            colorHexLabel.trailingAnchor.constraint(lessThanOrEqualTo: cardBlur.trailingAnchor, constant: -rm),

            // Thumbnail
            thumbnailView.widthAnchor.constraint(equalToConstant: 72),
            thumbnailView.heightAnchor.constraint(equalToConstant: 50),
            thumbnailView.leadingAnchor.constraint(equalTo: appNameLabel.leadingAnchor),
            thumbnailView.topAnchor.constraint(equalTo: appIconView.bottomAnchor, constant: 7),
            thumbnailView.bottomAnchor.constraint(lessThanOrEqualTo: cardBlur.bottomAnchor, constant: -12),

            // Copy button — bottom-right
            copyButton.widthAnchor.constraint(equalToConstant: 22),
            copyButton.heightAnchor.constraint(equalToConstant: 22),
            copyButton.trailingAnchor.constraint(equalTo: cardBlur.trailingAnchor, constant: -10),
            copyButton.bottomAnchor.constraint(equalTo: cardBlur.bottomAnchor, constant: -10),
        ])
    }

    // MARK: - Configuration

    /// Adjusts the glass card background opacity (0.4 = translucent … 1.0 = default).
    func applyOpacity(_ opacity: Double) {
        cardBlur.alphaValue = CGFloat(opacity)
    }

    func configure(with newEntry: ClipEntry, shortcut: String?) {
        self.entry = newEntry
        alphaValue = 1

        timestampLabel.stringValue = relativeTime(for: newEntry.copiedAt)
        shortcutLabel.stringValue = shortcut ?? ""
        shortcutLabel.isHidden = shortcut == nil

        // App icon
        let icon = NSRunningApplication
            .runningApplications(withBundleIdentifier: newEntry.sourceBundleID)
            .first?.icon
        if let icon {
            appIconView.image = icon
            appIconView.contentTintColor = nil
        } else {
            appIconView.image = NSImage(systemSymbolName: "app.fill",
                                        accessibilityDescription: nil)
            appIconView.contentTintColor = .secondaryLabelColor
        }

        appNameLabel.textColor = .white
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        timestampLabel.textColor = NSColor.white.withAlphaComponent(0.62)
        previewLabel.textColor = NSColor.white.withAlphaComponent(0.72)

        appNameLabel.stringValue  = newEntry.sourceAppName
        subtitleLabel.stringValue = newEntry.isSensitive ? "" :
            (domainFromEntry(newEntry) ?? contentTypeLabel(for: newEntry.contentType))

        let isColor = newEntry.contentType == .color
        let isImage = newEntry.contentType == .image

        previewLabel.isHidden  = isColor || isImage
        colorSwatch.isHidden   = !isColor
        colorHexLabel.isHidden = !isColor
        thumbnailView.isHidden = !isImage

        if newEntry.isSensitive {
            previewLabel.attributedStringValue = NSAttributedString(
                string: "••••••••",
                attributes: [.font: NSFont.systemFont(ofSize: 13),
                             .foregroundColor: NSColor.white.withAlphaComponent(0.45)]
            )
            previewLabel.isHidden  = false
            colorSwatch.isHidden   = true
            colorHexLabel.isHidden = true
            thumbnailView.isHidden = true
        } else if isColor {
            let hex = String(data: newEntry.contentData, encoding: .utf8) ?? ""
            colorSwatch.layer?.backgroundColor = colorFromHex(hex)?.cgColor
                ?? NSColor.systemGray.cgColor
            colorHexLabel.stringValue = hex.hasPrefix("#") ? hex : "#\(hex)"
        } else if isImage {
            thumbnailView.image = NSImage(data: newEntry.contentData)
        } else {
            let raw = String(data: newEntry.contentData, encoding: .utf8) ?? newEntry.previewText
            previewLabel.attributedStringValue = attributedPreview(for: raw, type: newEntry.contentType)
        }

        copyButton.isHidden = false

        // Pre-build drag artefacts now (cheap) so mouseDragged fires with zero latency.
        buildDragCache(for: newEntry)
    }

    func configureEmpty() {
        self.entry = nil
        alphaValue = 0.35

        // Clear drag cache — view is being reused as an empty slot.
        clearDragCache()

        timestampLabel.stringValue = ""
        appIconView.image          = NSImage(systemSymbolName: "doc.on.clipboard",
                                             accessibilityDescription: nil)
        appIconView.contentTintColor = .quaternaryLabelColor
        appNameLabel.stringValue   = "Empty"
        subtitleLabel.stringValue  = ""
        shortcutLabel.stringValue  = ""
        shortcutLabel.isHidden     = true

        previewLabel.attributedStringValue = NSAttributedString(
            string: "No clipboard item",
            attributes: [.font: NSFont.systemFont(ofSize: 12),
                         .foregroundColor: NSColor.white.withAlphaComponent(0.35)]
        )
        previewLabel.isHidden  = false
        colorSwatch.isHidden   = true
        colorHexLabel.isHidden = true
        thumbnailView.isHidden = true
        copyButton.isHidden    = true
    }

    // MARK: - Drag cache helpers

    private func buildDragCache(for entry: ClipEntry) {
        // Resolve file URLs first — needed for both writer and image.
        if entry.contentType == .file {
            let raw = String(data: entry.contentData, encoding: .utf8) ?? ""
            let urls = raw.components(separatedBy: "\n")
                .filter { !$0.isEmpty }
                .compactMap { URL(string: $0) as NSURL? }
            if urls.count > 1 {
                // Multiple files: we'll create multiple NSDraggingItems in mouseDragged.
                cachedFileURLs = urls
                cachedWriter   = nil
            } else {
                cachedFileURLs = nil
                cachedWriter   = urls.first ?? (raw as NSString)
            }
        } else if entry.contentType == .color {
            // Color: write both NSColor and hex string so Sketch/Figma pick it up.
            let hex = String(data: entry.contentData, encoding: .utf8) ?? ""
            let item = NSPasteboardItem()
            if let color = NSColor(hex: hex) {
                // NSColor directly via NSPasteboardWriting into a temporary pasteboard
                // to get the raw color data, then copy it into our item.
                let tmpPb = NSPasteboard(name: NSPasteboard.Name(rawValue: "_cmd_tmp_\(arc4random())"))
                tmpPb.clearContents()
                tmpPb.writeObjects([color])
                if let colorData = tmpPb.data(forType: .color) {
                    item.setData(colorData, forType: .color)
                }
                tmpPb.releaseGlobally()
            }
            let hexString = hex.hasPrefix("#") ? hex : "#\(hex)"
            item.setString(hexString, forType: .string)
            cachedWriter   = item
            cachedFileURLs = nil
        } else {
            cachedWriter   = ClipPasteboardWriter.primaryPasteboardWriter(for: entry)
            cachedFileURLs = nil
        }
        // Build the drag image respecting the current appearance.
        cachedDragImage = lightweightDragImage(for: entry)
    }

    private func clearDragCache() {
        cachedWriter    = nil
        cachedFileURLs  = nil
        cachedDragImage = nil
    }

    // MARK: - Highlight / dim (filter)

    func setHighlighted(_ highlighted: Bool) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = 0.18
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
            ctx.allowsImplicitAnimation = true
            self.animator().alphaValue = highlighted ? 1.0 : 0.18
        }
    }

    // Required so the nonactivating panel forwards mouse events to subviews.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Click to paste

    override func mouseUp(with event: NSEvent) {
        guard !dragStarted, let entry else { return }
        // Ignore if click landed on the copy button
        let pt = convert(event.locationInWindow, from: nil)
        if let hit = hitTest(pt), (hit === copyButton || hit.isDescendant(of: copyButton)) { return }
        // Must not have drifted more than 5 px from mouseDown (exclude accidental drag-clicks)
        let dx = pt.x - mouseDownLocation.x, dy = pt.y - mouseDownLocation.y
        guard dx*dx + dy*dy < 25 else { return }
        onSelect?(entry)
    }

    // MARK: - Hover

    override func mouseEntered(with event: NSEvent) {
        // Open hand = universal macOS drag affordance (Finder, Photos, etc.).
        // Pointing hand is reserved for empty/non-draggable slots (link-click metaphor).
        if entry != nil && cachedDragImage != nil {
            NSCursor.openHand.set()
        } else {
            NSCursor.pointingHand.set()
        }
        applyHover(true)
    }
    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        applyHover(false)
    }

    private func applyHover(_ on: Bool) {
        // Apple easing curves: ease-out on enter (fast start), ease-in on exit (fast end)
        let easeOut = CAMediaTimingFunction(controlPoints: 0.25, 0.46, 0.45, 0.94)
        let easeIn  = CAMediaTimingFunction(controlPoints: 0.55, 0.06, 1.00, 0.40)
        let timing  = on ? easeOut : easeIn
        let duration: CFTimeInterval = on ? 0.20 : 0.14

        // Border colour — animate directly on the CALayer (smoother than NSAnimationContext)
        let targetBorder = (on
            ? NSColor.white.withAlphaComponent(0.32)
            : NSColor.white.withAlphaComponent(0.13)).cgColor
        let borderAnim            = CABasicAnimation(keyPath: "borderColor")
        borderAnim.fromValue       = borderLayer.presentation()?.borderColor ?? borderLayer.borderColor
        borderAnim.toValue         = targetBorder
        borderAnim.duration        = duration
        borderAnim.timingFunction  = timing
        borderAnim.fillMode        = .forwards
        borderAnim.isRemovedOnCompletion = false
        borderLayer.add(borderAnim, forKey: "borderColor")
        borderLayer.borderColor = targetBorder

        // Shadow radius
        let targetShadow: CGFloat = on ? 24 : 14
        let shadowAnim            = CABasicAnimation(keyPath: "shadowRadius")
        shadowAnim.fromValue       = layer?.presentation()?.shadowRadius ?? layer?.shadowRadius
        shadowAnim.toValue         = targetShadow
        shadowAnim.duration        = duration
        shadowAnim.timingFunction  = timing
        shadowAnim.fillMode        = .forwards
        shadowAnim.isRemovedOnCompletion = false
        layer?.add(shadowAnim, forKey: "shadowRadius")
        layer?.shadowRadius = targetShadow

        // Micro scale lift — 1.5% on enter, back to identity on exit
        let targetScale: CGFloat = on ? 1.015 : 1.0
        let scaleAnim             = CABasicAnimation(keyPath: "transform.scale")
        scaleAnim.fromValue        = (layer?.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1.0
        scaleAnim.toValue          = targetScale
        scaleAnim.duration         = duration
        scaleAnim.timingFunction   = timing
        scaleAnim.fillMode         = .forwards
        scaleAnim.isRemovedOnCompletion = false
        layer?.add(scaleAnim, forKey: "hoverScale")
        layer?.setValue(targetScale, forKeyPath: "transform.scale")

        // Copy button fade
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration       = duration
            ctx.timingFunction = timing
            copyButton.animator().alphaValue = on ? 1 : 0
        }
    }

    // MARK: - Copy action

    @objc private func copyTapped() {
        guard let entry else { return }
        writeEntryToPasteboard(entry)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        copyButton.contentTintColor = .systemGreen
        copyRevertTimer?.invalidate()
        copyRevertTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc",
                                             accessibilityDescription: "Copy")
            self?.copyButton.contentTintColor = .tertiaryLabelColor
        }
    }

    // MARK: - Drag

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
        // Store in view-local coordinates for correct threshold math in mouseDragged.
        mouseDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragStarted else { return }

        let pt = convert(event.locationInWindow, from: nil)
        let dx = pt.x - mouseDownLocation.x
        let dy = pt.y - mouseDownLocation.y
        guard dx*dx + dy*dy > 16 else { return }  // 4 px radius — avoids accidental drags on trackpad

        // Need at least a drag image; writer may be nil for multi-file (handled below).
        guard let dragImg = cachedDragImage else { return }

        dragStarted = true
        // Note: onDragStart (→ dismissForDrag) is called in draggingSession(_:willBeginAt:),
        // not here, so the HUD vanishes exactly when the system drag session begins.

        // Ghost frame: fixed 340×56, anchored to the user's grab point so the card
        // appears to lift from exactly where they clicked — more natural than centering
        // on the card midpoint.
        let ghostW: CGFloat = 340
        let ghostH: CGFloat = 56
        let grabInWindow = convert(mouseDownLocation, to: nil)
        let ghostFrame = CGRect(
            x: grabInWindow.x - ghostW / 2,
            y: grabInWindow.y - ghostH / 2,
            width: ghostW,
            height: ghostH
        )

        // Build dragging items.
        var items: [NSDraggingItem] = []

        if let urls = cachedFileURLs, !urls.isEmpty {
            // Multiple files: one NSDraggingItem per URL, all using the same ghost image.
            for (idx, url) in urls.enumerated() {
                let fileItem = NSDraggingItem(pasteboardWriter: url)
                // Only the first item carries the visible ghost; the rest are hidden.
                if idx == 0 {
                    fileItem.setDraggingFrame(ghostFrame, contents: dragImg)
                } else {
                    fileItem.setDraggingFrame(ghostFrame, contents: nil)
                }
                items.append(fileItem)
            }
        } else if let writer = cachedWriter {
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(ghostFrame, contents: dragImg)
            items.append(item)
        } else {
            // Nothing to drag (e.g. empty slot that somehow slipped through).
            dragStarted = false
            return
        }

        beginDraggingSession(with: items, event: event, source: self)
    }

    // MARK: - Drag image
    //
    // Rendered once in configure() and reused instantly in mouseDragged.
    // Respects the card's effectiveAppearance so dark/light mode is correct.
    // Size: 340×56 — must match the ghostFrame in mouseDragged exactly.

    private static let ghostSize = NSSize(width: 340, height: 56)

    private func lightweightDragImage(for entry: ClipEntry) -> NSImage {
        let size = HUDSlotView.ghostSize
        let w = size.width
        let h = size.height
        let r: CGFloat = 14  // corner radius

        let img = NSImage(size: size)

        // Render inside the card's effectiveAppearance so colours are correct for
        // the current dark/light mode — lockFocus alone doesn't do this.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            img.lockFocus()
            defer { img.unlockFocus() }

            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

            // ── Subtle outer shadow drawn into the bitmap ─────────────────
            // (The real card already has a layer shadow; this adds depth to the ghost.)
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.setShadow(offset: CGSize(width: 0, height: -3),
                          blur: 10,
                          color: NSColor.black.withAlphaComponent(0.30).cgColor)

            // ── Background ────────────────────────────────────────────────
            let bgRect = NSRect(x: 0, y: 0, width: w, height: h)
            let path = NSBezierPath(roundedRect: bgRect, xRadius: r, yRadius: r)

            // Semi-transparent so the drop target is visible beneath the ghost.
            let bgColor: NSColor = isDark
                ? NSColor(srgbRed: 0.18, green: 0.18, blue: 0.20, alpha: 0.82)
                : NSColor(srgbRed: 0.97, green: 0.97, blue: 0.97, alpha: 0.88)
            bgColor.setFill()
            path.fill()

            // Disable shadow for the rest of the drawing (border, text, icon).
            ctx.setShadow(offset: .zero, blur: 0, color: nil)

            // ── Border ring — faint blue tint signals draggable content ────
            let borderColor: NSColor = NSColor(srgbRed: 0.039, green: 0.518, blue: 1.0, alpha: 0.25)
            borderColor.setStroke()
            path.lineWidth = 0.5
            path.stroke()

            // ── App icon (28×28, rounded) ─────────────────────────────────
            let iconSize: CGFloat = 28
            let iconX: CGFloat = 14
            let iconY: CGFloat = (h - iconSize) / 2
            if let icon = appIconView.image {
                // Clip to rounded rect for the ghost icon.
                let iconRect = NSRect(x: iconX, y: iconY, width: iconSize, height: iconSize)
                let iconPath = NSBezierPath(roundedRect: iconRect, xRadius: 7, yRadius: 7)
                ctx.saveGState()
                iconPath.addClip()
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
                ctx.restoreGState()
            }

            // ── App name (bold 12pt, single line) ─────────────────────────
            let textX: CGFloat = iconX + iconSize + 10
            let textMaxW: CGFloat = w - textX - 12
            let nameAttrs: [NSAttributedString.Key: Any] = [
                .font:            NSFont.boldSystemFont(ofSize: 12),
                .foregroundColor: isDark ? NSColor.white : NSColor.black,
            ]
            let nameStr = appNameLabel.stringValue as NSString
            let nameRect = NSRect(x: textX, y: h / 2 + 1, width: textMaxW, height: 16)
            nameStr.draw(with: nameRect,
                         options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                         attributes: nameAttrs)

            // ── Preview / subtitle (regular 11pt, single line) ────────────
            let preview: String
            switch entry.contentType {
            case .image: preview = "Image"
            case .color:
                let hex = String(data: entry.contentData, encoding: .utf8) ?? "Color"
                preview = hex.hasPrefix("#") ? hex : "#\(hex)"
            case .file:
                if let urls = cachedFileURLs, urls.count > 1 {
                    preview = "\(urls.count) files"
                } else {
                    preview = "File"
                }
            default:
                preview = String(entry.previewText.prefix(60))
            }
            let previewAttrs: [NSAttributedString.Key: Any] = [
                .font:            NSFont.systemFont(ofSize: 11),
                .foregroundColor: isDark
                    ? NSColor.white.withAlphaComponent(0.55)
                    : NSColor.black.withAlphaComponent(0.50),
            ]
            let previewRect = NSRect(x: textX, y: h / 2 - 15, width: textMaxW, height: 14)
            (preview as NSString).draw(with: previewRect,
                                       options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                                       attributes: previewAttrs)
        }

        return img
    }

    private func writeEntryToPasteboard(_ entry: ClipEntry) {
        ClipPasteboardWriter.write(entry)
    }

    // MARK: - Attributed preview

    private func attributedPreview(for raw: String, type: ClipContentType) -> NSAttributedString {
        let s = raw.replacingOccurrences(of: "\n", with: " ")
        let nonEmpty = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let display = nonEmpty.isEmpty ? fallbackPreview(for: type) : s
        let trimmed = display.count > 140 ? String(display.prefix(140)) + "…" : display
        return NSAttributedString(string: trimmed, attributes: [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
        ])
    }

    private func fallbackPreview(for type: ClipContentType) -> String {
        switch type {
        case .text: return "Text"
        case .url: return "URL"
        case .code: return "Code"
        case .image: return "Image"
        case .rich: return "Mixed"
        case .file: return "File"
        case .color: return "Color"
        }
    }

    // MARK: - Helpers

    private func relativeTime(for date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        switch s {
        case ..<10:    return "just now"
        case ..<3600:  return "\(s / 60)m ago"
        case ..<86400: return "\(s / 3600)h ago"
        default:       return "\(s / 86400)d ago"
        }
    }

    private func domainFromEntry(_ entry: ClipEntry) -> String? {
        guard entry.contentType == .url,
              let s = String(data: entry.contentData, encoding: .utf8),
              let host = URL(string: s)?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private func contentTypeLabel(for type: ClipContentType) -> String {
        switch type {
        case .text:  return ""
        case .url:   return "URL"
        case .code:  return "Code"
        case .image: return "Image"
        case .rich:  return "Mixed"
        case .file:  return "File"
        case .color: return "Color"
        }
    }

    private func colorFromHex(_ hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h = String(h.dropFirst()) }
        guard h.count == 6, let v = UInt64(h, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((v>>16)&0xFF)/255,
                       green:   CGFloat((v>>8)&0xFF)/255,
                       blue:    CGFloat(v&0xFF)/255, alpha: 1)
    }
}

// MARK: - NSDraggingSource

extension HUDSlotView: NSDraggingSource {

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : .copy
    }

    /// Called by the system the instant the drag image appears on screen.
    /// This is the correct moment to dismiss the HUD — not in mouseDragged.
    func draggingSession(_ session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint) {
        onDragStart?()  // → HUDPanel.dismissForDrag() — instant, no animation
    }

    /// Restore cursor to arrow when the drag ends (covers cancellation too).
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        NSCursor.arrow.set()
    }
}

// MARK: - NSColor hex init

private extension NSColor {
    convenience init?(hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard raw.count == 6 || raw.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: raw).scanHexInt64(&value) else { return nil }
        if raw.count == 8 {
            self.init(srgbRed: CGFloat((value>>24)&0xFF)/255,
                      green:   CGFloat((value>>16)&0xFF)/255,
                      blue:    CGFloat((value>>8)&0xFF)/255,
                      alpha:   CGFloat(value&0xFF)/255)
        } else {
            self.init(srgbRed: CGFloat((value>>16)&0xFF)/255,
                      green:   CGFloat((value>>8)&0xFF)/255,
                      blue:    CGFloat(value&0xFF)/255, alpha: 1)
        }
    }
}
