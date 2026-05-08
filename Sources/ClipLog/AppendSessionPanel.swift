import AppKit
import ClipLogCore

final class AppendSessionPanel {
    static let shared = AppendSessionPanel()

    private let panel: NSPanel
    private let container = NSVisualEffectView()
    private let statusDot = NSView()
    private let titleLabel = NSTextField(labelWithString: "Gathering")
    private let countLabel = NSTextField(labelWithString: "0 clips")
    private let previewView = TeleprompterTextView()
    private var observer: NSObjectProtocol?
    private var followTimer: Timer?
    private var latestSnapshot = AppendSessionSnapshot(
        isActive: false,
        itemCount: 0,
        characterCount: 0,
        preview: "",
        textCount: 0,
        imageCount: 0,
        imageByteCount: 0,
        expiresAt: nil
    )
    private var lastItemCount = 0
    private var sessionCursor: NSPoint?
    private var lastHapticAt = Date.distantPast
    private var latestAnchorFrame: NSRect?
    private var visibilityGeneration = 0
    private var lastRepositionFrame: NSRect?

    private init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 410, height: 62),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none

        buildView()
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .cmdAppendSessionChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let snapshot = notification.object as? AppendSessionSnapshot else { return }
            self?.apply(snapshot)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionFromNotification),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(repositionFromNotification),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func buildView() {
        container.translatesAutoresizingMaskIntoConstraints = false
        container.material = .hudWindow
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3.5
        statusDot.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.72).cgColor
        statusDot.layer?.shadowColor = NSColor.white.cgColor
        statusDot.layer?.shadowOpacity = 0.22
        statusDot.layer?.shadowRadius = 5
        statusDot.layer?.shadowOffset = .zero

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = NSColor.white.withAlphaComponent(0.88)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = NSColor.white.withAlphaComponent(0.52)
        countLabel.alignment = .right
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        previewView.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(statusDot)
        content.addSubview(titleLabel)
        content.addSubview(countLabel)
        content.addSubview(previewView)
        container.addSubview(content)
        panel.contentView = container

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            statusDot.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            statusDot.topAnchor.constraint(equalTo: content.topAnchor, constant: 15),
            statusDot.widthAnchor.constraint(equalToConstant: 7),
            statusDot.heightAnchor.constraint(equalToConstant: 7),

            titleLabel.leadingAnchor.constraint(equalTo: statusDot.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: statusDot.centerYAnchor),

            countLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),

            previewView.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewView.trailingAnchor.constraint(equalTo: countLabel.trailingAnchor),
            previewView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            previewView.heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    private func apply(_ snapshot: AppendSessionSnapshot) {
        let wasActive = latestSnapshot.isActive
        let previousItemCount = lastItemCount
        latestSnapshot = snapshot
        lastItemCount = snapshot.itemCount

        guard snapshot.isActive else {
            hide()
            return
        }

        if !wasActive {
            sessionCursor = NSEvent.mouseLocation
        }

        titleLabel.stringValue = "Gathering"
        countLabel.stringValue = countText(for: snapshot)
        previewView.setSegments(previewSegments(for: snapshot))
        reposition(animated: panel.isVisible)
        show()
        if snapshot.itemCount > previousItemCount {
            pulseCapture()
        }
        startFollowingScreen()
    }

    private func countText(for snapshot: AppendSessionSnapshot) -> String {
        var parts: [String] = []
        let itemWord = snapshot.itemCount == 1 ? "item" : "items"
        parts.append("\(snapshot.itemCount) \(itemWord)")
        if snapshot.imageCount > 0, snapshot.textCount > 0 {
            parts.append("\(snapshot.textCount)t \(snapshot.imageCount)i")
        } else if snapshot.imageCount > 0 {
            let imageWord = snapshot.imageCount == 1 ? "image" : "images"
            parts.append("\(snapshot.imageCount) \(imageWord)")
        } else if snapshot.characterCount > 0 {
            parts.append("\(snapshot.characterCount) chars")
        }
        if let expiresAt = snapshot.expiresAt {
            let remaining = max(0, Int(ceil(expiresAt.timeIntervalSinceNow)))
            if remaining <= 30 {
                parts.append("\(remaining)s")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func previewSegments(for snapshot: AppendSessionSnapshot) -> [String] {
        let segments = snapshot.preview
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return segments.isEmpty ? ["Copy text or images"] : segments
    }

    private func show() {
        visibilityGeneration &+= 1
        panel.contentView?.layer?.removeAllAnimations()
        panel.contentView?.layer?.transform = CATransform3DIdentity

        if panel.isVisible {
            panel.alphaValue = 1
            return
        }

        DiagnosticsLogbook.shared.record("append_indicator_shown", category: "append")
        panel.alphaValue = 0
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.transform = CATransform3DMakeScale(0.94, 0.94, 1)
        panel.orderFrontRegardless()
        animateContentScale(from: 0.94, to: 1.0, duration: 0.22)

        var frame = panel.frame
        frame.origin.y -= 5
        panel.setFrame(frame, display: true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            var target = panel.frame
            target.origin.y += 5
            panel.animator().setFrame(target, display: true)
        }
    }

    private func hide() {
        stopFollowingScreen()
        guard panel.isVisible else { return }
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        previewView.stop()
        DiagnosticsLogbook.shared.record("append_indicator_hidden", category: "append")
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.removeAllAnimations()
        animateContentScale(from: 1.0, to: 0.94, duration: 0.16)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            var frame = panel.frame
            frame.origin.y -= 5
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            guard self.visibilityGeneration == generation,
                  !self.latestSnapshot.isActive
            else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.panel.contentView?.layer?.transform = CATransform3DIdentity
            self.sessionCursor = nil
            self.lastRepositionFrame = nil
        }
    }

    @objc private func repositionFromNotification() {
        reposition(animated: true)
    }

    @objc private func reposition() {
        reposition(animated: true)
    }

    private func animateContentScale(from: CGFloat, to: CGFloat, duration: CFTimeInterval) {
        guard let layer = panel.contentView?.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = from
        animation.toValue = to
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.18, 0.86, 0.22, 1.0)
        layer.transform = CATransform3DMakeScale(to, to, 1)
        layer.add(animation, forKey: "cmd.append.scale")
    }

    private func pulseCapture() {
        guard panel.isVisible else { return }
        let now = Date()
        if now.timeIntervalSince(lastHapticAt) > 0.16 {
            lastHapticAt = now
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }

        let dotPulse = CABasicAnimation(keyPath: "opacity")
        dotPulse.fromValue = 1.0
        dotPulse.toValue = 0.38
        dotPulse.duration = 0.12
        dotPulse.autoreverses = true
        statusDot.layer?.add(dotPulse, forKey: "cmd.gather.dotPulse")
    }

    private func reposition(animated: Bool) {
        guard latestSnapshot.isActive else { return }
        let screen = currentScreen()
        let visible = screen.visibleFrame
        let cursor = sessionCursor ?? NSEvent.mouseLocation
        latestAnchorFrame = AppendTextInputAnchorLocator.frameNearCursor(cursor)

        let frame = panelFrame(cursor: cursor, anchor: latestAnchorFrame, visibleFrame: visible)
        if let lastRepositionFrame,
           abs(lastRepositionFrame.origin.x - frame.origin.x) < 1,
           abs(lastRepositionFrame.origin.y - frame.origin.y) < 1,
           abs(lastRepositionFrame.width - frame.width) < 1,
           abs(lastRepositionFrame.height - frame.height) < 1 {
            return
        }
        lastRepositionFrame = frame

        guard animated, panel.isVisible else {
            panel.setFrame(frame.integral, display: true)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame.integral, display: true)
        }
    }

    private func panelFrame(cursor: NSPoint, anchor: NSRect?, visibleFrame visible: NSRect) -> NSRect {
        let height: CGFloat = 62
        let horizontalMargin: CGFloat = 24
        let maxWidth = min(460, visible.width - horizontalMargin * 2)
        let width = max(340, min(maxWidth, anchor.map { $0.width * 0.72 } ?? 410))
        let preferredRightX = cursor.x + 14
        let preferredLeftX = cursor.x - width - 14
        let x = preferredRightX + width <= visible.maxX - horizontalMargin
            ? preferredRightX
            : clamp(preferredLeftX, min: visible.minX + horizontalMargin, max: visible.maxX - width - horizontalMargin)

        if let anchor {
            let aboveY = anchor.maxY + 10
            let belowY = anchor.minY - height - 10
            let y = aboveY + height <= visible.maxY - 8 ? aboveY : max(visible.minY + 18, belowY)
            return NSRect(x: x, y: y, width: width, height: height)
        }

        let aboveY = cursor.y + 12
        let belowY = cursor.y - height - 12
        let y = aboveY + height <= visible.maxY - 8 ? aboveY : max(visible.minY + 18, belowY)
        return NSRect(
            x: x,
            y: y,
            width: width,
            height: height
        )
    }

    private func clamp(_ value: CGFloat, min minValue: CGFloat, max maxValue: CGFloat) -> CGFloat {
        Swift.max(minValue, Swift.min(value, maxValue))
    }

    private func currentScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private func startFollowingScreen() {
        guard followTimer == nil else { return }
        followTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.countLabel.stringValue = self.countText(for: self.latestSnapshot)
            self.reposition()
        }
        RunLoop.main.add(followTimer!, forMode: .common)
    }

    private func stopFollowingScreen() {
        followTimer?.invalidate()
        followTimer = nil
    }
}

private final class TeleprompterTextView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var animationToken = UUID()
    private var scheduledWorkItem: DispatchWorkItem?
    private var segments: [String] = []
    private var currentIndex = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor.white.withAlphaComponent(0.72)
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
    }

    func setSegments(_ newSegments: [String]) {
        let normalized = newSegments.isEmpty ? ["Copy text to start collecting"] : newSegments
        guard segments != normalized else { return }
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        segments = normalized
        currentIndex = max(0, normalized.count - 1)
        animationToken = UUID()
        label.layer?.removeAllAnimations()
        showCurrentSegment()
    }

    func stop() {
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        animationToken = UUID()
        label.layer?.removeAllAnimations()
    }

    override func layout() {
        super.layout()
        layoutLabel()
    }

    private func layoutLabel() {
        let size = label.intrinsicContentSize
        label.frame = NSRect(
            x: 0,
            y: max(0, (bounds.height - size.height) / 2),
            width: max(size.width, bounds.width),
            height: size.height
        )
    }

    private func showCurrentSegment() {
        guard !segments.isEmpty else { return }
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        label.stringValue = segments[currentIndex]
        label.alphaValue = 0
        layoutLabel()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            self?.startTeleprompterIfNeeded()
        }
    }

    private func startTeleprompterIfNeeded() {
        guard bounds.width > 0 else { return }
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil

        let textWidth = label.intrinsicContentSize.width
        guard textWidth > bounds.width + 18 else {
            label.layer?.removeAllAnimations()
            label.frame.origin.x = 0
            scheduleNextSegment(after: 1.25)
            return
        }

        let token = animationToken
        label.frame.origin.x = 0

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.animationToken == token else { return }
            self.scheduledWorkItem = nil
            let overflow = textWidth - self.bounds.width
            NSAnimationContext.runAnimationGroup { context in
                context.duration = min(10.0, max(3.2, overflow / 36.0))
                context.timingFunction = CAMediaTimingFunction(name: .linear)
                self.label.animator().frame.origin.x = -overflow
            } completionHandler: { [weak self] in
                guard let self, self.animationToken == token else { return }
                self.scheduleNextSegment(after: 0.85)
            }
        }
        scheduledWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: workItem)
    }

    private func scheduleNextSegment(after delay: TimeInterval) {
        guard segments.count > 1 else { return }
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        let token = animationToken
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.animationToken == token else { return }
            self.scheduledWorkItem = nil
            self.currentIndex = (self.currentIndex + 1) % self.segments.count
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.label.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.animationToken == token else { return }
                self.showCurrentSegment()
            }
        }
        scheduledWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

private enum AppendTextInputAnchorLocator {
    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    private static let textSubroles: Set<String> = [
        kAXSearchFieldSubrole as String,
    ]

    static func frameNearCursor(_ cursor: NSPoint) -> NSRect? {
        guard AXIsProcessTrusted(),
              let focused = elementAttribute(
                  AXUIElementCreateSystemWide(),
                  kAXFocusedUIElementAttribute as CFString
              )
        else { return nil }

        return textInputFrame(startingAt: focused, cursor: cursor, remainingDepth: 4)
    }

    private static func textInputFrame(
        startingAt element: AXUIElement,
        cursor: NSPoint,
        remainingDepth: Int
    ) -> NSRect? {
        if isTextInput(element),
           let frame = normalizedFrame(for: element, cursor: cursor) {
            return frame
        }

        guard remainingDepth > 0,
              let parent = elementAttribute(element, kAXParentAttribute as CFString)
        else { return nil }

        return textInputFrame(startingAt: parent, cursor: cursor, remainingDepth: remainingDepth - 1)
    }

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        if let role = stringAttribute(element, kAXRoleAttribute as CFString),
           textRoles.contains(role) {
            return true
        }
        if let subrole = stringAttribute(element, kAXSubroleAttribute as CFString),
           textSubroles.contains(subrole) {
            return true
        }
        return false
    }

    private static func normalizedFrame(for element: AXUIElement, cursor: NSPoint) -> NSRect? {
        guard let axRect = frameAttribute(element),
              axRect.width >= 48,
              axRect.height >= 14
        else { return nil }

        return bestAppKitFrame(for: axRect, cursor: cursor)
    }

    private static func bestAppKitFrame(for axRect: CGRect, cursor: NSPoint) -> NSRect? {
        let raw = NSRect(x: axRect.minX, y: axRect.minY, width: axRect.width, height: axRect.height)
        let desktopFrame = NSScreen.screens.reduce(NSRect.null) { partial, screen in
            partial.union(screen.frame)
        }

        var candidates: [(rect: NSRect, bias: CGFloat)] = [(raw, 36)]
        candidates.append(contentsOf: NSScreen.screens.flatMap { screen -> [(NSRect, CGFloat)] in
            [
                (
                    NSRect(
                        x: raw.minX,
                        y: screen.frame.maxY - raw.minY - raw.height,
                        width: raw.width,
                        height: raw.height
                    ),
                    0
                ),
                (
                    NSRect(
                        x: raw.minX,
                        y: screen.frame.minY + raw.minY,
                        width: raw.width,
                        height: raw.height
                    ),
                    24
                ),
            ]
        })

        if !desktopFrame.isNull {
            candidates.append(
                (
                    NSRect(
                        x: raw.minX,
                        y: desktopFrame.maxY - raw.minY - raw.height,
                        width: raw.width,
                        height: raw.height
                    ),
                    6
                )
            )
        }

        return candidates
            .filter { candidate in
                candidate.rect.width >= 48 &&
                    candidate.rect.height >= 14 &&
                    candidate.rect.width <= 2_400 &&
                    candidate.rect.height <= 420 &&
                    NSScreen.screens.contains { $0.frame.intersects(candidate.rect) }
            }
            .min { left, right in
                score(candidate: left, cursor: cursor) < score(candidate: right, cursor: cursor)
            }?
            .rect
    }

    private static func score(candidate: (rect: NSRect, bias: CGFloat), cursor: NSPoint) -> CGFloat {
        let rect = candidate.rect
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let distance = hypot(center.x - cursor.x, center.y - cursor.y)
        let visiblePenalty: CGFloat = NSScreen.screens.contains { screen in
            screen.visibleFrame.intersects(rect)
        } ? 0 : 1_000
        let sizePenalty = rect.height > 160 ? rect.height : 0
        return candidate.bias + visiblePenalty + distance * 0.06 + sizePenalty * 0.35
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let raw = value,
              CFGetTypeID(raw) == AXUIElementGetTypeID()
        else { return nil }
        return (raw as! AXUIElement)
    }

    private static func frameAttribute(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue
        else { return nil }

        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &point),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: point, size: size)
    }
}
