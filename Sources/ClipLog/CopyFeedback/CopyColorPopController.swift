import AppKit
import ClipLogCore
import QuartzCore

// MARK: - CopyColorPopController
//
// Little activating colour pop near the cursor on every copy.
// Colour-coded by content type:
//   image = lime green, url = purple, text = pink,
//   code = orange, rich = teal, file = blue, color = yellow.
// Shows no clipboard contents — colour only — so sensitive clips stay private.

final class CopyColorPopController {
    nonisolated(unsafe) static let shared = CopyColorPopController()

    private var panel: NSPanel?
    private var popView: PopView?
    private var hideWorkItem: DispatchWorkItem?
    private var generation = 0

    // Intentionally empty: AppKit panels must be created on the main thread,
    // but flash() is first called from the pasteboard watcher queue.
    private init() {}

    /// Strong ease-out for UI response. Built-in .easeOut is too weak.
    nonisolated static var easeOut: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
    }

    static func color(for type: ClipContentType) -> NSColor {
        switch type {
        case .image:
            return NSColor(red: 0.68, green: 0.95, blue: 0.25, alpha: 1.0) // lime green
        case .url:
            return NSColor(red: 0.63, green: 0.38, blue: 0.95, alpha: 1.0) // purple
        case .text:
            return NSColor(red: 1.0, green: 0.42, blue: 0.68, alpha: 1.0) // pink
        case .code:
            return NSColor(red: 1.0, green: 0.62, blue: 0.20, alpha: 1.0) // orange
        case .rich:
            return NSColor(red: 0.30, green: 0.85, blue: 0.90, alpha: 1.0) // teal
        case .file:
            return NSColor(red: 0.35, green: 0.60, blue: 1.0, alpha: 1.0) // blue
        case .color:
            return NSColor(red: 1.0, green: 0.85, blue: 0.25, alpha: 1.0) // yellow
        }
    }

    nonisolated func flash(for entry: ClipEntry) {
        // onNewEntry fires on the pasteboard watcher queue. Bounce to main
        // before touching ClipLogSettings / AppKit.
        let captured = entry
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard ClipLogSettings.shared.copyPopEnabled else { return }
                let color = Self.color(for: captured.contentType)
                let reduceMotion = AccessibilityEnvironment.shared.shouldReduceMotion
                Self.shared.show(color: color, reduceMotion: reduceMotion, entryType: captured.contentType.rawValue)
            }
        }
    }

    /// Main-thread only. Lazily builds the panel so init stays thread-safe.
    @MainActor
    private func ensurePanel() -> (NSPanel, PopView) {
        if let panel, let popView {
            return (panel, popView)
        }
        let size: CGFloat = 140
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = false
        newPanel.level = .floating
        newPanel.ignoresMouseEvents = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        newPanel.animationBehavior = .none

        let newPopView = PopView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        newPanel.contentView = newPopView
        self.panel = newPanel
        self.popView = newPopView
        return (newPanel, newPopView)
    }

    @MainActor
    private func show(color: NSColor, reduceMotion: Bool, entryType: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let (panel, popView) = ensurePanel()
        generation &+= 1
        hideWorkItem?.cancel()
        hideWorkItem = nil

        let cursor = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(cursor) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = cursor.x - frame.width / 2
        frame.origin.y = cursor.y - frame.height / 2
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrame(frame, display: true)

        popView.burst(color: color, reduceMotion: reduceMotion)
        panel.orderFrontRegardless()

        DiagnosticsLogbook.shared.record(
            "copy_color_pop",
            category: "feedback",
            details: ["entryType": entryType]
        )

        let current = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.panel?.orderOut(nil)
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.35 : 0.65), execute: workItem)
    }
}

// MARK: - PopView

private final class PopView: NSView {
    private var burstID = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override var isOpaque: Bool { false }

    func burst(color: NSColor, reduceMotion: Bool) {
        burstID &+= 1
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard let layer else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let cgColor = color.cgColor
        let easeOut = CAMediaTimingFunction(name: .easeOut)

        // Expanding ring.
        let ringRadius: CGFloat = reduceMotion ? 16 : 44
        let ring = CAShapeLayer()
        ring.path = CGPath(
            ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20),
            transform: nil
        )
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = cgColor
        ring.lineWidth = 3
        ring.opacity = 1
        layer.addSublayer(ring)

        let ringScale = ringRadius / 10.0
        let ringGrow = CABasicAnimation(keyPath: "transform.scale")
        ringGrow.fromValue = 1.0
        ringGrow.toValue = ringScale
        ringGrow.duration = reduceMotion ? 0.22 : 0.45
        ringGrow.timingFunction = easeOut
        ringGrow.isRemovedOnCompletion = false
        ringGrow.fillMode = .forwards
        // Scale about the centre: anchor the layer then offset position.
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.position = center
        ring.add(ringGrow, forKey: "cmd.pop.ring")

        let ringFade = CABasicAnimation(keyPath: "opacity")
        ringFade.fromValue = 1.0
        ringFade.toValue = 0.0
        ringFade.duration = reduceMotion ? 0.22 : 0.45
        ringFade.timingFunction = easeOut
        ringFade.isRemovedOnCompletion = false
        ringFade.fillMode = .forwards
        ring.add(ringFade, forKey: "cmd.pop.ringFade")

        // Centre dot.
        let dotSize: CGFloat = 12
        let dot = CALayer()
        dot.backgroundColor = cgColor
        dot.cornerRadius = dotSize / 2
        dot.frame = CGRect(x: center.x - dotSize / 2, y: center.y - dotSize / 2, width: dotSize, height: dotSize)
        dot.shadowColor = cgColor
        dot.shadowOpacity = 0.8
        dot.shadowRadius = 8
        dot.shadowOffset = .zero
        layer.addSublayer(dot)

        let dotFade = CABasicAnimation(keyPath: "opacity")
        dotFade.fromValue = 1.0
        dotFade.toValue = 0.0
        dotFade.duration = reduceMotion ? 0.22 : 0.55
        dotFade.timingFunction = easeOut
        dotFade.isRemovedOnCompletion = false
        dotFade.fillMode = .forwards
        dot.add(dotFade, forKey: "cmd.pop.dotFade")

        guard !reduceMotion else { return }

        // Confetti burst — 12 particles flying outward.
        let count = 12
        for i in 0..<count {
            let angle = (CGFloat(i) / CGFloat(count)) * 2 * .pi + CGFloat.random(in: -0.2...0.2)
            let distance = CGFloat.random(in: 26...56)
            let target = CGPoint(
                x: center.x + cos(angle) * distance,
                y: center.y + sin(angle) * distance
            )
            let size = CGFloat.random(in: 4...7)
            let p = CALayer()
            p.backgroundColor = cgColor
            // Mix circles and little squares for a confetti feel.
            p.cornerRadius = (i % 3 == 0) ? 1 : size / 2
            p.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            p.opacity = 1
            layer.addSublayer(p)

            let move = CABasicAnimation(keyPath: "position")
            move.fromValue = NSValue(point: center)
            move.toValue = NSValue(point: target)
            move.duration = Double.random(in: 0.42...0.60)
            move.timingFunction = easeOut
            move.isRemovedOnCompletion = false
            move.fillMode = .forwards
            p.add(move, forKey: "cmd.pop.move")

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.0
            fade.duration = Double.random(in: 0.42...0.60)
            fade.timingFunction = easeOut
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            p.add(fade, forKey: "cmd.pop.fade")

            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = 1.0
            shrink.toValue = 0.4
            shrink.duration = 0.5
            shrink.isRemovedOnCompletion = false
            shrink.fillMode = .forwards
            p.add(shrink, forKey: "cmd.pop.shrink")
        }
    }
}
