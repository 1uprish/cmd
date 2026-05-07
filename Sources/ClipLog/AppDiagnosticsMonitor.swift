import Foundation
import ClipLogCore

final class AppDiagnosticsMonitor {
    static let shared = AppDiagnosticsMonitor()

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.cmd.diagnostics.monitor", qos: .utility)
    private var lastHeartbeat = Date.distantPast
    private let heartbeatInterval: TimeInterval = 300

    private init() {}

    func start() {
        guard timer == nil else { return }
        DiagnosticsLogbook.shared.record("monitor_started", category: "diagnostics")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(200))
        timer.setEventHandler {
            let sent = Date()
            DispatchQueue.main.async {
                let latency = Date().timeIntervalSince(sent)
                if latency >= 0.75 {
                    DiagnosticsLogbook.shared.record(
                        "main_thread_stall",
                        category: "performance",
                        details: ["latencyMs": "\(Int(latency * 1000))"]
                    )
                }
            }

            let now = Date()
            if now.timeIntervalSince(self.lastHeartbeat) >= self.heartbeatInterval {
                self.lastHeartbeat = now
                DiagnosticsLogbook.shared.record(
                    "health_heartbeat",
                    category: "diagnostics",
                    details: [
                        "uptimeSeconds": "\(Int(ProcessInfo.processInfo.systemUptime))"
                    ]
                )
            }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
        DiagnosticsLogbook.shared.record("monitor_stopped", category: "diagnostics")
    }
}
