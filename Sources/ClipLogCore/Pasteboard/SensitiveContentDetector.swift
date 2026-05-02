import Foundation

public enum SensitiveContentDetector {
    private static let labelledSecretPattern = #"""
    (?ix)
    \b(
        password|passwd|pwd|
        api[_-]?key|secret[_-]?key|client[_-]?secret|
        access[_-]?token|refresh[_-]?token|auth[_-]?token|
        private[_-]?key|secret|bearer
    )\b
    \s*[:=]\s*
    ["']?
    [A-Za-z0-9_./+=:@~$%!-]{8,}
    """#

    private static let awsAccessKeyPattern = #"\b(A3T[A-Z0-9]|AKIA|ASIA)[A-Z0-9]{16}\b"#
    private static let jwtPattern = #"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b"#
    private static let privateKeyPattern = #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----"#
    private static let slackTokenPattern = #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#
    private static let githubTokenPattern = #"\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9_]{30,}\b"#
    private static let stripeLikeSecretPattern = #"\b(sk|rk)_(live|test|demo)_[A-Za-z0-9_]{16,}\b"#

    private static let tokenCharacterSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-+/=.")

    public static func isSensitive(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 8 else { return false }

        if matches(trimmed, labelledSecretPattern) ||
           matches(trimmed, awsAccessKeyPattern) ||
           matches(trimmed, jwtPattern) ||
           matches(trimmed, privateKeyPattern) ||
           matches(trimmed, slackTokenPattern) ||
           matches(trimmed, githubTokenPattern) ||
           matches(trimmed, stripeLikeSecretPattern) {
            return true
        }

        return containsHighEntropyToken(in: trimmed)
    }

    public static func redactedPreview(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "••••••••" }

        let compact = trimmed.replacingOccurrences(of: "\n", with: " ")
        let visiblePrefix = min(8, compact.count)
        let prefix = compact.prefix(visiblePrefix)
        return "\(prefix)••••••••"
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func containsHighEntropyToken(in value: String) -> Bool {
        let candidates = value
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters).subtracting(tokenCharacterSet))
            .filter { $0.count >= 28 && $0.count <= 180 }

        for candidate in candidates {
            guard candidate.unicodeScalars.allSatisfy({ tokenCharacterSet.contains($0) }) else { continue }
            guard hasMixedSecretCharacterClasses(candidate) else { continue }
            if shannonEntropy(candidate) >= 3.65 {
                return true
            }
        }
        return false
    }

    private static func hasMixedSecretCharacterClasses(_ value: String) -> Bool {
        let hasLower = value.range(of: "[a-z]", options: .regularExpression) != nil
        let hasUpper = value.range(of: "[A-Z]", options: .regularExpression) != nil
        let hasDigit = value.range(of: #"\d"#, options: .regularExpression) != nil
        let hasSymbol = value.range(of: #"[_\-+/=.]"#, options: .regularExpression) != nil
        return [hasLower, hasUpper, hasDigit, hasSymbol].filter { $0 }.count >= 3
    }

    private static func shannonEntropy(_ value: String) -> Double {
        guard !value.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for character in value {
            counts[character, default: 0] += 1
        }
        let length = Double(value.count)
        return counts.values.reduce(0) { partial, count in
            let probability = Double(count) / length
            return partial - probability * log2(probability)
        }
    }
}
