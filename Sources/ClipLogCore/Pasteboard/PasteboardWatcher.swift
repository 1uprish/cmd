import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import os

// MARK: - PasteboardWatcher
//
// Polls NSPasteboard.changeCount every 200ms.
// On change: classify, hash, check sensitivity, emit ClipEntry.
//
// Sensitive handling:
//   1. NSPasteboard concealed type (transient flag set by password managers)
//   2. Source app bundle ID in user's exclusion list
//   3. Known password manager bundle IDs (hardcoded + user-addable)
//   4. Text/code/url payloads that look like passwords, API keys, tokens, or private keys are stored redacted.

public final class PasteboardWatcher: @unchecked Sendable {

    public init() {}

    public var onNewEntry: ((ClipEntry) -> Void)?
    public weak var store: ClipStore?

    private enum AppendClip {
        case text(String)
        case image(Data)

        var textValue: String? {
            guard case .text(let value) = self else { return nil }
            return value
        }

        var imageData: Data? {
            guard case .image(let data) = self else { return nil }
            return data
        }

        var characterCount: Int {
            textValue?.count ?? 0
        }

        var previewLine: String {
            switch self {
            case .text(let value):
                if SensitiveContentDetector.isSensitive(value) {
                    return SensitiveContentDetector.redactedPreview(for: value)
                }
                return value
            case .image:
                return "Image"
            }
        }
    }

    private struct AppendSession {
        var clips: [AppendClip]
        var expiresAt: Date

        var combinedText: String {
            clips.compactMap(\.textValue).joined(separator: "\n")
        }

        var hasText: Bool {
            clips.contains { $0.textValue?.isEmpty == false }
        }

        var hasImage: Bool {
            clips.contains { $0.imageData != nil }
        }

        var characterCount: Int {
            clips.reduce(0) { $0 + $1.characterCount }
        }

        var previewText: String {
            clips.map(\.previewLine).joined(separator: "\n")
        }
    }

    /// Persistent append collection. While active, every copied text value is
    /// merged into one clipboard payload, and copied images are written beside
    /// it as native image pasteboard objects.
    private var appendSession: AppendSession?
    private var appendExpiryWorkItem: DispatchWorkItem?
    private var appendSessionTimeout: TimeInterval = 8

    /// Start or stop append collection. The name is kept for the existing event
    /// tap call site, but the behavior is now a session instead of a one-shot.
    public func enableAppendMode(expiringAfter timeout: TimeInterval = 8) {
        queue.async {
            if self.appendSession != nil {
                self.endAppendSession()
            } else {
                self.startAppendSession(expiringAfter: timeout)
            }
        }
    }

    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var lastClipString: String = ""
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.cmd.pasteboard", qos: .utility)

    private static let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("org.webmproject.webp"),
        NSPasteboard.PasteboardType("com.adobe.pdf")
    ]

    private static let attachmentLabelFallbacks: Set<String> = [
        "User attachment",
        "Attachment"
    ]

    // Apps whose clipboard writes must never be stored (credentials).
    private static let knownPasswordManagers: Set<String> = [
        "com.agilebits.onepassword7",
        "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop",
        "com.lastpass.LastPass",
        "com.apple.keychainaccess"
    ]

    // Apps that make ephemeral writes not worth capturing (not credential-sensitive).
    private static let knownTransientSources: Set<String> = [
        "net.shinyfrog.bear"
    ]

    public var userExcludedBundles: Set<String> = []

    public func updateUserExcludedBundles(_ bundles: Set<String>) {
        queue.async {
            self.userExcludedBundles = bundles
        }
    }

    private static let logger = Logger(subsystem: "com.cliplog", category: "PasteboardWatcher")

    // MARK: - Start / stop

    public func start() {
        DiagnosticsLogbook.shared.record("pasteboard_watcher_started", category: "pasteboard")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        self.timer = t
    }

    public func stop() {
        DiagnosticsLogbook.shared.record("pasteboard_watcher_stopped", category: "pasteboard")
        timer?.cancel()
        timer = nil
    }

    // MARK: - Poll

    private func poll() {
        let startedAt = Date()
        defer {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= 0.25 {
                DiagnosticsLogbook.shared.record(
                    "slow_pasteboard_poll",
                    category: "performance",
                    details: ["durationMs": "\(Int(elapsed * 1000))"]
                )
            }
        }

        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        // Password managers write NSPasteboardTypeConcealed before the real data.
        if pb.types?.contains(.concealed) == true {
            return
        }

        // Capture frontmost bundle ID and window title on main thread where NSWorkspace is authoritative.
        let (bundle, windowTitle) = DispatchQueue.main.sync { () -> (String, String?) in
            let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            let title = self.frontWindowTitle(for: bid)
            return (bid, title)
        }

        if Self.knownPasswordManagers.contains(bundle) ||
           Self.knownTransientSources.contains(bundle) ||
           userExcludedBundles.contains(bundle) {
            return
        }

        // Append session: copied strings and images become one paste-ready
        // pasteboard payload. Text fields receive the combined string; rich
        // targets can also receive the image objects.
        if appendSession != nil {
            mergeCurrentPasteboardIntoAppendSession(pb)
            return
        }

        guard let entry = buildEntry(from: pb, sourceBundle: bundle, windowTitle: windowTitle) else { return }

        // Track the last plain-text content for potential future appends.
        if let str = pb.string(forType: .string) {
            lastClipString = str
        }

        onNewEntry?(entry)

        // Embed text-based entries for semantic search (fire-and-forget).
        if [.text, .url, .code, .rich].contains(entry.contentType), !entry.isSensitive {
            let capturedEntry = entry
            Task.detached(priority: .utility) { [weak self] in
                guard let store = self?.store else { return }
                await EmbeddingService.shared.embed(entry: capturedEntry, store: store)
            }
        }

        if entry.contentType == .image, let mediaPath = entry.mediaPath {
            let mediaDir = AppStoragePaths.mediaDirectory
            let imageURL = mediaDir.appendingPathComponent(mediaPath)
            let entryID  = entry.id
            Task.detached(priority: .utility) { [weak self] in
                guard let store = self?.store else { return }
                await OCRService.shared.processAndStore(entryID: entryID, imageURL: imageURL, store: store)
            }
        }
    }

    // MARK: - Append session

    private func startAppendSession(expiringAfter timeout: TimeInterval) {
        DiagnosticsLogbook.shared.record("append_started", category: "append")
        appendSessionTimeout = timeout
        appendSession = AppendSession(
            clips: [],
            expiresAt: Date().addingTimeInterval(timeout)
        )
        publishAppendSnapshot()
        scheduleAppendExpiry(after: timeout)
    }

    private func mergeCurrentPasteboardIntoAppendSession(_ pb: NSPasteboard) {
        let imageClip = imageData(from: pb).flatMap { data in
            data.isEmpty ? nil : AppendClip.image(data)
        }

        let textClip: AppendClip?
        if let newString = pb.string(forType: .string), !newString.isEmpty {
            if Self.attachmentLabelFallbacks.contains(newString.trimmingCharacters(in: .whitespacesAndNewlines)),
               pasteboardLooksLikeAttachment(pb) {
                textClip = nil
            } else {
                textClip = .text(newString)
            }
        } else {
            textClip = nil
        }

        mergeIntoAppendSession([textClip, imageClip].compactMap { $0 }, pasteboard: pb)
    }

    private func mergeIntoAppendSession(_ newClip: AppendClip, pasteboard pb: NSPasteboard) {
        mergeIntoAppendSession([newClip], pasteboard: pb)
    }

    private func mergeIntoAppendSession(_ newClips: [AppendClip], pasteboard pb: NSPasteboard) {
        guard var session = appendSession else { return }
        guard !newClips.isEmpty else { return }

        for newClip in newClips {
            if shouldAppend(newClip, to: session) {
                session.clips.append(newClip)
            }
        }

        session.expiresAt = Date().addingTimeInterval(appendSessionTimeout)
        appendSession = session

        writeAppendSession(session, to: pb)
        lastChangeCount = pb.changeCount
        lastClipString = session.combinedText

        publishAppendSnapshot()
        scheduleAppendExpiry(after: appendSessionTimeout)
    }

    private func shouldAppend(_ clip: AppendClip, to session: AppendSession) -> Bool {
        switch clip {
        case .text(let value):
            return value != session.combinedText && session.clips.last?.textValue != value
        case .image(let data):
            return session.clips.last?.imageData != data
        }
    }

    private func writeAppendSession(_ session: AppendSession, to pb: NSPasteboard) {
        pb.clearContents()

        if session.hasText, session.hasImage,
           let mixedItem = mixedAppendPasteboardItem(for: session) {
            pb.writeObjects([mixedItem])
            return
        }

        var writers: [NSPasteboardWriting] = []
        let merged = session.combinedText
        if !merged.isEmpty {
            writers.append(merged as NSString)
        }

        for data in session.clips.compactMap(\.imageData) {
            guard let writer = imagePasteboardItem(fromPNGData: data) else { continue }
            writers.append(writer)
        }

        if !writers.isEmpty {
            pb.writeObjects(writers)
        }
    }

    private func scheduleAppendExpiry(after timeout: TimeInterval) {
        appendExpiryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.endAppendSession()
        }
        appendExpiryWorkItem = workItem
        queue.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func endAppendSession() {
        DiagnosticsLogbook.shared.record("append_ended", category: "append")
        appendExpiryWorkItem?.cancel()
        appendExpiryWorkItem = nil
        commitAppendSessionIfNeeded()
        appendSession = nil
        publishAppendSnapshot(isActive: false)
    }

    private func commitAppendSessionIfNeeded() {
        guard let session = appendSession, !session.clips.isEmpty else { return }
        guard let entry = buildEntry(
            from: NSPasteboard.general,
            sourceBundle: Bundle.main.bundleIdentifier ?? "com.cmd.app",
            windowTitle: "Append"
        ) else { return }

        onNewEntry?(entry)

        if [.text, .url, .code, .rich].contains(entry.contentType), !entry.isSensitive {
            let capturedEntry = entry
            Task.detached(priority: .utility) { [weak self] in
                guard let store = self?.store else { return }
                await EmbeddingService.shared.embed(entry: capturedEntry, store: store)
            }
        }

        if entry.contentType == .image, let mediaPath = entry.mediaPath {
            let mediaDir = AppStoragePaths.mediaDirectory
            let imageURL = mediaDir.appendingPathComponent(mediaPath)
            let entryID = entry.id
            Task.detached(priority: .utility) { [weak self] in
                guard let store = self?.store else { return }
                await OCRService.shared.processAndStore(entryID: entryID, imageURL: imageURL, store: store)
            }
        }
    }

    private func publishAppendSnapshot(isActive: Bool = true) {
        let snapshot: AppendSessionSnapshot
        if isActive, let session = appendSession {
            snapshot = AppendSessionSnapshot(
                isActive: true,
                itemCount: session.clips.count,
                characterCount: session.characterCount,
                preview: session.previewText
            )
        } else {
            snapshot = AppendSessionSnapshot(
                isActive: false,
                itemCount: 0,
                characterCount: 0,
                preview: ""
            )
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cmdAppendSessionChanged, object: snapshot)
        }
    }

    // MARK: - Entry construction

    private func buildEntry(from pb: NSPasteboard, sourceBundle: String, windowTitle: String?) -> ClipEntry? {
        let type = classifyType(pb)

        switch type {
        case .text, .url, .code:
            guard let str = pb.string(forType: .string), !str.isEmpty else { return nil }
            let data = Data(str.utf8)
            let isSensitive = SensitiveContentDetector.isSensitive(str)
            return ClipEntry(
                contentType: type,
                contentData: data,
                contentHash: sha256(data),
                sourceBundleID: sourceBundle,
                charCount: str.count,
                isSensitive: isSensitive,
                sourceWindowTitle: windowTitle
            )

        case .rich:
            guard let payload = richPayload(from: pb),
                  let payloadData = ClipPasteboardWriter.encodeRichPayload(payload)
            else {
                guard let str = pb.string(forType: .string), !str.isEmpty else { return nil }
                let data = Data(str.utf8)
                return ClipEntry(
                    contentType: .text,
                    contentData: data,
                    contentHash: sha256(data),
                    sourceBundleID: sourceBundle,
                    charCount: str.count,
                    isSensitive: SensitiveContentDetector.isSensitive(str),
                    sourceWindowTitle: windowTitle
                )
            }

            let mediaUUID = UUID()
            let filename = "\(mediaUUID.uuidString).cmdrich"
            let mediaDir = AppStoragePaths.mediaDirectory
            let destURL = mediaDir.appendingPathComponent(filename)
            do {
                try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
                try payloadData.write(to: destURL, options: .atomic)
            } catch {
                Self.logger.error("Failed to write rich clipboard payload to disk: \(error)")
                return nil
            }

            let previewData = Data(payload.plainText.utf8)
            return ClipEntry(
                contentType: .rich,
                contentData: previewData,
                contentHash: sha256(payloadData),
                sourceBundleID: sourceBundle,
                charCount: payload.plainText.count,
                isSensitive: SensitiveContentDetector.isSensitive(payload.plainText),
                ocrText: nil,
                mediaPath: filename,
                sourceWindowTitle: windowTitle
            )

        case .image:
            guard let originalData = imageData(from: pb) else { return nil }
            if originalData.count > 10 * 1024 * 1024 {
                Self.logger.info("Skipped oversized image (\(originalData.count) bytes)")
                return nil
            }

            let mediaUUID = UUID()
            let filename  = "\(mediaUUID.uuidString).png"
            let mediaDir = AppStoragePaths.mediaDirectory
            let destURL  = mediaDir.appendingPathComponent(filename)

            do {
                try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
                try originalData.write(to: destURL, options: .atomic)
            } catch {
                Self.logger.error("Failed to write image to disk: \(error)")
                return nil
            }

            guard let thumbnailJPEG = makeThumbnail(from: originalData) else { return nil }

            return ClipEntry(
                contentType: .image,
                contentData: thumbnailJPEG,
                contentHash: sha256(originalData),
                sourceBundleID: sourceBundle,
                charCount: nil,
                isSensitive: false,
                ocrText: nil,
                mediaPath: filename,
                sourceWindowTitle: windowTitle
            )

        case .file:
            guard let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
                  !urls.isEmpty else { return nil }
            let joined = urls.map(\.absoluteString).joined(separator: "\n")
            let data = Data(joined.utf8)
            return ClipEntry(
                contentType: .file,
                contentData: data,
                contentHash: sha256(data),
                sourceBundleID: sourceBundle,
                charCount: nil,
                isSensitive: false,
                sourceWindowTitle: windowTitle
            )

        case .color:
            guard let color = pb.readObjects(forClasses: [NSColor.self])?.first as? NSColor else { return nil }
            let hex = color.hexString
            let data = Data(hex.utf8)
            return ClipEntry(
                contentType: .color,
                contentData: data,
                contentHash: sha256(data),
                sourceBundleID: sourceBundle,
                charCount: nil,
                isSensitive: false,
                sourceWindowTitle: windowTitle
            )
        }
    }

    // MARK: - Accessibility window title

    private func frontWindowTitle(for bundleID: String) -> String? {
        guard !bundleID.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
              let window = windowRef else { return nil }
        // Safe cast: verify the CFTypeRef is actually an AXUIElement before using it.
        // CFGetTypeID comparison avoids the force-cast crash on unexpected types.
        guard CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let axWindow = window as! AXUIElement   // safe: type confirmed above
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef) == .success,
              let title = titleRef as? String, !title.isEmpty else { return nil }
        return title
    }

    // MARK: - Type classification
    //
    // Order matters — check more specific types first.

    private func classifyType(_ pb: NSPasteboard) -> ClipContentType {
        if isRichClipboard(pb) { return .rich }
        if imageData(from: pb) != nil { return .image }
        if pb.types?.contains(.fileURL) == true { return .file }
        if pb.types?.contains(.color) == true { return .color }

        if let str = pb.string(forType: .string),
           str.hasPrefix("http://") || str.hasPrefix("https://") || str.hasPrefix("ftp://") {
            return .url
        }

        if let str = pb.string(forType: .string), looksLikeCode(str) {
            return .code
        }

        return .text
    }

    private func isRichClipboard(_ pb: NSPasteboard) -> Bool {
        if pb.data(forType: .rtfd) != nil ||
           pb.data(forType: .flatRTFD) != nil {
            return true
        }

        let html = pb.string(forType: .html)
            ?? pb.string(forType: NSPasteboard.PasteboardType("text/html"))
            ?? ""
        return html.localizedCaseInsensitiveContains("<img") ||
            html.localizedCaseInsensitiveContains("data:image")
    }

    private func richPayload(from pb: NSPasteboard) -> RichPasteboardPayload? {
        guard isRichClipboard(pb) else { return nil }

        let plainText = pb.string(forType: .string) ?? ""
        let html = pb.string(forType: .html)
            ?? pb.string(forType: NSPasteboard.PasteboardType("text/html"))
        let rtfd = pb.data(forType: .flatRTFD) ?? pb.data(forType: .rtfd)
        let rtf = pb.data(forType: .rtf)

        guard !plainText.isEmpty || html?.isEmpty == false || rtfd?.isEmpty == false else {
            return nil
        }

        return RichPasteboardPayload(
            plainText: plainText,
            html: html,
            rtfd: rtfd,
            rtf: rtf
        )
    }

    private func imageData(from pb: NSPasteboard) -> Data? {
        for type in Self.imagePasteboardTypes {
            if let data = pb.data(forType: type),
               let normalized = normalizedPNGData(from: data) {
                return normalized
            }
        }

        for item in pb.pasteboardItems ?? [] {
            for type in Self.imagePasteboardTypes {
                if let data = item.data(forType: type),
                   let normalized = normalizedPNGData(from: data) {
                    return normalized
                }
            }

        }

        return nil
    }

    private func imageData(fromFileURLString value: String) -> Data? {
        if let url = URL(string: value), url.isFileURL {
            return imageData(fromFileURL: url)
        }

        return imageData(fromFileURL: URL(fileURLWithPath: value))
    }

    private func imageData(fromFileURL url: URL) -> Data? {
        guard url.isFileURL,
              let raw = try? Data(contentsOf: url),
              let normalized = normalizedPNGData(from: raw)
        else { return nil }
        return normalized
    }

    private func normalizedPNGData(from data: Data) -> Data? {
        guard !data.isEmpty else { return nil }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
           NSImage(data: data) != nil {
            return data
        }

        guard let image = NSImage(data: data),
              image.size.width > 0,
              image.size.height > 0
        else { return nil }

        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            return bitmap.representation(using: .png, properties: [:])
        }

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: max(Int(image.size.width), 1),
            pixelsHigh: max(Int(image.size.height), 1),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )

        guard let bitmap else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(
            in: NSRect(origin: .zero, size: image.size),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    private func imagePasteboardItem(fromPNGData data: Data) -> NSPasteboardItem? {
        guard let image = NSImage(data: data) else { return nil }

        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        item.setData(data, forType: NSPasteboard.PasteboardType("public.png"))
        if let tiffData = image.tiffRepresentation {
            item.setData(tiffData, forType: .tiff)
        }
        if let fileURL = temporaryAppendImageURL(for: data) {
            item.setString(fileURL.absoluteString, forType: .fileURL)
            item.setString(fileURL.absoluteString, forType: NSPasteboard.PasteboardType("public.file-url"))
        }
        return item
    }

    private func mixedAppendPasteboardItem(for session: AppendSession) -> NSPasteboardItem? {
        let item = NSPasteboardItem()
        let plainText = session.combinedText

        if !plainText.isEmpty {
            item.setString(plainText, forType: .string)
        }

        if let html = mixedAppendHTML(for: session) {
            item.setString(html, forType: .html)
        }

        if let attributed = mixedAppendAttributedString(for: session) {
            let range = NSRange(location: 0, length: attributed.length)
            if let rtfdWrapper = try? attributed.fileWrapper(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd]
            ),
               let rtfdData = rtfdWrapper.serializedRepresentation {
                item.setData(rtfdData, forType: .rtfd)
                item.setData(rtfdData, forType: .flatRTFD)
            }

            if let rtfData = try? attributed.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            ) {
                item.setData(rtfData, forType: .rtf)
            }
        }

        return item.types.isEmpty ? nil : item
    }

    private func mixedAppendHTML(for session: AppendSession) -> String? {
        var body = ""
        for clip in session.clips {
            switch clip {
            case .text(let value):
                let escaped = escapeHTML(value)
                    .replacingOccurrences(of: "\n", with: "<br>")
                body += "<div>\(escaped)</div>"
            case .image(let data):
                body += """
                <div><img src="data:image/png;base64,\(data.base64EncodedString())" style="max-width:480px;height:auto;"></div>
                """
            }
        }

        guard !body.isEmpty else { return nil }
        return """
        <!doctype html><html><head><meta charset="utf-8"></head><body>\(body)</body></html>
        """
    }

    private func mixedAppendAttributedString(for session: AppendSession) -> NSAttributedString? {
        let result = NSMutableAttributedString()
        var needsSeparator = false

        for clip in session.clips {
            if needsSeparator {
                result.append(NSAttributedString(string: "\n"))
            }

            switch clip {
            case .text(let value):
                result.append(NSAttributedString(string: value))
            case .image(let data):
                guard let image = NSImage(data: data) else { continue }
                let attachment = NSTextAttachment()
                attachment.image = imageForAttachment(image)
                result.append(NSAttributedString(attachment: attachment))
            }

            needsSeparator = true
        }

        return result.length == 0 ? nil : result
    }

    private func imageForAttachment(_ image: NSImage) -> NSImage {
        let maxWidth: CGFloat = 520
        let maxHeight: CGFloat = 360
        let widthRatio = maxWidth / max(image.size.width, 1)
        let heightRatio = maxHeight / max(image.size.height, 1)
        let scale = min(widthRatio, heightRatio, 1)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)

        guard size.width > 0, size.height > 0, scale < 1 else { return image }
        let scaled = NSImage(size: size)
        scaled.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: size),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy,
            fraction: 1
        )
        scaled.unlockFocus()
        return scaled
    }

    private func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private func temporaryAppendImageURL(for pngData: Data) -> URL? {
        let digest = SHA256.hash(data: pngData)
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdAppendImages", isDirectory: true)
        let fileURL = directory.appendingPathComponent("\(digest).png")

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try pngData.write(to: fileURL, options: .atomic)
            return fileURL
        } catch {
            return nil
        }
    }

    private func pasteboardLooksLikeAttachment(_ pb: NSPasteboard) -> Bool {
        let types = Set((pb.types ?? []).map(\.rawValue))
        if types.contains(where: { $0.contains("file") || $0.contains("image") || $0.contains("png") || $0.contains("tiff") || $0.contains("jpeg") || $0.contains("heic") }) {
            return true
        }

        return (pb.pasteboardItems ?? []).contains { item in
            item.types.map(\.rawValue).contains { type in
                type.contains("file") || type.contains("image") || type.contains("png") || type.contains("tiff") || type.contains("jpeg") || type.contains("heic")
            }
        }
    }

    private func looksLikeCode(_ s: String) -> Bool {
        let lines = s.components(separatedBy: .newlines)
        guard lines.count >= 2 else { return false }
        // "let" and "var" are too common in English prose; require two distinct tokens to match.
        let codeTokens = ["{", "}", "func ", "def ", "const ",
                          "import ", "->", "=>", "SELECT ", "FROM ", "class "]
        let matchCount = codeTokens.filter { s.contains($0) }.count
        return matchCount >= 2
    }

    // MARK: - Hash

    private func sha256(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Thumbnail

    private func makeThumbnail(from data: Data, maxWidth: CGFloat = 400, maxHeight: CGFloat = 300) -> Data? {
        guard let source = NSImage(data: data) else { return nil }
        let srcSize = source.size
        guard srcSize.width > 0, srcSize.height > 0 else { return nil }

        let widthRatio  = maxWidth  / srcSize.width
        let heightRatio = maxHeight / srcSize.height
        let scale       = min(widthRatio, heightRatio, 1.0)
        let thumbSize   = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)

        let thumb = NSImage(size: thumbSize)
        thumb.lockFocus()
        source.draw(
            in: NSRect(origin: .zero, size: thumbSize),
            from: NSRect(origin: .zero, size: srcSize),
            operation: .copy,
            fraction: 1.0
        )
        thumb.unlockFocus()

        guard let cgImage = thumb.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
    }
}

// MARK: - Append session notifications

public struct AppendSessionSnapshot: Sendable {
    public let isActive: Bool
    public let itemCount: Int
    public let characterCount: Int
    public let preview: String

    public init(isActive: Bool, itemCount: Int, characterCount: Int, preview: String) {
        self.isActive = isActive
        self.itemCount = itemCount
        self.characterCount = characterCount
        self.preview = preview
    }
}

public extension Notification.Name {
    static let cmdAppendSessionChanged = Notification.Name("com.cmd.appendSessionChanged")
}

// MARK: - NSColor hex helper

extension NSColor {
    var hexString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(rgb.redComponent * 255)
        let g = Int(rgb.greenComponent * 255)
        let b = Int(rgb.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
