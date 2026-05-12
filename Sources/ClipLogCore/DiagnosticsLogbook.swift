import Foundation

public final class DiagnosticsLogbook: @unchecked Sendable {
    public static let shared = DiagnosticsLogbook()

    public var logFileURL: URL {
        AppStoragePaths.applicationSupportDirectory
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("cmd.log", isDirectory: false)
    }

    public var errorLogFileURL: URL {
        AppStoragePaths.applicationSupportDirectory
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("cmd-errors.log", isDirectory: false)
    }

    public var reportsDirectoryURL: URL {
        AppStoragePaths.applicationSupportDirectory
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("Reports", isDirectory: true)
    }

    private struct Entry: Codable {
        let timestamp: String
        let category: String
        let event: String
        let details: [String: String]
    }

    private let queue = DispatchQueue(label: "com.cmd.diagnostics", qos: .utility)
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var lastRemoteReportAt: [String: Date] = [:]
    private var lastPruneAt = Date.distantPast
    private var recentEntries: [Entry] = []
    private let recentEntryLimit = 500
    private let remoteReportCooldown: TimeInterval = 60
    private let allLogRetention: TimeInterval = 3 * 60 * 60
    private let errorLogRetention: TimeInterval = 7 * 24 * 60 * 60
    private let pruneInterval: TimeInterval = 5 * 60
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
        "slow_event_tap_callback",
        "hud_visibility_invariant_failed",
        "hud_stale_state_recovered",
        "hud_drag_watchdog"
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
                let entry = Entry(
                    timestamp: self.timestampFormatter.string(from: entryDate),
                    category: category,
                    event: event,
                    details: safeDetails
                )
                self.pruneIfNeeded(now: entryDate)
                self.remember(entry)
                let data = try encoder.encode(entry) + Data([0x0A])
                try self.append(data, to: url)
                if self.isErrorEntry(entry) {
                    try self.append(data, to: self.errorLogFileURL)
                }
                self.reportAnomalyIfNeeded(entry: entry)
            } catch {
                // Diagnostics must never affect clipboard behavior.
            }
        }
    }

    public func writeDailyErrorSummary(completion: (@Sendable (URL?) -> Void)? = nil) {
        queue.async {
            let url = self.writeDailyErrorSummaryLocked(now: Date())
            completion?(url)
        }
    }

    public func exportDebugBundle(
        appState: [String: String],
        completion: @escaping @Sendable (URL?) -> Void
    ) {
        queue.async {
            let createdAt = Date()
            let stamp = self.fileTimestampFormatter.string(from: createdAt)
            let directory = self.reportsDirectoryURL
                .appendingPathComponent("cmd-debug-report-\(stamp)", isDirectory: true)

            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )

                if FileManager.default.fileExists(atPath: self.logFileURL.path) {
                    try FileManager.default.copyItem(
                        at: self.logFileURL,
                        to: directory.appendingPathComponent("cmd.log")
                    )
                }
                if FileManager.default.fileExists(atPath: self.errorLogFileURL.path) {
                    try FileManager.default.copyItem(
                        at: self.errorLogFileURL,
                        to: directory.appendingPathComponent("cmd-errors.log")
                    )
                }

                let summaryURL = self.writeDailyErrorSummaryLocked(now: createdAt)
                if FileManager.default.fileExists(atPath: summaryURL.path) {
                    try? FileManager.default.copyItem(
                        at: summaryURL,
                        to: directory.appendingPathComponent("daily-error-summary.txt")
                    )
                }

                let state = self.defaultAppState(merging: appState, createdAt: createdAt)
                let stateData = try self.encoder.encode(state) + Data([0x0A])
                try stateData.write(
                    to: directory.appendingPathComponent("app-state.json"),
                    options: .atomic
                )

                let recentData = try self.recentEventsData()
                try recentData.write(
                    to: directory.appendingPathComponent("recent-events.jsonl"),
                    options: .atomic
                )

                self.record(
                    "debug_report_created",
                    category: "diagnostics",
                    details: ["path": directory.path]
                )
                completion(directory)
            } catch {
                self.record(
                    "debug_report_failed",
                    category: "diagnostics",
                    details: ["error": String(describing: error)]
                )
                completion(nil)
            }
        }
    }

    private func append(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url, options: .atomic)
        }
    }

    private func remember(_ entry: Entry) {
        recentEntries.append(entry)
        if recentEntries.count > recentEntryLimit {
            recentEntries.removeFirst(recentEntries.count - recentEntryLimit)
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

    private func pruneIfNeeded(now: Date) {
        guard now.timeIntervalSince(lastPruneAt) >= pruneInterval else { return }
        lastPruneAt = now
        pruneLog(at: logFileURL, keepingEntriesSince: now.addingTimeInterval(-allLogRetention))
        pruneLog(at: errorLogFileURL, keepingEntriesSince: now.addingTimeInterval(-errorLogRetention))
        removeLegacyRotatedLog()
    }

    private func pruneLog(at url: URL, keepingEntriesSince cutoff: Date) {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty
        else { return }

        let newline = Data([0x0A])
        var kept = Data()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  let timestamp = timestampFormatter.date(from: entry.timestamp)
            else { continue }
            if timestamp >= cutoff {
                kept.append(line)
                kept.append(newline)
            }
        }
        try? kept.write(to: url, options: .atomic)
    }

    private func removeLegacyRotatedLog() {
        let rotated = logFileURL.deletingLastPathComponent()
            .appendingPathComponent("cmd.log.1", isDirectory: false)
        try? FileManager.default.removeItem(at: rotated)
    }

    private func isErrorEntry(_ entry: Entry) -> Bool {
        if anomalyEvents.contains(entry.event) { return true }
        if entry.details["success"] == "false" { return true }
        let lowered = entry.event.lowercased()
        return [
            "error",
            "failed",
            "failure",
            "timed_out",
            "denied",
            "disabled",
            "not_trusted",
            "slow_",
            "dropped"
        ].contains { lowered.contains($0) }
    }

    private func writeDailyErrorSummaryLocked(now: Date) -> URL {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let day = dayFormatter.string(from: now)
        let summaryURL = reportsDirectoryURL
            .appendingPathComponent("daily-error-summary-\(day).txt", isDirectory: false)

        do {
            try FileManager.default.createDirectory(
                at: reportsDirectoryURL,
                withIntermediateDirectories: true
            )
            let entries = readEntries(from: errorLogFileURL, since: startOfDay)
            let summary = dailySummaryText(entries: entries, day: day, generatedAt: now)
            try summary.write(to: summaryURL, atomically: true, encoding: .utf8)
            try? summary.write(
                to: reportsDirectoryURL.appendingPathComponent("daily-error-summary-latest.txt"),
                atomically: true,
                encoding: .utf8
            )
            return summaryURL
        } catch {
            return summaryURL
        }
    }

    private func readEntries(from url: URL, since cutoff: Date) -> [Entry] {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              !data.isEmpty
        else { return [] }

        return data.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { line in
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  let timestamp = timestampFormatter.date(from: entry.timestamp),
                  timestamp >= cutoff
            else { return nil }
            return entry
        }
    }

    private func dailySummaryText(entries: [Entry], day: String, generatedAt: Date) -> String {
        var lines: [String] = []
        lines.append("cmd daily error summary")
        lines.append("date: \(day)")
        lines.append("generated: \(timestampFormatter.string(from: generatedAt))")
        lines.append("total: \(entries.count)")
        lines.append("")

        guard !entries.isEmpty else {
            lines.append("No errors recorded.")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        let groups = Dictionary(grouping: entries) { "\($0.category):\($0.event)" }
        let ranked = groups.sorted { lhs, rhs in
            if lhs.value.count != rhs.value.count { return lhs.value.count > rhs.value.count }
            return lhs.key < rhs.key
        }

        lines.append("Top problems:")
        for (key, values) in ranked.prefix(20) {
            let first = values.first?.timestamp ?? "unknown"
            let last = values.last?.timestamp ?? "unknown"
            let sample = values.last.map { sampleDetails($0.details) } ?? ""
            lines.append("- \(key): \(values.count) first=\(first) last=\(last) \(sample)")
        }
        lines.append("")
        lines.append("Recent events:")
        for entry in entries.suffix(30) {
            lines.append("- \(entry.timestamp) \(entry.category):\(entry.event) \(sampleDetails(entry.details))")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private func sampleDetails(_ details: [String: String]) -> String {
        let keys = ["reason", "error", "result", "success", "durationMs", "latencyMs", "sessionID"]
        let values = keys.compactMap { key -> String? in
            guard let value = details[key], !value.isEmpty else { return nil }
            return "\(key)=\(value)"
        }
        return values.joined(separator: " ")
    }

    private func recentEventsData() throws -> Data {
        var data = Data()
        for entry in recentEntries {
            data.append(try encoder.encode(entry))
            data.append(Data([0x0A]))
        }
        return data
    }

    private func defaultAppState(merging state: [String: String], createdAt: Date) -> [String: String] {
        var merged = [
            "createdAt": timestampFormatter.string(from: createdAt),
            "bundleID": Bundle.main.bundleIdentifier ?? "unknown",
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "processID": "\(ProcessInfo.processInfo.processIdentifier)",
            "executablePath": Bundle.main.executableURL?.path ?? "unknown"
        ]
        for (key, value) in state {
            merged[key] = value
        }
        return merged
    }

    private var fileTimestampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    private var dayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
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
