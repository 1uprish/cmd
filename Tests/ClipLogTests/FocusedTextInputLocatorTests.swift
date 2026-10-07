import XCTest
@testable import ClipLogCore

final class FocusedTextInputLocatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TestStorage.useTemporaryBase()
    }

    override func tearDown() {
        TestStorage.resetBase()
        super.tearDown()
    }

    func test_convertsAXRectOnPrimaryDisplay() {
        let ax = CGRect(x: 10, y: 100, width: 200, height: 30)
        let rect = FocusedTextInputLocator.appKitRect(fromAX: ax, primaryDisplayHeight: 900)
        XCTAssertEqual(rect, NSRect(x: 10, y: 770, width: 200, height: 30))
        XCTAssertEqual(rect.maxY, 800)
    }

    func test_preservesXIncludingNegativeOffsets() {
        let ax = CGRect(x: -500, y: 50, width: 100, height: 20)
        let rect = FocusedTextInputLocator.appKitRect(fromAX: ax, primaryDisplayHeight: 900)
        XCTAssertEqual(rect, NSRect(x: -500, y: 830, width: 100, height: 20))
    }

    func test_mapsDisplayAbovePrimaryIntoAppKitSpace() {
        let ax = CGRect(x: 0, y: -200, width: 300, height: 40)
        let rect = FocusedTextInputLocator.appKitRect(fromAX: ax, primaryDisplayHeight: 900)
        XCTAssertEqual(rect, NSRect(x: 0, y: 1060, width: 300, height: 40))
    }

    func test_mapsDisplayBelowPrimaryIntoAppKitSpace() {
        let ax = CGRect(x: 0, y: 1000, width: 300, height: 40)
        let rect = FocusedTextInputLocator.appKitRect(fromAX: ax, primaryDisplayHeight: 900)
        XCTAssertEqual(rect, NSRect(x: 0, y: -140, width: 300, height: 40))
    }

    func test_topEdgeIsFlippedAboutPrimaryHeight() {
        let ax = CGRect(x: 0, y: 250, width: 100, height: 40)
        let rect = FocusedTextInputLocator.appKitRect(fromAX: ax, primaryDisplayHeight: 1080)
        XCTAssertEqual(rect.maxY, 1080 - ax.minY)
    }
}
