import CoreGraphics
import AppKit
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
        let startedAt = Date()
        let details = singleEntryDetails(source: "slot_entry", entry: entry)
        DiagnosticsLogbook.shared.actionInput(feature: "paste", action: "slot_entry", details: details)
        logPasteAttempt(source: "slot_entry", entry: entry)
        DiagnosticsLogbook.shared.actionProcess(
            feature: "paste",
            action: "slot_entry",
            details: details.merging(["step": "write_pasteboard"], uniquingKeysWith: { _, new in new })
        )
        ClipPasteboardWriter.write(entry)
        DiagnosticsLogbook.shared.actionProcess(
            feature: "paste",
            action: "slot_entry",
            details: details.merging(["step": "synthesize_cmd_v"], uniquingKeysWith: { _, new in new })
        )
        synthesizeCmdV()
        DiagnosticsLogbook.shared.actionOutput(
            feature: "paste",
            action: "slot_entry",
            details: details.merging([
                "success": "true",
                "durationMs": "\(Self.milliseconds(since: startedAt))"
            ], uniquingKeysWith: { _, new in new })
        )
        return true
    }

    @discardableResult
    public func paste(entries: [ClipEntry]) -> Bool {
        guard !entries.isEmpty else {
            let details = ["source": "slot_entries", "entryCount": "0"]
            DiagnosticsLogbook.shared.actionInput(feature: "paste", action: "slot_entries", details: details)
            DiagnosticsLogbook.shared.actionOutput(
                feature: "paste",
                action: "slot_entries",
                details: details.merging(["success": "false", "reason": "empty"], uniquingKeysWith: { _, new in new })
            )
            return false
        }
        if entries.count == 1 {
            return paste(entry: entries[0])
        }
        let startedAt = Date()
        let details = batchEntryDetails(source: "slot_entries", entries: entries)
        DiagnosticsLogbook.shared.actionInput(feature: "paste", action: "slot_entries", details: details)
        logBatchPasteAttempt(source: "slot_entries", entries: entries)
        DiagnosticsLogbook.shared.actionProcess(
            feature: "paste",
            action: "slot_entries",
            details: details.merging(["step": "write_pasteboard"], uniquingKeysWith: { _, new in new })
        )
        ClipPasteboardWriter.write(entries)
        DiagnosticsLogbook.shared.actionProcess(
            feature: "paste",
            action: "slot_entries",
            details: details.merging(["step": "synthesize_cmd_v"], uniquingKeysWith: { _, new in new })
        )
        synthesizeCmdV()
        DiagnosticsLogbook.shared.actionOutput(
            feature: "paste",
            action: "slot_entries",
            details: details.merging([
                "success": "true",
                "durationMs": "\(Self.milliseconds(since: startedAt))"
            ], uniquingKeysWith: { _, new in new })
        )
        return true
    }

    /// Copy a specific entry into the system pasteboard without synthesising paste.
    @discardableResult
    public func copy(entry: ClipEntry) -> Bool {
        let startedAt = Date()
        let details = singleEntryDetails(source: "slot_entry", entry: entry)
        DiagnosticsLogbook.shared.actionInput(feature: "copy", action: "slot_entry", details: details)
        DiagnosticsLogbook.shared.record(
            "copy_requested",
            category: "interaction",
            details: [
                "entryType": entry.contentType.rawValue,
                "sourceApp": entry.sourceBundleID
            ]
        )
        DiagnosticsLogbook.shared.actionProcess(
            feature: "copy",
            action: "slot_entry",
            details: details.merging(["step": "write_pasteboard"], uniquingKeysWith: { _, new in new })
        )
        ClipPasteboardWriter.write(entry)
        DiagnosticsLogbook.shared.actionOutput(
            feature: "copy",
            action: "slot_entry",
            details: details.merging([
                "success": "true",
                "durationMs": "\(Self.milliseconds(since: startedAt))"
            ], uniquingKeysWith: { _, new in new })
        )
        return true
    }

    @discardableResult
    public func copy(entries: [ClipEntry]) -> Bool {
        guard !entries.isEmpty else {
            let details = ["source": "slot_entries", "entryCount": "0"]
            DiagnosticsLogbook.shared.actionInput(feature: "copy", action: "slot_entries", details: details)
            DiagnosticsLogbook.shared.actionOutput(
                feature: "copy",
                action: "slot_entries",
                details: details.merging(["success": "false", "reason": "empty"], uniquingKeysWith: { _, new in new })
            )
            return false
        }
        if entries.count == 1 {
            return copy(entry: entries[0])
        }
        let startedAt = Date()
        let details = batchEntryDetails(source: "slot_entries", entries: entries)
        DiagnosticsLogbook.shared.actionInput(feature: "copy", action: "slot_entries", details: details)
        DiagnosticsLogbook.shared.record(
            "copy_requested",
            category: "interaction",
            details: [
                "entryType": "multiple",
                "entryCount": "\(entries.count)",
                "entryTypes": entries.map(\.contentType.rawValue).joined(separator: ",")
            ]
        )
        DiagnosticsLogbook.shared.actionProcess(
            feature: "copy",
            action: "slot_entries",
            details: details.merging(["step": "write_pasteboard"], uniquingKeysWith: { _, new in new })
        )
        ClipPasteboardWriter.write(entries)
        DiagnosticsLogbook.shared.actionOutput(
            feature: "copy",
            action: "slot_entries",
            details: details.merging([
                "success": "true",
                "durationMs": "\(Self.milliseconds(since: startedAt))"
            ], uniquingKeysWith: { _, new in new })
        )
        return true
    }

    @discardableResult
    public func paste(slotIndex: Int) -> Bool {
        let slots = currentSlots
        let inputDetails = [
            "source": "slot_index",
            "slotIndex": "\(slotIndex)",
            "slotCount": "\(slots.count)"
        ]
        DiagnosticsLogbook.shared.actionInput(feature: "paste", action: "slot_index", details: inputDetails)
        guard slotIndex >= 0, slotIndex < slots.count else {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "paste",
                action: "slot_index",
                details: inputDetails.merging(["success": "false", "reason": "out_of_range"], uniquingKeysWith: { _, new in new })
            )
            return false
        }
        let startedAt = Date()
        let entry = slots[slotIndex]
        let details = singleEntryDetails(source: "slot_index", entry: entry)
            .merging(inputDetails, uniquingKeysWith: { current, _ in current })
        logPasteAttempt(source: "slot_index", entry: entry)
        DiagnosticsLogbook.shared.actionProcess(
            feature: "paste",
            action: "slot_index",
            details: details.merging(["step": "write_pasteboard"], uniquingKeysWith: { _, new in new })
        )
        ClipPasteboardWriter.write(entry)
        DiagnosticsLogbook.shared.actionProcess(
            feature: "paste",
            action: "slot_index",
            details: details.merging(["step": "synthesize_cmd_v"], uniquingKeysWith: { _, new in new })
        )
        synthesizeCmdV()
        DiagnosticsLogbook.shared.actionOutput(
            feature: "paste",
            action: "slot_index",
            details: details.merging([
                "success": "true",
                "durationMs": "\(Self.milliseconds(since: startedAt))"
            ], uniquingKeysWith: { _, new in new })
        )
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

        DiagnosticsLogbook.shared.record(
            "synthetic_paste_posted",
            category: "interaction",
            details: ["targetApp": Self.frontmostBundleIdentifier()]
        )
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }

    private func logPasteAttempt(source: String, entry: ClipEntry) {
        DiagnosticsLogbook.shared.record(
            "paste_requested",
            category: "interaction",
            details: [
                "source": source,
                "entryType": entry.contentType.rawValue,
                "entrySourceApp": entry.sourceBundleID,
                "targetApp": Self.frontmostBundleIdentifier()
            ]
        )
    }

    private func logBatchPasteAttempt(source: String, entries: [ClipEntry]) {
        DiagnosticsLogbook.shared.record(
            "paste_requested",
            category: "interaction",
            details: [
                "source": source,
                "entryType": "multiple",
                "entryCount": "\(entries.count)",
                "entryTypes": entries.map(\.contentType.rawValue).joined(separator: ","),
                "targetApp": Self.frontmostBundleIdentifier()
            ]
        )
    }

    private func singleEntryDetails(source: String, entry: ClipEntry) -> [String: String] {
        [
            "source": source,
            "entryType": entry.contentType.rawValue,
            "entrySourceApp": entry.sourceBundleID,
            "targetApp": Self.frontmostBundleIdentifier()
        ]
    }

    private func batchEntryDetails(source: String, entries: [ClipEntry]) -> [String: String] {
        [
            "source": source,
            "entryType": "multiple",
            "entryCount": "\(entries.count)",
            "entryTypes": entries.map(\.contentType.rawValue).joined(separator: ","),
            "targetApp": Self.frontmostBundleIdentifier()
        ]
    }

    private static func frontmostBundleIdentifier() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    }
}
