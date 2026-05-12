import AppKit
import ClipLogCore
import Foundation

final class OTTPiPLauncher {
    static let shared = OTTPiPLauncher()

    private var process: Process?
    private var warmProcess: Process?

    private init() {}

    func open(url: URL) -> Bool {
        if Self.requiresChromeNativePiP(url) {
            return openChrome(url: url)
        }
        return openHelper(url: url)
    }

    func warmUp() {
        guard warmProcess?.isRunning != true,
              let root = spikeRootURL(),
              let executable = electronExecutableURL(root: root)
        else { return }

        let task = Process()
        task.executableURL = executable
        task.currentDirectoryURL = root
        task.arguments = [root.path, "--warm"]
        task.standardOutput = nil
        task.standardError = nil
        warmProcess = task

        do {
            try task.run()
            DiagnosticsLogbook.shared.record(
                "ott_helper_warmed",
                category: "cursor_pip",
                details: ["pid": "\(task.processIdentifier)"]
            )
        } catch {
            warmProcess = nil
            DiagnosticsLogbook.shared.record(
                "ott_helper_warm_failed",
                category: "cursor_pip",
                details: ["error": "\(error)"]
            )
        }
    }

    static func requiresChromeNativePiP(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host.hasSuffix("netflix.com")
            || host.hasSuffix("primevideo.com")
            || host.hasSuffix("amazon.com")
    }

    private func openChrome(url: URL) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            configuration: configuration
        ) { app, error in
            DiagnosticsLogbook.shared.record(
                error == nil ? "chrome_native_pip_opened" : "chrome_native_pip_open_failed",
                category: "cursor_pip",
                details: [
                    "host": url.host ?? "",
                    "app": app?.bundleIdentifier ?? "",
                    "error": error.map(String.init(describing:)) ?? ""
                ]
            )
        }
        return true
    }

    private func openHelper(url: URL) -> Bool {
        guard let root = spikeRootURL() else {
            DiagnosticsLogbook.shared.record(
                "ott_helper_launch_failed",
                category: "cursor_pip",
                details: ["reason": "missing_helper"]
            )
            NSWorkspace.shared.open(url)
            return false
        }

        if process?.isRunning == true {
            process?.terminate()
        }
        guard let executable = electronExecutableURL(root: root) else {
            DiagnosticsLogbook.shared.record(
                "ott_helper_launch_failed",
                category: "cursor_pip",
                details: ["reason": "missing_electron_binary", "root": root.path]
            )
            NSWorkspace.shared.open(url)
            return false
        }

        let task = Process()
        task.executableURL = executable
        task.currentDirectoryURL = root
        task.arguments = [root.path, "--url", url.absoluteString]
        task.standardOutput = nil
        task.standardError = nil
        process = task

        do {
            try task.run()
            DiagnosticsLogbook.shared.record(
                "ott_helper_launched",
                category: "cursor_pip",
                details: ["host": url.host ?? "", "pid": "\(task.processIdentifier)"]
            )
            return true
        } catch {
            DiagnosticsLogbook.shared.record(
                "ott_helper_launch_failed",
                category: "cursor_pip",
                details: ["reason": "run_failed", "error": "\(error)"]
            )
            NSWorkspace.shared.open(url)
            return false
        }
    }

    private func electronExecutableURL(root: URL) -> URL? {
        let candidates = [
            root.appendingPathComponent("node_modules/electron/dist/Electron.app/Contents/MacOS/Electron"),
            root.appendingPathComponent("node_modules/.bin/electron")
        ]

        return candidates.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func spikeRootURL() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("OTTPiP", isDirectory: true),
            URL(fileURLWithPath: "/Users/arv/Desktop/cmd/spikes/castlabs-electron-pip")
        ].compactMap { $0 }

        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("package.json").path)
        }
    }
}
