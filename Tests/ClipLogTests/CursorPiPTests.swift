import XCTest
@testable import ClipLogCore

final class CursorPiPTests: XCTestCase {
    func test_youtubeWatchURLBuildsPlaybackURLs() throws {
        let url = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        let candidate = try XCTUnwrap(CursorPiPURLDetector.candidate(for: url))

        XCTAssertEqual(candidate.platformName, "YouTube")
        XCTAssertEqual(candidate.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(candidate.playbackURL.host, "www.youtube.com")
        XCTAssertEqual(candidate.playbackURL.path, "/embed/dQw4w9WgXcQ")
        XCTAssertEqual(candidate.embedURL.path, "/embed/dQw4w9WgXcQ")
        XCTAssertEqual(candidate.watchURL.path, "/watch")
        XCTAssertTrue(candidate.watchURL.absoluteString.contains("v=dQw4w9WgXcQ"))
        XCTAssertTrue(candidate.embedURL.absoluteString.contains("origin=https://com.cmd.app"))
    }

    func test_youtuBeURLBuildsEmbedURL() throws {
        let url = try XCTUnwrap(URL(string: "https://youtu.be/dQw4w9WgXcQ?t=42"))
        let candidate = try XCTUnwrap(CursorPiPURLDetector.candidate(for: url))

        XCTAssertEqual(candidate.videoID, "dQw4w9WgXcQ")
        XCTAssertEqual(candidate.playbackURL.path, "/embed/dQw4w9WgXcQ")
    }

    func test_detectorFindsURLInsideClipboardText() throws {
        let candidate = try XCTUnwrap(CursorPiPURLDetector.candidate(in: "watch this https://youtube.com/shorts/abcDEF_1234 now"))

        XCTAssertEqual(candidate.videoID, "abcDEF_1234")
    }

    func test_nonYouTubeURLIsIgnored() {
        XCTAssertNil(CursorPiPURLDetector.candidate(for: URL(string: "https://netflix.com/watch/123")!))
    }

    func test_netflixRoutesToOTT() {
        let route = CursorPiPURLDetector.route(for: URL(string: "https://www.netflix.com/watch/123")!)

        XCTAssertEqual(route, .ott(URL(string: "https://www.netflix.com/watch/123")!, platform: "Netflix"))
    }

    func test_detectorFindsNetflixURLInsideClipboardText() throws {
        let route = try XCTUnwrap(CursorPiPURLDetector.route(in: "Netflix: https://www.netflix.com/watch/123"))

        XCTAssertEqual(route, .ott(URL(string: "https://www.netflix.com/watch/123")!, platform: "Netflix"))
    }

    func test_detectorFindsNetflixURLWithoutScheme() throws {
        let route = try XCTUnwrap(CursorPiPURLDetector.route(in: "www.netflix.com/watch/123"))

        XCTAssertEqual(route, .ott(URL(string: "http://www.netflix.com/watch/123")!, platform: "Netflix"))
    }

    func test_geometryClampsBottomRight() {
        let origin = CursorPiPGeometry.clampedOrigin(
            cursor: CGPoint(x: 995, y: 795),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            panelSize: CGSize(width: 320, height: 180),
            offset: CGSize(width: 24, height: -24),
            padding: 12
        )

        XCTAssertEqual(origin.x, 668)
        XCTAssertEqual(origin.y, 608)
    }

    func test_geometryClampsTopLeft() {
        let origin = CursorPiPGeometry.clampedOrigin(
            cursor: CGPoint(x: 4, y: 4),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            panelSize: CGSize(width: 320, height: 180),
            offset: CGSize(width: -50, height: -50),
            padding: 12
        )

        XCTAssertEqual(origin.x, 12)
        XCTAssertEqual(origin.y, 12)
    }

    func test_wideWebcamSizeUsesHeightFirstAspectRatio() {
        let size = CursorPiPGeometry.wideWebcamSize(
            canvasSize: CGSize(width: 1440, height: 900),
            sizePercent: 30,
            margin: 12
        )

        XCTAssertEqual(size.width, 480, accuracy: 0.001)
        XCTAssertEqual(size.height, 270, accuracy: 0.001)
    }

    func test_wideWebcamSizeFitsSmallCanvas() {
        let size = CursorPiPGeometry.wideWebcamSize(
            canvasSize: CGSize(width: 300, height: 180),
            sizePercent: 100,
            margin: 12
        )

        XCTAssertLessThanOrEqual(size.width, 276.001)
        XCTAssertLessThanOrEqual(size.height, 156.001)
        XCTAssertEqual(size.width / size.height, 16.0 / 9.0, accuracy: 0.001)
    }

    func test_radiusAndEdgeBlurClampToShortSide() {
        let size = CGSize(width: 480, height: 270)

        XCTAssertEqual(CursorPiPGeometry.clampedRadius(cornerRadius: 999, size: size), 135)
        XCTAssertEqual(CursorPiPGeometry.clampedEdgeBlur(edgeBlur: 999, size: size), 48)
        XCTAssertEqual(CursorPiPGeometry.clampedEdgeBlur(edgeBlur: 40, size: CGSize(width: 120, height: 80)), 20)
    }
}
