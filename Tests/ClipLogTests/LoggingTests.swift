import AppKit
import XCTest
@testable import ClipLogCore

/// Asserts the load-bearing telemetry actually fires. Telemetry is the only
/// way these flows can be tracked in the field, so the logbook gets the same
/// treatment as behavior: the shared logbook drains synchronously in-process,
/// which flushes the writer queue and makes assertions deterministic.
///
/// Out of scope: EventTap key handling (needs a HID tap + Accessibility) and
/// HUD panels (app target, not importable here). The pure tap state machine
/// is covered by StateMachineTests.
final class LoggingTests: XCTestCase {
    private var previousString: String?

    override func setUp() {
        super.setUp()
        previousString = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        _ = DiagnosticsLogbook.shared.drainEntriesForTests()
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        if let previousString {
            NSPasteboard.general.setString(previousString, forType: .string)
        }
        previousString = nil
        super.tearDown()
    }

    func test_sinkCapturesRecords() {
        DiagnosticsLogbook.shared.record("test_probe", category: "test", details: ["key": "value"])

        let entries = DiagnosticsLogbook.shared.drainEntriesForTests()
        XCTAssertTrue(
            entries.contains {
                $0.event == "test_probe" && $0.category == "test" && $0.details["key"] == "value"
            }
        )
    }

    func test_appendLifecycleEmitsTelemetry() {
        let watcher = PasteboardWatcher()
        watcher.start()
        defer { watcher.stop() }

        watcher.enableAppendMode(expiringAfter: 30)
        var entries = collectUntil(timeout: 2.0) { entries in
            entries.contains { $0.event == "append_started" }
        }
        XCTAssertTrue(
            entries.contains { $0.event == "append_started" },
            "expected append_started after enableAppendMode"
        )
        XCTAssertTrue(
            entries.contains {
                $0.event == "feature_action_output"
                    && $0.details["action"] == "start_session"
                    && $0.details["success"] == "true"
            },
            "expected successful start_session output"
        )

        watcher.endAppendMode(reason: "test")
        entries = collectUntil(timeout: 2.0) { entries in
            entries.contains {
                $0.event == "feature_action_output"
                    && $0.details["action"] == "end_session"
                    && $0.details["reason"] == "test"
            }
        }
        XCTAssertTrue(
            entries.contains {
                $0.event == "feature_action_output"
                    && $0.details["action"] == "end_session"
                    && $0.details["reason"] == "test"
                    && $0.details["success"] == "true"
            },
            "expected successful end_session output"
        )
    }

    func test_appendMergeEmitsTelemetry() {
        let watcher = PasteboardWatcher()
        watcher.onNewEntry = { _ in }
        watcher.start()
        defer { watcher.stop() }

        watcher.enableAppendMode(expiringAfter: 30)
        _ = collectUntil(timeout: 2.0) { entries in
            entries.contains { $0.event == "append_started" }
        }
        _ = DiagnosticsLogbook.shared.drainEntriesForTests()

        copy("telemetry-alpha")
        let entries = collectUntil(timeout: 3.0) { entries in
            entries.contains {
                $0.event == "feature_action_output"
                    && $0.details["action"] == "merge_clips"
                    && $0.details["success"] == "true"
            }
        }
        XCTAssertTrue(
            entries.contains {
                $0.event == "feature_action_output"
                    && $0.details["action"] == "merge_clips"
                    && $0.details["success"] == "true"
            },
            "expected successful merge_clips output for the copied text"
        )
    }

    func test_copyEmitsTelemetry() throws {
        let store = try ClipStore.makeInMemory()
        let slots = SlotManager(store: store)

        slots.copy(entry: .fixture(text: "telemetry-copy"))

        let entries = collectUntil(timeout: 2.0) { entries in
            entries.contains { $0.event == "copy_requested" }
        }
        XCTAssertTrue(
            entries.contains { $0.event == "copy_requested" },
            "expected copy_requested record"
        )
        XCTAssertTrue(
            entries.contains {
                $0.event == "feature_action_output"
                    && $0.details["action"] == "slot_entry"
                    && $0.details["success"] == "true"
            },
            "expected successful slot_entry copy output"
        )
    }

    // MARK: - Helpers

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// Collects drained entries until `satisfied` passes or the deadline
    /// passes. Accumulates (never drops) so later assertions can check for
    /// entries that arrived alongside the awaited one.
    @discardableResult
    private func collectUntil(
        timeout: TimeInterval,
        satisfied: ([DiagnosticsLogbook.Entry]) -> Bool
    ) -> [DiagnosticsLogbook.Entry] {
        var collected: [DiagnosticsLogbook.Entry] = []
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            collected.append(contentsOf: DiagnosticsLogbook.shared.drainEntriesForTests())
            if satisfied(collected) { return collected }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        collected.append(contentsOf: DiagnosticsLogbook.shared.drainEntriesForTests())
        return collected
    }
}
