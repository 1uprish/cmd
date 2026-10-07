import Foundation

public enum AppStoragePaths {
    public static let appName = "cmd"
    public static let bundleIdentifier = "com.cmd.app"
    public static let legacyBundleIdentifiers = [
        "com.copypasta.app",
        "com.cliplog.app",
    ]

    private static let legacyDirectoryNames = [
        "CopyPasta",
    ]

    // Test-only redirect for the whole storage tree (logs, media, database).
    // Tests share the device's Application Support path with the running app,
    // so without this every test run mingles with field telemetry. Guarded by
    // a lock; set/restored per test. Skips legacy migration by design.
    private final class OverrideBox: @unchecked Sendable {
        let lock = NSLock()
        var baseDirectory: URL?
    }
    private static let overrideBox = OverrideBox()

    static var testBaseDirectoryOverride: URL? {
        get {
            overrideBox.lock.lock()
            defer { overrideBox.lock.unlock() }
            return overrideBox.baseDirectory
        }
        set {
            overrideBox.lock.lock()
            defer { overrideBox.lock.unlock() }
            overrideBox.baseDirectory = newValue
        }
    }

    public static var applicationSupportDirectory: URL {
        if let override = testBaseDirectoryOverride {
            try? FileManager.default.createDirectory(at: override, withIntermediateDirectories: true)
            return override
        }
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let current = base.appendingPathComponent(appName, isDirectory: true)
        migrateLegacyApplicationSupport(to: current, base: base)
        try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }

    public static var mediaDirectory: URL {
        let directory = applicationSupportDirectory.appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func migrateLegacyApplicationSupport(to current: URL, base: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: current.path) else { return }

        for name in legacyDirectoryNames {
            let legacy = base.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: legacy.path) else { continue }
            do {
                try fm.moveItem(at: legacy, to: current)
            } catch {
                try? fm.copyItem(at: legacy, to: current)
            }
            return
        }
    }
}
