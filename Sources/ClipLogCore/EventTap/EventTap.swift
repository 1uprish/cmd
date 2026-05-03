@preconcurrency import CoreGraphics
import AppKit
import Foundation

// MARK: - ClipLogEventTap
//
// Architecture:
//   CGEventTap installed at kCGHIDEventTap (before any app sees it).
//   On ⌘V keyDown:
//     - Immediately SUPPRESS the event (return nil)
//     - Start a 200ms timer
//     - If keyUp fires before timer: synthesise a real ⌘V and post it (passthrough)
//     - If timer fires before keyUp: trigger HUD, wait for slot selection
//   Releasing ⌘ after the HUD opens does not dismiss it.
//
// Threading:
//   The tap callback runs on a dedicated CFRunLoop thread (tapThread).
//   All state mutations go through a serial DispatchQueue (tapQueue).
//   HUD show/hide always dispatched to main.
//
// Why suppress immediately rather than delay?
//   If we pass the event through and then try to "undo" it, the target app
//   has already received it — you cannot recall a CGEvent once delivered.
//   So we must suppress on keyDown unconditionally, then re-synthesise if
//   the hold doesn't complete. This is the correct approach.

public final class ClipLogEventTap: @unchecked Sendable {

    public init() {}

    // MARK: - Public interface

    public var onHUDTrigger: ((UInt64) -> Void)?
    public var onPassthrough: (() -> Void)?
    public var onAppendGesture: (() -> Void)?
    public var onQueuedPaste: (() -> Void)?

    public var onHUDDismiss: ((UInt64) -> Void)?
    public var onHUDEscape: ((UInt64) -> Void)?
    public var onHUDMoveSelection: ((Int) -> Void)?
    public var onHUDConfirmSelection: ((UInt64) -> Void)?
    public var onHUDCharFilter: ((Character) -> Void)?
    public var onHUDBackspace: (() -> Void)?

    /// Safety net queried on tapQueue: is the HUD panel actually on screen?
    /// Prevents ⌘V from being permanently swallowed by a stale .hudActive state.
    public var isHUDActuallyVisible: (() -> Bool)?

    /// How long ⌘V must be held to trigger the HUD. Default 200ms.
    public var holdThreshold: TimeInterval = 0.200

    public func updateHoldThreshold(_ threshold: TimeInterval) {
        let clamped = min(max(threshold, 0.100), 0.500)
        tapQueue.async {
            self.holdThreshold = clamped
        }
    }


    // MARK: - Private state (all access serialised through tapQueue)

    fileprivate var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

    private var selfRef: Unmanaged<ClipLogEventTap>?
    private var tapRunLoop: CFRunLoop?

    private var healthMonitor: TapHealthMonitor?

    fileprivate let tapQueue = DispatchQueue(label: "com.cmd.eventTap", qos: .userInteractive)

    private var lastCommandTapTime: Date?
    private var commandKeyIsDown = false
    private var commandTapClean = false
    private let appendGestureInterval: TimeInterval = 0.65

    // State machine
    private enum State {
        case idle
        case pendingHold(sessionID: UInt64, timer: DispatchSourceTimer)
        case hudActive(sessionID: UInt64)
    }
    private var state: State = .idle
    private var nextSessionID: UInt64 = 0

    // MARK: - Start / stop

    public func start() throws {
        guard AXIsProcessTrusted() else {
            throw TapError.accessibilityPermissionDenied
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue)   |
            (1 << CGEventType.flagsChanged.rawValue)

        let selfPtr = Unmanaged.passRetained(self)

        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: selfPtr.toOpaque()
        ) else {
            selfPtr.release()
            throw TapError.tapCreationFailed
        }

        self.selfRef = selfPtr
        self.tap = port
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        self.runLoopSource = src

        let t = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            let rl = CFRunLoopGetCurrent()
            self.tapQueue.async { self.tapRunLoop = rl }
            CFRunLoopRun()
        }
        t.name = "com.cmd.tapRunLoop"
        t.qualityOfService = .userInteractive
        t.start()
        self.tapThread = t

        // Health monitor re-enables the tap if macOS disables it
        // (happens when the callback takes too long).
        let monitor = TapHealthMonitor(
            tap: port,
            onDegraded: {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .clipLogTapDegraded, object: nil)
                }
            },
            onRecovered: {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .clipLogTapRecovered, object: nil)
                }
            }
        )
        self.healthMonitor = monitor
        monitor.start()
        DiagnosticsLogbook.shared.record("event_tap_started", category: "event_tap")
    }

    public func stop() {
        DiagnosticsLogbook.shared.record("event_tap_stopped", category: "event_tap")
        tapQueue.sync {
            if case .pendingHold(_, let timer) = state {
                timer.cancel()
            }
            state = .idle
            commandKeyIsDown = false
            commandTapClean = false
            lastCommandTapTime = nil
        }
        tap.map { CGEvent.tapEnable(tap: $0, enable: false) }
        tapRunLoop.map { CFRunLoopStop($0) }
        tapRunLoop = nil
        selfRef?.release()
        selfRef = nil
        healthMonitor?.stop()
        healthMonitor = nil
        runLoopSource = nil
        tap = nil
    }

    // MARK: - Event handling (called from tapQueue)

    fileprivate func handle(event: CGEvent, type: CGEventType) -> CGEvent? {
        switch type {

        case .keyDown:
            if event.flags.contains(.maskCommand) {
                commandTapClean = false
            }
            // HUD is open — intercept all keys at HID level. If AppKit has
            // already dismissed the panel, reset first so the next ⌘V starts fresh.
            if case .hudActive = state, !isStaleHUDState() {
                return handleHUDKeyDown(event: event)
            }
            guard isCommandV(event) else { return event }
            return handleCommandVDown(event: event)

        case .keyUp:
            guard isCommandV(event) else { return event }
            return handleCommandVUp(event: event)

        case .flagsChanged:
            let commandDown = event.flags.contains(.maskCommand)

            if commandDown, !commandKeyIsDown {
                commandKeyIsDown = true
                commandTapClean = isOnlyCommandModifier(event)
                return event
            }

            if !commandDown, commandKeyIsDown {
                commandKeyIsDown = false
                let wasCleanCommandTap = commandTapClean && isIdle
                commandTapClean = false
                if wasCleanCommandTap {
                    handleAppendGesture(currentTime: Date(), lastTime: &lastCommandTapTime)
                }
                handleCommandRelease()
                return event
            }

            if !commandDown {
                handleCommandRelease()
            }
            return event

        default:
            return event
        }
    }

    // MARK: - State machine

    private func handleCommandVDown(event: CGEvent) -> CGEvent? {
        switch state {
        case .idle:
            if !PasteQueue.shared.isEmpty {
                DispatchQueue.main.async { self.onQueuedPaste?() }
                return nil
            }
            let sessionID = makeSessionID()
            let timer = makeHoldTimer(sessionID: sessionID)
            state = .pendingHold(sessionID: sessionID, timer: timer)
            timer.resume()
            return nil  // suppressed

        case .pendingHold:
            return nil  // key-repeat — already timing, keep suppressing

        case .hudActive:
            // Safety net: if the HUD is no longer on screen (dismissed via a path
            // that bypassed hudDidDismiss), reset and process this ⌘V inline.
            if isStaleHUDState() {
                return handleCommandVDown(event: event)
            }
            return nil
        }
    }

    private func handleCommandVUp(event: CGEvent) -> CGEvent? {
        switch state {
        case .pendingHold(_, let timer):
            // Released before hold threshold — deliver the paste we owe.
            timer.cancel()
            state = .idle
            synthesiseCommandV()
            DispatchQueue.main.async { self.onPassthrough?() }
            return nil

        case .hudActive:
            // HUD handles selection; keyUp is irrelevant.
            return nil

        case .idle:
            return event
        }
    }

    private func handleCommandRelease() {
        switch state {
        case .pendingHold(_, let timer):
            // ⌘ released before the hold threshold — deliver the paste we suppressed.
            timer.cancel()
            state = .idle
            synthesiseCommandV()
            DispatchQueue.main.async { self.onPassthrough?() }
        case .hudActive:
            // Do NOT cancel the HUD here.
            // Releasing command after the hold is normal; keep the notification
            // list alive for click, copy, drag, scroll, and type-to-filter.
            break
        case .idle:
            break
        }
    }

    /// Called when macOS disables the tap (timeout or user-input type).
    /// Re-enables the tap and resets state so leaked key-repeat events
    /// don't cause a double-paste on the next keyUp.
    fileprivate func handleTapDisabled() {
        DiagnosticsLogbook.shared.record("event_tap_disabled_reenable", category: "event_tap")
        // Re-enable immediately.
        if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }

        // Events leaked while tap was disabled — the app already received
        // them, so we must not synthesise again.
        if case .pendingHold(_, let timer) = state { timer.cancel() }
        state = .idle
    }

    // MARK: - Hold timer

    private func makeHoldTimer(sessionID: UInt64) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: tapQueue)
        timer.schedule(deadline: .now() + holdThreshold, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard case .pendingHold(let activeSessionID, _) = self.state,
                  activeSessionID == sessionID else { return }
            self.state = .hudActive(sessionID: sessionID)
            DispatchQueue.main.async { self.onHUDTrigger?(sessionID) }
        }
        return timer
    }

    private func makeSessionID() -> UInt64 {
        nextSessionID &+= 1
        if nextSessionID == 0 { nextSessionID = 1 }
        return nextSessionID
    }

    private func isStaleHUDState() -> Bool {
        guard case .hudActive = state,
              let check = isHUDActuallyVisible,
              !check()
        else { return false }
        state = .idle
        return true
    }

    private var isIdle: Bool {
        if case .idle = state { return true }
        return false
    }

    private func resetStaleHUDIfNeeded() {
        _ = isStaleHUDState()
    }

    // MARK: - Passthrough synthesis
    //
    // Post at .cgSessionEventTap so it goes below our HID tap and doesn't
    // re-enter the callback.

    private func synthesiseCommandV() {
        guard let src = CGEventSource(stateID: .hidSystemState) else { return }
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true) {
            down.flags = .maskCommand
            down.post(tap: .cgSessionEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) {
            up.flags = .maskCommand
            up.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: - Helpers

    private func isCommandV(_ event: CGEvent) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let exactCommand = event.flags.intersection([
            .maskCommand, .maskShift, .maskAlternate, .maskControl
        ]) == .maskCommand
        return keyCode == 0x09 && exactCommand
    }

    private func isKeyRepeat(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    }

    private func isOnlyCommandModifier(_ event: CGEvent) -> Bool {
        event.flags.intersection([
            .maskCommand, .maskShift, .maskAlternate, .maskControl
        ]) == .maskCommand
    }

    @discardableResult
    private func handleAppendGesture(currentTime now: Date, lastTime: inout Date?) -> Bool {
        if let last = lastTime, now.timeIntervalSince(last) <= appendGestureInterval {
            lastTime = nil
            DispatchQueue.main.async { self.onAppendGesture?() }
            return true
        } else {
            lastTime = now
            return false
        }
    }

    // MARK: - HUD key dispatch

    private static let kVK_Escape: Int64 = 53
    private static let kVK_Delete: Int64 = 51
    private static let kVK_Return: Int64 = 36
    private static let kVK_KeypadEnter: Int64 = 76
    private static let kVK_UpArrow: Int64 = 126
    private static let kVK_DownArrow: Int64 = 125
    private static let blockedCommandLetterKeys: Set<Int64> = [
        12, // Q
        13, // W
        14, // E
        15, // R
        17, // T
    ]

    private func handleHUDKeyDown(event: CGEvent) -> CGEvent? {
        guard case .hudActive(let sessionID) = state else { return event }

        let vk  = event.getIntegerValueField(.keyboardEventKeycode)
        let cmd = event.flags.contains(.maskCommand)
        let opt = event.flags.contains(.maskAlternate)
        let ctrl = event.flags.contains(.maskControl)
        let exactCommand = event.flags.intersection([
            .maskCommand, .maskShift, .maskAlternate, .maskControl
        ]) == .maskCommand

        // ESC → dismiss
        if vk == Self.kVK_Escape {
            DispatchQueue.main.async { self.onHUDEscape?(sessionID) }
            return nil
        }

        // Arrow keys → move visual selection.
        if !cmd, !opt, !ctrl, vk == Self.kVK_UpArrow {
            DispatchQueue.main.async { self.onHUDMoveSelection?(-1) }
            return nil
        }
        if !cmd, !opt, !ctrl, vk == Self.kVK_DownArrow {
            DispatchQueue.main.async { self.onHUDMoveSelection?(1) }
            return nil
        }

        // Return → paste the selected visible entry.
        if !cmd, !opt, !ctrl, vk == Self.kVK_Return || vk == Self.kVK_KeypadEnter {
            DispatchQueue.main.async { self.onHUDConfirmSelection?(sessionID) }
            return nil
        }

        // The HUD no longer exposes command-key slot shortcuts. While it is open,
        // suppress exact command-letter chords so they do not quit/close the
        // foreground app behind the non-activating panel.
        if exactCommand, Self.blockedCommandLetterKeys.contains(vk) {
            return nil
        }

        // Delete/backspace → clear filter
        if vk == Self.kVK_Delete {
            DispatchQueue.main.async { self.onHUDBackspace?() }
            return nil
        }

        // Plain printable character (no modifiers) → type-to-filter
        if !cmd, !opt, !ctrl, let chars = event.getUnicode(), let ch = chars.first,
           ch.isLetter || ch.isNumber || ch.isPunctuation || ch.isSymbol {
            DispatchQueue.main.async { self.onHUDCharFilter?(ch) }
            return nil
        }

        // Everything else passes through (screenshots, media keys, etc.)
        return event
    }

    public func hudDidDismiss(sessionID: UInt64) {
        tapQueue.async { [weak self] in
            guard let self,
                  case .hudActive(let activeSessionID) = self.state,
                  activeSessionID == sessionID
            else { return }
            self.state = .idle
        }
    }

    // MARK: - Error

    public enum TapError: LocalizedError {
        case accessibilityPermissionDenied
        case tapCreationFailed

        public var errorDescription: String? {
            switch self {
            case .accessibilityPermissionDenied:
                return "Accessibility permission required. Enable cmd in System Settings → Privacy & Security → Accessibility."
            case .tapCreationFailed:
                return "CGEventTap creation failed. Try restarting cmd."
            }
        }
    }
}

// MARK: - Notification names

public extension Notification.Name {
    static let clipLogHUDCancel    = Notification.Name("com.cmd.hudCancel")
    static let clipLogTapDegraded  = Notification.Name("com.cmd.tapDegraded")
    static let clipLogTapRecovered = Notification.Name("com.cmd.tapRecovered")
}

// MARK: - CGEvent unicode helper

private extension CGEvent {
    func getUnicode() -> [Character]? {
        var length: Int = 0
        self.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
        guard length > 0 else { return nil }
        var buffer = [UInt16](repeating: 0, count: length)
        self.keyboardGetUnicodeString(maxStringLength: length, actualStringLength: &length, unicodeString: &buffer)
        return buffer.prefix(length).compactMap { Unicode.Scalar($0).map(Character.init) }
    }
}

// MARK: - C-compatible tap callback

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    guard let ptr = userInfo else { return Unmanaged.passRetained(event) }
    let tapObj = Unmanaged<ClipLogEventTap>.fromOpaque(ptr).takeUnretainedValue()

    // macOS disables an event tap whose callback takes too long.
    // Re-enable immediately and reset state — events leaked while the tap
    // was disabled, so we must not synthesise a duplicate paste.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        tapObj.tapQueue.async { tapObj.handleTapDisabled() }
        return nil
    }

    var result: CGEvent? = event
    tapObj.tapQueue.sync {
        result = tapObj.handle(event: event, type: type)
    }

    if let r = result {
        return Unmanaged.passRetained(r)
    }
    return nil
}
