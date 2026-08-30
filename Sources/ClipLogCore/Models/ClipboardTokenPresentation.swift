import Foundation

public struct ClipboardTokenPresentation: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case text
        case link
        case code
        case image
        case rich
        case file
        case color
        case email
        case secure
    }

    public let kind: Kind
    public let label: String

    public init?(entry: ClipEntry) {
        if entry.isSensitive {
            kind = .secure
            label = "Copied securely"
            return
        }

        let raw = String(data: entry.contentData, encoding: .utf8) ?? entry.previewText
        switch entry.contentType {
        case .image:
            kind = .image
            label = "Image"
        case .url:
            guard let value = Self.normalized(raw) else { return nil }
            kind = .link
            label = Self.domainLabel(for: value) ?? Self.bounded(value)
        case .text:
            guard let value = Self.normalized(raw) else { return nil }
            kind = Self.isEmailLike(value) ? .email : .text
            label = Self.bounded(value)
        case .code:
            guard let value = Self.normalized(raw) else { return nil }
            kind = .code
            label = Self.bounded(value)
        case .rich:
            guard let value = Self.normalized(raw) else { return nil }
            kind = Self.isEmailLike(value) ? .email : .rich
            label = Self.bounded(value)
        case .file:
            guard let value = Self.normalized(entry.previewText) else { return nil }
            kind = .file
            label = Self.bounded(value)
        case .color:
            guard let value = Self.normalized(raw) else { return nil }
            kind = .color
            label = Self.bounded(value)
        }
    }

    private static func normalized(_ raw: String) -> String? {
        let value = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return value.isEmpty ? nil : value
    }

    private static func bounded(_ value: String, limit: Int = 48) -> String {
        guard value.count > limit else { return value }
        return String(value.prefix(limit)) + "…"
    }

    private static func domainLabel(for value: String) -> String? {
        let candidate = value.contains("://") ? value : "https://\(value)"
        guard var host = URLComponents(string: candidate)?.host, !host.isEmpty else { return nil }
        if host.lowercased().hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    private static func isEmailLike(_ value: String) -> Bool {
        guard value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        return value.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
    }
}
