import Foundation

// MARK: - TapEvent

public enum TapEvent {
    case cmdVDown
    case cmdVUp
    case cmdRelease
}

// MARK: - TapAction

public enum TapAction: Equatable {
    case suppress       // eat the event
    case passthrough    // synthesise real ⌘V
    case showHUD        // trigger HUD
    case cancelHUD      // hide HUD (⌘ released without selection)
    case none
}

// MARK: - StateMachine
//
// Pure synchronous value type; zero CoreGraphics dependencies.
// The hold timer is external — the caller fires `.cmdVDown` (after threshold)
// via `hudDidAppear()` and sends `.cmdVUp` before it when the key is released
// early. This keeps the state machine fully testable without Accessibility
// permission or a real run loop.

public struct StateMachine {

    private enum State {
        case idle
        case pendingHold
        case hudActive
    }

    private var state: State = .idle

    public init() {}

    public mutating func handle(_ event: TapEvent) -> TapAction {
        switch state {
        case .idle:
            switch event {
            case .cmdVDown:
                state = .pendingHold
                return .suppress
            case .cmdVUp, .cmdRelease:
                return .none
            }

        case .pendingHold:
            switch event {
            case .cmdVDown:
                // Key repeat while waiting for threshold — keep suppressing.
                return .suppress
            case .cmdVUp:
                state = .idle
                return .passthrough
            case .cmdRelease:
                // ⌘ physically released before V came back up — rare edge case.
                state = .idle
                return .passthrough
            }

        case .hudActive:
            switch event {
            case .cmdVDown:
                return .suppress
            case .cmdVUp:
                return .none
            case .cmdRelease:
                // Releasing command after the hold is normal. Keep the HUD alive
                // for click, copy, drag, scroll, and type-to-filter.
                return .none
            }
        }
    }

    // Called by the real EventTap when the hold timer fires and the HUD appears.
    // Transitions pendingHold → hudActive; no-op in any other state.
    public mutating func hudDidAppear() {
        guard case .pendingHold = state else { return }
        state = .hudActive
    }
}
