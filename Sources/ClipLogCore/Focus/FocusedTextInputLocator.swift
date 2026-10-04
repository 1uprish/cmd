import AppKit
import ApplicationServices

// MARK: - FocusedTextInputLocator
//
// Finds the accessibility frame of the text input the user is currently
// editing so the HUD can size and position itself to that control.
//
// Coordinate spaces:
//   AX reports geometry in the global display space — origin at the top-left
//   of the main display, y increasing downward.
//   AppKit uses the bottom-left of the main display with y increasing upward.
//
// The main display defines both origins, so a single flip about its height is
// exact for every screen and scale factor. We convert deterministically rather
// than guessing from cursor proximity; the cursor-scored heuristic is retained
// only as a fallback for apps that report an unusual coordinate space.

public enum FocusedTextInputLocator {

    private static let textRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    private static let textSubroles: Set<String> = [
        kAXSearchFieldSubrole as String,
    ]

    private static let minWidth: CGFloat = 48
    private static let minHeight: CGFloat = 14
    private static let maxWidth: CGFloat = 2_400
    private static let maxHeight: CGFloat = 420
    private static let maxParentDepth = 4

    public static func frameNearCursor(_ cursor: NSPoint) -> NSRect? {
        guard AXIsProcessTrusted(),
              let focused = elementAttribute(
                  AXUIElementCreateSystemWide(),
                  kAXFocusedUIElementAttribute as CFString
              )
        else { return nil }

        return textInputFrame(startingAt: focused, cursor: cursor, remainingDepth: maxParentDepth)
    }

    // MARK: - Traversal

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

    // MARK: - Geometry

    private static func normalizedFrame(for element: AXUIElement, cursor: NSPoint) -> NSRect? {
        guard let axRect = frameAttribute(element),
              axRect.width >= minWidth,
              axRect.height >= minHeight
        else { return nil }

        return bestAppKitFrame(for: axRect, cursor: cursor)
    }

    static func bestAppKitFrame(for axRect: CGRect, cursor: NSPoint) -> NSRect? {
        if let rect = deterministicAppKitRect(for: axRect), isPlausible(rect) {
            return rect
        }
        return heuristicAppKitRect(for: axRect, cursor: cursor)
    }

    /// Exact conversion from AX global coordinates to AppKit global coordinates.
    ///
    /// `primaryDisplayHeight` is the AppKit y of the main display's top edge,
    /// which equals its height because the main display's frame origin is
    /// (0, 0). Exposed for testing.
    public static func appKitRect(fromAX axRect: CGRect, primaryDisplayHeight: CGFloat) -> NSRect {
        NSRect(
            x: axRect.minX,
            y: primaryDisplayHeight - axRect.maxY,
            width: axRect.width,
            height: axRect.height
        )
    }

    private static func deterministicAppKitRect(for axRect: CGRect) -> NSRect? {
        guard let primary = primaryScreen else { return nil }
        return appKitRect(fromAX: axRect, primaryDisplayHeight: primary.frame.maxY)
    }

    private static var primaryScreen: NSScreen? {
        NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.screens.first
    }

    private static func isPlausible(_ rect: NSRect) -> Bool {
        guard rect.width >= minWidth,
              rect.height >= minHeight,
              rect.width <= maxWidth,
              rect.height <= maxHeight
        else { return false }
        return NSScreen.screens.contains { $0.frame.intersects(rect) }
    }

    // MARK: - Fallback heuristic
    //
    // Used only when the deterministic conversion lands off every display.

    private static func heuristicAppKitRect(for axRect: CGRect, cursor: NSPoint) -> NSRect? {
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
                candidate.rect.width >= minWidth &&
                    candidate.rect.height >= minHeight &&
                    candidate.rect.width <= maxWidth &&
                    candidate.rect.height <= maxHeight &&
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

    // MARK: - AX attribute helpers

    private static func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func frameAttribute(_ element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(element, kAXPositionAttribute as CFString),
              let size = sizeAttribute(element, kAXSizeAttribute as CFString)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func pointAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }
}
