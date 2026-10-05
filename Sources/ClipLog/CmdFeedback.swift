import AppKit

// MARK: - CmdFeedbackSound
//
// Subtle confirmation sounds for meaningful commit moments (copy, paste,
// capture). Opt-in via Settings; the matching haptic is fired by the caller on
// the same frame so the two stay in harmony. Selection and other high-frequency
// events deliberately stay silent so feedback keeps its signal.

enum CmdFeedbackSound {

    enum Moment {
        case copy
        case paste
        case capture
    }

    static func play(_ moment: Moment) {
        guard ClipLogSettings.shared.feedbackSoundsEnabled else { return }
        let name: NSSound.Name
        switch moment {
        case .copy:    name = NSSound.Name("Morse")
        case .paste:   name = NSSound.Name("Tink")
        case .capture: name = NSSound.Name("Pop")
        }
        NSSound(named: name)?.play()
    }
}
