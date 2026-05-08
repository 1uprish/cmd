import AppKit
import ApplicationServices
import CryptoKit
import Foundation
import os

// MARK: - PasteboardWatcher
//
// Polls NSPasteboard.changeCount on a throttled interval.
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

        var imageByteCount: Int {
            clips.reduce(0) { total, clip in
                total + (clip.imageData?.count ?? 0)
            }
        }

        var imageCount: Int {
            clips.reduce(0) { total, clip in
                total + (clip.imageData == nil ? 0 : 1)
            }
        }

        var textCount: Int {
            clips.reduce(0) { total, clip in
                total + (clip.textValue?.isEmpty == false ? 1 : 0)
            }
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
    private let imageCaptureQueue = DispatchQueue(label: "com.cmd.pasteboard.imageCapture", qos: .utility)
    private var imageCaptureInFlight = false
    private var appendImageCaptureInFlight = false
    private static let pollInterval: DispatchTimeInterval = .milliseconds(350)
    private static let slowPollThreshold: TimeInterval = 0.25
    private static let maxInlineImageBytes = 18 * 1024 * 1024
    private static let maxRichPayloadBytes = 12 * 1024 * 1024
    private static let maxAppendClips = 24
    private static let maxAppendImageBytes = 24 * 1024 * 1024
    private static let maxAppendTextCharacters = 60_000
    private static let maxRichAppendImageBytes = 4 * 1024 * 1024
    private static let maxRichAppendImages = 3

    private static let imagePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("org.webmproject.webp")
    ]

    private static let compressedImagePasteboardTypes: [NSPasteboard.PasteboardType] = [
        .png,
        NSPasteboard.PasteboardType("public.png"),
        NSPasteboard.PasteboardType("public.jpeg"),
        NSPasteboard.PasteboardType("public.heic"),
        NSPasteboard.PasteboardType("public.heif"),
        NSPasteboard.PasteboardType("com.compuserve.gif"),
        NSPasteboard.PasteboardType("org.webmproject.webp")
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
    private var imageOCREnabled = false

    public func updateUserExcludedBundles(_ bundles: Set<String>) {
        DiagnosticsLogbook.shared.actionInput(
            feature: "pasteboard",
            action: "update_excluded_bundles",
            details: ["bundleCount": "\(bundles.count)"]
        )
        queue.async {
            self.userExcludedBundles = bundles
            DiagnosticsLogbook.shared.actionOutput(
                feature: "pasteboard",
                action: "update_excluded_bundles",
                details: ["success": "true", "bundleCount": "\(bundles.count)"]
            )
        }
    }

    public func updateImageOCREnabled(_ enabled: Bool) {
        DiagnosticsLogbook.shared.actionInput(
            feature: "pasteboard",
            action: "update_image_ocr",
            details: ["enabled": "\(enabled)"]
        )
        queue.async {
            self.imageOCREnabled = enabled
            DiagnosticsLogbook.shared.actionOutput(
                feature: "pasteboard",
                action: "update_image_ocr",
                details: ["success": "true", "enabled": "\(enabled)"]
            )
        }
    }

    private static let logger = Logger(subsystem: "com.cliplog", category: "PasteboardWatcher")

    // MARK: - Start / stop

    public func start() {
        DiagnosticsLogbook.shared.actionInput(feature: "pasteboard", action: "start_watcher")
        DiagnosticsLogbook.shared.record("pasteboard_watcher_started", category: "pasteboard")
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Self.pollInterval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        self.timer = t
        DiagnosticsLogbook.shared.actionOutput(feature: "pasteboard", action: "start_watcher", details: ["success": "true"])
    }

    public func stop() {
        DiagnosticsLogbook.shared.actionInput(feature: "pasteboard", action: "stop_watcher")
        DiagnosticsLogbook.shared.record("pasteboard_watcher_stopped", category: "pasteboard")
        timer?.cancel()
        timer = nil
        shutdownAppendSession()
        DiagnosticsLogbook.shared.actionOutput(feature: "pasteboard", action: "stop_watcher", details: ["success": "true"])
    }

    // MARK: - Poll

    private func poll() {
        let startedAt = Date()
        var entryType = "none"
        var buildEntryMs = 0
        var ingestMs = 0
        var appendMs = 0
        defer {
            let elapsed = Date().timeIntervalSince(startedAt)
            if elapsed >= Self.slowPollThreshold {
                DiagnosticsLogbook.shared.record(
                    "slow_pasteboard_poll",
                    category: "performance",
                    details: [
                        "durationMs": "\(Int(elapsed * 1000))",
                        "entryType": entryType,
                        "buildEntryMs": "\(buildEntryMs)",
                        "ingestMs": "\(ingestMs)",
                        "appendMs": "\(appendMs)"
                    ]
                )
            }
        }

        let pb = NSPasteboard.general
        let current = pb.changeCount
        guard current != lastChangeCount else { return }
        DiagnosticsLogbook.shared.actionInput(
            feature: "pasteboard",
            action: "poll_change",
            details: ["changeCount": "\(current)"]
        )
        lastChangeCount = current

        // Password managers write NSPasteboardTypeConcealed before the real data.
        if pb.types?.contains(.concealed) == true {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "pasteboard",
                action: "poll_change",
                details: ["success": "false", "reason": "concealed_type"]
            )
            return
        }

        let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""

        if Self.knownPasswordManagers.contains(bundle) ||
           Self.knownTransientSources.contains(bundle) ||
           userExcludedBundles.contains(bundle) {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "pasteboard",
                action: "poll_change",
                details: ["success": "false", "reason": "excluded_source", "sourceApp": bundle]
            )
            return
        }

        // Append session: copied strings and images become one paste-ready
        // pasteboard payload. Text fields receive the combined string; rich
        // targets can also receive the image objects.
        if appendSession != nil {
            let appendStartedAt = Date()
            DiagnosticsLogbook.shared.actionProcess(
                feature: "pasteboard",
                action: "poll_change",
                details: ["step": "append_merge", "sourceApp": bundle]
            )
            mergeCurrentPasteboardIntoAppendSession(pb)
            appendMs = Self.milliseconds(since: appendStartedAt)
            entryType = "append"
            DiagnosticsLogbook.shared.actionOutput(
                feature: "pasteboard",
                action: "poll_change",
                details: ["success": "true", "result": "append", "durationMs": "\(Self.milliseconds(since: startedAt))"]
            )
            return
        }

        let classifiedType = classifyType(pb)
        DiagnosticsLogbook.shared.actionProcess(
            feature: "pasteboard",
            action: "poll_change",
            details: ["step": "classify", "entryType": classifiedType.rawValue, "sourceApp": bundle]
        )
        if classifiedType == .image {
            entryType = "image_deferred"
            scheduleImageCapture(sourceBundle: bundle, changeCount: current)
            DiagnosticsLogbook.shared.actionOutput(
                feature: "pasteboard",
                action: "poll_change",
                details: ["success": "true", "result": "image_deferred"]
            )
            return
        }

        let buildStartedAt = Date()
        guard let entry = buildEntry(from: pb, sourceBundle: bundle, windowTitle: nil, forcedType: classifiedType) else {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "pasteboard",
                action: "poll_change",
                details: ["success": "false", "reason": "empty_entry", "entryType": classifiedType.rawValue]
            )
            return
        }
        buildEntryMs = Self.milliseconds(since: buildStartedAt)
        entryType = entry.contentType.rawValue

        // Track the last plain-text content for potential future appends.
        if let str = pb.string(forType: .string) {
            lastClipString = str
        }

        ingestMs = publishCapturedEntry(entry)
        DiagnosticsLogbook.shared.actionOutput(
            feature: "pasteboard",
            action: "poll_change",
            details: [
                "success": "true",
                "entryType": entry.contentType.rawValue,
                "buildEntryMs": "\(buildEntryMs)",
                "ingestMs": "\(ingestMs)",
                "durationMs": "\(Self.milliseconds(since: startedAt))"
            ]
        )
    }

    private func scheduleImageCapture(sourceBundle: String, changeCount: Int) {
        guard !imageCaptureInFlight else {
            DiagnosticsLogbook.shared.record(
                "image_capture_dropped",
                category: "pasteboard",
                details: ["reason": "capture_in_flight"]
            )
            return
        }

        imageCaptureInFlight = true
        DiagnosticsLogbook.shared.record(
            "image_capture_deferred",
            category: "pasteboard",
            details: ["changeCount": "\(changeCount)"]
        )

        imageCaptureQueue.async { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            let pb = NSPasteboard.general
            guard pb.changeCount == changeCount else {
                self.finishDeferredImageCapture(
                    changeCount: changeCount,
                    buildMs: Self.milliseconds(since: startedAt),
                    ingestMs: 0,
                    result: "stale"
                )
                return
            }

            guard let entry = self.buildEntry(
                from: pb,
                sourceBundle: sourceBundle,
                windowTitle: nil,
                forcedType: .image
            ) else {
                self.finishDeferredImageCapture(
                    changeCount: changeCount,
                    buildMs: Self.milliseconds(since: startedAt),
                    ingestMs: 0,
                    result: "empty"
                )
                return
            }

            let buildMs = Self.milliseconds(since: startedAt)
            let ingestMs = self.publishCapturedEntry(entry)
            self.finishDeferredImageCapture(
                changeCount: changeCount,
                buildMs: buildMs,
                ingestMs: ingestMs,
                result: "captured"
            )
        }
    }

    private func finishDeferredImageCapture(
        changeCount: Int,
        buildMs: Int,
        ingestMs: Int,
        result: String
    ) {
        DiagnosticsLogbook.shared.record(
            "deferred_image_capture_completed",
            category: "pasteboard",
            details: [
                "changeCount": "\(changeCount)",
                "buildMs": "\(buildMs)",
                "ingestMs": "\(ingestMs)",
                "result": result
            ]
        )

        queue.async {
            self.imageCaptureInFlight = false
        }
    }

    private func publishCapturedEntry(_ entry: ClipEntry) -> Int {
        let ingestStartedAt = Date()
        onNewEntry?(entry)
        let ingestMs = Self.milliseconds(since: ingestStartedAt)

        schedulePostProcessing(for: entry)
        return ingestMs
    }

    private func schedulePostProcessing(for entry: ClipEntry) {
        if [.text, .url, .code, .rich].contains(entry.contentType), !entry.isSensitive {
            let capturedEntry = entry
            Task.detached(priority: .utility) { [weak self] in
                guard let store = self?.store else { return }
                await EmbeddingService.shared.embed(entry: capturedEntry, store: store)
            }
        }

        if imageOCREnabled, entry.contentType == .image, let mediaPath = entry.mediaPath {
            let mediaDir = AppStoragePaths.mediaDirectory
            let imageURL = mediaDir.appendingPathComponent(mediaPath)
            let entryID = entry.id
            Task.detached(priority: .utility) { [weak self] in
                guard let store = self?.store else { return }
                await OCRService.shared.processAndStore(entryID: entryID, imageURL: imageURL, store: store)
            }
        }
    }

    // MARK: - Append session

    private func startAppendSession(expiringAfter timeout: TimeInterval) {
        DiagnosticsLogbook.shared.actionInput(
            feature: "append",
            action: "start_session",
            details: ["timeoutSeconds": "\(Int(timeout))"]
        )
        DiagnosticsLogbook.shared.record("append_started", category: "append")
        appendSessionTimeout = timeout
        appendSession = AppendSession(
            clips: [],
            expiresAt: Date().addingTimeInterval(timeout)
        )
        DiagnosticsLogbook.shared.actionProcess(feature: "append", action: "start_session", details: ["step": "publish_snapshot"])
        publishAppendSnapshot()
        scheduleAppendExpiry(after: timeout)
        DiagnosticsLogbook.shared.actionOutput(feature: "append", action: "start_session", details: ["success": "true"])
    }

    private func mergeCurrentPasteboardIntoAppendSession(_ pb: NSPasteboard) {
        DiagnosticsLogbook.shared.actionInput(
            feature: "append",
            action: "merge_current_pasteboard",
            details: ["changeCount": "\(pb.changeCount)", "hasImage": "\(hasImageType(pb))"]
        )
        if hasImageType(pb) {
            DiagnosticsLogbook.shared.actionProcess(feature: "append", action: "merge_current_pasteboard", details: ["step": "schedule_image_capture"])
            scheduleAppendImageCapture(changeCount: pb.changeCount)
            DiagnosticsLogbook.shared.actionOutput(feature: "append", action: "merge_current_pasteboard", details: ["success": "true", "result": "image_deferred"])
            return
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

        DiagnosticsLogbook.shared.actionProcess(
            feature: "append",
            action: "merge_current_pasteboard",
            details: ["step": "merge_text", "clipCount": textClip == nil ? "0" : "1"]
        )
        mergeIntoAppendSession([textClip].compactMap { $0 }, pasteboard: pb)
        DiagnosticsLogbook.shared.actionOutput(
            feature: "append",
            action: "merge_current_pasteboard",
            details: ["success": "true", "result": textClip == nil ? "ignored" : "merged"]
        )
    }

    private func scheduleAppendImageCapture(changeCount: Int) {
        guard !appendImageCaptureInFlight else {
            DiagnosticsLogbook.shared.record(
                "append_image_capture_dropped",
                category: "append",
                details: ["reason": "capture_in_flight"]
            )
            return
        }

        appendImageCaptureInFlight = true
        DiagnosticsLogbook.shared.record(
            "append_image_capture_deferred",
            category: "append",
            details: ["changeCount": "\(changeCount)"]
        )

        imageCaptureQueue.async { [weak self] in
            guard let self else { return }
            let startedAt = Date()
            let pb = NSPasteboard.general
            guard pb.changeCount == changeCount else {
                self.finishAppendImageCapture(
                    clips: [],
                    changeCount: changeCount,
                    captureMs: Self.milliseconds(since: startedAt),
                    result: "stale"
                )
                return
            }

            var clips: [AppendClip] = []
            if let newString = pb.string(forType: .string),
               !newString.isEmpty,
               !Self.attachmentLabelFallbacks.contains(newString.trimmingCharacters(in: .whitespacesAndNewlines)) {
                clips.append(.text(newString))
            }

            if let data = self.imageData(from: pb), !data.isEmpty {
                clips.append(.image(data))
            }

            self.finishAppendImageCapture(
                clips: clips,
                changeCount: changeCount,
                captureMs: Self.milliseconds(since: startedAt),
                result: clips.isEmpty ? "empty" : "captured"
            )
        }
    }

    private func finishAppendImageCapture(
        clips: [AppendClip],
        changeCount: Int,
        captureMs: Int,
        result: String
    ) {
        queue.async {
            self.appendImageCaptureInFlight = false
            DiagnosticsLogbook.shared.record(
                "append_image_capture_completed",
                category: "append",
                details: [
                    "changeCount": "\(changeCount)",
                    "captureMs": "\(captureMs)",
                    "result": result,
                    "clipCount": "\(clips.count)"
                ]
            )

            guard !clips.isEmpty else { return }
            DiagnosticsLogbook.shared.actionProcess(
                feature: "append",
                action: "image_capture",
                details: ["step": "merge_clips", "clipCount": "\(clips.count)"]
            )
            self.mergeIntoAppendSession(clips, pasteboard: NSPasteboard.general)
        }
    }

    private func mergeIntoAppendSession(_ newClip: AppendClip, pasteboard pb: NSPasteboard) {
        mergeIntoAppendSession([newClip], pasteboard: pb)
    }

    private func mergeIntoAppendSession(_ newClips: [AppendClip], pasteboard pb: NSPasteboard) {
        DiagnosticsLogbook.shared.actionInput(
            feature: "append",
            action: "merge_clips",
            details: ["incomingCount": "\(newClips.count)"]
        )
        guard var session = appendSession else {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "append",
                action: "merge_clips",
                details: ["success": "false", "reason": "no_session"]
            )
            return
        }
        guard !newClips.isEmpty else {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "append",
                action: "merge_clips",
                details: ["success": "false", "reason": "empty_input"]
            )
            return
        }

        var didAppend = false
        for newClip in newClips {
            if shouldAppend(newClip, to: session),
               canAppend(newClip, to: session) {
                session.clips.append(newClip)
                didAppend = true
            }
        }

        guard didAppend else {
            lastChangeCount = pb.changeCount
            DiagnosticsLogbook.shared.actionOutput(
                feature: "append",
                action: "merge_clips",
                details: ["success": "false", "reason": "duplicate_or_limit"]
            )
            return
        }

        session.expiresAt = Date().addingTimeInterval(appendSessionTimeout)
        appendSession = session

        DiagnosticsLogbook.shared.actionProcess(
            feature: "append",
            action: "merge_clips",
            details: [
                "step": "write_session",
                "clipCount": "\(session.clips.count)",
                "imageCount": "\(session.imageCount)",
                "characters": "\(session.characterCount)"
            ]
        )
        writeAppendSession(session, to: pb)
        lastChangeCount = pb.changeCount
        lastClipString = session.combinedText

        publishAppendSnapshot()
        scheduleAppendExpiry(after: appendSessionTimeout)
        DiagnosticsLogbook.shared.actionOutput(
            feature: "append",
            action: "merge_clips",
            details: [
                "success": "true",
                "clipCount": "\(session.clips.count)",
                "imageCount": "\(session.imageCount)",
                "characters": "\(session.characterCount)"
            ]
        )
    }

    private func shouldAppend(_ clip: AppendClip, to session: AppendSession) -> Bool {
        switch clip {
        case .text(let value):
            return value != session.combinedText && session.clips.last?.textValue != value
        case .image(let data):
            return session.clips.last?.imageData != data
        }
    }

    private func canAppend(_ clip: AppendClip, to session: AppendSession) -> Bool {
        guard session.clips.count < Self.maxAppendClips else {
            logAppendSkip(reason: "clip_limit", value: session.clips.count, limit: Self.maxAppendClips)
            return false
        }

        switch clip {
        case .text(let value):
            let newCount = session.characterCount + value.count
            guard newCount <= Self.maxAppendTextCharacters else {
                logAppendSkip(reason: "text_character_limit", value: newCount, limit: Self.maxAppendTextCharacters)
                return false
            }
            return true
        case .image(let data):
            let newCount = session.imageByteCount + data.count
            guard newCount <= Self.maxAppendImageBytes else {
                logAppendSkip(reason: "image_byte_limit", value: newCount, limit: Self.maxAppendImageBytes)
                return false
            }
            return true
        }
    }

    private func logAppendSkip(reason: String, value: Int, limit: Int) {
        DiagnosticsLogbook.shared.record(
            "append_clip_skipped",
            category: "append",
            details: [
                "reason": reason,
                "value": "\(value)",
                "limit": "\(limit)"
            ]
        )
    }

    private func writeAppendSession(_ session: AppendSession, to pb: NSPasteboard) {
        let startedAt = Date()
        DiagnosticsLogbook.shared.actionInput(
            feature: "append",
            action: "write_session",
            details: [
                "clipCount": "\(session.clips.count)",
                "imageCount": "\(session.imageCount)",
                "characters": "\(session.characterCount)"
            ]
        )
        defer {
            let elapsedMs = Self.milliseconds(since: startedAt)
            DiagnosticsLogbook.shared.actionOutput(
                feature: "append",
                action: "write_session",
                details: [
                    "success": "true",
                    "durationMs": "\(elapsedMs)",
                    "clipCount": "\(session.clips.count)",
                    "imageCount": "\(session.imageCount)",
                    "characters": "\(session.characterCount)"
                ]
            )
            if elapsedMs >= 250 {
                DiagnosticsLogbook.shared.record(
                    "slow_append_pasteboard_write",
                    category: "performance",
                    details: [
                        "durationMs": "\(elapsedMs)",
                        "clipCount": "\(session.clips.count)",
                        "imageCount": "\(session.imageCount)",
                        "imageBytes": "\(session.imageByteCount)",
                        "characters": "\(session.characterCount)"
                    ]
                )
            }
        }

        pb.clearContents()
        DiagnosticsLogbook.shared.actionProcess(feature: "append", action: "write_session", details: ["step": "clear_pasteboard"])

        if session.hasText, session.hasImage,
           let mixedItem = mixedAppendPasteboardItem(for: session) {
            DiagnosticsLogbook.shared.actionProcess(feature: "append", action: "write_session", details: ["step": "write_mixed_item"])
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
            DiagnosticsLogbook.shared.actionProcess(
                feature: "append",
                action: "write_session",
                details: ["step": "write_objects", "writerCount": "\(writers.count)"]
            )
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
        DiagnosticsLogbook.shared.actionInput(feature: "append", action: "end_session")
        DiagnosticsLogbook.shared.record("append_ended", category: "append")
        appendExpiryWorkItem?.cancel()
        appendExpiryWorkItem = nil
        DiagnosticsLogbook.shared.actionProcess(feature: "append", action: "end_session", details: ["step": "commit_if_needed"])
        commitAppendSessionIfNeeded()
        appendSession = nil
        publishAppendSnapshot(isActive: false)
        DiagnosticsLogbook.shared.actionOutput(feature: "append", action: "end_session", details: ["success": "true"])
    }

    private func shutdownAppendSession() {
        appendExpiryWorkItem?.cancel()
        appendExpiryWorkItem = nil
        appendSession = nil
        publishAppendSnapshot(isActive: false)
    }

    private func commitAppendSessionIfNeeded() {
        DiagnosticsLogbook.shared.actionInput(feature: "append", action: "commit_session")
        guard let session = appendSession, !session.clips.isEmpty else {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "append",
                action: "commit_session",
                details: ["success": "false", "reason": "empty_session"]
            )
            return
        }
        guard let entry = buildEntry(
            from: NSPasteboard.general,
            sourceBundle: Bundle.main.bundleIdentifier ?? "com.cmd.app",
            windowTitle: "Append"
        ) else {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "append",
                action: "commit_session",
                details: ["success": "false", "reason": "build_entry_failed"]
            )
            return
        }

        _ = publishCapturedEntry(entry)
        DiagnosticsLogbook.shared.actionOutput(
            feature: "append",
            action: "commit_session",
            details: ["success": "true", "entryType": entry.contentType.rawValue, "clipCount": "\(session.clips.count)"]
        )
    }

    private func publishAppendSnapshot(isActive: Bool = true) {
        let snapshot: AppendSessionSnapshot
        if isActive, let session = appendSession {
            snapshot = AppendSessionSnapshot(
                isActive: true,
                itemCount: session.clips.count,
                characterCount: session.characterCount,
                preview: session.previewText,
                textCount: session.textCount,
                imageCount: session.imageCount,
                imageByteCount: session.imageByteCount,
                expiresAt: session.expiresAt
            )
        } else {
            snapshot = AppendSessionSnapshot(
                isActive: false,
                itemCount: 0,
                characterCount: 0,
                preview: "",
                textCount: 0,
                imageCount: 0,
                imageByteCount: 0,
                expiresAt: nil
            )
        }

        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cmdAppendSessionChanged, object: snapshot)
        }
    }

    // MARK: - Entry construction

    private func buildEntry(
        from pb: NSPasteboard,
        sourceBundle: String,
        windowTitle: String?,
        forcedType: ClipContentType? = nil
    ) -> ClipEntry? {
        let type = forcedType ?? classifyType(pb)
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
            let imageStartedAt = Date()
            guard let originalData = imageData(from: pb) else { return nil }
            let imageDataMs = Self.milliseconds(since: imageStartedAt)
            if originalData.count > Self.maxInlineImageBytes {
                Self.logger.info("Skipped oversized image (\(originalData.count) bytes)")
                DiagnosticsLogbook.shared.record(
                    "oversized_image_skipped",
                    category: "pasteboard",
                    details: ["bytes": "\(originalData.count)"]
                )
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

            let thumbnailStartedAt = Date()
            guard let thumbnailJPEG = makeThumbnail(from: originalData) else { return nil }
            let thumbnailMs = Self.milliseconds(since: thumbnailStartedAt)
            let totalMs = Self.milliseconds(since: imageStartedAt)
            if totalMs >= 250 {
                DiagnosticsLogbook.shared.record(
                    "slow_image_capture",
                    category: "performance",
                    details: [
                        "durationMs": "\(totalMs)",
                        "imageDataMs": "\(imageDataMs)",
                        "thumbnailMs": "\(thumbnailMs)",
                        "bytes": "\(originalData.count)"
                    ]
                )
            }

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

    // MARK: - Type classification
    //
    // Order matters — check more specific types first.

    private func classifyType(_ pb: NSPasteboard) -> ClipContentType {
        if isRichClipboard(pb) { return .rich }
        if hasImageType(pb) { return .image }
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
        if pb.types?.contains(.rtfd) == true ||
           pb.types?.contains(.flatRTFD) == true {
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
        let rtfd = boundedData(from: pb, forType: .flatRTFD, maxBytes: Self.maxRichPayloadBytes)
            ?? boundedData(from: pb, forType: .rtfd, maxBytes: Self.maxRichPayloadBytes)
        let rtf = boundedData(from: pb, forType: .rtf, maxBytes: Self.maxRichPayloadBytes)

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

    private func hasImageType(_ pb: NSPasteboard) -> Bool {
        if let types = pb.types, Self.imagePasteboardTypes.contains(where: { types.contains($0) }) {
            return true
        }

        return pb.pasteboardItems?.contains { item in
            Self.imagePasteboardTypes.contains { item.types.contains($0) }
        } == true
    }

    private func imageData(from pb: NSPasteboard) -> Data? {
        for type in Self.compressedImagePasteboardTypes {
            if let data = boundedData(from: pb, forType: type, maxBytes: Self.maxInlineImageBytes),
               let normalized = normalizedPNGData(from: data) {
                return normalized
            }
        }

        for item in pb.pasteboardItems ?? [] {
            for type in Self.compressedImagePasteboardTypes {
                if let data = boundedData(from: item, forType: type, maxBytes: Self.maxInlineImageBytes),
                   let normalized = normalizedPNGData(from: data) {
                    return normalized
                }
            }
        }

        DiagnosticsLogbook.shared.record(
            "tiff_image_capture_skipped",
            category: "pasteboard",
            details: ["reason": "tiff_auto_capture_deferred"]
        )

        return nil
    }

    private func boundedData(
        from pb: NSPasteboard,
        forType type: NSPasteboard.PasteboardType,
        maxBytes: Int
    ) -> Data? {
        guard let data = pb.data(forType: type) else { return nil }
        return boundedData(data, type: type, maxBytes: maxBytes)
    }

    private func boundedData(
        from item: NSPasteboardItem,
        forType type: NSPasteboard.PasteboardType,
        maxBytes: Int
    ) -> Data? {
        guard let data = item.data(forType: type) else { return nil }
        return boundedData(data, type: type, maxBytes: maxBytes)
    }

    private func boundedData(
        _ data: Data,
        type: NSPasteboard.PasteboardType,
        maxBytes: Int
    ) -> Data? {
        guard data.count <= maxBytes else {
            DiagnosticsLogbook.shared.record(
                "oversized_pasteboard_payload_skipped",
                category: "pasteboard",
                details: [
                    "type": type.rawValue,
                    "bytes": "\(data.count)",
                    "limitBytes": "\(maxBytes)"
                ]
            )
            return nil
        }
        return data
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
        guard NSImage(data: data) != nil else { return nil }

        let item = NSPasteboardItem()
        item.setData(data, forType: .png)
        item.setData(data, forType: NSPasteboard.PasteboardType("public.png"))
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

        if shouldWriteRichAppendFormats(for: session) {
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
            }
        }

        return item.types.isEmpty ? nil : item
    }

    private func shouldWriteRichAppendFormats(for session: AppendSession) -> Bool {
        guard session.imageCount <= Self.maxRichAppendImages,
              session.imageByteCount <= Self.maxRichAppendImageBytes
        else {
            DiagnosticsLogbook.shared.record(
                "append_rich_formats_skipped",
                category: "append",
                details: [
                    "imageCount": "\(session.imageCount)",
                    "imageBytes": "\(session.imageByteCount)"
                ]
            )
            return false
        }
        return true
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

    private static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

// MARK: - Append session notifications

public struct AppendSessionSnapshot: Sendable {
    public let isActive: Bool
    public let itemCount: Int
    public let characterCount: Int
    public let preview: String
    public let textCount: Int
    public let imageCount: Int
    public let imageByteCount: Int
    public let expiresAt: Date?

    public var hasText: Bool {
        textCount > 0
    }

    public var hasImages: Bool {
        imageCount > 0
    }

    public init(
        isActive: Bool,
        itemCount: Int,
        characterCount: Int,
        preview: String,
        textCount: Int = 0,
        imageCount: Int = 0,
        imageByteCount: Int = 0,
        expiresAt: Date? = nil
    ) {
        self.isActive = isActive
        self.itemCount = itemCount
        self.characterCount = characterCount
        self.preview = preview
        self.textCount = textCount
        self.imageCount = imageCount
        self.imageByteCount = imageByteCount
        self.expiresAt = expiresAt
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
