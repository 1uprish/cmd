import AppKit
import Foundation

final class DragPasteboardPayloadCache: @unchecked Sendable {
    static let shared = DragPasteboardPayloadCache()
    private static let hudPrewarmLimit = 20

    private let imagePayloads = NSCache<NSString, ImageDragPayload>()
    private let filePayloads = NSCache<NSString, FileDragPayload>()
    private let cacheLock = NSLock()
    private let pruner = DragPayloadCacheDirectoryPruner()
    private let directory: URL

    init(
        directory: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdDragImages", isDirectory: true)
    ) {
        self.directory = directory
        imagePayloads.countLimit = 64
        imagePayloads.totalCostLimit = 128 * 1024 * 1024
        filePayloads.countLimit = 128
    }

    func imagePayload(for entry: ClipEntry) -> ImageDragPayload {
        let key = cacheKey(for: entry) as NSString
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let payload = imagePayloads.object(forKey: key) {
            return payload
        }

        let payload = ImageDragPayload(entry: entry, cacheKey: key as String, directory: directory, pruner: pruner)
        imagePayloads.setObject(payload, forKey: key, cost: min(entry.contentData.count, 4 * 1024 * 1024))
        return payload
    }

    func prewarm(entries: [ClipEntry]) {
        let imageEntries = entries.filter { $0.contentType == .image }
        guard !imageEntries.isEmpty else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let batchStartedAt = Date()
            let entriesToPrewarm = Array(imageEntries.prefix(Self.hudPrewarmLimit))
            var succeeded = 0
            var failed = 0

            for entry in entriesToPrewarm {
                let payload = self.imagePayload(for: entry)
                let result = payload.prewarm()
                self.recordPrewarmResult(result, entry: entry)
                if result.succeeded {
                    succeeded += 1
                } else {
                    failed += 1
                }
            }

            DiagnosticsLogbook.shared.record(
                "drag_payload_prewarm_batch",
                category: "drag",
                details: [
                    "requested": "\(entries.count)",
                    "imageCount": "\(imageEntries.count)",
                    "attempted": "\(entriesToPrewarm.count)",
                    "succeeded": "\(succeeded)",
                    "failed": "\(failed)",
                    "durationMs": "\(Int(Date().timeIntervalSince(batchStartedAt) * 1000))"
                ]
            )
        }
    }

    func fileURLs(for entry: ClipEntry) -> [NSURL] {
        let key = cacheKey(for: entry) as NSString
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let payload = filePayloads.object(forKey: key) {
            return payload.urls
        }

        let raw = String(data: entry.contentData, encoding: .utf8) ?? ""
        let urls = raw
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) as NSURL? }
        let payload = FileDragPayload(urls: urls)
        filePayloads.setObject(payload, forKey: key)
        return urls
    }

    private func cacheKey(for entry: ClipEntry) -> String {
        [
            entry.contentType.rawValue,
            entry.contentHash,
            entry.mediaPath ?? "",
            "\(entry.contentData.count)"
        ].joined(separator: "|")
    }

    private func recordPrewarmResult(_ result: DragPayloadPrewarmResult, entry: ClipEntry) {
        let event: String
        if result.succeeded {
            event = result.durationMs >= 250 ? "slow_drag_payload_prewarm" : "drag_payload_prewarm_succeeded"
        } else {
            event = "drag_payload_prewarm_failed"
        }

        DiagnosticsLogbook.shared.record(
            event,
            category: "drag",
            details: [
                "entryID": entry.id.uuidString,
                "contentHashPrefix": String(entry.contentHash.prefix(12)),
                "contentBytes": "\(entry.contentData.count)",
                "pngBytes": result.pngBytes.map(String.init) ?? "nil",
                "fileURL": result.fileURL?.path ?? "nil",
                "fileExists": "\(result.fileExists)",
                "durationMs": "\(result.durationMs)",
                "mediaPathPresent": "\(entry.mediaPath != nil)"
            ]
        )
    }
}

struct DragPayloadPrewarmResult {
    let pngBytes: Int?
    let fileURL: URL?
    let fileExists: Bool
    let durationMs: Int

    var succeeded: Bool {
        pngBytes != nil && fileURL != nil && fileExists
    }
}

final class ImageDragPayload: @unchecked Sendable {
    private static let pngSignature = [UInt8]([0x89, 0x50, 0x4E, 0x47])
    private static let tiffLittleEndianSignature = [UInt8]([0x49, 0x49, 0x2A, 0x00])
    private static let tiffBigEndianSignature = [UInt8]([0x4D, 0x4D, 0x00, 0x2A])

    private let entry: ClipEntry
    private let cacheKey: String
    private let directory: URL
    private let pruner: DragPayloadCacheDirectoryPruner
    private let lock = NSLock()

    private var cachedOriginalDataCandidates: [Data]?
    private var cachedPNGData: Data?
    private var cachedTIFFData: Data?
    private var cachedFileURL: URL?

    init(entry: ClipEntry, cacheKey: String, directory: URL, pruner: DragPayloadCacheDirectoryPruner) {
        self.entry = entry
        self.cacheKey = cacheKey
        self.directory = directory
        self.pruner = pruner
    }

    func pngData() -> Data? {
        lock.lock()
        defer { lock.unlock() }

        return pngDataLocked()
    }

    func tiffData() -> Data? {
        lock.lock()
        defer { lock.unlock() }

        return tiffDataLocked()
    }

    func temporaryFileURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }

        if let cachedFileURL { return cachedFileURL }
        guard let data = pngDataLocked() else { return nil }
        let fileURL = directory.appendingPathComponent(cacheFilename)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            pruner.pruneIfNeeded(directory)
            if cachedFileIsCurrent(fileURL, byteCount: data.count) {
                cachedFileURL = fileURL
                return fileURL
            }
            try data.write(to: fileURL, options: .atomic)
            cachedFileURL = fileURL
            return fileURL
        } catch {
            return nil
        }
    }

    @discardableResult
    func prewarm() -> DragPayloadPrewarmResult {
        let startedAt = Date()
        let png = pngData()
        let fileURL = temporaryFileURL()
        let fileExists = fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return DragPayloadPrewarmResult(
            pngBytes: png?.count,
            fileURL: fileURL,
            fileExists: fileExists,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
        )
    }

    private var cacheFilename: String {
        let safeKey = cacheKey
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { partial, character in
                if partial.last != "-" || character != "-" {
                    partial.append(character)
                }
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return "\(safeKey.isEmpty ? entry.id.uuidString : safeKey).png"
    }

    private func originalDataCandidatesLocked() -> [Data] {
        if let cachedOriginalDataCandidates { return cachedOriginalDataCandidates }
        let candidates = ClipPasteboardWriter.storedImageDataCandidates(for: entry)
        cachedOriginalDataCandidates = candidates
        return candidates
    }

    private func pngDataLocked() -> Data? {
        if let cachedPNGData { return cachedPNGData }
        for data in originalDataCandidatesLocked() {
            if data.starts(with: Self.pngSignature) {
                cachedPNGData = data
                return data
            }
            if let bitmap = NSBitmapImageRep(data: data),
               let png = bitmap.representation(using: .png, properties: [:]) {
                cachedPNGData = png
                return png
            }
            guard let image = NSImage(data: data),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { continue }
            cachedPNGData = png
            return png
        }
        return nil
    }

    private func tiffDataLocked() -> Data? {
        if let cachedTIFFData { return cachedTIFFData }
        for data in originalDataCandidatesLocked() {
            if data.starts(with: Self.tiffLittleEndianSignature) || data.starts(with: Self.tiffBigEndianSignature) {
                cachedTIFFData = data
                return data
            }
            guard let image = NSImage(data: data) else { continue }
            let tiff = image.tiffRepresentation
            cachedTIFFData = tiff
            return tiff
        }
        return nil
    }

    private func cachedFileIsCurrent(_ url: URL, byteCount: Int) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              values.fileSize == byteCount
        else { return false }
        return true
    }
}

final class DragPayloadCacheDirectoryPruner: @unchecked Sendable {
    private let maxCacheFileAge: TimeInterval = 24 * 60 * 60
    private let maxCacheBytes: Int = 256 * 1024 * 1024
    private let pruneInterval: TimeInterval = 60 * 60
    private let lock = NSLock()
    private var lastPrune: Date?

    func pruneIfNeeded(_ directory: URL) {
        lock.lock()
        let now = Date()
        if let lastPrune, now.timeIntervalSince(lastPrune) < pruneInterval {
            lock.unlock()
            return
        }
        lastPrune = now
        lock.unlock()

        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = now.addingTimeInterval(-maxCacheFileAge)
        var keptFiles: [(url: URL, modifiedAt: Date, size: Int)] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modifiedAt = values?.contentModificationDate
            if let modifiedAt, modifiedAt < cutoff {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            if let modifiedAt {
                keptFiles.append((url, modifiedAt, values?.fileSize ?? 0))
            }
        }

        var totalBytes = keptFiles.reduce(0) { $0 + $1.size }
        for file in keptFiles.sorted(by: { $0.modifiedAt < $1.modifiedAt }) where totalBytes > maxCacheBytes {
            try? FileManager.default.removeItem(at: file.url)
            totalBytes -= file.size
        }
    }
}

private final class FileDragPayload {
    let urls: [NSURL]

    init(urls: [NSURL]) {
        self.urls = urls
    }
}
