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
    private var lastRemoteReportAt: [String: Date] = [:]
    private let remoteReportCooldown: TimeInterval = 60
    private let anomalyEvents: Set<String> = [
        "startup_failed",
        "database_open_failed",
        "database_migration_failed",
        "event_tap_start_failed",
        "event_tap_disabled_reenable",
        "main_thread_stall",
        "slow_pasteboard_poll",
        "slow_image_capture",
        "slow_slot_ingest",
        "slow_append_pasteboard_write",
        "slow_clipboard_write",
        "drag_payload_prewarm_failed",
        "slow_drag_payload_prewarm",
        "slow_drag_payload_materialize",
        "slow_drag_session_start",
        "slow_event_tap_callback"
    ]
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
                self.reportAnomalyIfNeeded(entry: entry)
            } catch {
                // Diagnostics must never affect clipboard behavior.
            }
        }
    }

    public func actionInput(
        feature: String,
        action: String,
        details: [String: String] = [:]
    ) {
        recordAction(stage: "input", feature: feature, action: action, details: details)
    }

    public func actionProcess(
        feature: String,
        action: String,
        details: [String: String] = [:]
    ) {
        recordAction(stage: "process", feature: feature, action: action, details: details)
    }

    public func actionOutput(
        feature: String,
        action: String,
        details: [String: String] = [:]
    ) {
        recordAction(stage: "output", feature: feature, action: action, details: details)
    }

    private func recordAction(
        stage: String,
        feature: String,
        action: String,
        details: [String: String]
    ) {
        var merged = [
            "stage": stage,
            "feature": feature,
            "action": action
        ]
        for (key, value) in details {
            merged[key] = value
        }
        record("feature_action_\(stage)", category: feature, details: merged)
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

    private func reportAnomalyIfNeeded(entry: Entry) {
        guard anomalyEvents.contains(entry.event) else { return }

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "remoteDiagnosticsEnabled"),
              let endpointValue = defaults.string(forKey: "remoteDiagnosticsEndpoint")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !endpointValue.isEmpty,
              let endpointURL = URL(string: endpointValue),
              ["https", "http"].contains(endpointURL.scheme?.lowercased())
        else { return }

        let now = Date()
        let throttleKey = "\(entry.category):\(entry.event)"
        if let previous = lastRemoteReportAt[throttleKey],
           now.timeIntervalSince(previous) < remoteReportCooldown {
            return
        }
        lastRemoteReportAt[throttleKey] = now

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = defaults.string(forKey: "remoteDiagnosticsToken"),
           !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let envelope = RemoteDiagnosticsEnvelope(
            schemaVersion: 1,
            installationID: installationID(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            event: RemoteDiagnosticsEvent(
                timestamp: entry.timestamp,
                category: entry.category,
                name: entry.event,
                details: redactedDetails(entry.details)
            )
        )

        guard let body = try? encoder.encode(envelope) else { return }
        request.httpBody = body

        URLSession.shared.dataTask(with: request).resume()
    }

    private func redactedDetails(_ details: [String: String]) -> [String: String] {
        let sensitiveFragments = [
            "content",
            "clipboard",
            "password",
            "token",
            "secret",
            "key",
            "text",
            "html"
        ]

        return details.reduce(into: [:]) { result, pair in
            let loweredKey = pair.key.lowercased()
            if sensitiveFragments.contains(where: { loweredKey.contains($0) }) {
                result[pair.key] = "[redacted]"
            } else {
                result[pair.key] = pair.value.count > 256 ? String(pair.value.prefix(256)) : pair.value
            }
        }
    }

    private func installationID() -> String {
        let key = "remoteDiagnosticsInstallationID"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), !existing.isEmpty {
            return existing
        }

        let created = UUID().uuidString
        defaults.set(created, forKey: key)
        return created
    }

    private struct RemoteDiagnosticsEnvelope: Codable {
        let schemaVersion: Int
        let installationID: String
        let appVersion: String
        let build: String
        let bundleID: String
        let osVersion: String
        let event: RemoteDiagnosticsEvent
    }

    private struct RemoteDiagnosticsEvent: Codable {
        let timestamp: String
        let category: String
        let name: String
        let details: [String: String]
    }
}

private func + (lhs: Data, rhs: Data) -> Data {
    var data = lhs
    data.append(rhs)
    return data
}
