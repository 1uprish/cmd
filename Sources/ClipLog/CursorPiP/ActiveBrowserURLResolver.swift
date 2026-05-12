import AppKit
import Foundation

enum ActiveBrowserURLResolver {
    static func currentURL() -> URL? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundleID = app.bundleIdentifier ?? ""
        let appName = app.localizedName ?? ""

        let script: String?
        switch bundleID {
        case "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser":
            script = chromiumScript(appName: appName)
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            script = safariScript(appName: appName)
        default:
            script = nil
        }

        guard let script,
              let raw = runAppleScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }
        return URL(string: raw)
    }

    private static func chromiumScript(appName: String) -> String {
        """
        tell application "\(appName)"
            if not (exists front window) then return ""
            return URL of active tab of front window
        end tell
        """
    }

    private static func safariScript(appName: String) -> String {
        """
        tell application "\(appName)"
            if not (exists front document) then return ""
            return URL of front document
        end tell
        """
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result?.stringValue
    }
}
