import AppKit
import XCTest
@testable import ClipLogCore

final class AppendModeTests: XCTestCase {
    private var previousString: String?

    override func setUp() {
        super.setUp()
        previousString = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        if let previousString {
            NSPasteboard.general.setString(previousString, forType: .string)
        }
        previousString = nil
        super.tearDown()
    }

    func test_appendModeMergesTextIntoSingleEntry() throws {
        let harness = AppendHarness(timeout: 0.6)
        defer { harness.stop() }

        harness.startAppend()
        copy("alpha")
        harness.wait(0.45)
        copy("beta")

        let entries = harness.waitForEntries(count: 1, timeout: 2.0)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(String(data: entries[0].contentData, encoding: .utf8), "alpha\nbeta")
    }

    func test_appendModeDoesNotSelfFeedDuplicateCopies() throws {
        let harness = AppendHarness(timeout: 0.6)
        defer { harness.stop() }

        harness.startAppend()
        for _ in 0..<6 {
            copy("same")
            harness.wait(0.12)
        }

        let entries = harness.waitForEntries(count: 1, timeout: 2.0)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(String(data: entries[0].contentData, encoding: .utf8), "same")
    }

    func test_stopWhileAppendActiveDoesNotCommitLater() throws {
        let harness = AppendHarness(timeout: 0.4)

        harness.startAppend()
        copy("will-not-commit")
        harness.wait(0.25)
        harness.stop()
        harness.wait(0.8)

        XCTAssertTrue(harness.entries.isEmpty)
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

private final class AppendHarness {
    private let watcher = PasteboardWatcher()
    private let lock = NSLock()
    private let timeout: TimeInterval
    private var capturedEntries: [ClipEntry] = []

    var entries: [ClipEntry] {
        lock.withLock { capturedEntries }
    }

    init(timeout: TimeInterval) {
        self.timeout = timeout
        watcher.onNewEntry = { [weak self] entry in
            self?.lock.withLock {
                self?.capturedEntries.append(entry)
            }
        }
        watcher.start()
    }

    func startAppend() {
        watcher.enableAppendMode(expiringAfter: timeout)
        wait(0.1)
    }

    func stop() {
        watcher.stop()
    }

    func waitForEntries(count: Int, timeout: TimeInterval) -> [ClipEntry] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let current = entries
            if current.count >= count { return current }
            wait(0.05)
        }
        return entries
    }

    func wait(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
