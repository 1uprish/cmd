import AppKit
import SwiftUI
import ClipLogCore

public final class MenuBarController: NSObject {

    private let store: ClipStore
    private let slotManager: SlotManager

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var featuresWindow: NSWindow?
    private var clipBookController: ClipBookWindowController?

    private var degradedObserver:  (any NSObjectProtocol)?
    private var recoveredObserver: (any NSObjectProtocol)?
    private var clearAllObserver:  (any NSObjectProtocol)?

    public init(store: ClipStore, slots: SlotManager) {
        self.store = store
        self.slotManager = slots
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
