import AppKit
import ApplicationServices
import SwiftUI
import ClipLogCore

public final class MenuBarController: NSObject {

    private let store: ClipStore
    private let slotManager: SlotManager
    private let diagnosticsSnapshotProvider: () -> [String: String]

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var featuresWindow: NSWindow?
    private var clipBookController: ClipBookWindowController?

    private var degradedObserver:  (any NSObjectProtocol)?
    private var recoveredObserver: (any NSObjectProtocol)?
    private var clearAllObserver:  (any NSObjectProtocol)?
    private var isTapDegraded = false
    private var isAccessibilityGranted = true

    init(
        store: ClipStore,
        slots: SlotManager,
        diagnosticsSnapshotProvider: @escaping () -> [String: String]
    ) {
        self.store = store
        self.slotManager = slots
        self.diagnosticsSnapshotProvider = diagnosticsSnapshotProvider
    }

    public func setup() {
        DiagnosticsLogbook.shared.actionInput(feature: "menu_bar", action: "setup")
        isAccessibilityGranted = AXIsProcessTrusted()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "command",
                accessibilityDescription: "cmd"
            )
            button.image?.isTemplate = true
        }

        item.menu = buildMenu()
        updateStatusIcon()
        DiagnosticsLogbook.shared.actionProcess(feature: "menu_bar", action: "setup", details: ["step": "menu_built"])

        let nc = NotificationCenter.default

        degradedObserver = nc.addObserver(
            forName: .clipLogTapDegraded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isTapDegraded = true
            self?.updateStatusIcon()
        }

        recoveredObserver = nc.addObserver(
            forName: .clipLogTapRecovered,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isTapDegraded = false
            self?.updateStatusIcon()
        }

        clearAllObserver = nc.addObserver(
            forName: .cmdClearAllHistory,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            try? self.store.purgeExpired(before: .distantFuture)
        }
        DiagnosticsLogbook.shared.actionOutput(feature: "menu_bar", action: "setup", details: ["success": "true"])
    }

    deinit {
        if let obs = degradedObserver  { NotificationCenter.default.removeObserver(obs) }
        if let obs = recoveredObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = clearAllObserver  { NotificationCenter.default.removeObserver(obs) }
    }

    // Shows a warning triangle (and a Grant Permission item) until Accessibility
    // is granted, then switches back to the command logo and hides the item.
    public func setAccessibilityGranted(_ granted: Bool) {
        DispatchQueue.main.async {
            guard granted != self.isAccessibilityGranted else {
                self.updateStatusIcon()
                return
            }
            self.isAccessibilityGranted = granted
            self.statusItem?.menu = self.buildMenu()
            self.updateStatusIcon()
        }
    }

    /// Rebuild the menu and icon after the capture-pause state changes.
    public func refreshPauseState() {
        DispatchQueue.main.async {
            self.statusItem?.menu = self.buildMenu()
            self.updateStatusIcon()
        }
    }

    private func updateStatusIcon() {
        let symbol: String
        if !isAccessibilityGranted || isTapDegraded {
            symbol = "exclamationmark.triangle.fill"
        } else if ClipLogSettings.shared.isCapturePaused {
            symbol = "pause.circle"
        } else {
            symbol = "command"
        }
        setButtonImage(symbolName: symbol)
    }

    // MARK: - Menu construction

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let titleItem = NSMenuItem(title: "cmd", action: nil, keyEquivalent: "")
        titleItem.isEnabled = false
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        ]
        titleItem.attributedTitle = NSAttributedString(string: "cmd", attributes: attrs)
        menu.addItem(titleItem)
        menu.addItem(.separator())

        if !isAccessibilityGranted {
            let grantItem = NSMenuItem(
                title: "Grant Accessibility Permission…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            grantItem.target = self
            grantItem.image = NSImage(
                systemSymbolName: "exclamationmark.triangle.fill",
                accessibilityDescription: nil
            )
            menu.addItem(grantItem)
            menu.addItem(.separator())
        }

        let historyItem = NSMenuItem(
            title: "Show History…",
            action: #selector(showHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        menu.addItem(historyItem)

        let recent = (try? store.recent(limit: 5)) ?? []
        if !recent.isEmpty {
            let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for entry in recent {
                let item = NSMenuItem(
                    title: Self.recentTitle(for: entry),
                    action: #selector(copyRecent(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = entry
                submenu.addItem(item)
            }
            recentItem.submenu = submenu
            menu.addItem(recentItem)
        }

        let capturePaused = ClipLogSettings.shared.isCapturePaused
        let pauseItem = NSMenuItem(title: "Pause Capturing", action: nil, keyEquivalent: "")
        let pauseMenu = NSMenu()
        if capturePaused {
            let resume = NSMenuItem(title: "Resume Capturing", action: #selector(resumeCapture), keyEquivalent: "")
            resume.target = self
            pauseMenu.addItem(resume)
            pauseMenu.addItem(.separator())
        }
        let pause15 = NSMenuItem(title: "For 15 Minutes", action: #selector(pauseFor15Minutes), keyEquivalent: "")
        pause15.target = self
        let pause60 = NSMenuItem(title: "For 1 Hour", action: #selector(pauseFor1Hour), keyEquivalent: "")
        pause60.target = self
        let pauseUntil = NSMenuItem(title: "Until I Resume", action: #selector(pauseIndefinitely), keyEquivalent: "")
        pauseUntil.target = self
        pauseMenu.addItem(pause15)
        pauseMenu.addItem(pause60)
        pauseMenu.addItem(pauseUntil)
        pauseItem.submenu = pauseMenu
        pauseItem.state = capturePaused ? .on : .off
        menu.addItem(pauseItem)

        let featuresItem = NSMenuItem(
            title: "Features & Guide",
            action: #selector(showFeatures),
            keyEquivalent: ""
        )
        featuresItem.target = self
        menu.addItem(featuresItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        let diagnosticsItem = NSMenuItem(
            title: "Open Diagnostics Log",
            action: #selector(openDiagnosticsLog),
            keyEquivalent: ""
        )
        diagnosticsItem.target = self
        menu.addItem(diagnosticsItem)

        let summaryItem = NSMenuItem(
            title: "Open Daily Error Summary",
            action: #selector(openDailyErrorSummary),
            keyEquivalent: ""
        )
        summaryItem.target = self
        menu.addItem(summaryItem)

        let exportItem = NSMenuItem(
            title: "Export Debug Report",
            action: #selector(exportDebugReport),
            keyEquivalent: ""
        )
        exportItem.target = self
        menu.addItem(exportItem)

        let clearItem = NSMenuItem(
            title: "Clear All History…",
            action: #selector(clearAllHistory),
            keyEquivalent: ""
        )
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let aboutItem = NSMenuItem(
            title: "About cmd",
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        aboutItem.target = self
        menu.addItem(aboutItem)

        let quitItem = NSMenuItem(
            title: "Quit cmd",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    @objc private func showHistory() {
        DiagnosticsLogbook.shared.actionInput(feature: "menu_bar", action: "show_history")
        // Capture the app that was active BEFORE we steal focus —
        // ClipBookWindowController needs it to re-activate the right target on paste.
        let previousApp = NSWorkspace.shared.frontmostApplication

        if let existing = clipBookController, existing.window?.isVisible == true {
            DiagnosticsLogbook.shared.actionProcess(
                feature: "menu_bar",
                action: "show_history",
                details: ["step": "focus_existing"]
            )
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DiagnosticsLogbook.shared.actionOutput(
                feature: "menu_bar",
                action: "show_history",
                details: ["success": "true", "window": "existing"]
            )
            return
        }

        DiagnosticsLogbook.shared.actionProcess(
            feature: "menu_bar",
            action: "show_history",
            details: ["step": "create_window", "previousApp": previousApp?.bundleIdentifier ?? "unknown"]
        )
        let controller = ClipBookWindowController(store: store, previousApp: previousApp)
        controller.onClose = { [weak self] in self?.clipBookController = nil }
        clipBookController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        DiagnosticsLogbook.shared.actionOutput(
            feature: "menu_bar",
            action: "show_history",
            details: ["success": "true", "window": "new"]
        )
    }

    /// Called whenever a new entry is added so the open history window stays current.
    public func notifyNewEntry() {
        clipBookController?.reloadData()
    }

    @objc private func showFeatures() {
        DiagnosticsLogbook.shared.actionInput(feature: "menu_bar", action: "show_features")
        if let existing = featuresWindow, existing.isVisible {
            DiagnosticsLogbook.shared.actionProcess(feature: "menu_bar", action: "show_features", details: ["step": "focus_existing"])
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DiagnosticsLogbook.shared.actionOutput(feature: "menu_bar", action: "show_features", details: ["success": "true", "window": "existing"])
            return
        }
        DiagnosticsLogbook.shared.actionProcess(feature: "menu_bar", action: "show_features", details: ["step": "create_window"])
        let hosting = NSHostingController(rootView: FeaturesView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "cmd — Features & Guide"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 620))
        window.center()
        featuresWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DiagnosticsLogbook.shared.actionOutput(feature: "menu_bar", action: "show_features", details: ["success": "true", "window": "new"])
    }

    @objc private func showSettings() {
        DiagnosticsLogbook.shared.actionInput(feature: "menu_bar", action: "show_settings")
        if let existing = settingsWindow, existing.isVisible {
            DiagnosticsLogbook.shared.actionProcess(feature: "menu_bar", action: "show_settings", details: ["step": "focus_existing"])
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            DiagnosticsLogbook.shared.actionOutput(feature: "menu_bar", action: "show_settings", details: ["success": "true", "window": "existing"])
            return
        }

        DiagnosticsLogbook.shared.actionProcess(feature: "menu_bar", action: "show_settings", details: ["step": "create_window"])
        let hosting = NSHostingController(rootView: SettingsView())
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "cmd Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 780, height: 560))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DiagnosticsLogbook.shared.actionOutput(feature: "menu_bar", action: "show_settings", details: ["success": "true", "window": "new"])
    }

    @objc private func openDiagnosticsLog() {
        DiagnosticsLogbook.shared.actionInput(feature: "menu_bar", action: "open_diagnostics_log")
        let url = DiagnosticsLogbook.shared.logFileURL
        DiagnosticsLogbook.shared.actionProcess(
            feature: "menu_bar",
            action: "open_diagnostics_log",
            details: ["step": "ensure_file"]
        )
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url, options: .atomic)
            DiagnosticsLogbook.shared.record("diagnostics_log_created", category: "diagnostics")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        DiagnosticsLogbook.shared.actionOutput(feature: "menu_bar", action: "open_diagnostics_log", details: ["success": "true"])
    }

    @objc private func openDailyErrorSummary() {
        DiagnosticsLogbook.shared.actionInput(feature: "menu_bar", action: "open_daily_error_summary")
        DiagnosticsLogbook.shared.writeDailyErrorSummary { url in
            DispatchQueue.main.async {
                guard let url else {
                    DiagnosticsLogbook.shared.actionOutput(
                        feature: "menu_bar",
                        action: "open_daily_error_summary",
                        details: ["success": "false", "reason": "summary_unavailable"]
                    )
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                DiagnosticsLogbook.shared.actionOutput(
                    feature: "menu_bar",
                    action: "open_daily_error_summary",
                    details: ["success": "true", "path": url.path]
                )
            }
        }
    }

    @objc private func exportDebugReport() {
        DiagnosticsLogbook.shared.actionInput(feature: "menu_bar", action: "export_debug_report")
        DiagnosticsLogbook.shared.exportDebugBundle(appState: diagnosticsSnapshotProvider()) { url in
            DispatchQueue.main.async {
                guard let url else {
                    DiagnosticsLogbook.shared.actionOutput(
                        feature: "menu_bar",
                        action: "export_debug_report",
                        details: ["success": "false", "reason": "export_failed"]
                    )
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([url])
                DiagnosticsLogbook.shared.actionOutput(
                    feature: "menu_bar",
                    action: "export_debug_report",
                    details: ["success": "true", "path": url.path]
                )
            }
        }
    }

    @objc private func clearAllHistory() {
        DiagnosticsLogbook.shared.actionInput(feature: "menu_bar", action: "clear_all_history")
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "Pinned items will not be removed. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "menu_bar",
                action: "clear_all_history",
                details: ["success": "false", "reason": "cancelled"]
            )
            return
        }
        DiagnosticsLogbook.shared.actionProcess(feature: "menu_bar", action: "clear_all_history", details: ["step": "purge_store"])
        do {
            try store.purgeExpired(before: .distantFuture)
        } catch {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "menu_bar",
                action: "clear_all_history",
                details: ["success": "false", "reason": "store_error"]
            )
            return
        }

        // Rebuild the menu so the Recent section reflects the cleared state.
        statusItem?.menu = buildMenu()
        DiagnosticsLogbook.shared.actionOutput(feature: "menu_bar", action: "clear_all_history", details: ["success": "true"])
    }

    @objc private func resumeCapture() {
        ClipLogSettings.shared.capturePausedUntil = 0
    }

    @objc private func pauseFor15Minutes() {
        ClipLogSettings.shared.capturePausedUntil = Date()
            .addingTimeInterval(15 * 60)
            .timeIntervalSinceReferenceDate
    }

    @objc private func pauseFor1Hour() {
        ClipLogSettings.shared.capturePausedUntil = Date()
            .addingTimeInterval(60 * 60)
            .timeIntervalSinceReferenceDate
    }

    @objc private func pauseIndefinitely() {
        ClipLogSettings.shared.capturePausedUntil = .greatestFiniteMagnitude
    }

    @objc private func openAccessibilitySettings() {
        // Trigger the system prompt so cmd is registered in the Accessibility
        // list, then jump straight to the pane.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility",
        ]
        for raw in urls {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    @objc private func copyRecent(_ sender: NSMenuItem) {
        guard let entry = sender.representedObject as? ClipEntry else { return }
        ClipPasteboardWriter.write(entry)
    }

    @objc private func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let alert = NSAlert()
        alert.messageText = "cmd"
        alert.informativeText = "Clipboard history for macOS.\nVersion \(version)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func recentTitle(for entry: ClipEntry) -> String {
        let preview = entry.previewText.replacingOccurrences(of: "\n", with: " ")
        let trimmed = preview.count > 42 ? String(preview.prefix(42)) + "…" : preview
        return trimmed.isEmpty ? entry.sourceAppName : "\(entry.sourceAppName) — \(trimmed)"
    }

    // MARK: - Helpers

    private func setButtonImage(symbolName: String) {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: symbolName
        )
        button.image?.isTemplate = true
    }
}

// MARK: - NSNotification names
// clipLogTapDegraded / clipLogTapRecovered are defined in ClipLogCore (EventTap.swift).
// Only ClipLog-specific names live here.

public extension Notification.Name {
    static let cmdClearAllHistory = Notification.Name("com.cmd.clearAllHistory")
}
