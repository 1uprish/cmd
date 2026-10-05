import AppKit
import Foundation

public struct RichPasteboardPayload: Codable, Sendable {
    public let plainText: String
    public let html: String?
    public let rtfd: Data?
    public let rtf: Data?

    public init(plainText: String, html: String?, rtfd: Data?, rtf: Data?) {
        self.plainText = plainText
        self.html = html
        self.rtfd = rtfd
        self.rtf = rtf
    }
}

public enum ClipPasteboardWriter {
    private static let payloadEncoder = PropertyListEncoder()
    private static let payloadDecoder = PropertyListDecoder()

    public static func write(_ entry: ClipEntry, to pasteboard: NSPasteboard = .general) {
        let startedAt = Date()
        let details = [
            "entryType": entry.contentType.rawValue,
            "dataBytes": "\(entry.contentData.count)",
            "sourceApp": entry.sourceBundleID
        ]
        DiagnosticsLogbook.shared.actionInput(
            feature: "pasteboard_write",
            action: "single_entry",
            details: details
        )
        pasteboard.clearContents()
        DiagnosticsLogbook.shared.actionProcess(
            feature: "pasteboard_write",
            action: "single_entry",
            details: details.merging(["step": "build_writers"], uniquingKeysWith: { _, new in new })
        )
        let writers = pasteboardWriters(for: entry)
        if !writers.isEmpty {
            DiagnosticsLogbook.shared.actionProcess(
                feature: "pasteboard_write",
                action: "single_entry",
                details: details.merging([
                    "step": "write_objects",
                    "writerCount": "\(writers.count)"
                ], uniquingKeysWith: { _, new in new })
            )
            pasteboard.writeObjects(writers)
        }
        let elapsedMs = milliseconds(since: startedAt)
        DiagnosticsLogbook.shared.actionOutput(
            feature: "pasteboard_write",
            action: "single_entry",
            details: details.merging([
                "success": writers.isEmpty ? "false" : "true",
                "writerCount": "\(writers.count)",
                "durationMs": "\(elapsedMs)"
            ], uniquingKeysWith: { _, new in new })
        )
        if elapsedMs >= 250 {
            DiagnosticsLogbook.shared.record(
                "slow_clipboard_write",
                category: "performance",
                details: [
                    "durationMs": "\(elapsedMs)",
                    "entryType": entry.contentType.rawValue,
                    "writerCount": "\(writers.count)"
                ]
            )
        }
    }

    public static func write(_ entries: [ClipEntry], to pasteboard: NSPasteboard = .general) {
        let startedAt = Date()
        let details = [
            "entryType": "multiple",
            "entryCount": "\(entries.count)",
            "entryTypes": entries.map(\.contentType.rawValue).joined(separator: ",")
        ]
        DiagnosticsLogbook.shared.actionInput(
            feature: "pasteboard_write",
            action: "multiple_entries",
            details: details
        )
        pasteboard.clearContents()
        DiagnosticsLogbook.shared.actionProcess(
            feature: "pasteboard_write",
            action: "multiple_entries",
            details: details.merging(["step": "build_writers"], uniquingKeysWith: { _, new in new })
        )
        let writers = pasteboardWriters(for: entries)
        if !writers.isEmpty {
            DiagnosticsLogbook.shared.actionProcess(
                feature: "pasteboard_write",
                action: "multiple_entries",
                details: details.merging([
                    "step": "write_objects",
                    "writerCount": "\(writers.count)"
                ], uniquingKeysWith: { _, new in new })
            )
            pasteboard.writeObjects(writers)
        }
        let elapsedMs = milliseconds(since: startedAt)
        DiagnosticsLogbook.shared.actionOutput(
            feature: "pasteboard_write",
            action: "multiple_entries",
            details: details.merging([
                "success": writers.isEmpty ? "false" : "true",
                "writerCount": "\(writers.count)",
                "durationMs": "\(elapsedMs)"
            ], uniquingKeysWith: { _, new in new })
        )
        if elapsedMs >= 250 {
            DiagnosticsLogbook.shared.record(
                "slow_clipboard_write",
                category: "performance",
                details: [
                    "durationMs": "\(elapsedMs)",
                    "entryType": "multiple",
                    "entryCount": "\(entries.count)",
                    "writerCount": "\(writers.count)"
                ]
            )
        }
    }

    public static func pasteboardWriters(for entry: ClipEntry) -> [NSPasteboardWriting] {
        switch entry.contentType {
        case .text, .code:
            return [plainTextItem(String(data: entry.contentData, encoding: .utf8) ?? "")]

        case .url:
            return [urlItem(String(data: entry.contentData, encoding: .utf8) ?? "")]

        case .image:
            guard let item = imageItem(for: entry) else { return [] }
            return [item]

        case .rich:
            guard let item = richItem(for: entry) else {
                return [plainTextItem(String(data: entry.contentData, encoding: .utf8) ?? "")]
            }
            return [item]

        case .file:
            let raw = String(data: entry.contentData, encoding: .utf8) ?? ""
            let urls = fileURLs(for: entry)
            return urls.isEmpty ? [plainTextItem(raw)] : urls

        case .color:
            let hex = String(data: entry.contentData, encoding: .utf8) ?? ""
            if let color = NSColor(cmdHex: hex) {
                return [color]
            }
            return [plainTextItem(hex)]
        }
    }

    public static func pasteboardWriters(for entries: [ClipEntry]) -> [NSPasteboardWriting] {
        pasteboardWriters(for: entries, dragOptimized: false)
    }

    public static func primaryPasteboardWriter(for entry: ClipEntry) -> NSPasteboardWriting {
        pasteboardWriters(for: entry).first ?? plainTextItem(entry.previewText)
    }

    public static func dragPasteboardWriters(for entry: ClipEntry) -> [NSPasteboardWriting] {
        switch entry.contentType {
        case .image:
            guard let item = lazyImageDragItem(for: entry) else { return [] }
            return [item]
        case .text, .code:
            return [dragTextItem(String(data: entry.contentData, encoding: .utf8) ?? entry.previewText)]
        case .rich:
            guard let item = lazyRichDragItem(for: entry) else {
                return [plainTextItem(String(data: entry.contentData, encoding: .utf8) ?? entry.previewText)]
            }
            return [item]
        case .file:
            let raw = String(data: entry.contentData, encoding: .utf8) ?? ""
            let urls = DragPasteboardPayloadCache.shared.fileURLs(for: entry)
            return urls.isEmpty ? [plainTextItem(raw)] : urls
        default:
            return pasteboardWriters(for: entry)
        }
    }

    public static func dragPasteboardWriters(for entries: [ClipEntry]) -> [NSPasteboardWriting] {
        pasteboardWriters(for: entries, dragOptimized: true)
    }

    public static func primaryDragPasteboardWriter(for entry: ClipEntry) -> NSPasteboardWriting {
        dragPasteboardWriters(for: entry).first ?? plainTextItem(entry.previewText)
    }

    public static func prewarmDragPayloads(for entries: [ClipEntry]) {
        DragPasteboardPayloadCache.shared.prewarm(entries: entries)
    }

    public static func originalImageData(for entry: ClipEntry) -> Data? {
        guard entry.contentType == .image else { return nil }
        return storedImageDataCandidates(for: entry).first { NSImage(data: $0) != nil }
    }

    static func storedImageData(for entry: ClipEntry) -> Data? {
        storedImageDataCandidates(for: entry).first
    }

    static func storedImageDataCandidates(for entry: ClipEntry) -> [Data] {
        guard entry.contentType == .image else { return [] }
        var candidates: [Data] = []
        if let mediaPath = entry.mediaPath {
            let url = AppStoragePaths.mediaDirectory.appendingPathComponent(mediaPath)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                candidates.append(data)
            }
        }
        if !entry.contentData.isEmpty, candidates.last != entry.contentData {
            candidates.append(entry.contentData)
        }
        return candidates
    }

    public static func encodeRichPayload(_ payload: RichPasteboardPayload) -> Data? {
        try? payloadEncoder.encode(payload)
    }

    public static func decodeRichPayload(_ data: Data) -> RichPasteboardPayload? {
        try? payloadDecoder.decode(RichPasteboardPayload.self, from: data)
    }

    private static func pasteboardWriters(
        for entries: [ClipEntry],
        dragOptimized: Bool
    ) -> [NSPasteboardWriting] {
        let entries = entries.filter { !$0.contentData.isEmpty || $0.mediaPath != nil }
        guard !entries.isEmpty else { return [] }
        guard entries.count > 1 else {
            return dragOptimized ? dragPasteboardWriters(for: entries[0]) : pasteboardWriters(for: entries[0])
        }

        if !dragOptimized,
           let mixedItem = mixedPasteboardItem(for: entries) {
            return [mixedItem]
        }

        var writers: [NSPasteboardWriting] = []
        let textFragments = entries.compactMap(textFragment(for:))
        if !textFragments.isEmpty {
            let joined = textFragments.joined(separator: "\n")
            writers.append(dragOptimized ? dragTextItem(joined) : plainTextItem(joined))
        }

        for entry in entries {
            switch entry.contentType {
            case .image, .file:
                writers.append(contentsOf: dragOptimized ? dragPasteboardWriters(for: entry) : pasteboardWriters(for: entry))
            case .rich:
                if textFragment(for: entry) == nil {
                    writers.append(contentsOf: dragOptimized ? dragPasteboardWriters(for: entry) : pasteboardWriters(for: entry))
                }
            case .text, .code, .url, .color:
                break
            }
        }

        if writers.isEmpty {
            writers.append(plainTextItem(entries.map(\.previewText).joined(separator: "\n")))
        }
        return writers
    }

    private static func mixedPasteboardItem(for entries: [ClipEntry]) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        let plainText = entries.compactMap(textFragment(for:)).joined(separator: "\n")
        if !plainText.isEmpty {
            item.setString(plainText, forType: .string)
        }

        let imageEntries = entries.filter { $0.contentType == .image }
        if !imageEntries.isEmpty {
            if let html = mixedHTML(for: entries) {
                item.setString(html, forType: .html)
            }
            if let attributed = mixedAttributedString(for: entries) {
                let range = NSRange(location: 0, length: attributed.length)
                if let rtfdWrapper = try? attributed.fileWrapper(
                    from: range,
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
                ),
                   let rtfdData = rtfdWrapper.serializedRepresentation {
                    item.setData(rtfdData, forType: .rtfd)
                    item.setData(rtfdData, forType: .flatRTFD)
                }
            }
        }

        return item.types.isEmpty ? nil : item
    }

    private static func mixedHTML(for entries: [ClipEntry]) -> String? {
        var body = ""
        for entry in entries {
            if entry.contentType == .image,
               let data = originalImageData(for: entry),
               let image = NSImage(data: data),
               let png = pngData(from: data, image: image) {
                body += """
                <div><img src="data:image/png;base64,\(png.base64EncodedString())" style="max-width:480px;height:auto;"></div>
                """
            } else if let text = textFragment(for: entry) {
                let escaped = escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>")
                body += "<div>\(escaped)</div>"
            }
        }

        guard !body.isEmpty else { return nil }
        return """
        <!doctype html><html><head><meta charset="utf-8"></head><body>\(body)</body></html>
        """
    }

    private static func mixedAttributedString(for entries: [ClipEntry]) -> NSAttributedString? {
        let result = NSMutableAttributedString()
        var needsSeparator = false

        for entry in entries {
            if needsSeparator {
                result.append(NSAttributedString(string: "\n"))
            }

            if entry.contentType == .image,
               let data = originalImageData(for: entry),
               let image = NSImage(data: data) {
                let attachment = NSTextAttachment()
                attachment.image = imageForAttachment(image)
                result.append(NSAttributedString(attachment: attachment))
                needsSeparator = true
            } else if let text = textFragment(for: entry) {
                result.append(NSAttributedString(string: text))
                needsSeparator = true
            }
        }

        return result.length == 0 ? nil : result
    }

    private static func imageForAttachment(_ image: NSImage) -> NSImage {
        let maxWidth: CGFloat = 520
        let maxHeight: CGFloat = 520
        let widthRatio = maxWidth / max(image.size.width, 1)
        let heightRatio = maxHeight / max(image.size.height, 1)
        let scale = min(1, widthRatio, heightRatio)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        guard size.width > 0, size.height > 0, scale < 1 else { return image }

        let resized = NSImage(size: size)
        resized.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        resized.unlockFocus()
        return resized
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func textFragment(for entry: ClipEntry) -> String? {
        switch entry.contentType {
        case .text, .code, .url, .color, .rich:
            let value = String(data: entry.contentData, encoding: .utf8) ?? entry.previewText
            return value.isEmpty ? nil : value
        case .image, .file:
            return nil
        }
    }

    private static func plainTextItem(_ value: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)

        let attributed = NSAttributedString(
            string: value,
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        )
        if let rtf = try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ) {
            item.setData(rtf, forType: .rtf)
        }
        return item
    }

    /// Drag-only plain text item. It advertises only `public.utf8-plain-text`
    /// (no RTF, no file URL) because some drop targets reject a drag that also
    /// offers richer types or treat a file URL as an attachment instead of text.
    private static func dragTextItem(_ value: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(value, forType: .string)
        return item
    }

    private static func urlItem(_ value: String) -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if let url = URL(string: value) {
            item.setString(url.absoluteString, forType: NSPasteboard.PasteboardType("public.url"))
            item.setString(url.absoluteString, forType: .URL)
        }
        item.setString(value, forType: .string)
        return item
    }

    private static func imageItem(for entry: ClipEntry) -> NSPasteboardItem? {
        guard let data = originalImageData(for: entry),
              let image = NSImage(data: data)
        else { return nil }

        let item = NSPasteboardItem()
        if let pngData = pngData(from: data, image: image) {
            item.setData(pngData, forType: .png)
            item.setData(pngData, forType: NSPasteboard.PasteboardType("public.png"))
            if let fileURL = temporaryImageURL(for: entry, pngData: pngData) {
                item.setString(fileURL.absoluteString, forType: .fileURL)
                item.setString(fileURL.absoluteString, forType: NSPasteboard.PasteboardType("public.file-url"))
            }
        }
        if let tiffData = image.tiffRepresentation {
            item.setData(tiffData, forType: .tiff)
        }
        return item.types.isEmpty ? nil : item
    }

    private static func lazyImageDragItem(for entry: ClipEntry) -> NSPasteboardItem? {
        guard entry.contentType == .image else { return nil }
        let payload = DragPasteboardPayloadCache.shared.imagePayload(for: entry)
        let provider = LazyImageDragProvider(entry: entry, payload: payload)
        return LazyPasteboardItem(provider: provider, types: [
            .png,
            NSPasteboard.PasteboardType("public.png"),
            .tiff,
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url")
        ])
    }

    private static func lazyRichDragItem(for entry: ClipEntry) -> NSPasteboardItem? {
        guard entry.contentType == .rich else { return nil }
        let provider = LazyRichDragProvider(entry: entry)
        return LazyPasteboardItem(provider: provider, types: [
            .string,
            .html,
            .rtfd,
            .flatRTFD,
            .rtf
        ])
    }

    private static func richItem(for entry: ClipEntry) -> NSPasteboardItem? {
        let payload: RichPasteboardPayload?
        if let mediaPath = entry.mediaPath {
            let url = AppStoragePaths.mediaDirectory.appendingPathComponent(mediaPath)
            payload = (try? Data(contentsOf: url)).flatMap(decodeRichPayload)
        } else {
            payload = decodeRichPayload(entry.contentData)
        }

        guard let payload else { return nil }
        let item = NSPasteboardItem()
        item.setString(payload.plainText, forType: .string)

        if let html = payload.html, !html.isEmpty {
            item.setString(html, forType: .html)
        }
        if let rtfd = payload.rtfd, !rtfd.isEmpty {
            item.setData(rtfd, forType: .rtfd)
            item.setData(rtfd, forType: .flatRTFD)
        }
        if let rtf = payload.rtf, !rtf.isEmpty {
            item.setData(rtf, forType: .rtf)
        }

        return item.types.isEmpty ? nil : item
    }

    private static func fileURLs(for entry: ClipEntry) -> [NSURL] {
        let raw = String(data: entry.contentData, encoding: .utf8) ?? ""
        return raw
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { URL(string: $0) as NSURL? }
    }

    private static func pngData(from data: Data, image: NSImage) -> Data? {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return data
        }
        if let bitmap = NSBitmapImageRep(data: data),
           let png = bitmap.representation(using: .png, properties: [:]) {
            return png
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func temporaryImageURL(for entry: ClipEntry, pngData: Data) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdDragImages", isDirectory: true)
        let fileURL = directory.appendingPathComponent("\(entry.id.uuidString).png")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pngData.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

private final class LazyPasteboardItem: NSPasteboardItem {
    private let retainedProvider: NSPasteboardItemDataProvider

    init(provider: NSPasteboardItemDataProvider, types: [NSPasteboard.PasteboardType]) {
        retainedProvider = provider
        super.init()
        setDataProvider(provider, forTypes: types)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    @available(*, unavailable)
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError()
    }
}

private final class LazyImageDragProvider: NSObject, NSPasteboardItemDataProvider {
    private let entry: ClipEntry
    private let payload: ImageDragPayload

    init(entry: ClipEntry, payload: ImageDragPayload) {
        self.entry = entry
        self.payload = payload
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        let startedAt = Date()
        defer {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            if elapsedMs >= 50 {
                DiagnosticsLogbook.shared.record(
                    "slow_drag_payload_materialize",
                    category: "performance",
                    details: [
                        "durationMs": "\(elapsedMs)",
                        "entryType": entry.contentType.rawValue,
                        "pasteboardType": type.rawValue
                    ]
                )
            }
        }

        if type == .png || type.rawValue == "public.png" {
            guard let data = payload.pngData() else { return }
            item.setData(data, forType: type)
            return
        }

        if type == .tiff {
            guard let data = payload.tiffData() else { return }
            item.setData(data, forType: type)
            return
        }

        if type == .fileURL || type.rawValue == "public.file-url" {
            guard let url = payload.temporaryFileURL() else { return }
            item.setString(url.absoluteString, forType: type)
        }
    }
}

private final class LazyRichDragProvider: NSObject, NSPasteboardItemDataProvider {
    private let entry: ClipEntry
    private var cachedPayload: RichPasteboardPayload?

    init(entry: ClipEntry) {
        self.entry = entry
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        let startedAt = Date()
        defer {
            let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            if elapsedMs >= 50 {
                DiagnosticsLogbook.shared.record(
                    "slow_drag_payload_materialize",
                    category: "performance",
                    details: [
                        "durationMs": "\(elapsedMs)",
                        "entryType": entry.contentType.rawValue,
                        "pasteboardType": type.rawValue
                    ]
                )
            }
        }

        guard let payload = richPayload() else { return }
        switch type {
        case .string:
            item.setString(payload.plainText, forType: type)
        case .html:
            if let html = payload.html { item.setString(html, forType: type) }
        case .rtfd, .flatRTFD:
            if let rtfd = payload.rtfd { item.setData(rtfd, forType: type) }
        case .rtf:
            if let rtf = payload.rtf { item.setData(rtf, forType: type) }
        default:
            break
        }
    }

    private func richPayload() -> RichPasteboardPayload? {
        if let cachedPayload { return cachedPayload }
        let payload: RichPasteboardPayload?
        if let mediaPath = entry.mediaPath {
            let url = AppStoragePaths.mediaDirectory.appendingPathComponent(mediaPath)
            payload = (try? Data(contentsOf: url)).flatMap(ClipPasteboardWriter.decodeRichPayload)
        } else {
            payload = ClipPasteboardWriter.decodeRichPayload(entry.contentData)
        }
        cachedPayload = payload
        return payload
    }
}

private extension NSColor {
    convenience init?(cmdHex: String) {
        let raw = cmdHex.hasPrefix("#") ? String(cmdHex.dropFirst()) : cmdHex
        guard raw.count == 6 || raw.count == 8 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: raw).scanHexInt64(&value) else { return nil }

        let hasAlpha = raw.count == 8
        let r, g, b, a: CGFloat
        if hasAlpha {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255
            a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
