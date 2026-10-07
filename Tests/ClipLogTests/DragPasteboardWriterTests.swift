import XCTest
import AppKit
@testable import ClipLogCore

final class DragPasteboardWriterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestStorage.useTemporaryBase()
    }

    override func tearDown() {
        TestStorage.resetBase()
        super.tearDown()
    }

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
        XCTAssertEqual(item?.string(forType: .string), "hello world")
        // Text so text fields insert it; file URL so file-only drop targets
        // (which ignore text) still receive it as an attachment.
        XCTAssertTrue(types.contains(.string))
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
