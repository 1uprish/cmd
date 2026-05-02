import NaturalLanguage
import Foundation

// MARK: - SemanticSearch
//
// On-device semantic similarity using Apple's NLEmbedding (512-dim sentence vectors).
// No network calls, no model downloads — ships with every Mac via NaturalLanguage.framework.

public final class SemanticSearch: Sendable {
    public static let shared = SemanticSearch()
    private init() {}

    // MARK: - Embedding

    /// Embed a string into a 512-dim float array.
    /// Returns nil if NLEmbedding is unavailable on this OS/language combo.
    public func embed(_ text: String) -> [Double]? {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
        // NL works best under 512 chars; truncate longer strings.
        let truncated = String(text.prefix(512))
        return embedding.vector(for: truncated)
    }

    // MARK: - Similarity

    /// Cosine similarity between two equal-length vectors. Returns 0 if lengths differ or
    /// either magnitude is zero.
    public func similarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot  = zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
        let magA = sqrt(a.reduce(0.0) { $0 + $1 * $1 })
        let magB = sqrt(b.reduce(0.0) { $0 + $1 * $1 })
        guard magA > 0, magB > 0 else { return 0 }
        return dot / (magA * magB)
    }

    // MARK: - Ranking

    /// Given a natural-language query and a list of (ClipEntry, storedEmbedding) pairs,
    /// returns entries sorted by cosine similarity descending.
    /// Entries whose similarity falls at or below 0.25 are excluded.
    public func rank(query: String, entries: [(ClipEntry, [Double])]) -> [ClipEntry] {
        guard let queryVec = embed(query) else {
            // NLEmbedding unavailable — return entries unsorted rather than nothing.
            return entries.map { $0.0 }
        }
        let scored: [(ClipEntry, Double)] = entries.compactMap { entry, vec in
            let score = similarity(queryVec, vec)
            return score > 0.25 ? (entry, score) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.map { $0.0 }
    }
}
