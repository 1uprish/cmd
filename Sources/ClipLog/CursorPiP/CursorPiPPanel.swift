import AppKit

final class CursorPiPPanel: NSPanel {
    init(frame: NSRect) {
        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        title = "CursorPiP"
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        minSize = NSSize(width: 100, height: 56)
        becomesKeyOnlyIfNeeded = true
        contentAspectRatio = NSSize(width: 16, height: 9)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
