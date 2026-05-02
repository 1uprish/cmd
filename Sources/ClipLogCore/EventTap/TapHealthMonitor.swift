@preconcurrency import CoreGraphics
import Foundation

public final class TapHealthMonitor: @unchecked Sendable {

    private let tap: CFMachPort
    private let onDegraded: @Sendable () -> Void
    private let onRecovered: @Sendable () -> Void

    private let queue = DispatchQueue(label: "com.cmd.tapHealthMonitor", qos: .utility)

    // Wrapped in a class box so we can mutate from within a Sendable context
    // without triggering Swift 6 isolation errors on stored var properties.
    private final class MutableState: @unchecked Sendable {
        var timer: DispatchSourceTimer?
        var wasDegraded = false
    }
    private let state = MutableState()

    public init(
        tap: CFMachPort,
        onDegraded: @escaping @Sendable () -> Void,
        onRecovered: @escaping @Sendable () -> Void
    ) {
        self.tap = tap
        self.onDegraded = onDegraded
        self.onRecovered = onRecovered
    }

    public func start() {
        queue.async { [self] in
            guard state.timer == nil else { return }

            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in self?.poll() }
            state.timer = t
            t.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            state.timer?.cancel()
            state.timer = nil
        }
    }

    private func poll() {
        let isEnabled = CGEvent.tapIsEnabled(tap: tap)

        if !isEnabled {
            // Re-enable before firing the callback so callers see a consistent
            // state if they immediately query tap health.
            CGEvent.tapEnable(tap: tap, enable: true)

            if !state.wasDegraded {
                state.wasDegraded = true
                let cb = onDegraded
                DispatchQueue.main.async { cb() }
            }
        } else if state.wasDegraded {
            state.wasDegraded = false
            let cb = onRecovered
            DispatchQueue.main.async { cb() }
        }
    }
}
