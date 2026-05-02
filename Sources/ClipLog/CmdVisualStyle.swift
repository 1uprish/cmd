import AppKit
import ClipLogCore

enum CmdVisualStyle {
    static let cardCornerRadius: CGFloat = 18
    static let compactCornerRadius: CGFloat = 12
    static let hairline: CGFloat = 0.5

    static let cardBorder = NSColor.white.withAlphaComponent(0.12)
    static let cardBorderHover = NSColor.white.withAlphaComponent(0.22)
    static let cardBorderSelected = NSColor.white.withAlphaComponent(0.30)

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
