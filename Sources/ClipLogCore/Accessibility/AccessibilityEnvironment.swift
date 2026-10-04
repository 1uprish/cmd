import AppKit

// MARK: - AccessibilityEnvironment
//
// Single, observed source of truth for the user's accessibility display
// preferences. Reading them once at launch is not enough — users can change
// them while the app is running, so we observe the workspace notification and
// notify listeners to re-apply their appearance.
//
//   reduceMotion          → cross-fade instead of slides/springs
//   reduceTransparency    → frost/solid chrome instead of glass
//   increaseContrast      → defined, higher-contrast borders

public final class AccessibilityEnvironment: NSObject, @unchecked Sendable {

    public static let shared = AccessibilityEnvironment()

    public private(set) var shouldReduceMotion: Bool
    public private(set) var shouldReduceTransparency: Bool
    public private(set) var shouldIncreaseContrast: Bool

    /// Called on the main thread whenever any display preference changes.
    public var onChange: (() -> Void)?

    private override init() {
        let workspace = NSWorkspace.shared
        shouldReduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        shouldReduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        shouldIncreaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        super.init()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(displayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    /// Collapses a motion duration to zero when the user prefers reduced motion,
    /// so callers can keep their animation code but cross-fade instead of travel.
    public func motionDuration(_ duration: TimeInterval) -> TimeInterval {
        shouldReduceMotion ? 0 : duration
    }

    @objc private func displayOptionsDidChange() {
        let workspace = NSWorkspace.shared
        let motion = workspace.accessibilityDisplayShouldReduceMotion
        let transparency = workspace.accessibilityDisplayShouldReduceTransparency
        let contrast = workspace.accessibilityDisplayShouldIncreaseContrast
        guard motion != shouldReduceMotion
            || transparency != shouldReduceTransparency
            || contrast != shouldIncreaseContrast
        else { return }

        shouldReduceMotion = motion
        shouldReduceTransparency = transparency
        shouldIncreaseContrast = contrast

        DispatchQueue.main.async { [weak self] in
            self?.onChange?()
        }
    }
}
