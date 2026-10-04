import AppKit
import ClipLogCore
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var tapController: TapController?
    private var isPollingForAccessibility = false
    private var eventTapIsRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Touch ClipLogSettings.shared first so defaults are registered before
        // we check them inside syncIfNeeded().
        _ = ClipLogSettings.shared
        DiagnosticsLogbook.shared.record("app_launch", category: "lifecycle")
        AppDiagnosticsMonitor.shared.start()
        // Keep the LaunchAgent plist current (handles rebuild / app move).
        LaunchAtLoginManager.syncIfNeeded()

        let tc = TapController()
        self.tapController = tc

        // Menu bar appears immediately — Accessibility not required for this.
        tc.startUI()

        startStartupPermissionFlow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticsLogbook.shared.record("app_terminate", category: "lifecycle")
        AppDiagnosticsMonitor.shared.stop()
        tapController?.stop()
    }

    // MARK: - Accessibility bootstrap

    /// Try to start the event tap. Handles three cases:
    ///  1. Already trusted → try to start immediately.
    ///  2. Not trusted yet → show system prompt, poll until granted.
    ///  3. Trusted (TCC says yes) but tap creation fails → stale TCC entry
    ///     from a previous build's code-signature; reset + re-prompt.
    private func startStartupPermissionFlow() {
        DiagnosticsLogbook.shared.record("startup_permission_flow_started", category: "permissions")
        checkAndStartEventTap()
    }

    private func checkAndStartEventTap() {
        if AXIsProcessTrusted() {
            DiagnosticsLogbook.shared.record("accessibility_trusted", category: "event_tap")
            attemptStart()
        } else {
            DiagnosticsLogbook.shared.record("accessibility_not_trusted", category: "event_tap")
            showAccessibilityPrompt()
            pollForAccessibility()
        }
    }

    /// Attempt to create the event tap. If it fails despite AX being trusted,
    /// the binary was rebuilt (new ad-hoc signature) and the old TCC entry is
    /// stale — clear it and ask the user to grant again.
    private func attemptStart() {
        guard !eventTapIsRunning else { return }
        do {
            try tapController?.startEventTap()
            eventTapIsRunning = true
            isPollingForAccessibility = false
        } catch {
            DiagnosticsLogbook.shared.record(
                "event_tap_start_failed",
                category: "event_tap",
                details: ["error": error.localizedDescription]
            )
            showAccessibilityPrompt()
            pollForAccessibility()
        }
    }

    private func pollForAccessibility() {
        guard !isPollingForAccessibility else { return }
        isPollingForAccessibility = true
        DiagnosticsLogbook.shared.record("accessibility_poll_started", category: "event_tap")
        pollForAccessibilityTick()
    }

    private func pollForAccessibilityTick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            if AXIsProcessTrusted() {
                DiagnosticsLogbook.shared.record("accessibility_granted", category: "event_tap")
                self.isPollingForAccessibility = false
                self.attemptStart()
            } else {
                self.pollForAccessibilityTick()
            }
        }
    }

    // MARK: - Helpers

    /// Show the system Accessibility permission dialog (or open System Settings if already shown).
    private func showAccessibilityPrompt() {
        let opts: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
        AXIsProcessTrustedWithOptions(opts)
    }

}
