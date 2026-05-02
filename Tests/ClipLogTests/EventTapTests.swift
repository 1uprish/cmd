import XCTest
@testable import ClipLogCore

final class StateMachineTests: XCTestCase {

    func test_cmdVDown_suppressed() {
        var sm = StateMachine()
        XCTAssertEqual(sm.handle(.cmdVDown), .suppress)
    }

    func test_quickRelease_passthrough() {
        var sm = StateMachine()
        _ = sm.handle(.cmdVDown)
        XCTAssertEqual(sm.handle(.cmdVUp), .passthrough)
    }

    func test_keyRepeat_stillSuppressed() {
        var sm = StateMachine()
        XCTAssertEqual(sm.handle(.cmdVDown), .suppress)
        XCTAssertEqual(sm.handle(.cmdVDown), .suppress)
        XCTAssertEqual(sm.handle(.cmdVDown), .suppress)
    }

    func test_holdThenHUDAppear_showsHUD() {
        var sm = StateMachine()
        _ = sm.handle(.cmdVDown)
        sm.hudDidAppear()
        // Still suppresses further key-down events while HUD is active.
        XCTAssertEqual(sm.handle(.cmdVDown), .suppress)
    }

    func test_hudActive_cmdRelease_keepsHUDOpen() {
        var sm = StateMachine()
        _ = sm.handle(.cmdVDown)
        sm.hudDidAppear()
        XCTAssertEqual(sm.handle(.cmdRelease), .none)
        XCTAssertEqual(sm.handle(.cmdVDown), .suppress)
    }

    func test_idle_cmdRelease_isNoop() {
        var sm = StateMachine()
        XCTAssertEqual(sm.handle(.cmdRelease), .none)
    }

    func test_pendingHold_cmdRelease_passthrough() {
        var sm = StateMachine()
        _ = sm.handle(.cmdVDown)
        XCTAssertEqual(sm.handle(.cmdRelease), .passthrough)
    }
}
