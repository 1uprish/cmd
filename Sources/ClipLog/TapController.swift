import AppKit
import Combine
import ClipLogCore

final class TapController {
    private let eventTap = ClipLogEventTap()
    private let pasteboardWatcher = PasteboardWatcher()
    private var clipStore: ClipStore?
    private var slotManager: SlotManager?
    private var menuBarController: MenuBarController?
    private var sensitivePurgeTimer: Timer?
    private var settingsCancellables = Set<AnyCancellable>()

    // Called immediately on launch — shows menu bar, starts storage + watcher.
    // Does NOT require Accessibility permission.
    func startUI() {
        do {
            let store = try ClipStore()
            let slots = SlotManager(store: store)
            self.clipStore = store
            self.slotManager = slots
            pasteboardWatcher.store = store

            // Apply user settings to live objects.
            let settings = ClipLogSettings.shared
            pasteboardWatcher.updateUserExcludedBundles(Set(settings.userExcludedBundles))
            pasteboardWatcher.updateImageOCREnabled(false)
            eventTap.updateHoldThreshold(TimeInterval(settings.holdThresholdMs) / 1000.0)
            observeSettings(settings)

            purgeExpiredHistoryIfNeeded(in: store, retentionDays: settings.retentionDays)
            purgeExpiredSensitiveItems(in: store)

            // Build MenuBarController first so onNewEntry can weakly reference it.
            let mbc = MenuBarController(store: store, slots: slots)
            menuBarController = mbc
            mbc.setup()
            AppendSessionPanel.shared.start()

            // Single onNewEntry closure — ingest into slots AND refresh open history.
            pasteboardWatcher.onNewEntry = { [weak self, weak slots, weak mbc] entry in
                slots?.ingest(entry)
                mbc?.notifyNewEntry()
                if let store = self?.clipStore {
                    self?.purgeExpiredSensitiveItems(in: store)
                }
            }
            pasteboardWatcher.start()
            startSensitivePurgeTimer(store: store)

            // HUD trigger: show floating panel with recent clipboard entries.
            eventTap.onHUDTrigger = { [weak slots] sessionID in
                HUDPanel.shared.show(
                    sessionID: sessionID,
                    slots: slots?.recentEntries(limit: 20) ?? []
                )
            }

            // Give HUDPanel a reference to SlotManager so slot selection actually pastes.
            HUDPanel.shared.slotManager = slots

            // Any dismiss path (outside click, sleep/space change, drag) must notify
            // the event tap, otherwise the tap stays stuck in .hudActive and swallows
            // every keystroke until the app is restarted.
            HUDPanel.shared.onDismiss = { [weak self] sessionID in
                self?.eventTap.hudDidDismiss(sessionID: sessionID)
            }

            // Safety net: lets the tap self-heal if hudDidDismiss was never called.
            // Called on tapQueue; panel.isVisible is thread-safe (read-only property).
            eventTap.isHUDActuallyVisible = { HUDPanel.shared.isVisible }

            // HUD key interactions — handled at HID level so they fire even
            // though the HUD is a nonactivatingPanel.
            eventTap.onHUDDismiss = { sessionID in
                HUDPanel.shared.dismiss(sessionID: sessionID)
            }
            eventTap.onHUDEscape = { sessionID in
                HUDPanel.shared.handleEscape(sessionID: sessionID)
            }
            eventTap.onHUDMoveSelection = { delta in
                HUDPanel.shared.moveSelection(delta: delta)
            }
            eventTap.onHUDConfirmSelection = { sessionID in
                HUDPanel.shared.confirmSelection(sessionID: sessionID)
            }
            eventTap.onHUDCharFilter = { ch in
                HUDPanel.shared.applyFilter(character: ch)
            }
            eventTap.onHUDBackspace = {
                HUDPanel.shared.deleteFilterCharacter()
            }

            // Double-tap Command toggles append collection. While on,
            // copied text is continuously merged into one paste-ready payload.
            let watcher = pasteboardWatcher
            eventTap.onAppendGesture = {
                watcher.enableAppendMode()
            }

            // ⌘V while paste queue is non-empty → advance the queue instead of showing HUD.
            eventTap.onQueuedPaste = {
                PasteQueue.shared.pasteNext()
            }
        } catch {
            DiagnosticsLogbook.shared.record(
                "startup_failed",
                category: "lifecycle",
                details: ["error": String(describing: error)]
            )
            NSAlert(error: error).runModal()
        }
    }

    // Called once Accessibility permission is confirmed.
    // Throws so AppDelegate can detect tap-creation failure (e.g. stale TCC entry after rebuild).
    func startEventTap() throws {
        eventTap.updateHoldThreshold(TimeInterval(ClipLogSettings.shared.holdThresholdMs) / 1000.0)
        try eventTap.start()
        menuBarController?.setAccessibilityGranted(true)
    }

    func stop() {
        sensitivePurgeTimer?.invalidate()
        sensitivePurgeTimer = nil
        settingsCancellables.removeAll()
        eventTap.stop()
        pasteboardWatcher.stop()
    }

    private func observeSettings(_ settings: ClipLogSettings) {
        settingsCancellables.removeAll()

        settings.$holdThresholdMs
            .removeDuplicates()
            .sink { [weak self] milliseconds in
                self?.eventTap.updateHoldThreshold(TimeInterval(milliseconds) / 1000.0)
            }
            .store(in: &settingsCancellables)

        settings.$userExcludedBundles
            .removeDuplicates()
            .sink { [weak self] bundles in
                self?.pasteboardWatcher.updateUserExcludedBundles(Set(bundles))
            }
            .store(in: &settingsCancellables)

        settings.$retentionDays
            .removeDuplicates()
            .sink { [weak self] days in
                guard let store = self?.clipStore else { return }
                self?.purgeExpiredHistoryIfNeeded(in: store, retentionDays: days)
            }
            .store(in: &settingsCancellables)
    }

    private func purgeExpiredHistoryIfNeeded(in store: ClipStore, retentionDays: Int) {
        guard retentionDays > 0,
              let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())
        else { return }
        try? store.purgeExpired(before: cutoff)
    }

    private func startSensitivePurgeTimer(store: ClipStore) {
        sensitivePurgeTimer?.invalidate()
        sensitivePurgeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self, weak store] _ in
            guard let store else { return }
            self?.purgeExpiredSensitiveItems(in: store)
        }
    }

    private func purgeExpiredSensitiveItems(in store: ClipStore) {
        let minutes = ClipLogSettings.shared.sensitiveRetentionMinutes
        guard minutes > 0,
              let cutoff = Calendar.current.date(byAdding: .minute, value: -minutes, to: Date())
        else { return }
        try? store.purgeExpiredSensitive(before: cutoff)
    }
}
