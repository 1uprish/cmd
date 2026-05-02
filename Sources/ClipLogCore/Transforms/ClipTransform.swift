import Foundation

// MARK: - ClipTransform
//
// Text transformation operations available via the card right-click menu.
// Each case maps to a human-readable menu title and a pure String→String? function.

public enum ClipTransform: String, CaseIterable {
    case plainText        = "Paste as Plain Text"
    case uppercase        = "UPPERCASE"
    case lowercase        = "lowercase"
    case titleCase        = "Title Case"
    case trimWhitespace   = "Trim Whitespace"
    case formatJSON       = "Format JSON"
    case encodeBase64     = "Encode Base64"
    case decodeBase64     = "Decode Base64"
    case encodeURL        = "URL Encode"
    case decodeURL        = "URL Decode"
    case stripHTML        = "Strip HTML Tags"
    case extractURLs      = "Extract URLs"
    case countWords       = "Word Count → Clipboard"
    case reverseLines     = "Reverse Line Order"
    case sortLines        = "Sort Lines A→Z"
    case removeDuplicates = "Remove Duplicate Lines"

    // MARK: - Menu sections
    //
    // Returns transforms grouped into labelled sections for menu construction.
    // Each inner array is one section; the outer array defines section order.

    public static var menuSections: [(title: String, transforms: [ClipTransform])] {
        [
            ("Case",       [.uppercase, .lowercase, .titleCase]),
            ("Whitespace", [.trimWhitespace, .removeDuplicates, .sortLines, .reverseLines]),
            ("Format",     [.formatJSON, .stripHTML, .extractURLs]),
            ("Encode",     [.encodeBase64, .decodeBase64, .encodeURL, .decodeURL]),
            ("Info",       [.countWords]),
        ]
    }

    // MARK: - Apply

    /// Apply this transform to `text`.
    /// Returns `nil` when the transform is not applicable to the given content
    /// (e.g. `.formatJSON` on non-JSON input), signalling the caller to skip or
    /// show the item as disabled.
    public func apply(to text: String) -> String? {
        switch self {

        // ── Case ────────────────────────────────────────────────────────────

        case .plainText:
            // Caller is responsible for stripping rich-text attributes; we just
            // return the raw string so the upstream write path handles it uniformly.
            return text

        case .uppercase:
            return text.uppercased()

        case .lowercase:
            return text.lowercased()

        case .titleCase:
            return text
                .components(separatedBy: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                .joined(separator: " ")

        // ── Whitespace ───────────────────────────────────────────────────────

        case .trimWhitespace:
            // Trim outer whitespace then collapse internal runs to a single space.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let components = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            return components.joined(separator: " ")

        case .removeDuplicates:
            let lines = text.components(separatedBy: "\n")
            let ordered = NSOrderedSet(array: lines)
            return (ordered.array as! [String]).joined(separator: "\n")

        case .sortLines:
            return text.components(separatedBy: "\n").sorted().joined(separator: "\n")

        case .reverseLines:
            return text.components(separatedBy: "\n").reversed().joined(separator: "\n")

        // ── Format ───────────────────────────────────────────────────────────

        case .formatJSON:
            guard let data = text.data(using: .utf8) else { return nil }
            guard let obj  = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
                return nil
            }
            guard let pretty = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.prettyPrinted, .sortedKeys]
            ) else { return nil }
            return String(data: pretty, encoding: .utf8)

        case .stripHTML:
            // Remove all tags first.
            let tagless = (try? NSRegularExpression(pattern: "<[^>]+>"))
                .flatMap { regex -> String in
                    let range = NSRange(text.startIndex..., in: text)
                    return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
                } ?? text

            // Decode common HTML entities.
            return tagless
                .replacingOccurrences(of: "&amp;",  with: "&")
                .replacingOccurrences(of: "&lt;",   with: "<")
                .replacingOccurrences(of: "&gt;",   with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'")

        case .extractURLs:
            guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
                return nil
            }
            let range   = NSRange(text.startIndex..., in: text)
            let matches = detector.matches(in: text, range: range)
            let urls    = matches.compactMap { $0.url?.absoluteString }
            guard !urls.isEmpty else { return nil }
            return urls.joined(separator: "\n")

        // ── Encode ───────────────────────────────────────────────────────────

        case .encodeBase64:
            return Data(text.utf8).base64EncodedString()

        case .decodeBase64:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Data(base64Encoded: trimmed).flatMap { String(data: $0, encoding: .utf8) }

        case .encodeURL:
            return text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)

        case .decodeURL:
            return text.removingPercentEncoding

        // ── Info ─────────────────────────────────────────────────────────────

        case .countWords:
            let count = text
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .count
            return "\(count) words"
        }
    }
}
