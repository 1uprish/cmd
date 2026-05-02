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

// MARK: - In-memory ClipStore factory

extension ClipStore {
    static func makeInMemory() throws -> ClipStore {
        let queue = try DatabaseQueue()       // DatabaseQueue() with no path → in-memory
        let key = SymmetricKey(size: .bits256)
        return try ClipStore(databaseQueue: queue, encryptionKey: key)
    }
}
