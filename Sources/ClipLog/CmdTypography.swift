import AppKit

// MARK: - CmdTypography
//
// Respects the user's text-size setting. macOS exposes the preferred content
// size through `NSFont.preferredFont(forTextStyle:)`; we derive a scale factor
// from it relative to the default body size and apply it to the HUD and
// ClipBook chrome so text and its surrounding metrics grow together.
//
// The platform system font already ships optical sizing and tracking tables,
// so we only scale size here; display-size titles keep their negative tracking
// at the call site.

enum CmdTypography {

    /// Ratio of the user's preferred body size to the macOS default (13pt).
    /// Returns 1.0 when the system is at the default size.
    static var textScale: CGFloat {
        let preferred = NSFont.preferredFont(forTextStyle: .body).pointSize
        let base = NSFont.systemFont(ofSize: 13).pointSize
        guard base > 0 else { return 1 }
        return min(1.5, max(0.85, preferred / base))
    }

    /// System font at `size` scaled by the user's text-size preference.
    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: (size * textScale).rounded(), weight: weight)
    }

    /// Monospaced system font at `size`, scaled the same way.
    static func monoFont(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: (size * textScale).rounded(), weight: weight)
    }

    /// Scales a point metric (row height, spacing) alongside the text.
    static func metric(_ value: CGFloat) -> CGFloat {
        (value * textScale).rounded()
    }
}
