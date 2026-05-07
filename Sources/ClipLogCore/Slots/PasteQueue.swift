import CoreGraphics
import AppKit
import Foundation

// MARK: - PasteQueue
//
// Thread-safe FIFO queue for sequential clipboard paste.
// Populated by ClipBookWindowController when the user selects multiple cards
// and triggers "Queue Paste" (⌘⇧V / toolbar button).
//
// Each call to pasteNext():
//   1. Pops the first entry, writes it to NSPasteboard.general
//   2. Synthesises ⌘V at .cgSessionEventTap
//   3. Posts clipLogQueueDidAdvance with ["remaining": queue.count]
//
// The EventTap intercepts every ⌘V while the queue is non-empty and
// calls pasteNext() instead of its normal HUD logic.

public final class PasteQueue: @unchecked Sendable {

    public static let shared = PasteQueue()

    private var queue: [ClipEntry] = []
    private let lock = NSLock()

    private init() {}

    // MARK: - Public API

    /// Replace the current queue with `entries` (previously queued items are discarded).
    public func enqueue(_ entries: [ClipEntry]) {
        lock.withLock { queue = entries }
    }

    /// Paste the next entry in the queue.
    /// - Returns: `true` if an item was pasted, `false` if the queue was empty.
    @discardableResult
    public func pasteNext() -> Bool {
        let startedAt = Date()
        let queuedBefore = count
        DiagnosticsLogbook.shared.actionInput(
            feature: "paste_queue",
            action: "paste_next",
            details: [
                "queuedBefore": "\(queuedBefore)",
                "targetApp": Self.frontmostBundleIdentifier()
            ]
        )
        let entry: ClipEntry? = lock.withLock {
            guard !queue.isEmpty else { return nil }
            return queue.removeFirst()
        }
        guard let entry else {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "paste_queue",
                action: "paste_next",
                details: [
                    "success": "false",
                    "reason": "empty",
                    "queuedBefore": "\(queuedBefore)"
                ]
            )
            return false
        }

        DiagnosticsLogbook.shared.record(
            "paste_requested",
            category: "interaction",
            details: [
                "source": "queue",
                "entryType": entry.contentType.rawValue,
                "entrySourceApp": entry.sourceBundleID,
                "targetApp": Self.frontmostBundleIdentifier(),
                "remainingBeforePaste": "\(count)"
            ]
        )
        DiagnosticsLogbook.shared.actionProcess(
            feature: "paste_queue",
            action: "paste_next",
            details: [
                "step": "write_pasteboard",
                "entryType": entry.contentType.rawValue,
                "entrySourceApp": entry.sourceBundleID
            ]
        )
        ClipPasteboardWriter.write(entry)
        DiagnosticsLogbook.shared.actionProcess(
            feature: "paste_queue",
            action: "paste_next",
            details: ["step": "synthesize_cmd_v"]
        )
        synthesiseCmdV()

        let remaining = count
        NotificationCenter.default.post(
            name: .clipLogQueueDidAdvance,
            object: nil,
            userInfo: ["remaining": remaining]
        )
        DiagnosticsLogbook.shared.actionOutput(
            feature: "paste_queue",
            action: "paste_next",
            details: [
                "success": "true",
                "remaining": "\(remaining)",
                "durationMs": "\(Self.milliseconds(since: startedAt))"
            ]
        )
        return true
    }

    public var count: Int {
        lock.withLock { queue.count }
    }

    public var isEmpty: Bool {
        lock.withLock { queue.isEmpty }
    }

    // MARK: - ⌘V synthesis

    // Post at .cgSessionEventTap to stay below our own HID tap and avoid
    // re-entering the event tap callback (which would cause a double-paste loop).
    private func synthesiseCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09

        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgSessionEventTap)

        DiagnosticsLogbook.shared.record(
            "synthetic_paste_posted",
            category: "interaction",
            details: ["targetApp": Self.frontmostBundleIdentifier()]
        )
    }

    private static func frontmostBundleIdentifier() -> String {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - Notification name

public extension Notification.Name {
    static let clipLogQueueDidAdvance = Notification.Name("com.cmd.queueDidAdvance")
}
