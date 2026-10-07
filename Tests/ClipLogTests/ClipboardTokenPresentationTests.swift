import Foundation
import XCTest
@testable import ClipLogCore

final class ClipboardTokenPresentationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestStorage.useTemporaryBase()
    }

    override func tearDown() {
        TestStorage.resetBase()
        super.tearDown()
    }

    func testTextUsesACompactSingleLinePreview() throws {
        let presentation = try XCTUnwrap(presentation(type: .text, value: "  Apple skill\nright now  "))

        XCTAssertEqual(presentation.kind, .text)
        XCTAssertEqual(presentation.label, "Apple skill right now")
    }

    func testURLUsesTheRecognizableDomain() throws {
        let presentation = try XCTUnwrap(
            presentation(type: .url, value: "https://www.openai.com/research/index.html")
        )

        XCTAssertEqual(presentation.kind, .link)
        XCTAssertEqual(presentation.label, "openai.com")
    }

    func testEmailLikeTextUsesAnEmailToken() throws {
        let presentation = try XCTUnwrap(presentation(type: .text, value: "hello@example.com"))

        XCTAssertEqual(presentation.kind, .email)
        XCTAssertEqual(presentation.label, "hello@example.com")
    }

    func testFileUsesItsFilename() throws {
        let presentation = try XCTUnwrap(
            presentation(type: .file, value: "file:///Users/example/Desktop/reference.png")
        )

        XCTAssertEqual(presentation.kind, .file)
        XCTAssertEqual(presentation.label, "reference.png")
    }

    func testColorKeepsTheCopiedValue() throws {
        let presentation = try XCTUnwrap(presentation(type: .color, value: "  #ff4d67  "))

        XCTAssertEqual(presentation.kind, .color)
        XCTAssertEqual(presentation.label, "#ff4d67")
    }

    func testImageProducesATokenWithoutTextData() throws {
        let presentation = try XCTUnwrap(presentation(type: .image, value: ""))

        XCTAssertEqual(presentation.kind, .image)
        XCTAssertEqual(presentation.label, "Image")
    }

    func testSensitiveEntryNeverExposesItsPayload() throws {
        let presentation = try XCTUnwrap(
            presentation(type: .text, value: "demo-secret-4831", isSensitive: true)
        )

        XCTAssertEqual(presentation.kind, .secure)
        XCTAssertEqual(presentation.label, "Copied securely")
        XCTAssertFalse(presentation.label.contains("demo-secret"))
    }

    func testEmptyTextDoesNotCreateVisualNoise() {
        XCTAssertNil(presentation(type: .text, value: " \n\t "))
    }

    func testLongTextIsBoundedForTheOneLineToken() throws {
        let value = String(repeating: "clipboard ", count: 20)
        let presentation = try XCTUnwrap(presentation(type: .text, value: value))

        XCTAssertLessThanOrEqual(presentation.label.count, 49)
        XCTAssertTrue(presentation.label.hasSuffix("…"))
    }

    private func presentation(
        type: ClipContentType,
        value: String,
        isSensitive: Bool = false
    ) -> ClipboardTokenPresentation? {
        let data = Data(value.utf8)
        let entry = ClipEntry(
            contentType: type,
            contentData: data,
            contentHash: "test-hash",
            sourceBundleID: "com.test",
            charCount: value.count,
            isSensitive: isSensitive
        )
        return ClipboardTokenPresentation(entry: entry)
    }
}
