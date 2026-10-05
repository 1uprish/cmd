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

    private static var cachedSound: NSSound?

    static func play(_ moment: Moment) {
        guard ClipLogSettings.shared.feedbackSoundsEnabled else { return }
        preview()
    }

    /// Plays regardless of the setting, so Settings can offer a preview.
    static func preview() {
        guard let sound = sound() else { return }
        // Restart so rapid commits each get their own poke.
        sound.stop()
        sound.play()
    }

    private static func sound() -> NSSound? {
        if let cachedSound { return cachedSound }
        let url = Bundle.main.url(forResource: "bencho-poke", withExtension: "wav")
            ?? Bundle.module.url(forResource: "bencho-poke", withExtension: "wav")
        guard let url, let sound = NSSound(contentsOf: url, byReference: true) else { return nil }
        cachedSound = sound
        return sound
    }
}
