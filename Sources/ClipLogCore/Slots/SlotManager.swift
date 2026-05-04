import CoreGraphics
import Foundation

public final class SlotManager: @unchecked Sendable {

    private let store: ClipStore
    private let queue = DispatchQueue(label: "com.cmd.SlotManager", qos: .userInteractive)
    private var _slots: [ClipEntry] = []

    public init(store: ClipStore) {
        self.store = store
        _slots = (try? store.recent(limit: 5)) ?? []
    }

    public func ingest(_ entry: ClipEntry) {
        queue.sync {
            let startedAt = Date()
            let insertStartedAt = Date()
            try? store.insert(entry)
            let insertMs = Self.milliseconds(since: insertStartedAt)
            let recentStartedAt = Date()
            _slots = (try? store.recent(limit: 5)) ?? _slots
            let recentMs = Self.milliseconds(since: recentStartedAt)
            let totalMs = Self.milliseconds(since: startedAt)
            if totalMs >= 250 {
                DiagnosticsLogbook.shared.record(
                    "slow_slot_ingest",
                    category: "performance",
                    details: [
                        "durationMs": "\(totalMs)",
                        "insertMs": "\(insertMs)",
                        "recentMs": "\(recentMs)",
                        "entryType": entry.contentType.rawValue
                    ]
                )
            }
        }
    }

    /// Top 5 slots (used by paste-by-index).
    public var currentSlots: [ClipEntry] {
        queue.sync { _slots }
    }

    /// Up to `limit` recent entries — used by the scrollable HUD list.
    public func recentEntries(limit: Int = 20) -> [ClipEntry] {
        queue.sync { (try? store.recent(limit: limit)) ?? _slots }
    }

    /// Paste a specific entry directly (safe: not affected by concurrent slot shifts).
    @discardableResult
    public func paste(entry: ClipEntry) -> Bool {
        ClipPasteboardWriter.write(entry)
        synthesizeCmdV()
        return true
    }

    /// Copy a specific entry into the system pasteboard without synthesising paste.
    @discardableResult
    public func copy(entry: ClipEntry) -> Bool {
        ClipPasteboardWriter.write(entry)
        return true
    }

    @discardableResult
    public func paste(slotIndex: Int) -> Bool {
        let slots = currentSlots
        guard slotIndex >= 0, slotIndex < slots.count else { return false }
        ClipPasteboardWriter.write(slots[slotIndex])
        synthesizeCmdV()
        return true
    }

    // CGSessionEventTap rather than cghidEventTap: posting at the HID level
    // would re-enter our own event tap and cause a double-paste loop.
    private func synthesizeCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cgSessionEventTap)
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}
