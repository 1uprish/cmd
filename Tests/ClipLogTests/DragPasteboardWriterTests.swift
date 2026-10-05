import XCTest
import AppKit
@testable import ClipLogCore

final class DragPasteboardWriterTests: XCTestCase {

    private func entry(_ type: ClipContentType, _ text: String) -> ClipEntry {
        let data = Data(text.utf8)
        return ClipEntry(
            contentType: type,
            contentData: data,
            contentHash: "hash",
            sourceBundleID: "com.test.app",
            charCount: text.count
        )
    }

    func test_text_drag_advertises_string_and_file_url() {
        let writers = ClipPasteboardWriter.dragPasteboardWriters(for: entry(.text, "hello world"))
        let item = writers.compactMap { $0 as? NSPasteboardItem }.first
        let types = item?.types ?? []
        XCTAssertTrue(types.contains(.string))
        XCTAssertEqual(item?.string(forType: .string), "hello world")
        // A file URL lets media-only drop targets accept text drags (Finder does
        // the same for text files).
        XCTAssertTrue(types.contains(.fileURL))
    }

    func test_code_drag_advertises_string() {
        let types = ClipPasteboardWriter.dragPasteboardWriters(for: entry(.code, "let x = 1"))
            .compactMap { $0 as? NSPasteboardItem }
            .flatMap(\.types)
        XCTAssertTrue(types.contains(.string))
    }

    func test_url_drag_advertises_string() {
        let types = ClipPasteboardWriter.dragPasteboardWriters(for: entry(.url, "https://apple.com"))
            .compactMap { $0 as? NSPasteboardItem }
            .flatMap(\.types)
        XCTAssertTrue(types.contains(.string))
    }
}
