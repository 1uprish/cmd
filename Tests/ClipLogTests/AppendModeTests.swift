import AppKit
import XCTest
@testable import ClipLogCore

final class AppendModeTests: XCTestCase {
    private var previousString: String?

    override func setUp() {
        super.setUp()
        TestStorage.useTemporaryBase()
        previousString = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
    }

    override func tearDown() {
        TestStorage.resetBase()
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
        XCTAssertEqual(harness.waitForAppendItemCount(1, timeout: 1.5), 1)
        copy("beta")

        let entries = harness.waitForEntries(count: 1, timeout: 2.0)
        XCTAssertEqual(entries.count, 1)
        guard let entry = entries.first else { return }
        XCTAssertEqual(String(data: entry.contentData, encoding: .utf8), "alpha\nbeta")
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
    private var latestAppendSnapshot: AppendSessionSnapshot?
    private var appendObserver: NSObjectProtocol?

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
        appendObserver = NotificationCenter.default.addObserver(
            forName: .cmdAppendSessionChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  notification.userInfo?["watcher"] as? PasteboardWatcher === self.watcher,
                  let snapshot = notification.object as? AppendSessionSnapshot
            else {
                return
            }
            self.lock.withLock {
                self.latestAppendSnapshot = snapshot
            }
        }
        watcher.start()
    }

    deinit {
        if let appendObserver {
            NotificationCenter.default.removeObserver(appendObserver)
        }
    }

    func startAppend() {
        watcher.enableAppendMode(expiringAfter: timeout)
        _ = waitForAppendActive(timeout: 1.0)
    }

    func stop() {
        watcher.stop()
        if let appendObserver {
            NotificationCenter.default.removeObserver(appendObserver)
            self.appendObserver = nil
        }
    }

    func waitForAppendItemCount(_ count: Int, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let currentCount = lock.withLock { latestAppendSnapshot?.itemCount ?? 0 }
            if currentCount >= count { return currentCount }
            wait(0.05)
        }
        return lock.withLock { latestAppendSnapshot?.itemCount ?? 0 }
    }

    private func waitForAppendActive(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let isActive = lock.withLock { latestAppendSnapshot?.isActive == true }
            if isActive { return true }
            wait(0.05)
        }
        return lock.withLock { latestAppendSnapshot?.isActive == true }
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
