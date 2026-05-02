import Foundation

public final class DiagnosticsLogbook: @unchecked Sendable {
    public static let shared = DiagnosticsLogbook()

    public var logFileURL: URL {
        AppStoragePaths.applicationSupportDirectory
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("cmd.log", isDirectory: false)
    }

    private struct Entry: Codable {
        let timestamp: String
        let category: String
        let event: String
        let details: [String: String]
    }

    private let queue = DispatchQueue(label: "com.cmd.diagnostics", qos: .utility)
    private let encoder = JSONEncoder()
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private init() {}

    public func record(
        _ event: String,
        category: String = "general",
        details: [String: String] = [:]
    ) {
        let entryDate = Date()
        let safeDetails = details.mapValues { value in
            value.count > 512 ? String(value.prefix(512)) : value
        }

        queue.async { [encoder] in
            do {
                let url = self.logFileURL
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                self.rotateIfNeeded(at: url)
                let entry = Entry(
                    timestamp: self.timestampFormatter.string(from: entryDate),
                    category: category,
                    event: event,
                    details: safeDetails
                )
                let data = try encoder.encode(entry) + Data([0x0A])
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                } else {
                    try data.write(to: url, options: .atomic)
                }
            } catch {
                // Diagnostics must never affect clipboard behavior.
            }
        }
    }

    private func rotateIfNeeded(at url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 2 * 1024 * 1024
        else { return }

        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent("cmd.log.1", isDirectory: false)
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var data = lhs
    data.append(rhs)
    return data
}
