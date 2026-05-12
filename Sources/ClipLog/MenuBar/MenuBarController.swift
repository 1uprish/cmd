import AppKit
import SwiftUI
import ClipLogCore

public final class MenuBarController: NSObject {

    private let store: ClipStore
    private let slotManager: SlotManager
    private let cursorPiPController: CursorPiPController
    private let diagnosticsSnapshotProvider: () -> [String: String]

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var featuresWindow: NSWindow?
    private var clipBookController: ClipBookWindowController?

    private var degradedObserver:  (any NSObjectProtocol)?
    private var recoveredObserver: (any NSObjectProtocol)?
    private var clearAllObserver:  (any NSObjectProtocol)?

    init(
        store: ClipStore,
        slots: SlotManager,
        cursorPiPController: CursorPiPController,
        diagnosticsSnapshotProvider: @escaping () -> [String: String]
    ) {
        self.store = store
        self.slotManager = slots
        self.cursorPiPController = cursorPiPController
        self.diagnosticsSnapshotProvider = diagnosticsSnapshotProvider
    }

    public func setup() {
        DiagnosticsLogbook.shared.actionInput(feature: "menu_bar", action: "setup")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        if let button = item.button {
            button.image = NSImage(
                systemSymbolName: "command",
                accessibilityDescription: "cmd"
            )
            button.image?.isTemplate = true
        }
        cursorPiPController.anchorRectProvider = { [weak item] in
            guard let button = item?.button,
                  let window = button.window
            else { return nil }
            return window.convertToScreen(button.bounds)
        }

        item.menu = buildMenu()
        DiagnosticsLogbook.shared.actionProcess(feature: "menu_bar", action: "setup", details: ["step": "menu_built"])

        let nc = NotificationCenter.default

        degradedObserver = nc.addObserver(
            forName: .clipLogTapDegraded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setButtonImage(symbolName: "exclamationmark.triangle")
        }

        recoveredObserver = nc.addObserver(
            forName: .clipLogTapRecovered,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setButtonImage(symbolName: "command")
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

    // Shows a warning triangle until Accessibility permission is granted,
    // then switches back to the command logo.
    public func setAccessibilityGranted(_ granted: Bool) {
        DispatchQueue.main.async {
            self.setButtonImage(symbolName: granted ? "command" : "exclamationmark.triangle.fill")
        }
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

        let historyItem = NSMenuItem(
            title: "Show History…",
            action: #selector(showHistory),
            keyEquivalent: ""
        )
        historyItem.target = self
        menu.addItem(historyItem)

        let featuresItem = NSMenuItem(
            title: "Features & Guide",
            action: #selector(showFeatures),
            keyEquivalent: ""
        )
        featuresItem.target = self
        menu.addItem(featuresItem)

        menu.addItem(.separator())

        addCursorPiPItems(to: menu)

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

        let quitItem = NSMenuItem(
            title: "Quit cmd",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Actions

    private func addCursorPiPItems(to menu: NSMenu) {
        let settings = ClipLogSettings.shared
        let title = settings.cursorPiPEnabled ? "CursorPiP Beta" : "CursorPiP Beta Off"
        let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let launchCurrentItem = NSMenuItem(
            title: "Launch Current Video PiP",
            action: #selector(openCursorPiPFromActiveBrowser),
            keyEquivalent: ""
        )
        launchCurrentItem.target = self
        launchCurrentItem.isEnabled = settings.cursorPiPEnabled
        menu.addItem(launchCurrentItem)

        let openClipboardItem = NSMenuItem(
            title: "Open Clipboard PiP",
            action: #selector(openCursorPiPFromClipboard),
            keyEquivalent: ""
        )
        openClipboardItem.target = self
        openClipboardItem.isEnabled = settings.cursorPiPEnabled
        menu.addItem(openClipboardItem)

        let openURLItem = NSMenuItem(
            title: "Open Video URL...",
            action: #selector(openCursorPiPURL),
            keyEquivalent: ""
        )
        openURLItem.target = self
        openURLItem.isEnabled = settings.cursorPiPEnabled
        menu.addItem(openURLItem)

        let pinItem = NSMenuItem(
            title: "Pin Position",
            action: #selector(toggleCursorPiPPin),
            keyEquivalent: ""
        )
        pinItem.target = self
        pinItem.state = settings.cursorPiPPinned ? .on : .off
        pinItem.isEnabled = settings.cursorPiPEnabled
        menu.addItem(pinItem)

        let sizeMenu = NSMenu()
        for preset in CursorPiPSizePreset.allCases {
            let item = NSMenuItem(title: preset.rawValue.capitalized, action: #selector(setCursorPiPSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.rawValue
            sizeMenu.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        sizeItem.isEnabled = settings.cursorPiPEnabled
        menu.addItem(sizeItem)

        let closeItem = NSMenuItem(
            title: "Close CursorPiP",
            action: #selector(closeCursorPiP),
            keyEquivalent: ""
        )
        closeItem.target = self
        closeItem.isEnabled = settings.cursorPiPEnabled && cursorPiPController.isVisible
        menu.addItem(closeItem)
    }

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

    @objc private func openCursorPiPFromClipboard() {
        DiagnosticsLogbook.shared.actionInput(feature: "cursor_pip", action: "open_clipboard")
        cursorPiPController.openFromPasteboard()
        statusItem?.menu = buildMenu()
        DiagnosticsLogbook.shared.actionOutput(feature: "cursor_pip", action: "open_clipboard", details: ["success": "true"])
    }

    @objc private func openCursorPiPFromActiveBrowser() {
        DiagnosticsLogbook.shared.actionInput(feature: "cursor_pip", action: "open_active_browser")
        cursorPiPController.openFromActiveBrowser()
        statusItem?.menu = buildMenu()
        DiagnosticsLogbook.shared.actionOutput(feature: "cursor_pip", action: "open_active_browser", details: ["success": "true"])
    }

    @objc private func openCursorPiPURL() {
        DiagnosticsLogbook.shared.actionInput(feature: "cursor_pip", action: "open_url")
        cursorPiPController.promptForURL()
        statusItem?.menu = buildMenu()
        DiagnosticsLogbook.shared.actionOutput(feature: "cursor_pip", action: "open_url", details: ["success": "true"])
    }

    @objc private func toggleCursorPiPFollow() {
        cursorPiPController.toggleFollowing()
        statusItem?.menu = buildMenu()
    }

    @objc private func toggleCursorPiPPin() {
        cursorPiPController.togglePinned()
        statusItem?.menu = buildMenu()
    }

    @objc private func setCursorPiPSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preset = CursorPiPSizePreset(rawValue: raw)
        else { return }
        cursorPiPController.applySizePreset(preset)
        statusItem?.menu = buildMenu()
    }

    @objc private func closeCursorPiP() {
        cursorPiPController.hide()
        statusItem?.menu = buildMenu()
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

    @objc private func showOnboarding() {
        DiagnosticsLogbook.shared.actionInput(feature: "menu_bar", action: "show_onboarding")
        NotificationCenter.default.post(name: .cmdShowOnboarding, object: nil)
        DiagnosticsLogbook.shared.actionOutput(feature: "menu_bar", action: "show_onboarding", details: ["success": "true"])
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
        window.setContentSize(NSSize(width: 520, height: 700))
        window.minSize = NSSize(width: 480, height: 500)
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
    static let cmdShowOnboarding = Notification.Name("com.cmd.showOnboarding")
}
