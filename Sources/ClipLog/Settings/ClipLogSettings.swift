import Foundation
import Darwin
import ServiceManagement
import ClipLogCore

public final class ClipLogSettings: ObservableObject {

    public static let shared = ClipLogSettings()

    private enum Keys {
        static let holdThresholdMs     = "holdThresholdMs"
        static let retentionDays       = "retentionDays"
        static let sensitiveRetentionMinutes = "sensitiveRetentionMinutes"
        static let userExcludedBundles = "userExcludedBundles"
        static let launchAtLogin       = "launchAtLogin"
        static let hudOpacity          = "hudOpacity"
        static let hudSizeScale        = "hudSizeScale"
        static let hudAnimationStyle   = "hudAnimationStyle"
        static let onboardingCompleted = "onboardingCompleted"
        static let remoteDiagnosticsEnabled = "remoteDiagnosticsEnabled"
        static let remoteDiagnosticsEndpoint = "remoteDiagnosticsEndpoint"
        static let remoteDiagnosticsToken = "remoteDiagnosticsToken"
    }

    @Published public var holdThresholdMs: Int {
        didSet {
            let clamped = holdThresholdMs.clamped(to: 100...500)
            UserDefaults.standard.set(clamped, forKey: Keys.holdThresholdMs)
            if clamped != holdThresholdMs { holdThresholdMs = clamped }
        }
    }

    @Published public var retentionDays: Int {
        didSet {
            UserDefaults.standard.set(retentionDays, forKey: Keys.retentionDays)
        }
    }

    @Published public var sensitiveRetentionMinutes: Int {
        didSet {
            UserDefaults.standard.set(sensitiveRetentionMinutes, forKey: Keys.sensitiveRetentionMinutes)
        }
    }

    @Published public var userExcludedBundles: [String] {
        didSet {
            UserDefaults.standard.set(userExcludedBundles, forKey: Keys.userExcludedBundles)
        }
    }

    @Published public var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            LaunchAtLoginManager.setEnabled(launchAtLogin)
        }
    }

    /// HUD card background opacity — 0.4 (very transparent) … 1.0 (fully opaque glass)
    @Published public var hudOpacity: Double {
        didSet {
            let clamped = hudOpacity.clamped(to: 0.55...1.0)
            UserDefaults.standard.set(clamped, forKey: Keys.hudOpacity)
            if clamped != hudOpacity { hudOpacity = clamped }
        }
    }

    /// HUD size scale — 0.85 (compact) … 1.20 (large)
    @Published public var hudSizeScale: Double {
        didSet {
            let clamped = hudSizeScale.clamped(to: 0.85...1.20)
            UserDefaults.standard.set(clamped, forKey: Keys.hudSizeScale)
            if clamped != hudSizeScale { hudSizeScale = clamped }
        }
    }

    @Published public var hudAnimationStyle: String {
        didSet {
            let allowed = ["magnetic", "genie", "cascade", "calm"]
            let value = allowed.contains(hudAnimationStyle) ? hudAnimationStyle : "magnetic"
            UserDefaults.standard.set(value, forKey: Keys.hudAnimationStyle)
            if value != hudAnimationStyle { hudAnimationStyle = value }
        }
    }

    @Published public var onboardingCompleted: Bool {
        didSet {
            UserDefaults.standard.set(onboardingCompleted, forKey: Keys.onboardingCompleted)
        }
    }

    @Published public var remoteDiagnosticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(remoteDiagnosticsEnabled, forKey: Keys.remoteDiagnosticsEnabled)
        }
    }

    @Published public var remoteDiagnosticsEndpoint: String {
        didSet {
            UserDefaults.standard.set(remoteDiagnosticsEndpoint, forKey: Keys.remoteDiagnosticsEndpoint)
        }
    }

    @Published public var remoteDiagnosticsToken: String {
        didSet {
            UserDefaults.standard.set(remoteDiagnosticsToken, forKey: Keys.remoteDiagnosticsToken)
        }
    }

    private init() {
        let defaults = UserDefaults.standard

        defaults.register(defaults: [
            Keys.holdThresholdMs:     160,
            Keys.retentionDays:       30,
            Keys.sensitiveRetentionMinutes: 60,
            Keys.userExcludedBundles: [String](),
            Keys.launchAtLogin:       false,
            Keys.hudOpacity:          1.0,
            Keys.hudSizeScale:        1.0,
            Keys.hudAnimationStyle:   "magnetic",
            Keys.onboardingCompleted: false,
            Keys.remoteDiagnosticsEnabled: false,
            Keys.remoteDiagnosticsEndpoint: "",
            Keys.remoteDiagnosticsToken: "",
        ])

        holdThresholdMs     = defaults.integer(forKey: Keys.holdThresholdMs)
        retentionDays       = defaults.integer(forKey: Keys.retentionDays)
        sensitiveRetentionMinutes = defaults.integer(forKey: Keys.sensitiveRetentionMinutes)
        userExcludedBundles = defaults.stringArray(forKey: Keys.userExcludedBundles) ?? []
        launchAtLogin       = defaults.bool(forKey: Keys.launchAtLogin)
        hudOpacity          = defaults.double(forKey: Keys.hudOpacity)
        hudSizeScale        = defaults.double(forKey: Keys.hudSizeScale)
        hudAnimationStyle   = defaults.string(forKey: Keys.hudAnimationStyle) ?? "magnetic"
        onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        remoteDiagnosticsEnabled = defaults.bool(forKey: Keys.remoteDiagnosticsEnabled)
        remoteDiagnosticsEndpoint = defaults.string(forKey: Keys.remoteDiagnosticsEndpoint) ?? ""
        remoteDiagnosticsToken = defaults.string(forKey: Keys.remoteDiagnosticsToken) ?? ""
    }
}

// MARK: - Launch-at-login

/// Manages a LaunchAgent plist at ~/Library/LaunchAgents/com.cmd.app.plist.
///
/// Why not SMAppService.mainApp?
///   SMAppService.mainApp requires the app to be in /Applications (or another
///   standard location that macOS recognises as an "installed" app). It silently
///   fails for apps run from a build directory.  A LaunchAgent plist works from
///   any path and persists correctly across reboots.
public enum LaunchAtLoginManager {

    private static let plistLabel = AppStoragePaths.bundleIdentifier
    private static let launchctlTimeout: TimeInterval = 2.0
    private static let launchctlQueue = DispatchQueue(label: "com.cmd.launchctl", qos: .utility)
    private static let legacyPlistLabels = AppStoragePaths.legacyBundleIdentifiers
    private static var plistURL: URL {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return launchAgents.appendingPathComponent("\(plistLabel).plist")
    }
    private static var launchAgentsDirectory: URL {
        let launchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return launchAgents
    }
    private static var launchctlDomain: String {
        "gui/\(getuid())"
    }

    /// Install or remove the LaunchAgent for the current bundle path.
    public static func setEnabled(_ enabled: Bool) {
        if enabled {
            install()
        } else {
            remove()
        }
    }

    /// Sync the LaunchAgent so it always points to the current bundle path.
    /// Call this on every app launch so the plist stays current if the app is moved.
    public static func syncIfNeeded() {
        // Keep the persisted LaunchAgent aligned with the preference. This also
        // cleans up beta builds that created a login item before the default was
        // changed to off.
        guard UserDefaults.standard.bool(forKey: "launchAtLogin") else {
            remove()
            return
        }
        install(reloadLoadedAgent: false)
    }

    // MARK: - Private

    private static func install(reloadLoadedAgent: Bool = true) {
        let bundlePath = Bundle.main.bundleURL.path
        guard bundlePath.hasSuffix(".app") else { return }
        removeLegacyAgents()

        let launchAgents = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: launchAgents, withIntermediateDirectories: true
        )

        // Launch the .app bundle rather than the raw Mach-O. On current macOS,
        // running the executable directly can exit immediately because the app
        // is not launched with the normal LaunchServices bundle context.
        let plist: [String: Any] = [
            "Label":             plistLabel,
            "ProgramArguments":  ["/usr/bin/open", "-g", bundlePath],
            "RunAtLoad":         true,
            "KeepAlive":         false,
            "StandardOutPath":   "/tmp/com.cmd.app.stdout",
            "StandardErrorPath": "/tmp/com.cmd.app.stderr",
        ]

        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        ) else { return }

        let existingData = try? Data(contentsOf: plistURL)
        let plistChanged = existingData != data
        if plistChanged {
            try? data.write(to: plistURL, options: .atomic)
        }

        guard reloadLoadedAgent || plistChanged else { return }

        // Modern macOS expects per-user LaunchAgents to be bootstrapped into
        // gui/$UID. The old `launchctl load -w` path fails on current systems.
        //
        // Do not kickstart here. This code runs inside the app; kickstarting the
        // same label during launch can race LaunchServices and terminate or
        // duplicate the running app. Registering the agent is enough for the
        // next login, while the current process keeps running normally.
        runLaunchctl(["bootout", launchctlDomain, plistURL.path])
        runLaunchctl(["bootstrap", launchctlDomain, plistURL.path])
        runLaunchctl(["enable", "\(launchctlDomain)/\(plistLabel)"])
    }

    private static func remove() {
        if FileManager.default.fileExists(atPath: plistURL.path) {
            bootout(label: plistLabel, plistURL: plistURL)
        }
        try? FileManager.default.removeItem(at: plistURL)
        removeLegacyAgents()
    }

    private static func removeLegacyAgents() {
        for label in legacyPlistLabels {
            let url = launchAgentsDirectory.appendingPathComponent("\(label).plist")
            if FileManager.default.fileExists(atPath: url.path) {
                bootout(label: label, plistURL: url)
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func bootout(label: String, plistURL: URL) {
        runLaunchctl(["bootout", "\(launchctlDomain)/\(label)"])
        runLaunchctl(["bootout", launchctlDomain, plistURL.path])
    }

    private static func runLaunchctl(_ arguments: [String]) {
        let capturedArguments = arguments
        launchctlQueue.async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            task.arguments = capturedArguments
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice

            let finished = DispatchSemaphore(value: 0)
            task.terminationHandler = { _ in finished.signal() }

            do {
                try task.run()
            } catch {
                DiagnosticsLogbook.shared.record(
                    "launchctl_failed_to_start",
                    category: "lifecycle",
                    details: [
                        "arguments": capturedArguments.joined(separator: " "),
                        "error": String(describing: error)
                    ]
                )
                return
            }

            if finished.wait(timeout: .now() + launchctlTimeout) == .timedOut {
                task.terminate()
                DiagnosticsLogbook.shared.record(
                    "launchctl_timed_out",
                    category: "lifecycle",
                    details: ["arguments": capturedArguments.joined(separator: " ")]
                )
            }
        }
    }
}

// MARK: - Helpers

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
