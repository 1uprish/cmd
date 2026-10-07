import Foundation
import CryptoKit
@testable import ClipLogCore
import GRDB

// MARK: - ClipEntry fixture

extension ClipEntry {
    static func fixture(
        text: String = "hello",
        hash: String? = nil,
        copiedAt: Date = Date(),
        isPinned: Bool = false,
        isSensitive: Bool = false
    ) -> ClipEntry {
        let data = text.data(using: .utf8)!
        let resolvedHash = hash ?? SHA256.hash(data: data)
            .compactMap { String(format: "%02x", $0) }
            .joined()
        return ClipEntry(
            id: UUID(),
            copiedAt: copiedAt,
            contentType: .text,
            contentData: data,
            contentHash: resolvedHash,
            sourceBundleID: "com.test",
            charCount: text.count,
            isPinned: isPinned,
            isSensitive: isSensitive
        )
    }
}

// MARK: - Test storage isolation

/// Redirects the whole storage tree (logs, media, database paths) at a
/// per-test temporary directory, so test runs never mingle with the field
/// state in ~/Library/Application Support/cmd. Call `useTemporaryBase()`
/// in setUp and `resetBase()` in tearDown. The general pasteboard itself is
/// inherently shared; tests that touch it must keep save/restoring it.
enum TestStorage {
    @discardableResult
    static func useTemporaryBase() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmd-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        AppStoragePaths.testBaseDirectoryOverride = url
        return url
    }

    static func resetBase() {
        AppStoragePaths.testBaseDirectoryOverride = nil
    }
}

// MARK: - In-memory ClipStore factory

extension ClipStore {
    static func makeInMemory() throws -> ClipStore {
        let queue = try DatabaseQueue()       // DatabaseQueue() with no path → in-memory
        let key = SymmetricKey(size: .bits256)
        return try ClipStore(databaseQueue: queue, encryptionKey: key)
    }
}
