import AppKit
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
}

