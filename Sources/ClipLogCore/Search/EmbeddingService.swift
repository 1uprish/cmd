import Foundation

// MARK: - EmbeddingService
//
// Computes and persists NLEmbedding vectors for newly captured ClipEntry values.
// Called from PasteboardWatcher on a background Task after each new entry is stored.
// Only text-based content types are embedded (.text, .url, .code, .rich).

public final class EmbeddingService: Sendable {
    public static let shared = EmbeddingService()
    private init() {}

    /// Compute an embedding for `entry` and write it to `store`.
    /// Runs asynchronously; all failures are silently swallowed so a missing
    /// embedding never blocks the normal capture flow.
    public func embed(entry: ClipEntry, store: ClipStore) async {
        // Images, files, and colors don't carry meaningful prose — skip them.
        guard [.text, .url, .code, .rich].contains(entry.contentType) else { return }

        // Build the text to embed: preview content + source app + optional OCR text.
        var parts = [entry.previewText, entry.sourceAppName]
        if let ocr = entry.ocrText { parts.append(ocr) }
        let text = parts.joined(separator: " ")

        guard let vec = SemanticSearch.shared.embed(text) else { return }
        try? store.updateEmbedding(id: entry.id, embedding: vec)
    }
}
