import AppKit
import ClipLogCore
import Foundation

enum BrowserPlaybackController {
    private static var warnedAppleEventApps = Set<String>()

    static func pauseMatchingBrowserMedia(for url: URL) {
        guard let host = url.host?.lowercased() else { return }
        DispatchQueue.global(qos: .utility).async {
            let script = pauseJavaScript(host: host)
            let matchToken = browserMatchToken(for: url, host: host)
            DiagnosticsLogbook.shared.record(
                "browser_media_pause_requested",
                category: "cursor_pip",
                details: ["host": host, "matchToken": matchToken]
            )
            pauseChromiumMedia(matchToken: matchToken, javaScript: script)
            pauseSafariMedia(matchToken: matchToken, javaScript: script)
        }
    }

    private static func pauseChromiumMedia(matchToken: String, javaScript: String) {
        let appNames = [
            "Google Chrome",
            "Google Chrome Canary",
            "Brave Browser",
            "Microsoft Edge",
            "Arc"
        ]

        for appName in appNames {
            guard NSWorkspace.shared.runningApplications.contains(where: { $0.localizedName == appName }) else {
                continue
            }
            let result = runAppleScript("""
            tell application "\(appName)"
                repeat with browserWindow in windows
                    repeat with browserTab in tabs of browserWindow
                        set tabURL to URL of browserTab as string
                        if tabURL contains "\(appleScriptString(matchToken))" then
                            execute browserTab javascript "\(appleScriptString(javaScript))"
                            return
                        end if
                    end repeat
                end repeat
            end tell
            """)
            if result.success { continue }
            let fallbackResult = runAppleScript("""
            tell application "\(appName)"
                if not (exists front window) then return
                execute active tab of front window javascript "\(appleScriptString(javaScript))"
            end tell
            """)
            if !fallbackResult.success {
                recordAppleScriptFailure(appName: appName, error: fallbackResult.error ?? result.error)
            }
        }
    }

    private static func pauseSafariMedia(matchToken: String, javaScript: String) {
        guard NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.Safari" }) else {
            return
        }
        let result = runAppleScript("""
        tell application "Safari"
            repeat with browserDocument in documents
                set documentURL to URL of browserDocument as string
                if documentURL contains "\(appleScriptString(matchToken))" then
                    do JavaScript "\(appleScriptString(javaScript))" in browserDocument
                    return
                end if
            end repeat
            if exists front document then
                do JavaScript "\(appleScriptString(javaScript))" in front document
            end if
        end tell
        """)
        if !result.success {
            recordAppleScriptFailure(appName: "Safari", error: result.error)
        }
    }

    private static func pauseJavaScript(host: String) -> String {
        """
        (() => {
          const target = "\(host)";
          const current = location.hostname.toLowerCase();
          const bare = target.replace(/^www\\./, "");
          if (!current.endsWith(bare)) return "host-mismatch";
          document.querySelectorAll("video,audio").forEach(media => {
            try { media.pause(); } catch (_) {}
          });
          try {
            const player = document.getElementById("movie_player");
            if (player && typeof player.pauseVideo === "function") {
              player.pauseVideo();
            }
          } catch (_) {}
          return "paused";
        })();
        """
    }

    private static func browserMatchToken(for url: URL, host: String) -> String {
        if host.contains("youtube.com") || host.contains("youtu.be"),
           let videoID = youtubeVideoID(from: url) {
            return videoID
        }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    private static func youtubeVideoID(from url: URL) -> String? {
        if url.host?.lowercased().contains("youtu.be") == true {
            return url.pathComponents.dropFirst().first
        }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "v" })?
            .value
    }

    private static func appleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func runAppleScript(_ source: String) -> (success: Bool, error: NSDictionary?) {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return (error == nil, error)
    }

    private static func recordAppleScriptFailure(appName: String, error: NSDictionary?) {
        let number = error?[NSAppleScript.errorNumber] as? Int
        let message = error?[NSAppleScript.errorMessage] as? String ?? "unknown"
        DiagnosticsLogbook.shared.record(
            "browser_media_pause_failed",
            category: "cursor_pip",
            details: [
                "app": appName,
                "errorNumber": number.map(String.init) ?? "",
                "message": message
            ]
        )
        if number == -1743 {
            showAppleEventsPermissionWarning(appName: appName)
        }
    }

    private static func showAppleEventsPermissionWarning(appName: String) {
        DispatchQueue.main.async {
            guard !warnedAppleEventApps.contains(appName) else { return }
            warnedAppleEventApps.insert(appName)
            let alert = NSAlert()
            alert.messageText = "Allow CMD to control \(appName)"
            alert.informativeText = "macOS blocked CMD from pausing the original browser video. Open System Settings > Privacy & Security > Automation and allow CMD for \(appName)."
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
