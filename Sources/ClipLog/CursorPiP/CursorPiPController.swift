import AppKit
import ClipLogCore
import Combine
import WebKit

final class CursorPiPController: NSObject, ObservableObject {
    private enum Layout {
        static let defaultFrame = NSRect(x: 160, y: 160, width: 480, height: 270)
        static let edgePadding: CGFloat = 12
        static let trackingInterval: TimeInterval = 1.0 / 60.0
        static let activeBrowserPollInterval: TimeInterval = 1.5
        static let animationDuration: TimeInterval = 0.08
    }

    private let settings = ClipLogSettings.shared
    private let panel: CursorPiPPanel
    private let contentView: CursorPiPContentView
    private var suggestionPanel: CursorPiPSuggestionPanel?
    private var trackingTimer: Timer?
    private var activeBrowserTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var isMovingFromTimer = false
    private var lastCandidate: CursorPiPVideoCandidate?
    private var lastSuggestedVideoID: String?
    private var lastSuggestedOTTURL: String?
    private var lastActiveBrowserURL: String?

    var anchorRectProvider: (() -> NSRect?)?

    var isVisible: Bool {
        panel.isVisible
    }

    override init() {
        ClipLogSettings.shared.cursorPiPFollowCursor = false
        ClipLogSettings.shared.cursorPiPPinned = true
        let initialSize = CGSize(
            width: ClipLogSettings.shared.cursorPiPWidth,
            height: ClipLogSettings.shared.cursorPiPHeight
        )
        let initialOrigin = CursorPiPController.restoredOrigin(size: initialSize)
        self.panel = CursorPiPPanel(frame: NSRect(origin: initialOrigin, size: initialSize))
        self.contentView = CursorPiPContentView()
        super.init()

        panel.delegate = self
        panel.contentView = contentView
        contentView.onSubmitURL = { [weak self] raw in self?.open(raw) }
        contentView.onClose = { [weak self] in self?.hide() }
        contentView.onTogglePin = { [weak self] in self?.togglePinned() }
        contentView.onToggleFollow = { [weak self] in self?.toggleFollowing() }
        contentView.onSizePreset = { [weak self] preset in self?.applySizePreset(preset) }
        contentView.onOpenInBrowser = { [weak self] in self?.openCurrentURLInBrowser() }
        contentView.updateState(following: settings.cursorPiPFollowCursor, pinned: settings.cursorPiPPinned)
        contentView.applyAppearance(
            cornerRadius: CGFloat(settings.cursorPiPCornerRadius),
            edgeBlur: CGFloat(settings.cursorPiPEdgeBlur),
            opacity: settings.cursorPiPOpacity,
            chromeVisible: settings.cursorPiPChromeVisible
        )
        bindSettings()
        applyEnabledState()
        updateActiveBrowserMonitorState()
        if settings.cursorPiPEnabled {
            OTTPiPLauncher.shared.warmUp()
        }
    }

    func handleClipboardEntry(_ entry: ClipEntry) {
        guard settings.cursorPiPEnabled else {
            DiagnosticsLogbook.shared.record(
                "clipboard_candidate_ignored",
                category: "cursor_pip",
                details: ["reason": "disabled"]
            )
            return
        }
        guard settings.cursorPiPAutoSuggest else {
            DiagnosticsLogbook.shared.record(
                "clipboard_candidate_ignored",
                category: "cursor_pip",
                details: ["reason": "auto_suggest_off"]
            )
            return
        }
        guard [.text, .url, .rich].contains(entry.contentType) else {
            DiagnosticsLogbook.shared.record(
                "clipboard_candidate_ignored",
                category: "cursor_pip",
                details: ["reason": "unsupported_entry_type", "entryType": entry.contentType.rawValue]
            )
            return
        }
        guard let text = String(data: entry.contentData, encoding: .utf8) else {
            DiagnosticsLogbook.shared.record(
                "clipboard_candidate_ignored",
                category: "cursor_pip",
                details: ["reason": "invalid_text", "entryType": entry.contentType.rawValue]
            )
            return
        }
        guard let route = CursorPiPURLDetector.route(in: text) else {
            if entry.isSensitive {
                DiagnosticsLogbook.shared.record(
                    "clipboard_candidate_ignored",
                    category: "cursor_pip",
                    details: ["reason": "sensitive", "entryType": entry.contentType.rawValue]
                )
                return
            }
            DiagnosticsLogbook.shared.record(
                "clipboard_candidate_ignored",
                category: "cursor_pip",
                details: ["reason": "no_supported_url", "entryType": entry.contentType.rawValue]
            )
            return
        }

        switch route {
        case .native(let candidate):
            lastCandidate = candidate
            DiagnosticsLogbook.shared.record(
                "clipboard_candidate_detected",
                category: "cursor_pip",
                details: [
                    "route": "native",
                    "platform": candidate.platformName,
                    "entrySensitive": "\(entry.isSensitive)"
                ]
            )
            showSuggestionIfNeeded(candidate)
        case .ott(let url, let platform):
            DiagnosticsLogbook.shared.record(
                "clipboard_candidate_detected",
                category: "cursor_pip",
                details: [
                    "route": "ott",
                    "platform": platform,
                    "host": url.host ?? "",
                    "entrySensitive": "\(entry.isSensitive)"
                ]
            )
            showOTTSuggestionIfNeeded(url: url, platform: platform)
        case .unsupported:
            DiagnosticsLogbook.shared.record(
                "clipboard_candidate_ignored",
                category: "cursor_pip",
                details: ["reason": "unsupported_route", "entryType": entry.contentType.rawValue]
            )
            return
        }
    }

    func openFromPasteboard() {
        guard let raw = NSPasteboard.general.string(forType: .string),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            promptForURL()
            return
        }
        open(raw)
    }

    func openFromActiveBrowser() {
        guard let url = ActiveBrowserURLResolver.currentURL() else {
            let alert = NSAlert()
            alert.messageText = "No supported browser video found."
            alert.informativeText = "Open Netflix, JioCinema, Prime, Hotstar, YouTube, or Vimeo in the frontmost browser, then launch PiP again."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        open(url.absoluteString)
    }

    func promptForURL() {
        let alert = NSAlert()
        alert.messageText = "Open YouTube in CursorPiP"
        alert.informativeText = "Paste a YouTube link."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        field.stringValue = settings.cursorPiPLastURL
        field.placeholderString = "https://www.youtube.com/watch?v=..."
        alert.accessoryView = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        open(field.stringValue)
    }

    func open(_ rawValue: String) {
        let normalized = normalizeURLInput(rawValue)
        guard let url = URL(string: normalized) else {
            showUnsupportedAlert()
            return
        }

        switch CursorPiPURLDetector.route(for: url) {
        case .native(let candidate):
            lastCandidate = candidate
            settings.cursorPiPLastURL = candidate.originalURL.absoluteString
            contentView.load(candidate: candidate)
            show()
            BrowserPlaybackController.pauseMatchingBrowserMedia(for: candidate.originalURL)
        case .ott(let url, _):
            settings.cursorPiPLastURL = url.absoluteString
            _ = OTTPiPLauncher.shared.open(url: url)
            if !OTTPiPLauncher.requiresChromeNativePiP(url) {
                BrowserPlaybackController.pauseMatchingBrowserMedia(for: url)
            }
        case .unsupported:
            showUnsupportedAlert()
        }
    }

    func openLastCandidate() {
        if let candidate = lastCandidate {
            open(candidate.originalURL.absoluteString)
        } else {
            openFromPasteboard()
        }
    }

    func toggleVisibility() {
        isVisible ? hide() : openLastCandidate()
    }

    func hide() {
        suggestionPanel?.close()
        suggestionPanel = nil
        contentView.pausePlayback()
        panel.orderOut(nil)
        stopTracking()
    }

    func togglePinned() {
        settings.cursorPiPPinned.toggle()
        contentView.updateState(following: settings.cursorPiPFollowCursor, pinned: settings.cursorPiPPinned)
        updateTrackingState()
        persistPanelFrame()
    }

    func toggleFollowing() {
        settings.cursorPiPFollowCursor = false
        settings.cursorPiPPinned = true
        contentView.updateState(following: settings.cursorPiPFollowCursor, pinned: settings.cursorPiPPinned)
        stopTracking()
    }

    func applySizePreset(_ preset: CursorPiPSizePreset) {
        let screen = screen(containing: panel.frame.center) ?? NSScreen.main
        let canvasSize = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        let size = CursorPiPGeometry.wideWebcamSize(
            canvasSize: canvasSize,
            sizePercent: preset.sizePercent,
            margin: Layout.edgePadding
        )
        settings.cursorPiPWidth = Double(size.width)
        settings.cursorPiPHeight = Double(size.height)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true, animate: true)
        clampToVisibleScreen()
        persistPanelFrame()
    }

    private func show() {
        panel.orderFrontRegardless()
        contentView.urlString = settings.cursorPiPLastURL
        clampToVisibleScreen()
        updateTrackingState()
    }

    private func bindSettings() {
        settings.$cursorPiPEnabled
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.applyEnabledState()
                self?.updateActiveBrowserMonitorState()
            }
            .store(in: &cancellables)

        settings.$cursorPiPAutoSuggest
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateActiveBrowserMonitorState() }
            .store(in: &cancellables)

        Publishers.CombineLatest(settings.$cursorPiPFollowCursor, settings.$cursorPiPPinned)
            .sink { [weak self] following, pinned in
                self?.contentView.updateState(following: following, pinned: pinned)
                self?.updateTrackingState()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            settings.$cursorPiPCornerRadius,
            settings.$cursorPiPEdgeBlur,
            settings.$cursorPiPOpacity,
            settings.$cursorPiPChromeVisible
        )
            .sink { [weak self] radius, edgeBlur, opacity, visible in
                self?.contentView.applyAppearance(
                    cornerRadius: CGFloat(radius),
                    edgeBlur: CGFloat(edgeBlur),
                    opacity: opacity,
                    chromeVisible: visible
                )
            }
            .store(in: &cancellables)
    }

    private func applyEnabledState() {
        if !settings.cursorPiPEnabled {
            hide()
        }
    }

    private func updateActiveBrowserMonitorState() {
        if settings.cursorPiPEnabled && settings.cursorPiPAutoSuggest {
            startActiveBrowserMonitoring()
        } else {
            stopActiveBrowserMonitoring()
        }
    }

    private func startActiveBrowserMonitoring() {
        guard activeBrowserTimer == nil else { return }
        checkActiveBrowserURL()
        let timer = Timer.scheduledTimer(withTimeInterval: Layout.activeBrowserPollInterval, repeats: true) { [weak self] _ in
            self?.checkActiveBrowserURL()
        }
        RunLoop.main.add(timer, forMode: .common)
        activeBrowserTimer = timer
    }

    private func stopActiveBrowserMonitoring() {
        activeBrowserTimer?.invalidate()
        activeBrowserTimer = nil
        lastActiveBrowserURL = nil
    }

    private func checkActiveBrowserURL() {
        guard settings.cursorPiPEnabled,
              settings.cursorPiPAutoSuggest,
              let url = ActiveBrowserURLResolver.currentURL()
        else { return }

        let key = url.absoluteString
        if key == lastActiveBrowserURL, suggestionPanel != nil {
            return
        }
        lastActiveBrowserURL = key

        switch CursorPiPURLDetector.route(for: url) {
        case .native(let candidate):
            lastCandidate = candidate
            DiagnosticsLogbook.shared.record(
                "active_browser_candidate_detected",
                category: "cursor_pip",
                details: ["route": "native", "platform": candidate.platformName]
            )
            showSuggestionIfNeeded(candidate)
        case .ott(let url, let platform):
            DiagnosticsLogbook.shared.record(
                "active_browser_candidate_detected",
                category: "cursor_pip",
                details: ["route": "ott", "platform": platform, "host": url.host ?? ""]
            )
            showOTTSuggestionIfNeeded(url: url, platform: platform)
        case .unsupported:
            return
        }
    }

    private func updateTrackingState() {
        stopTracking()
    }

    private func startTracking() {
        guard trackingTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Layout.trackingInterval, repeats: true) { [weak self] _ in
            self?.movePanelNearCursor()
        }
        RunLoop.main.add(timer, forMode: .common)
        trackingTimer = timer
    }

    private func stopTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
    }

    private func movePanelNearCursor() {
        guard let screen = screen(containing: NSEvent.mouseLocation) else { return }
        let origin = CursorPiPGeometry.clampedOrigin(
            cursor: NSEvent.mouseLocation,
            visibleFrame: screen.visibleFrame,
            panelSize: panel.frame.size,
            offset: CGSize(width: settings.cursorPiPOffsetX, height: settings.cursorPiPOffsetY),
            padding: Layout.edgePadding
        )

        isMovingFromTimer = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Layout.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(origin)
        } completionHandler: { [weak self] in
            self?.isMovingFromTimer = false
        }
    }

    private func clampToVisibleScreen() {
        guard let screen = screen(containing: panel.frame.center) ?? NSScreen.main else { return }
        let origin = CursorPiPGeometry.clampedOrigin(
            cursor: panel.frame.origin,
            visibleFrame: screen.visibleFrame,
            panelSize: panel.frame.size,
            offset: .zero,
            padding: Layout.edgePadding
        )
        panel.setFrameOrigin(origin)
    }

    private func persistPanelFrame() {
        let frame = panel.frame
        settings.cursorPiPOriginX = Double(frame.origin.x)
        settings.cursorPiPOriginY = Double(frame.origin.y)
        settings.cursorPiPWidth = Double(frame.size.width)
        settings.cursorPiPHeight = Double(frame.size.height)
    }

    private func showSuggestionIfNeeded(_ candidate: CursorPiPVideoCandidate) {
        guard candidate.videoID != lastSuggestedVideoID else { return }
        lastSuggestedVideoID = candidate.videoID

        let panel = CursorPiPSuggestionPanel(candidate: candidate)
        panel.onOpen = { [weak self] in
            self?.suggestionPanel?.close()
            self?.suggestionPanel = nil
            self?.open(candidate.originalURL.absoluteString)
        }
        panel.onDismiss = { [weak self] in
            self?.suggestionPanel?.close()
            self?.suggestionPanel = nil
        }

        let anchor = anchorRectProvider?()
        let origin: NSPoint
        if let anchor {
            origin = NSPoint(x: anchor.minX - 210, y: anchor.minY - 78)
        } else {
            origin = NSPoint(x: NSEvent.mouseLocation.x + 18, y: NSEvent.mouseLocation.y - 84)
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
        suggestionPanel?.close()
        suggestionPanel = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self, weak panel] in
            guard self?.suggestionPanel === panel else { return }
            panel?.close()
            self?.suggestionPanel = nil
        }
    }

    private func showOTTSuggestionIfNeeded(url: URL, platform: String) {
        let key = url.absoluteString
        if key == lastSuggestedOTTURL, suggestionPanel != nil {
            return
        }
        lastSuggestedOTTURL = key

        let panel = CursorPiPSuggestionPanel(
            title: "Open \(platform) PiP?",
            subtitle: url.host ?? url.absoluteString,
            openTitle: OTTPiPLauncher.requiresChromeNativePiP(url) ? "Open Chrome" : "Open"
        )
        panel.onOpen = { [weak self] in
            self?.suggestionPanel?.close()
            self?.suggestionPanel = nil
            if !OTTPiPLauncher.requiresChromeNativePiP(url) {
                BrowserPlaybackController.pauseMatchingBrowserMedia(for: url)
            }
            _ = OTTPiPLauncher.shared.open(url: url)
        }
        panel.onDismiss = { [weak self] in
            self?.suggestionPanel?.close()
            self?.suggestionPanel = nil
        }

        let anchor = anchorRectProvider?()
        let origin: NSPoint
        if let anchor {
            origin = NSPoint(x: anchor.minX - 210, y: anchor.minY - 78)
        } else {
            origin = NSPoint(x: NSEvent.mouseLocation.x + 18, y: NSEvent.mouseLocation.y - 84)
        }
        panel.setFrameOrigin(origin)
        suggestionPanel?.close()
        suggestionPanel = panel
        panel.orderFrontRegardless()
        panel.makeKey()
        DiagnosticsLogbook.shared.record(
            "suggestion_shown",
            category: "cursor_pip",
            details: [
                "route": OTTPiPLauncher.requiresChromeNativePiP(url) ? "chrome_native" : "ott",
                "platform": platform,
                "host": url.host ?? ""
            ]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak panel] in
            guard self?.suggestionPanel === panel else { return }
            panel?.close()
            self?.suggestionPanel = nil
        }
    }

    private func openCurrentURLInBrowser() {
        guard let raw = contentView.currentOriginalURLString,
              let url = URL(string: raw)
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func showUnsupportedAlert() {
        let alert = NSAlert()
        alert.messageText = "CursorPiP supports YouTube first."
        alert.informativeText = "Copy or paste a YouTube URL, or a supported OTT URL for the experimental Browser PiP path."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func normalizeURLInput(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            return trimmed
        }
        return "https://\(trimmed)"
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private static func restoredOrigin(size: CGSize) -> CGPoint {
        let stored = CGPoint(
            x: ClipLogSettings.shared.cursorPiPOriginX,
            y: ClipLogSettings.shared.cursorPiPOriginY
        )
        guard stored != .zero,
              let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(stored) }) ?? NSScreen.main
        else {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            return CGPoint(x: screen.maxX - size.width - 36, y: screen.maxY - size.height - 64)
        }
        return CursorPiPGeometry.clampedOrigin(
            cursor: stored,
            visibleFrame: screen.visibleFrame,
            panelSize: size,
            offset: .zero,
            padding: Layout.edgePadding
        )
    }
}

extension CursorPiPController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        guard !isMovingFromTimer else { return }
        settings.cursorPiPPinned = true
        persistPanelFrame()
    }

    func windowDidResize(_ notification: Notification) {
        persistPanelFrame()
    }

    func windowWillClose(_ notification: Notification) {
        hide()
    }
}

private extension NSRect {
    var center: NSPoint {
        NSPoint(x: midX, y: midY)
    }
}
