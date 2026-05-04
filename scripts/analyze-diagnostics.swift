#!/usr/bin/env swift
import Foundation

struct Entry: Decodable {
    let timestamp: String
    let category: String
    let event: String
    let details: [String: String]
}

struct SlowEvent {
    let entry: Entry
    let durationMs: Int
}

let defaultLogPath = FileManager.default
    .homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/cmd/Diagnostics/cmd.log")
    .path

let logPath = CommandLine.arguments.dropFirst().first ?? defaultLogPath
let url = URL(fileURLWithPath: logPath)

guard let data = try? Data(contentsOf: url),
      let contents = String(data: data, encoding: .utf8)
else {
    fputs("No diagnostics log found at \(logPath)\n", stderr)
    exit(1)
}

let decoder = JSONDecoder()
let entries = contents
    .split(separator: "\n")
    .compactMap { line -> Entry? in
        try? decoder.decode(Entry.self, from: Data(line.utf8))
    }

func int(_ entry: Entry, _ key: String) -> Int {
    Int(entry.details[key] ?? "") ?? 0
}

func slow(_ event: String, key: String = "durationMs") -> [SlowEvent] {
    entries
        .filter { $0.event == event }
        .map { SlowEvent(entry: $0, durationMs: int($0, key)) }
        .filter { $0.durationMs > 0 }
        .sorted { $0.durationMs > $1.durationMs }
}

func count(_ event: String) -> Int {
    entries.filter { $0.event == event }.count
}

func printTop(_ title: String, _ events: [SlowEvent], limit: Int = 5) {
    guard !events.isEmpty else { return }
    print("\n\(title)")
    for event in events.prefix(limit) {
        let details = event.entry.details
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        print("- \(event.durationMs)ms \(event.entry.timestamp) \(details)")
    }
}

let slowPolls = slow("slow_pasteboard_poll")
let slowImages = slow("slow_image_capture")
let slowIngest = slow("slow_slot_ingest")
let slowAppendWrites = slow("slow_append_pasteboard_write")
let slowClipboardWrites = slow("slow_clipboard_write")
let slowTap = slow("slow_event_tap_callback")
let stalls = slow("main_thread_stall", key: "latencyMs")

print("CMD diagnostics report")
print("Log: \(logPath)")
print("Events: \(entries.count)")
if let last = entries.last {
    print("Latest: \(last.timestamp) \(last.category)/\(last.event)")
}

print("\nCounts")
print("- slow_pasteboard_poll: \(slowPolls.count)")
print("- slow_image_capture: \(slowImages.count)")
print("- slow_slot_ingest: \(slowIngest.count)")
print("- slow_append_pasteboard_write: \(slowAppendWrites.count)")
print("- slow_clipboard_write: \(slowClipboardWrites.count)")
print("- slow_event_tap_callback: \(slowTap.count)")
print("- main_thread_stall: \(stalls.count)")
print("- event_tap_disabled_reenable: \(count("event_tap_disabled_reenable"))")
print("- event_tap_start_failed: \(count("event_tap_start_failed"))")

printTop("Worst pasteboard polls", slowPolls)
printTop("Worst image captures", slowImages)
printTop("Worst slot ingests", slowIngest)
printTop("Worst append writes", slowAppendWrites)
printTop("Worst clipboard writes", slowClipboardWrites)
printTop("Worst event tap callbacks", slowTap)
printTop("Worst main thread stalls", stalls)

var evidence: [(name: String, score: Int, reason: String)] = []

if let worst = slowTap.first, worst.durationMs >= 50 {
    evidence.append((
        "global Cmd+V event tap",
        worst.durationMs,
        "event tap callback reached \(worst.durationMs)ms"
    ))
}

if let worst = slowImages.first {
    let imageDataMs = int(worst.entry, "imageDataMs")
    let thumbnailMs = int(worst.entry, "thumbnailMs")
    let phase = imageDataMs >= thumbnailMs ? "image read/normalize" : "thumbnail generation"
    evidence.append((
        "image clipboard capture",
        worst.durationMs,
        "\(phase) dominated image capture at \(worst.durationMs)ms"
    ))
}

if let worst = slowIngest.first {
    let insertMs = int(worst.entry, "insertMs")
    let recentMs = int(worst.entry, "recentMs")
    let phase = insertMs >= recentMs ? "database insert" : "recent history read"
    evidence.append((
        "history database ingest",
        worst.durationMs,
        "\(phase) dominated slot ingest at \(worst.durationMs)ms"
    ))
}

if let worst = slowAppendWrites.first {
    evidence.append((
        "append pasteboard write",
        worst.durationMs,
        "append payload write reached \(worst.durationMs)ms"
    ))
}

if let worst = slowClipboardWrites.first {
    evidence.append((
        "clipboard write",
        worst.durationMs,
        "copy/paste write reached \(worst.durationMs)ms"
    ))
}

if let worst = slowPolls.first {
    let build = int(worst.entry, "buildEntryMs")
    let ingest = int(worst.entry, "ingestMs")
    let append = int(worst.entry, "appendMs")
    if max(build, ingest, append) > 0 {
        let phase: String
        switch max(build, ingest, append) {
        case build:
            phase = "entry build/classification"
        case ingest:
            phase = "history ingest"
        default:
            phase = "append merge"
        }
        evidence.append((
            "pasteboard polling",
            worst.durationMs,
            "\(phase) dominated a \(worst.durationMs)ms pasteboard poll"
        ))
    } else {
        evidence.append((
            "pasteboard polling",
            worst.durationMs,
            "older log format shows slow polls but lacks phase timing"
        ))
    }
}

if let worst = stalls.first {
    let maxSpecific = evidence.map(\.score).max() ?? 0
    if maxSpecific < worst.durationMs / 2 {
        evidence.append((
            "system or AppKit main-thread pressure",
            worst.durationMs,
            "main thread stall reached \(worst.durationMs)ms without matching CMD phase evidence"
        ))
    }
}

print("\nVerdict")
if evidence.isEmpty {
    print("- No slow CMD path is visible in this log.")
} else {
    for item in evidence.sorted(by: { $0.score > $1.score }).prefix(5) {
        print("- \(item.name): \(item.reason)")
    }
}

let hasNewPhaseTiming = slowPolls.contains {
    int($0.entry, "buildEntryMs") > 0 ||
    int($0.entry, "ingestMs") > 0 ||
    int($0.entry, "appendMs") > 0
} || !slowImages.isEmpty || !slowIngest.isEmpty || !slowAppendWrites.isEmpty || !slowClipboardWrites.isEmpty || !slowTap.isEmpty

if !hasNewPhaseTiming, !slowPolls.isEmpty || !stalls.isEmpty {
    print("\nNote")
    print("- This log was produced before detailed phase probes existed. Reproduce once with the latest CMD build, then rerun this script for exact attribution.")
}
