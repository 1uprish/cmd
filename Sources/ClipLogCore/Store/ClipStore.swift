import Foundation
import CryptoKit
import Security
import GRDB

// MARK: - ClipStore

public final class ClipStore: @unchecked Sendable {

    private let db: DatabaseQueue
    private let encryptionKey: SymmetricKey

    public init() throws {
        let appSupport = AppStoragePaths.applicationSupportDirectory

        try FileManager.default.createDirectory(
            at: appSupport,
            withIntermediateDirectories: true
        )

        let dbURL = appSupport.appendingPathComponent("clips.db")

        encryptionKey = try Self.loadOrCreateEncryptionKey()

        do {
            let queue = try DatabaseQueue(path: dbURL.path)
            try Self.runMigrations(on: queue)
            db = queue
        } catch {
            DiagnosticsLogbook.shared.record(
                "store_open_recovered",
                category: "storage",
                details: ["error": String(describing: error)]
            )
            Self.quarantineDatabase(reason: "open_or_migration_failed")
            let queue = try DatabaseQueue(path: dbURL.path)
            try Self.runMigrations(on: queue)
            db = queue
        }
    }

    // Testable init — bypasses Keychain and the default on-disk path so unit
    // tests can use an in-memory database with a caller-supplied key.
    init(databaseQueue: DatabaseQueue, encryptionKey: SymmetricKey) throws {
        self.db = databaseQueue
        self.encryptionKey = encryptionKey
        try Self.runMigrations(on: databaseQueue)
    }

    // MARK: - Public API

    public func insert(_ entry: ClipEntry) throws {
        let encrypted = try encrypt(entry.contentData)

        try db.write { database in
            if let existing = try Row.fetchOne(
                database,
                sql: "SELECT id FROM clips WHERE content_hash = ?",
                arguments: [entry.contentHash]
            ) {
                let existingID = existing["id"] as String
                try database.execute(
                    sql: "UPDATE clips SET copied_at = ?, slot = 1, is_sensitive = MAX(is_sensitive, ?) WHERE id = ?",
                    arguments: [Date().timeIntervalSinceReferenceDate, entry.isSensitive ? 1 : 0, existingID]
                )
                return
            }

            // Shift slots before inserting so the new row cleanly takes slot 1.
            // Slots 5+ collapse to NULL; we only track the 5 most recent positions.
            try database.execute(sql: """
                UPDATE clips
                SET slot = CASE
                    WHEN slot = 4 THEN 5
                    WHEN slot = 3 THEN 4
                    WHEN slot = 2 THEN 3
                    WHEN slot = 1 THEN 2
                    ELSE NULL
                END
                WHERE slot IS NOT NULL
                """)

            let record = DatabaseRecord(
                id: entry.id.uuidString,
                copiedAt: entry.copiedAt.timeIntervalSinceReferenceDate,
                contentType: entry.contentType.rawValue,
                contentData: encrypted,
                contentHash: entry.contentHash,
                sourceBundle: entry.sourceBundleID,
                charCount: entry.charCount,
                isPinned: entry.isPinned ? 1 : 0,
                isSensitive: entry.isSensitive ? 1 : 0,
                slot: 1,
                ocrText: entry.ocrText,
                mediaPath: entry.mediaPath,
                sourceWindowTitle: entry.sourceWindowTitle
            )
            try record.insert(database)
        }
    }

    public func recent(limit: Int) throws -> [ClipEntry] {
        try db.read { database in
            let records = try DatabaseRecord.fetchAll(
                database,
                sql: "SELECT * FROM clips ORDER BY copied_at DESC LIMIT ?",
                arguments: [limit]
            )
            return try records.map { try self.toEntry($0) }
        }
    }

    public func pin(_ id: UUID, pinned: Bool) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE clips SET is_pinned = ? WHERE id = ?",
                arguments: [pinned ? 1 : 0, id.uuidString]
            )
        }
    }

    public func delete(_ id: UUID) throws {
        let mediaPaths = try db.write { database -> [String] in
            let paths = try Self.mediaPaths(
                database,
                whereSQL: "id = ?",
                arguments: [id.uuidString]
            )
            try database.execute(
                sql: "DELETE FROM clips WHERE id = ?",
                arguments: [id.uuidString]
            )
            return paths
        }
        removeMediaFiles(named: mediaPaths)
    }

    public func purgeExpired(before date: Date) throws {
        let mediaPaths = try db.write { database -> [String] in
            let paths = try Self.mediaPaths(
                database,
                whereSQL: "is_pinned = 0 AND copied_at < ?",
                arguments: [date.timeIntervalSinceReferenceDate]
            )
            try database.execute(
                sql: "DELETE FROM clips WHERE is_pinned = 0 AND copied_at < ?",
                arguments: [date.timeIntervalSinceReferenceDate]
            )
            return paths
        }
        removeMediaFiles(named: mediaPaths)
    }

    public func purgeExpiredSensitive(before date: Date) throws {
        let mediaPaths = try db.write { database -> [String] in
            let paths = try Self.mediaPaths(
                database,
                whereSQL: "is_sensitive = 1 AND copied_at < ?",
                arguments: [date.timeIntervalSinceReferenceDate]
            )
            try database.execute(
                sql: "DELETE FROM clips WHERE is_sensitive = 1 AND copied_at < ?",
                arguments: [date.timeIntervalSinceReferenceDate]
            )
            return paths
        }
        removeMediaFiles(named: mediaPaths)
    }

    public func updateOCRText(id: UUID, text: String) throws {
        try db.write { database in
            try database.execute(
                sql: "UPDATE clips SET ocr_text = ? WHERE id = ?",
                arguments: [text, id.uuidString]
            )
        }
    }

    /// Persist a precomputed embedding vector for the given entry.
    /// The vector is JSON-encoded and stored as a BLOB for portability.
    public func updateEmbedding(id: UUID, embedding: [Double]) throws {
        let data = try JSONEncoder().encode(embedding)
        try db.write { database in
            try database.execute(
                sql: "UPDATE clips SET embedding = ? WHERE id = ?",
                arguments: [data, id.uuidString]
            )
        }
    }

    /// Return all entries that have a stored embedding, paired with their decoded vector.
    /// Rows where the embedding column is NULL are skipped.
    public func allWithEmbeddings() throws -> [(ClipEntry, [Double])] {
        try db.read { database in
            let records = try DatabaseRecord.fetchAll(
                database,
                sql: "SELECT * FROM clips WHERE embedding IS NOT NULL ORDER BY copied_at DESC"
            )
            return try records.compactMap { record in
                guard let embeddingData = record.embedding,
                      let vec = try? JSONDecoder().decode([Double].self, from: embeddingData)
                else { return nil }
                let entry = try self.toEntry(record)
                return (entry, vec)
            }
        }
    }

    public func mediaURL(for entry: ClipEntry) -> URL? {
        guard let filename = entry.mediaPath else { return nil }
        return AppStoragePaths.mediaDirectory.appendingPathComponent(filename)
    }

    public func all() throws -> [ClipEntry] {
        try db.read { database in
            let records = try DatabaseRecord.fetchAll(
                database,
                sql: "SELECT * FROM clips ORDER BY copied_at DESC"
            )
            return try records.map { try self.toEntry($0) }
        }
    }

    // MARK: - Migrations

    private static func runMigrations(on queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { database in
            try database.execute(sql: """
                CREATE TABLE clips (
                    id            TEXT PRIMARY KEY NOT NULL,
                    copied_at     REAL NOT NULL,
                    content_type  TEXT NOT NULL,
                    content_data  BLOB NOT NULL,
                    content_hash  TEXT NOT NULL,
                    source_bundle TEXT NOT NULL,
                    char_count    INTEGER,
                    is_pinned     INTEGER NOT NULL DEFAULT 0,
                    slot          INTEGER
                );
                CREATE UNIQUE INDEX clips_hash ON clips (content_hash);
                CREATE INDEX clips_copied_at ON clips (copied_at DESC);
                """)
        }

        migrator.registerMigration("v2") { database in
            try database.execute(sql: """
                ALTER TABLE clips ADD COLUMN ocr_text  TEXT;
                ALTER TABLE clips ADD COLUMN media_path TEXT;
                """)
        }

        migrator.registerMigration("v3") { database in
            try database.execute(sql: """
                ALTER TABLE clips ADD COLUMN source_window_title TEXT;
                """)
        }

        migrator.registerMigration("v4") { database in
            try database.execute(sql: """
                ALTER TABLE clips ADD COLUMN embedding BLOB;
                """)
        }

        migrator.registerMigration("v5") { database in
            try database.execute(sql: """
                ALTER TABLE clips ADD COLUMN is_sensitive INTEGER NOT NULL DEFAULT 0;
                """)
        }

        try migrator.migrate(queue)
    }

    // MARK: - Encryption helpers

    private func encrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.seal(data, using: encryptionKey)
        // Layout: 12-byte nonce | ciphertext | 16-byte tag
        // combined already packs nonce+ciphertext+tag contiguously.
        guard let combined = sealedBox.combined else {
            throw ClipStoreError.encryptionFailed
        }
        return combined
    }

    private func decrypt(_ data: Data) throws -> Data {
        let sealedBox = try AES.GCM.SealedBox(combined: data)
        return try AES.GCM.open(sealedBox, using: encryptionKey)
    }

    // MARK: - Encryption key storage
    //
    // The AES-256 key is stored as a flat file (0600 perms) inside the same
    // Application Support directory as the database. This approach:
    //   • Requires no Keychain entitlements (works with ad-hoc signing)
    //   • Never shows a password prompt regardless of code-signature changes
    //   • Is protected by macOS filesystem permissions (owner-read-write only)
    //
    // If a legacy Keychain item exists from a previous build it is silently
    // deleted; the database is wiped simultaneously because it was encrypted
    // with the now-lost key.

    private static func loadOrCreateEncryptionKey() throws -> SymmetricKey {
        let appSupport = AppStoragePaths.applicationSupportDirectory

        try FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)

        let keyFileURL = appSupport.appendingPathComponent(".enckey")

        // Clean up any stale Keychain item from a previous build (no-op if absent).
        let legacyDelete: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "com.copypasta.encryptionKey",
            kSecAttrAccount: "main",
        ]
        SecItemDelete(legacyDelete as CFDictionary)

        // Load existing key file.
        if let keyData = try? Data(contentsOf: keyFileURL), keyData.count == 32 {
            return SymmetricKey(data: keyData)
        }

        // First launch (or key file missing): generate a fresh key.
        // Wipe any existing database — it was encrypted with the old key.
        wipeDatabase()

        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }

        // Write with owner-read-write-only permissions (0600).
        let fm = FileManager.default
        fm.createFile(atPath: keyFileURL.path, contents: keyData, attributes: [
            .posixPermissions: 0o600
        ])

        return newKey
    }

    /// Remove the on-disk database so stale data encrypted with a now-lost key
    /// does not surface as corrupt entries.
    private static func wipeDatabase() {
        removeDatabaseFiles()
    }

    private static func quarantineDatabase(reason: String) {
        let appSupport = AppStoragePaths.applicationSupportDirectory
        let dbURL = appSupport.appendingPathComponent("clips.db")
        let timestamp = ISO8601DateFormatter()
            .string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let quarantineDirectory = appSupport
            .appendingPathComponent("Recovered Databases", isDirectory: true)
            .appendingPathComponent("\(timestamp)-\(reason)", isDirectory: true)

        try? FileManager.default.createDirectory(
            at: quarantineDirectory,
            withIntermediateDirectories: true
        )

        for url in databaseFileURLs(for: dbURL) where FileManager.default.fileExists(atPath: url.path) {
            let destination = quarantineDirectory.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.moveItem(at: url, to: destination)
        }
    }

    private static func removeDatabaseFiles() {
        let appSupport = AppStoragePaths.applicationSupportDirectory

        let dbURL = appSupport.appendingPathComponent("clips.db")
        for url in databaseFileURLs(for: dbURL) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func databaseFileURLs(for dbURL: URL) -> [URL] {
        [
            dbURL,
            URL(fileURLWithPath: dbURL.path + "-wal"),
            URL(fileURLWithPath: dbURL.path + "-shm"),
            dbURL.appendingPathExtension("wal"),
            dbURL.appendingPathExtension("shm"),
        ]
    }

    // MARK: - Record <-> Entry mapping

    private func toEntry(_ record: DatabaseRecord) throws -> ClipEntry {
        let decrypted = try decrypt(record.contentData)
        guard let contentType = ClipContentType(rawValue: record.contentType) else {
            throw ClipStoreError.unknownContentType(record.contentType)
        }
        guard let id = UUID(uuidString: record.id) else {
            throw ClipStoreError.malformedUUID(record.id)
        }
        return ClipEntry(
            id: id,
            copiedAt: Date(timeIntervalSinceReferenceDate: record.copiedAt),
            contentType: contentType,
            contentData: decrypted,
            contentHash: record.contentHash,
            sourceBundleID: record.sourceBundle,
            charCount: record.charCount,
            isPinned: record.isPinned != 0,
            isSensitive: record.isSensitive != 0,
            ocrText: record.ocrText,
            mediaPath: record.mediaPath,
            sourceWindowTitle: record.sourceWindowTitle
        )
    }

    private static func mediaPaths(
        _ database: Database,
        whereSQL: String,
        arguments: StatementArguments
    ) throws -> [String] {
        try String.fetchAll(
            database,
            sql: "SELECT media_path FROM clips WHERE media_path IS NOT NULL AND \(whereSQL)",
            arguments: arguments
        )
    }

    private func removeMediaFiles(named filenames: [String]) {
        guard !filenames.isEmpty else { return }
        let mediaDirectory = AppStoragePaths.mediaDirectory.standardizedFileURL
        var removed = 0

        for filename in Set(filenames) {
            let url = mediaDirectory.appendingPathComponent(filename).standardizedFileURL
            guard url.path.hasPrefix(mediaDirectory.path + "/") else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed += 1
            }
        }

        if removed > 0 {
            DiagnosticsLogbook.shared.record(
                "media_files_removed",
                category: "storage",
                details: ["count": "\(removed)"]
            )
        }
    }
}

// MARK: - DatabaseRecord

private struct DatabaseRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "clips"

    let id: String
    let copiedAt: Double
    let contentType: String
    let contentData: Data
    let contentHash: String
    let sourceBundle: String
    let charCount: Int?
    let isPinned: Int
    let isSensitive: Int
    let slot: Int?
    let ocrText: String?
    let mediaPath: String?
    let sourceWindowTitle: String?
    let embedding: Data?

    // FetchableRecord
    init(row: Row) {
        id                = row["id"]
        copiedAt          = row["copied_at"]
        contentType       = row["content_type"]
        contentData       = row["content_data"]
        contentHash       = row["content_hash"]
        sourceBundle      = row["source_bundle"]
        charCount         = row["char_count"]
        isPinned          = row["is_pinned"]
        isSensitive       = row["is_sensitive"]
        slot              = row["slot"]
        ocrText           = row["ocr_text"]
        mediaPath         = row["media_path"]
        sourceWindowTitle = row["source_window_title"]
        embedding         = row["embedding"]
    }

    // PersistableRecord
    func encode(to container: inout PersistenceContainer) {
        container["id"]                  = id
        container["copied_at"]           = copiedAt
        container["content_type"]        = contentType
        container["content_data"]        = contentData
        container["content_hash"]        = contentHash
        container["source_bundle"]       = sourceBundle
        container["char_count"]          = charCount
        container["is_pinned"]           = isPinned
        container["is_sensitive"]        = isSensitive
        container["slot"]                = slot
        container["ocr_text"]            = ocrText
        container["media_path"]          = mediaPath
        container["source_window_title"] = sourceWindowTitle
        container["embedding"]           = embedding
    }

    // Memberwise init used in ClipStore.insert()
    init(
        id: String,
        copiedAt: Double,
        contentType: String,
        contentData: Data,
        contentHash: String,
        sourceBundle: String,
        charCount: Int?,
        isPinned: Int,
        isSensitive: Int,
        slot: Int?,
        ocrText: String? = nil,
        mediaPath: String? = nil,
        sourceWindowTitle: String? = nil,
        embedding: Data? = nil
    ) {
        self.id                = id
        self.copiedAt          = copiedAt
        self.contentType       = contentType
        self.contentData       = contentData
        self.contentHash       = contentHash
        self.sourceBundle      = sourceBundle
        self.charCount         = charCount
        self.isPinned          = isPinned
        self.isSensitive       = isSensitive
        self.slot              = slot
        self.ocrText           = ocrText
        self.mediaPath         = mediaPath
        self.sourceWindowTitle = sourceWindowTitle
        self.embedding         = embedding
    }
}

// MARK: - Errors

public enum ClipStoreError: Error {
    case encryptionFailed
    case unknownContentType(String)
    case malformedUUID(String)
}
