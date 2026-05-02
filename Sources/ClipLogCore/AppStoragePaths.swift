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

    public static var applicationSupportDirectory: URL {
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
