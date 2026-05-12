import Foundation

public enum CursorPiPSizePreset: String, CaseIterable, Sendable {
    case small
    case medium
    case large

    public var size: CGSize {
        switch self {
        case .small:
            return CGSize(width: 356, height: 200)
        case .medium:
            return CGSize(width: 480, height: 270)
        case .large:
            return CGSize(width: 640, height: 360)
        }
    }

    public var sizePercent: CGFloat {
        switch self {
        case .small: return 22
        case .medium: return 30
        case .large: return 40
        }
    }
}

public enum CursorPiPGeometry {
    public static let wideAspectRatio: CGFloat = 16.0 / 9.0

    public static func wideWebcamSize(
        canvasSize: CGSize,
        sizePercent: CGFloat,
        zoomScale: CGFloat = 1,
        reactToZoom: Bool = false,
        margin: CGFloat = 12,
        minimumSide: CGFloat = 56
    ) -> CGSize {
        let base = min(canvasSize.width, canvasSize.height)
        let percent = sizePercent.clamped(to: 10...100)
        let zoom = max(zoomScale, 0.001)
        let scale = reactToZoom ? 1 / zoom : 1
        let rawHeight = base * (percent / 100) * scale
        let rawWidth = rawHeight * wideAspectRatio
        let maxWidth = max(minimumSide, canvasSize.width - margin * 2)
        let maxHeight = max(minimumSide, canvasSize.height - margin * 2)
        let fitScale = min(1, maxWidth / rawWidth, maxHeight / rawHeight)

        return CGSize(
            width: max(minimumSide, rawWidth * fitScale),
            height: max(minimumSide, rawHeight * fitScale)
        )
    }

    public static func clampedRadius(cornerRadius: CGFloat, size: CGSize) -> CGFloat {
        cornerRadius.clamped(to: 0...(min(size.width, size.height) / 2))
    }

    public static func clampedEdgeBlur(edgeBlur: CGFloat, size: CGSize) -> CGFloat {
        edgeBlur.clamped(to: 0...min(48, min(size.width, size.height) / 4))
    }

    public static func clampedOrigin(
        cursor: CGPoint,
        visibleFrame: CGRect,
        panelSize: CGSize,
        offset: CGSize,
        padding: CGFloat
    ) -> CGPoint {
        let maxX = visibleFrame.maxX - panelSize.width - padding
        let maxY = visibleFrame.maxY - panelSize.height - padding
        let minX = visibleFrame.minX + padding
        let minY = visibleFrame.minY + padding

        return CGPoint(
            x: max(minX, min(cursor.x + offset.width, maxX)),
            y: max(minY, min(cursor.y + offset.height, maxY))
        )
    }
}

public struct CursorPiPVideoCandidate: Equatable, Sendable {
    public let originalURL: URL
    public let playbackURL: URL
    public let watchURL: URL
    public let embedURL: URL
    public let platformName: String
    public let videoID: String

    public init(
        originalURL: URL,
        playbackURL: URL,
        watchURL: URL,
        embedURL: URL,
        platformName: String,
        videoID: String
    ) {
        self.originalURL = originalURL
        self.playbackURL = playbackURL
        self.watchURL = watchURL
        self.embedURL = embedURL
        self.platformName = platformName
        self.videoID = videoID
    }
}

public enum CursorPiPURLDetector {
    public enum Route: Equatable, Sendable {
        case native(CursorPiPVideoCandidate)
        case ott(URL, platform: String)
        case unsupported(URL)
    }

    public static func route(in text: String) -> Route? {
        urlCandidates(in: text).compactMap(route(for:)).first
    }

    public static func route(for url: URL) -> Route {
        if let candidate = candidate(for: url) {
            return .native(candidate)
        }
        if let platform = ottPlatform(for: url) {
            return .ott(url, platform: platform)
        }
        return .unsupported(url)
    }

    public static func candidate(in text: String) -> CursorPiPVideoCandidate? {
        urlCandidates(in: text).compactMap(candidate(for:)).first
    }

    public static func candidate(for url: URL) -> CursorPiPVideoCandidate? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased()
        else { return nil }

        let videoID: String?
        if host == "youtu.be" {
            videoID = components.path
                .split(separator: "/")
                .first
                .map(String.init)
        } else if host.hasSuffix("youtube.com") || host.hasSuffix("youtube-nocookie.com") {
            let pathParts = components.path
                .split(separator: "/")
                .map(String.init)

            if components.path == "/watch" {
                videoID = components.queryItems?.first(where: { $0.name == "v" })?.value
            } else if let markerIndex = pathParts.firstIndex(where: { ["embed", "shorts", "live"].contains($0) }),
                      pathParts.indices.contains(markerIndex + 1) {
                videoID = pathParts[markerIndex + 1]
            } else {
                videoID = nil
            }
        } else {
            videoID = nil
        }

        guard let rawID = videoID,
              let cleanID = sanitizeYouTubeVideoID(rawID)
        else { return nil }

        var watch = URLComponents()
        watch.scheme = "https"
        watch.host = "www.youtube.com"
        watch.path = "/watch"
        watch.queryItems = [
            URLQueryItem(name: "v", value: cleanID)
        ]

        var embed = URLComponents()
        embed.scheme = "https"
        embed.host = "www.youtube.com"
        embed.path = "/embed/\(cleanID)"
        embed.queryItems = [
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            URLQueryItem(name: "enablejsapi", value: "1"),
            URLQueryItem(name: "controls", value: "1"),
            URLQueryItem(name: "rel", value: "0"),
            URLQueryItem(name: "modestbranding", value: "1"),
            URLQueryItem(name: "origin", value: "https://com.cmd.app"),
            URLQueryItem(name: "widget_referrer", value: "https://com.cmd.app/")
        ]

        guard let watchURL = watch.url,
              let embedURL = embed.url
        else { return nil }
        return CursorPiPVideoCandidate(
            originalURL: url,
            playbackURL: embedURL,
            watchURL: watchURL,
            embedURL: embedURL,
            platformName: "YouTube",
            videoID: cleanID
        )
    }

    private static func urlCandidates(in text: String) -> [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector?
            .matches(in: text, options: [], range: range)
            .compactMap(\.url) ?? []
    }

    private static func ottPlatform(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if host.hasSuffix("netflix.com") { return "Netflix" }
        if host.hasSuffix("primevideo.com") || host.hasSuffix("amazon.com") { return "Prime Video" }
        if host.hasSuffix("jiocinema.com") { return "JioCinema" }
        if host.hasSuffix("hotstar.com") || host.hasSuffix("disneyplus.com") { return "Hotstar" }
        return nil
    }

    private static func sanitizeYouTubeVideoID(_ raw: String) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        let clean = raw
            .split(whereSeparator: { !$0.unicodeScalars.allSatisfy(allowed.contains) })
            .first
            .map(String.init) ?? raw
        guard clean.count >= 6,
              clean.count <= 32,
              clean.unicodeScalars.allSatisfy(allowed.contains)
        else { return nil }
        return clean
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
