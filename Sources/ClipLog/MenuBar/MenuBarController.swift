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
        // Capture the app that was active BEFORE we steal focus —
        // ClipBookWindowController needs it to re-activate the right target on paste.
        let previousApp = NSWorkspace.shared.frontmostApplication

        if let existing = clipBookController, existing.window?.isVisible == true {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = ClipBookWindowController(store: store, previousApp: previousApp)
        controller.onClose = { [weak self] in self?.clipBookController = nil }
        clipBookController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Called whenever a new entry is added so the open history window stays current.
    public func notifyNewEntry() {
        clipBookController?.reloadData()
    }

    @objc private func showFeatures() {
        if let existing = featuresWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: FeaturesView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "cmd — Features & Guide"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 640, height: 620))
        window.center()
        featuresWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showOnboarding() {
        NotificationCenter.default.post(name: .cmdShowOnboarding, object: nil)
    }

    @objc private func showSettings() {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

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
    }

    @objc private func openDiagnosticsLog() {
        let url = DiagnosticsLogbook.shared.logFileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data().write(to: url, options: .atomic)
            DiagnosticsLogbook.shared.record("diagnostics_log_created", category: "diagnostics")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func clearAllHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear all clipboard history?"
        alert.informativeText = "Pinned items will not be removed. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? store.purgeExpired(before: .distantFuture)

        // Rebuild the menu so the Recent section reflects the cleared state.
        statusItem?.menu = buildMenu()
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
