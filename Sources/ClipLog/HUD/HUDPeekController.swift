import AppKit
import ClipLogCore

// MARK: - HUDPeekController
//
// A Quick Look-style preview for image clips: hovering a card reveals the full
// image in a floating material panel, so the small thumbnail only has to be a
// signpost. Mouse-transparent and never activates the app.

final class HUDPeekController {
    static let shared = HUDPeekController()

    private enum Layout {
        static let maxSize = NSSize(width: 440, height: 340)
        static let margin: CGFloat = 14
        static let padding: CGFloat = 8
    }

    private var panel: NSPanel?
    private let imageView = NSImageView()

    private init() {}

    func show(image: NSImage, near anchor: NSRect) {
        let panel = ensurePanel()
        let display = fittedSize(for: image.size)
        let contentSize = NSSize(
            width: display.width + Layout.padding * 2,
            height: display.height + Layout.padding * 2
        )
        imageView.image = image
        imageView.frame = NSRect(x: Layout.padding, y: Layout.padding, width: display.width, height: display.height)
        panel.setContentSize(contentSize)
        panel.setFrameOrigin(origin(for: contentSize, near: anchor))
        panel.orderFrontRegardless()
        panel.alphaValue = 1

        // Materialize: scale + fade the surface in together.
        guard let layer = panel.contentView?.layer else { return }
        layer.removeAllAnimations()
        if AccessibilityEnvironment.shared.shouldReduceMotion {
            layer.transform = CATransform3DIdentity
            layer.opacity = 1
            return
        }

        let from = CATransform3DMakeScale(0.96, 0.96, 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
        layer.add(
            CmdSpring.animation(
                keyPath: "transform",
                spec: CmdSpring.standard,
                from: NSValue(caTransform3D: from),
                to: NSValue(caTransform3D: CATransform3DIdentity)
            ),
            forKey: "cmd.peek.scale"
        )
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "cmd.peek.opacity")
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        DiagnosticsLogbook.shared.record("peek_hidden", category: "hud")
        panel.orderOut(nil)
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Layout.maxSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        imageView.imageScaling = .scaleProportionallyUpOrDown
        effect.addSubview(imageView)
        panel.contentView = effect
        self.panel = panel
        return panel
    }

    private func fittedSize(for imageSize: NSSize) -> NSSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return NSSize(width: 200, height: 140)
        }
        let scale = min(1, Layout.maxSize.width / imageSize.width, Layout.maxSize.height / imageSize.height)
        return NSSize(
            width: max(1, (imageSize.width * scale).rounded()),
            height: max(1, (imageSize.height * scale).rounded())
        )
    }

    private func origin(for size: NSSize, near anchor: NSRect) -> NSPoint {
        let screen = NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        var x = anchor.maxX + Layout.margin
        if x + size.width > visible.maxX - Layout.margin {
            x = anchor.minX - size.width - Layout.margin
        }
        x = min(max(visible.minX + Layout.margin, x), visible.maxX - size.width - Layout.margin)

        var y = anchor.midY - size.height / 2
        y = min(max(visible.minY + Layout.margin, y), visible.maxY - size.height - Layout.margin)
        return NSPoint(x: x.rounded(), y: y.rounded())
    }
}
