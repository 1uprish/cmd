import XCTest
@testable import ClipLogCore

final class SensitiveContentDetectorTests: XCTestCase {
    func test_detectsLabelledApiKey() {
        XCTAssertTrue(SensitiveContentDetector.isSensitive("api_key=sk-demo_copy_this_is_fake_9x4Tqv7L"))
    }

    func test_detectsPasswordAssignment() {
        XCTAssertTrue(SensitiveContentDetector.isSensitive("password: demo-password-not-real-4831"))
    }

    func test_detectsJwt() {
        XCTAssertTrue(SensitiveContentDetector.isSensitive("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"))
    }

    func test_doesNotFlagNormalSentence() {
        XCTAssertFalse(SensitiveContentDetector.isSensitive("Welcome to cmd. Copy once, reuse anytime."))
    }
}
