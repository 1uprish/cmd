import AppKit
import ClipLogCore
import QuartzCore

// MARK: - Motion tokens
//
// Apple-style springs described by damping ratio + response (seconds), not the
// raw mass/stiffness/damping triplet. `standard` is critically damped and is
// the default; reserve `momentum` bounce for interactions that carried a
// gesture's velocity.

enum CmdSpring {
    struct Spec {
        let dampingRatio: CGFloat
        let response: TimeInterval
    }

    static let standard = Spec(dampingRatio: 1.0, response: 0.34)
    static let momentum = Spec(dampingRatio: 0.8, response: 0.34)

    /// Builds a `CASpringAnimation` from a spec. Stiffness is derived from the
    /// response (ω₀ = 2π / response, k = ω₀²), so callers keep thinking in
    /// response seconds.
    static func animation(
        keyPath: String,
        spec: Spec = standard,
        from: Any?,
        to: Any?,
        initialVelocity: CGFloat = 0
    ) -> CASpringAnimation {
        let omega = (2 * CGFloat.pi) / CGFloat(spec.response)
        let animation = CASpringAnimation(keyPath: keyPath)
        animation.stiffness = omega * omega
        animation.mass = 1
        // ζ = damping / (2·√(k·m))  ⇒  damping = 2·ζ·ω
        animation.damping = 2 * spec.dampingRatio * omega
        animation.initialVelocity = initialVelocity
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }
}

enum CmdVisualStyle {
    static let cardCornerRadius: CGFloat = 18
    static let compactCornerRadius: CGFloat = 12
    static let hairline: CGFloat = 0.5

    static let cardBorder = NSColor.white.withAlphaComponent(0.12)
    static let cardBorderHover = NSColor.white.withAlphaComponent(0.22)
    static let cardBorderSelected = NSColor.white.withAlphaComponent(0.30)

    // Increase-contrast variants for the always-dark HUD chrome.
    static let cardBorderStrong = NSColor.white.withAlphaComponent(0.28)
    static let cardBorderHoverStrong = NSColor.white.withAlphaComponent(0.40)
    static let cardBorderSelectedStrong = NSColor.white.withAlphaComponent(0.52)

    static let primaryText = NSColor.white
    static let secondaryText = NSColor.white.withAlphaComponent(0.72)
    static let tertiaryText = NSColor.white.withAlphaComponent(0.48)

    static func label(for type: ClipContentType, uppercase: Bool = false) -> String {
        let value: String
        switch type {
        case .text: value = "Text"
        case .url: value = "URL"
        case .code: value = "Code"
        case .image: value = "Image"
        case .rich: value = "Mixed"
        case .file: value = "File"
        case .color: value = "Color"
        }
        return uppercase ? value.uppercased() : value
    }
}
