import AppKit
import ClipLogCore
import Foundation
import ImageIO

final class HUDThumbnailCache {
    static let shared = HUDThumbnailCache()

    struct Request: Equatable {
        let key: String
        let entryID: UUID
    }

    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.cmd.hud.thumbnail-cache", qos: .userInitiated)

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 24 * 1024 * 1024
    }

    func request(
        entry: ClipEntry,
        size: NSSize,
        completion: @escaping (Request, NSImage?) -> Void
    ) -> Request? {
        guard entry.contentType == .image, !entry.isSensitive else { return nil }

        let request = Request(
            key: cacheKey(for: entry, size: size),
            entryID: entry.id
        )
        if let image = cache.object(forKey: request.key as NSString) {
            DispatchQueue.main.async {
                completion(request, image)
            }
            return request
        }

        queue.async { [weak self] in
            guard let self else { return }
            let image = self.decodeThumbnail(for: entry, size: size)
            if let image {
                self.cache.setObject(
                    image,
                    forKey: request.key as NSString,
                    cost: max(1, Int(size.width * size.height * 4))
                )
            }
            DispatchQueue.main.async {
                completion(request, image)
            }
        }
        return request
    }

    private func cacheKey(for entry: ClipEntry, size: NSSize) -> String {
        [
            entry.contentHash,
            entry.mediaPath ?? "",
            "\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
        ].joined(separator: "|")
    }

    private func decodeThumbnail(for entry: ClipEntry, size: NSSize) -> NSImage? {
        if let mediaPath = entry.mediaPath {
            let url = AppStoragePaths.mediaDirectory.appendingPathComponent(mediaPath)
            if let image = decodeThumbnail(url: url, size: size) {
                return image
            }
        }
        guard !entry.contentData.isEmpty else { return nil }
        return decodeThumbnail(data: entry.contentData, size: size)
    }

    private func decodeThumbnail(url: URL, size: NSSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return decodeThumbnail(source: source, size: size)
    }

    private func decodeThumbnail(data: Data, size: NSSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return decodeThumbnail(source: source, size: size)
    }

    private func decodeThumbnail(source: CGImageSource, size: NSSize) -> NSImage? {
        let maxDimension = max(size.width, size.height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxDimension * 2)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: size)
    }
}
