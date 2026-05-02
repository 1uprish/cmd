import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum DemoContentKind: String, CaseIterable {
    case text
    case image
    case url
    case secret
    case color
    case file

    var registerLabel: String {
        switch self {
        case .text: return "TEXT"
        case .image: return "IMAGE"
        case .url: return "URL"
        case .secret: return "SENSITIVE"
        case .color: return "COLOR"
        case .file: return "FILE"
        }
    }

    var symbolName: String {
        switch self {
        case .text: return "text.alignleft"
        case .image: return "photo"
        case .url: return "link"
        case .secret: return "key.fill"
        case .color: return "eyedropper.halffull"
        case .file: return "doc.fill"
        }
    }
}

struct DemoRegisterEntry: Identifiable, Equatable {
    let id: UUID
    let sourceApp: String
    let sourceSymbolName: String
    let kind: DemoContentKind
    let rawValue: String
    let displayValue: String
    let timestamp: Date
    let accent: NSColor
    let thumbnail: NSImage?
    let isSensitive: Bool

    init(
        id: UUID = UUID(),
        sourceApp: String,
        sourceSymbolName: String,
        kind: DemoContentKind,
        rawValue: String,
        displayValue: String? = nil,
        timestamp: Date = Date(),
        accent: NSColor,
        thumbnail: NSImage? = nil,
        isSensitive: Bool = false
    ) {
        self.id = id
        self.sourceApp = sourceApp
        self.sourceSymbolName = sourceSymbolName
        self.kind = kind
        self.rawValue = rawValue
        self.displayValue = displayValue ?? rawValue
        self.timestamp = timestamp
        self.accent = accent
        self.thumbnail = thumbnail
        self.isSensitive = isSensitive
    }

    var registerPreview: String {
        if isSensitive {
            return "sk-demo...hidden"
        }
        let singleLine = displayValue.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 76 ? String(singleLine.prefix(76)) + "..." : singleLine
    }

    var dragPayload: String {
        rawValue
    }

    var fingerprint: String {
        let digest = SHA256.hash(data: Data(rawValue.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum OnboardingDemoEntries {
    private static let neutralAccent = NSColor(calibratedWhite: 0.72, alpha: 1)

    static let text = DemoRegisterEntry(
        sourceApp: "Notes",
        sourceSymbolName: "note.text",
        kind: .text,
        rawValue: "Welcome to cmd. Copy once, reuse anytime.",
        accent: neutralAccent
    )

    static let image = DemoRegisterEntry(
        sourceApp: "Preview",
        sourceSymbolName: "photo.fill.on.rectangle.fill",
        kind: .image,
        rawValue: "Product image copied from the launch brief.",
        displayValue: "Launch image card",
        accent: neutralAccent,
        thumbnail: DemoImageFactory.productCard()
    )

    static let url = DemoRegisterEntry(
        sourceApp: "Safari",
        sourceSymbolName: "safari.fill",
        kind: .url,
        rawValue: "https://cmd.local/launch-brief",
        accent: neutralAccent
    )

    static let secret = DemoRegisterEntry(
        sourceApp: "Xcode",
        sourceSymbolName: "curlybraces.square.fill",
        kind: .secret,
        rawValue: "sk-demo_copy_this_is_fake_9x4Tqv7L",
        displayValue: "Fake demo API key with expiry controls",
        accent: neutralAccent,
        isSensitive: true
    )

    static let color = DemoRegisterEntry(
        sourceApp: "Figma",
        sourceSymbolName: "paintpalette.fill",
        kind: .color,
        rawValue: "#34C759",
        displayValue: "Success green #34C759",
        accent: .systemGreen
    )

    static let file = DemoRegisterEntry(
        sourceApp: "Finder",
        sourceSymbolName: "folder.fill",
        kind: .file,
        rawValue: "file:///Users/demo/Desktop/Invoice-May-Demo.pdf",
        displayValue: "Invoice-May-Demo.pdf",
        accent: neutralAccent
    )

    static let rehearsalSequence: [DemoRegisterEntry] = [
        text,
        image,
        url,
        secret,
        color,
        file,
    ]
}

enum DemoImageFactory {
    static func productCard() -> NSImage {
        let size = NSSize(width: 220, height: 150)
        let image = NSImage(size: size)
        image.lockFocus()

        let bounds = NSRect(origin: .zero, size: size)
        NSGradient(
            colors: [
                NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1),
                NSColor(calibratedRed: 0.06, green: 0.07, blue: 0.09, alpha: 1),
            ]
        )?.draw(in: bounds, angle: 90)

        let card = NSBezierPath(roundedRect: NSRect(x: 22, y: 28, width: 176, height: 94), xRadius: 18, yRadius: 18)
        NSColor(calibratedWhite: 1, alpha: 0.12).setFill()
        card.fill()
        NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
        card.lineWidth = 1
        card.stroke()

        let glow = NSBezierPath(ovalIn: NSRect(x: 68, y: 44, width: 84, height: 58))
        NSColor(calibratedWhite: 0.76, alpha: 0.44).setFill()
        glow.fill()
        let inner = NSBezierPath(ovalIn: NSRect(x: 86, y: 58, width: 48, height: 32))
        NSColor(calibratedWhite: 0.92, alpha: 0.58).setFill()
        inner.fill()

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 17, weight: .heavy),
            .foregroundColor: NSColor.white,
        ]
        "cmd".draw(at: NSPoint(x: 54, y: 95), withAttributes: titleAttrs)

        let lineAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
        ]
        "visual clipboard memory".draw(at: NSPoint(x: 52, y: 76), withAttributes: lineAttrs)

        image.unlockFocus()
        return image
    }
}
