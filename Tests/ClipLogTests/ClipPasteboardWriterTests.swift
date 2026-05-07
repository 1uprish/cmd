import AppKit
import CryptoKit
import XCTest
@testable import ClipLogCore

final class ClipPasteboardWriterTests: XCTestCase {
    func test_batchTextWritersJoinInOrder() throws {
        let entries = [
            textEntry("alpha"),
            textEntry("beta"),
            textEntry("gamma")
        ]

        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmd.test.batch.text.\(UUID().uuidString)"))
        ClipPasteboardWriter.write(entries, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "alpha\nbeta\ngamma")
    }

    func test_singleBatchUsesSingleEntryWriter() throws {
        let entry = textEntry("solo")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmd.test.batch.single.\(UUID().uuidString)"))

        ClipPasteboardWriter.write([entry], to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "solo")
    }

    func test_mixedBatchExposesTextFallback() throws {
        let entries = [
            textEntry("alpha"),
            urlEntry("https://cmd.local/test")
        ]
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("cmd.test.batch.mixed.\(UUID().uuidString)"))

        ClipPasteboardWriter.write(entries, to: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "alpha\nhttps://cmd.local/test")
    }

    func test_batchDragWritersReturnPayload() throws {
        let writers = ClipPasteboardWriter.dragPasteboardWriters(for: [
            textEntry("alpha"),
            textEntry("beta")
        ])

        XCTAssertFalse(writers.isEmpty)
    }

    func test_dragImageCacheSharesPayloadWithoutMaterializingFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmd.tests.drag.cache.\(UUID().uuidString)", isDirectory: true)
        let cache = DragPasteboardPayloadCache(directory: directory)
        let entry = imageEntry(Data([0x01, 0x02, 0x03]))

        let first = cache.imagePayload(for: entry)
        let second = cache.imagePayload(for: entry)

        XCTAssertTrue(first === second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(first.pngData())
    }

    func test_dragImageCacheReusesMaterializedFileURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmd.tests.drag.cache.\(UUID().uuidString)", isDirectory: true)
        let cache = DragPasteboardPayloadCache(directory: directory)
        let data = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=
        """)!
        let entry = imageEntry(data)
        let payload = cache.imagePayload(for: entry)

        let first = try XCTUnwrap(payload.temporaryFileURL())
        let second = try XCTUnwrap(cache.imagePayload(for: entry).temporaryFileURL())

        XCTAssertEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }

    private func textEntry(_ value: String) -> ClipEntry {
        let data = Data(value.utf8)
        return ClipEntry(
            contentType: .text,
            contentData: data,
            contentHash: sha256(data),
            sourceBundleID: "com.cmd.tests",
            charCount: value.count
        )
    }

    private func urlEntry(_ value: String) -> ClipEntry {
        let data = Data(value.utf8)
        return ClipEntry(
            contentType: .url,
            contentData: data,
            contentHash: sha256(data),
            sourceBundleID: "com.cmd.tests",
            charCount: value.count
        )
    }

    private func imageEntry(_ data: Data) -> ClipEntry {
        ClipEntry(
            contentType: .image,
            contentData: data,
            contentHash: sha256(data),
            sourceBundleID: "com.cmd.tests",
            charCount: nil
        )
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
