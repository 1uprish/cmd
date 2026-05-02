import XCTest
import CryptoKit
import GRDB
@testable import ClipLogCore

final class ClipStoreTests: XCTestCase {

    private var store: ClipStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try .makeInMemory()
    }

    override func tearDown() {
        store = nil
        super.tearDown()
    }

    // MARK: -

    func test_insert_storesEntry() throws {
        let entry = ClipEntry.fixture(text: "alpha")
        try store.insert(entry)

        let results = try store.recent(limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].contentHash, entry.contentHash)
    }

    func test_dedup_bumpsCopiedAt() throws {
        let entry = ClipEntry.fixture(text: "alpha")
        try store.insert(entry)

        // Short sleep so the second insert gets a measurably later timestamp.
        Thread.sleep(forTimeInterval: 0.01)
        let laterEntry = ClipEntry.fixture(text: "alpha", hash: entry.contentHash)
        try store.insert(laterEntry)

        let results = try store.recent(limit: 10)
        XCTAssertEqual(results.count, 1, "duplicate hash must not create a second row")
        XCTAssertGreaterThan(
            results[0].copiedAt.timeIntervalSinceReferenceDate,
            entry.copiedAt.timeIntervalSinceReferenceDate,
            "copied_at must be bumped to the re-insert time"
        )
    }

    func test_dedup_bumpsToSlotOne() throws {
        let a = ClipEntry.fixture(text: "A")
        let b = ClipEntry.fixture(text: "B")
        try store.insert(a)     // A → slot 1
        try store.insert(b)     // B → slot 1, A → slot 2

        // Re-insert A by the same hash → A should reclaim slot 1, B becomes slot 2.
        let aAgain = ClipEntry.fixture(text: "A", hash: a.contentHash)
        try store.insert(aAgain)

        let results = try store.recent(limit: 5)
        // recent() orders by copied_at DESC; A was just bumped so it should be first.
        XCTAssertEqual(results[0].contentHash, a.contentHash)
    }

    func test_slotShift_on_insert() throws {
        var entries: [ClipEntry] = []
        for i in 1...6 {
            let e = ClipEntry.fixture(text: "item-\(i)")
            entries.append(e)
            try store.insert(e)
        }

        let results = try store.recent(limit: 10)
        XCTAssertEqual(results.count, 6)
        // The most recently inserted item must be the first result (slot 1).
        XCTAssertEqual(results[0].contentHash, entries[5].contentHash)
        // The very first item inserted should have fallen off slot tracking (slot = nil),
        // but it still exists in the DB — only 5 slots are tracked.
        let firstInserted = results.first { $0.contentHash == entries[0].contentHash }
        XCTAssertNotNil(firstInserted, "first entry must still exist in the database")
    }

    func test_pin_survivesExpiry() throws {
        let entry = ClipEntry.fixture(text: "keep me", isPinned: true)
        try store.insert(entry)
        try store.pin(entry.id, pinned: true)

        try store.purgeExpired(before: .distantFuture)

        let results = try store.recent(limit: 10)
        XCTAssertFalse(results.isEmpty, "pinned entry must survive purge")
        XCTAssertEqual(results[0].contentHash, entry.contentHash)
    }

    func test_purge_removesOld() throws {
        let past = Date(timeIntervalSinceReferenceDate: 0)   // 2001-01-01
        let entry = ClipEntry.fixture(text: "old", copiedAt: past)
        try store.insert(entry)

        try store.purgeExpired(before: Date())

        let results = try store.recent(limit: 10)
        XCTAssertTrue(results.isEmpty, "expired unpinned entry must be removed")
    }

    func test_encryption_roundtrip() throws {
        let original = "sensitive payload"
        let entry = ClipEntry.fixture(text: original)
        try store.insert(entry)

        let fetched = try store.recent(limit: 1)
        XCTAssertEqual(fetched.count, 1)

        let decoded = String(data: fetched[0].contentData, encoding: .utf8)
        XCTAssertEqual(decoded, original, "contentData must decrypt to the original string")
    }

    func test_sensitiveFlag_survivesRoundtrip() throws {
        let entry = ClipEntry.fixture(
            text: "api_key=sk-demo_copy_this_is_fake_9x4Tqv7L",
            isSensitive: true
        )
        try store.insert(entry)

        let fetched = try store.recent(limit: 1)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertTrue(fetched[0].isSensitive)
        XCTAssertTrue(fetched[0].previewText.contains("••••"))
    }

    func test_purgeExpiredSensitive_removesSensitiveEvenWhenPinned() throws {
        let past = Date(timeIntervalSinceReferenceDate: 0)
        let sensitive = ClipEntry.fixture(text: "password: demo-password-not-real-4831", copiedAt: past, isPinned: true, isSensitive: true)
        let normal = ClipEntry.fixture(text: "normal pinned note", copiedAt: past, isPinned: true)
        try store.insert(sensitive)
        try store.insert(normal)

        try store.purgeExpiredSensitive(before: Date())

        let results = try store.recent(limit: 10)
        XCTAssertFalse(results.contains { $0.contentHash == sensitive.contentHash })
        XCTAssertTrue(results.contains { $0.contentHash == normal.contentHash })
    }
}
