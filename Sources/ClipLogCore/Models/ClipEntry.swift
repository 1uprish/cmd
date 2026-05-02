import AppKit
import Foundation

// MARK: - ClipEntry
//
// Immutable value type representing one clipboard capture.
// Written to SQLite via ClipStore; shown in HUD and menu bar panel.

public struct ClipEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let copiedAt: Date
    public let contentType: ClipContentType
    public let contentData: Data          // encrypted at rest in DB; decrypted in memory
    public let contentHash: String        // SHA-256 hex, used for dedup
    public let sourceBundleID: String
    public let charCount: Int?
    public var isPinned: Bool
    public var isSensitive: Bool
    public var ocrText: String?
    public var mediaPath: String?
    public var sourceWindowTitle: String?

    public init(
        id: UUID = UUID(),
        copiedAt: Date = Date(),
        contentType: ClipContentType,
        contentData: Data,
        contentHash: String,
        sourceBundleID: String,
        charCount: Int?,
        isPinned: Bool = false,
        isSensitive: Bool = false,
        ocrText: String? = nil,
        mediaPath: String? = nil,
        sourceWindowTitle: String? = nil
    ) {
        self.id = id
        self.copiedAt = copiedAt
        self.contentType = contentType
        self.contentData = contentData
        self.contentHash = contentHash
        self.sourceBundleID = sourceBundleID
        self.charCount = charCount
        self.isPinned = isPinned
        self.isSensitive = isSensitive
        self.ocrText = ocrText
        self.mediaPath = mediaPath
        self.sourceWindowTitle = sourceWindowTitle
    }

    // Display string for HUD preview (truncated)
    public var previewText: String {
        if isSensitive {
            let raw = String(data: contentData, encoding: .utf8) ?? ""
            return SensitiveContentDetector.redactedPreview(for: raw)
        }

        switch contentType {
        case .text, .url, .code:
            let str = String(data: contentData, encoding: .utf8) ?? ""
            let single = str.replacingOccurrences(of: "\n", with: " ")
            return single.count > 80 ? String(single.prefix(80)) + "…" : single
        case .image:
            if let text = ocrText, !text.isEmpty {
                return text.count > 80 ? String(text.prefix(80)) + "…" : text
            }
            return "Image"
        case .rich:
            let str = String(data: contentData, encoding: .utf8) ?? ""
            let single = str.replacingOccurrences(of: "\n", with: " ")
            if !single.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return single.count > 80 ? String(single.prefix(80)) + "…" : single
            }
            return "Mixed content"
        case .file:
            let raw = String(data: contentData, encoding: .utf8) ?? ""
            let parts = raw.components(separatedBy: "\n").filter { !$0.isEmpty }
            if parts.count > 1 {
                return "\(parts.count) files"
            }
            return URL(string: parts.first ?? raw)?.lastPathComponent ?? raw
        case .color:
            return String(data: contentData, encoding: .utf8) ?? ""
        }
    }

    // App display name derived from bundle ID (best effort)
    public var sourceAppName: String {
        if let name = NSRunningApplication
            .runningApplications(withBundleIdentifier: sourceBundleID)
            .first?.localizedName,
           !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return name
        }

        let fallback = sourceBundleID
            .components(separatedBy: ".")
            .last?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized

        return fallback?.isEmpty == false ? fallback! : "Unknown App"
    }
}

// MARK: - ClipContentType

public enum ClipContentType: String, CaseIterable, Sendable {
    case text
    case url
    case code
    case image
    case rich
    case file
    case color
}
