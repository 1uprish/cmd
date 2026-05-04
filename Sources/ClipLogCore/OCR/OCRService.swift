import Vision
import AppKit
import Foundation

public actor OCRService {
    public static let shared = OCRService()
    private static let maxBackgroundOCRBytes = 6 * 1024 * 1024

    private init() {}

    public func recognizeText(in imageURL: URL) async -> String? {
        guard imageIsSmallEnoughForBackgroundOCR(imageURL) else {
            DiagnosticsLogbook.shared.record(
                "ocr_skipped",
                category: "performance",
                details: ["reason": "image_too_large"]
            )
            return nil
        }

        var proposedRect = CGRect.zero
        guard
            let nsImage = NSImage(contentsOf: imageURL),
            let cgImage = nsImage.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)
        else { return nil }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observations = request.results else { return nil }

        let joined = observations
            .compactMap { $0.topCandidates(1).first?.string }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return joined.isEmpty ? nil : joined
    }

    public func processAndStore(entryID: UUID, imageURL: URL, store: ClipStore) async {
        guard let text = await recognizeText(in: imageURL), !text.isEmpty else { return }
        try? store.updateOCRText(id: entryID, text: text)
        await MainActor.run {
            NotificationCenter.default.post(
                name: .clipLogOCRCompleted,
                object: nil,
                userInfo: ["entryID": entryID.uuidString]
            )
        }
    }

    private func imageIsSmallEnoughForBackgroundOCR(_ imageURL: URL) -> Bool {
        let values = try? imageURL.resourceValues(forKeys: [.fileSizeKey])
        return (values?.fileSize ?? 0) <= Self.maxBackgroundOCRBytes
    }
}

extension Notification.Name {
    public static let clipLogOCRCompleted = Notification.Name("com.cmd.ocrCompleted")
}
