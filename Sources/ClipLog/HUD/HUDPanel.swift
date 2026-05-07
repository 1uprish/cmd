import AppKit
import ApplicationServices
import ClipLogCore
import UniformTypeIdentifiers

// MARK: - HUDPanel
//
// Notification-style clipboard register shown by holding Cmd-V.
// The event-tap state is session-scoped; this view layer keeps layout
// deterministic while allowing cursor-origin show/hide animation.

public final class HUDPanel {

    public static let shared = HUDPanel()

    public weak var slotManager: SlotManager?
    public var onDismiss: ((UInt64) -> Void)?

    private enum Layout {
        static let fallbackWidth: CGFloat = 520
        static let minWidth: CGFloat = 420
        static let maxWidth: CGFloat = 1_800
        static let screenInset: CGFloat = 18
        static let textFieldGap: CGFloat = 10
        static let padding: CGFloat = 14
        static let headerHeight: CGFloat = 0
        static let rowHeight: CGFloat = 92
        static let rowGap: CGFloat = 10
        static let scrollbarGutter: CGFloat = 18
        static let visibleRows = 6
        static let maxEntries = 20
        static let cornerRadius: CGFloat = 24
        static let animationDuration: TimeInterval = 0.22
        static let rowStagger: TimeInterval = 0.018
    }

    private enum TransitionStyle: String {
        case magnetic
        case genie
        case cascade
        case calm

        init(setting: String) {
            self = TransitionStyle(rawValue: setting) ?? .magnetic
        }

        var inDuration: TimeInterval {
            switch self {
            case .magnetic: return 0.24
            case .genie: return 0.27
            case .cascade: return 0.23
            case .calm: return 0.17
            }
        }

        var outDuration: TimeInterval {
            switch self {
            case .magnetic: return 0.19
            case .genie: return 0.23
            case .cascade: return 0.18
            case .calm: return 0.14
            }
        }

        var initialRootScale: CGFloat {
            switch self {
            case .magnetic: return 0.34
            case .genie: return 0.20
            case .cascade: return 0.62
            case .calm: return 0.94
            }
        }

        var exitRootScale: CGFloat {
            switch self {
            case .magnetic: return 0.18
            case .genie: return 0.12
            case .cascade: return 0.32
            case .calm: return 0.94
            }
        }

        var rowEntryScale: CGFloat {
            switch self {
            case .magnetic: return 0.72
            case .genie: return 0.62
            case .cascade: return 0.80
            case .calm: return 0.96
            }
        }

        var rowExitScale: CGFloat {
            switch self {
            case .magnetic: return 0.68
            case .genie: return 0.58
            case .cascade: return 0.58
            case .calm: return 0.94
            }
        }

        var rowTranslationMultiplier: CGFloat {
            switch self {
            case .magnetic: return 0.36
            case .genie: return 0.48
            case .cascade: return 0.28
            case .calm: return 0.08
            }
        }

        var rowStagger: TimeInterval {
            switch self {
            case .magnetic: return 0.014
            case .genie: return 0.018
            case .cascade: return 0.030
            case .calm: return 0.006
            }
        }

        var inTiming: CAMediaTimingFunction {
            switch self {
            case .magnetic: return CAMediaTimingFunction(controlPoints: 0.13, 0.90, 0.20, 1.00)
            case .genie: return CAMediaTimingFunction(controlPoints: 0.10, 0.92, 0.18, 1.00)
            case .cascade: return CAMediaTimingFunction(controlPoints: 0.18, 0.84, 0.24, 1.00)
            case .calm: return CAMediaTimingFunction(controlPoints: 0.25, 0.80, 0.25, 1.00)
            }
        }

        var outTiming: CAMediaTimingFunction {
            switch self {
            case .magnetic: return CAMediaTimingFunction(controlPoints: 0.34, 0.00, 0.86, 0.18)
            case .genie: return CAMediaTimingFunction(controlPoints: 0.38, 0.00, 1.00, 0.08)
            case .cascade: return CAMediaTimingFunction(controlPoints: 0.40, 0.00, 0.92, 0.22)
            case .calm: return CAMediaTimingFunction(controlPoints: 0.32, 0.00, 0.68, 1.00)
            }
        }
    }

    private let panel: NSPanel
    private let rootView = HUDRootView()
    private let headerScrim = HUDHeaderScrimView()
    private let titleLabel = NSTextField(labelWithString: "cmd")
    private let subtitleLabel = NSTextField(labelWithString: "Recent clipboard")
    private let filterBadge = NSTextField(labelWithString: "")
    private let selectionBadge = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let rowContainer = HUDRowsDocumentView()
    private let topScrollFade = HUDScrollFadeView(isTop: true)
    private let bottomScrollFade = HUDScrollFadeView(isTop: false)

    private var rowViews: [HUDRowView] = []
    private var currentSlots: [ClipEntry] = []
    private var filterText = ""
    private var selectedDisplayIndex: Int?
    private var multiSelectedOriginalIndices: Set<Int> = []
    private var multiSelectionAnchorDisplayIndex: Int?
    private var lastCursorLocation = NSPoint.zero
    private var focusedTextFrame: NSRect?
    private var lastAnimationOrigin = NSPoint.zero
    private var currentPanelWidth = Layout.fallbackWidth
    private var currentHUDScale: CGFloat = 1.0
    private var currentTransitionStyle = TransitionStyle.magnetic
    private var animationGeneration: UInt64 = 0
    private var dragRestoreSnapshot: DragRestoreSnapshot?

    private let visibilityLock = NSLock()
    private var _isVisible = false
    private var activeSessionID: UInt64?

    public var isVisible: Bool {
        visibilityLock.withLock { _isVisible }
    }

    private var clickMonitor: Any?
    private var sleepObserver: Any?
    private var spaceObserver: Any?
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private struct DragRestoreSnapshot {
        let slots: [ClipEntry]
        let filterText: String
        let selectedDisplayIndex: Int?
        let selectedOriginalIndices: Set<Int>
        let anchorDisplayIndex: Int?
    }

    private init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = rootView

        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.clear.cgColor
        rootView.layer?.cornerRadius = 0
        rootView.layer?.borderWidth = 0
        rootView.layer?.borderColor = NSColor.clear.cgColor
        rootView.layer?.masksToBounds = false

        headerScrim.wantsLayer = true
        headerScrim.layer?.backgroundColor = NSColor(calibratedWhite: 0.02, alpha: 0.34).cgColor
        headerScrim.layer?.cornerRadius = 18
        headerScrim.layer?.masksToBounds = false
        headerScrim.layer?.shadowColor = NSColor.black.withAlphaComponent(0.38).cgColor
        headerScrim.layer?.shadowOpacity = 1
        headerScrim.layer?.shadowRadius = 18
        headerScrim.layer?.shadowOffset = CGSize(width: 0, height: -4)

        titleLabel.font = .systemFont(ofSize: 19, weight: .heavy)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.wantsLayer = true
        titleLabel.shadow = NSShadow()
        titleLabel.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.72)
        titleLabel.shadow?.shadowBlurRadius = 5
        titleLabel.shadow?.shadowOffset = CGSize(width: 0, height: -1)

        subtitleLabel.font = .systemFont(ofSize: 13, weight: .bold)
        subtitleLabel.textColor = NSColor.white.withAlphaComponent(0.68)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.shadow = NSShadow()
        subtitleLabel.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.62)
        subtitleLabel.shadow?.shadowBlurRadius = 4
        subtitleLabel.shadow?.shadowOffset = CGSize(width: 0, height: -1)

        filterBadge.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        filterBadge.textColor = .white
        filterBadge.alignment = .center
        filterBadge.drawsBackground = true
        filterBadge.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85)
        filterBadge.wantsLayer = true
        filterBadge.layer?.cornerRadius = 8
        filterBadge.layer?.masksToBounds = true
        filterBadge.isHidden = true

        selectionBadge.font = .systemFont(ofSize: 11, weight: .bold)
        selectionBadge.textColor = .white
        selectionBadge.alignment = .center
        selectionBadge.drawsBackground = true
        selectionBadge.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.88)
        selectionBadge.wantsLayer = true
        selectionBadge.layer?.cornerRadius = 9
        selectionBadge.layer?.masksToBounds = true
        selectionBadge.isHidden = true

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = rowContainer

        headerScrim.isHidden = true
        titleLabel.isHidden = true
        subtitleLabel.isHidden = true
        filterBadge.isHidden = true
        rootView.addSubview(scrollView)
        rootView.addSubview(selectionBadge)
        topScrollFade.isHidden = true
        bottomScrollFade.isHidden = true
    }

    // MARK: - Show

    public func show(sessionID: UInt64, slots: [ClipEntry]) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.show(sessionID: sessionID, slots: slots) }
            return
        }

        animationGeneration &+= 1
        removeDismissGuards()
        resetRootLayer()

        currentSlots = Array(slots.prefix(Layout.maxEntries))
        filterText = ""
        selectedDisplayIndex = currentSlots.isEmpty ? nil : 0
        multiSelectedOriginalIndices = []
        multiSelectionAnchorDisplayIndex = selectedDisplayIndex
        filterBadge.isHidden = true
        selectionBadge.isHidden = true
        dragRestoreSnapshot = nil
        lastCursorLocation = NSEvent.mouseLocation
        focusedTextFrame = FocusedTextInputLocator.frameNearCursor(lastCursorLocation)
        currentHUDScale = CGFloat(ClipLogSettings.shared.hudSizeScale.clamped(to: 0.85...1.20))
        currentTransitionStyle = TransitionStyle(setting: ClipLogSettings.shared.hudAnimationStyle)
        currentPanelWidth = preferredPanelWidth(for: focusedTextFrame)

        setVisible(true, sessionID: sessionID)
        rebuildRows()
        layoutPanel()
        scrollToTop()

        lastAnimationOrigin = animationOrigin(for: focusedTextFrame, panelFrame: panel.frame)
        rootView.layoutSubtreeIfNeeded()
        rowContainer.layoutSubtreeIfNeeded()
        if reduceMotion {
            resetRootLayer()
        } else {
            prepareCursorOriginTransform(from: lastAnimationOrigin)
            prepareRowsForEntry(from: lastAnimationOrigin)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        animateIn()

        DispatchQueue.main.async { [weak self] in
            self?.installDismissGuards(sessionID: sessionID)
        }
    }

    // MARK: - Dismiss

    public func dismissForDrag() {
        dragRestoreSnapshot = DragRestoreSnapshot(
            slots: currentSlots,
            filterText: filterText,
            selectedDisplayIndex: selectedDisplayIndex,
            selectedOriginalIndices: selectionOriginalIndicesForDisplay(),
            anchorDisplayIndex: multiSelectionAnchorDisplayIndex
        )
        dismiss(selecting: nil, sessionID: nil, animated: false)
    }

    public func restoreAfterCancelledDrag() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.restoreAfterCancelledDrag() }
            return
        }
        guard !isVisible, let snapshot = dragRestoreSnapshot else { return }

        show(sessionID: UInt64.random(in: 1...UInt64.max), slots: snapshot.slots)
        filterText = snapshot.filterText
        selectedDisplayIndex = snapshot.selectedDisplayIndex
        multiSelectedOriginalIndices = snapshot.selectedOriginalIndices.count > 1
            ? snapshot.selectedOriginalIndices
            : []
        multiSelectionAnchorDisplayIndex = snapshot.anchorDisplayIndex
        rebuildRows()
        layoutPanel()
        updateFilterBadge()
        updateSelection()
        scrollSelectedRowToVisible()
        dragRestoreSnapshot = nil
    }

    func dismiss() {
        dismiss(selecting: nil, sessionID: nil)
    }

    public func dismiss(sessionID: UInt64) {
        dismiss(selecting: nil, sessionID: sessionID)
    }

    public func dismiss(selecting index: Int? = nil, sessionID: UInt64? = nil) {
        dismiss(selecting: index, sessionID: sessionID, animated: true)
    }

    private func dismiss(selecting index: Int?, sessionID: UInt64?, animated: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.dismiss(selecting: index, sessionID: sessionID, animated: animated)
            }
            return
        }

        guard let dismissedSessionID = beginDismiss(sessionID: sessionID) else { return }
        let selectedEntries = entriesForAction(fallbackOriginalIndex: index)

        removeDismissGuards()
        onDismiss?(dismissedSessionID)

        if !selectedEntries.isEmpty {
            slotManager?.paste(entries: selectedEntries)
        }

        if animated {
            animateOut(to: lastAnimationOrigin, selectedOriginalIndex: index)
        } else {
            panel.orderOut(nil)
            resetRootLayer()
            resetRows()
        }
    }

    private func copy(index: Int) {
        let entries = entriesForAction(fallbackOriginalIndex: index)
        guard !entries.isEmpty else { return }
        slotManager?.copy(entries: entries)
    }

    public func moveSelection(delta: Int) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.moveSelection(delta: delta) }
            return
        }

        let indices = displayedIndices()
        guard !indices.isEmpty else {
            selectedDisplayIndex = nil
            updateSelection()
            return
        }

        let current = selectedDisplayIndex ?? 0
        selectedDisplayIndex = (current + delta + indices.count) % indices.count
        multiSelectedOriginalIndices = []
        multiSelectionAnchorDisplayIndex = selectedDisplayIndex
        updateSelection()
        scrollSelectedRowToVisible()
    }

    public func confirmSelection(sessionID: UInt64) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.confirmSelection(sessionID: sessionID) }
            return
        }

        let indices = displayedIndices()
        guard let selectedDisplayIndex,
              indices.indices.contains(selectedDisplayIndex)
        else { return }

        let originalIndex = indices[selectedDisplayIndex]
        guard currentSlots.indices.contains(originalIndex) else { return }
        dismiss(selecting: originalIndex, sessionID: sessionID)
    }

    public func handleEscape(sessionID: UInt64) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.handleEscape(sessionID: sessionID) }
            return
        }

        if !filterText.isEmpty {
            filterText = ""
            refreshRowsForFilter()
        } else if !multiSelectedOriginalIndices.isEmpty {
            multiSelectedOriginalIndices = []
            updateSelection()
        } else {
            dismiss(sessionID: sessionID)
        }
    }

    // MARK: - Filter

    public func applyFilter(character: Character) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.applyFilter(character: character) }
            return
        }

        guard isVisible else { return }
        filterText.append(character)
        refreshRowsForFilter()
    }

    public func deleteFilterCharacter() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.deleteFilterCharacter() }
            return
        }

        guard !filterText.isEmpty else { return }
        filterText.removeLast()
        refreshRowsForFilter()
    }

    public func clearFilter() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.clearFilter() }
            return
        }

        filterText = ""
        refreshRowsForFilter()
    }

    // MARK: - Rows

    private func rebuildRows() {
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews.removeAll()

        let indices = displayedIndices()

        if currentSlots.isEmpty {
            let row = HUDRowView()
            row.applySizeScale(ClipLogSettings.shared.hudSizeScale)
            row.configureEmpty(title: "No clipboard history yet", message: "Copy something, then hold Cmd-V again.")
            row.applyOpacity(ClipLogSettings.shared.hudOpacity)
            rowContainer.addSubview(row)
            rowViews.append(row)
            return
        }

        if indices.isEmpty {
            let row = HUDRowView()
            row.applySizeScale(ClipLogSettings.shared.hudSizeScale)
            row.configureEmpty(title: "No matches", message: "Try a different filter.")
            row.applyOpacity(ClipLogSettings.shared.hudOpacity)
            rowContainer.addSubview(row)
            rowViews.append(row)
            return
        }

        for index in indices {
            let entry = currentSlots[index]
            let row = HUDRowView()
            row.applySizeScale(ClipLogSettings.shared.hudSizeScale)
            row.configure(entry: entry, index: index)
            row.applyOpacity(ClipLogSettings.shared.hudOpacity)
            row.onPaste = { [weak self] selectedIndex in
                self?.dismiss(selecting: selectedIndex, sessionID: nil)
            }
            row.onModifiedClick = { [weak self] selectedIndex, modifiers in
                self?.handleModifiedClick(index: selectedIndex, modifiers: modifiers)
            }
            row.onCopy = { [weak self] selectedIndex in
                self?.copy(index: selectedIndex)
            }
            row.dragEntriesProvider = { [weak self] selectedIndex in
                self?.entriesForAction(fallbackOriginalIndex: selectedIndex) ?? []
            }
            row.onDragStart = { [weak self] in
                self?.dismissForDrag()
            }
            row.onDragEnd = { [weak self] operation in
                if operation.isEmpty {
                    self?.restoreAfterCancelledDrag()
                } else {
                    self?.clearDragRestoreSnapshot()
                }
            }
            rowContainer.addSubview(row)
            rowViews.append(row)
        }
        updateSelection()
    }

    private func refreshRowsForFilter() {
        selectedDisplayIndex = displayedIndices().isEmpty ? nil : 0
        multiSelectedOriginalIndices = []
        multiSelectionAnchorDisplayIndex = selectedDisplayIndex
        rebuildRows()
        currentHUDScale = CGFloat(ClipLogSettings.shared.hudSizeScale.clamped(to: 0.85...1.20))
        currentPanelWidth = preferredPanelWidth(for: focusedTextFrame)
        layoutPanel()
        scrollToTop()
        updateFilterBadge()
    }

    private func updateFilterBadge() {
        let cleanFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        filterBadge.isHidden = true
        if cleanFilter.isEmpty {
            filterBadge.stringValue = ""
        } else {
            filterBadge.stringValue = "  \(cleanFilter) · \(displayedIndices().count)  "
        }
    }

    private func updateHintText() {
        if currentSlots.isEmpty {
            subtitleLabel.stringValue = "Recent clipboard"
        } else if filterText.isEmpty {
            subtitleLabel.stringValue = "Type to filter · ↑↓ select · Return paste · Esc close"
        } else {
            let count = displayedIndices().count
            subtitleLabel.stringValue = "\(count) match\(count == 1 ? "" : "es") · Backspace edit · Esc clear"
        }
    }

    private func displayedIndices() -> [Int] {
        let cleanFilter = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanFilter.isEmpty else {
            return Array(currentSlots.indices)
        }
        return currentSlots.indices.filter { matches(entry: currentSlots[$0], filter: cleanFilter) }
    }

    private func matches(entry: ClipEntry, filter: String) -> Bool {
        let haystack = [
            entry.previewText,
            entry.sourceAppName,
            entry.sourceWindowTitle ?? "",
            entry.contentType.rawValue
        ].joined(separator: " ").lowercased()
        return haystack.contains(filter.lowercased())
    }

    private func updateSelection() {
        let selectedOriginalIndices = selectionOriginalIndicesForDisplay()
        for row in rowViews {
            let originalIndex = row.originalIndex
            row.setSelected(originalIndex.map { selectedOriginalIndices.contains($0) } ?? false)
        }
        updateSelectionBadge(count: selectedOriginalIndices.count)
    }

    private func updateSelectionBadge(count: Int) {
        guard count > 1 else {
            selectionBadge.isHidden = true
            selectionBadge.stringValue = ""
            return
        }
        selectionBadge.stringValue = "  \(count) selected  "
        selectionBadge.isHidden = false
        layoutSelectionBadge()
    }

    private func layoutSelectionBadge() {
        guard !selectionBadge.isHidden else { return }
        let width = max(78, selectionBadge.intrinsicContentSize.width + 12)
        let height: CGFloat = 22
        selectionBadge.frame = NSRect(
            x: max(scaled(Layout.padding), rootView.bounds.width - scaled(Layout.padding) - width),
            y: max(scaled(Layout.padding), rootView.bounds.height - scaled(Layout.padding) - height),
            width: width,
            height: height
        )
    }

    private func clearDragRestoreSnapshot() {
        dragRestoreSnapshot = nil
    }

    private func handleModifiedClick(index: Int, modifiers: NSEvent.ModifierFlags) {
        let visibleIndices = displayedIndices()
        guard let displayIndex = visibleIndices.firstIndex(of: index) else { return }

        if modifiers.contains(.shift) {
            let anchor = multiSelectionAnchorDisplayIndex ?? selectedDisplayIndex ?? displayIndex
            let lower = min(anchor, displayIndex)
            let upper = max(anchor, displayIndex)
            multiSelectedOriginalIndices = Set(visibleIndices[lower...upper])
            selectedDisplayIndex = displayIndex
            updateSelection()
            return
        }

        if modifiers.contains(.command) {
            if multiSelectedOriginalIndices.isEmpty {
                multiSelectedOriginalIndices = selectionOriginalIndicesForDisplay()
            }
            if multiSelectedOriginalIndices.contains(index) {
                multiSelectedOriginalIndices.remove(index)
            } else {
                multiSelectedOriginalIndices.insert(index)
            }
            selectedDisplayIndex = displayIndex
            multiSelectionAnchorDisplayIndex = displayIndex
            updateSelection()
            return
        }

        multiSelectedOriginalIndices = []
        selectedDisplayIndex = displayIndex
        multiSelectionAnchorDisplayIndex = displayIndex
        updateSelection()
    }

    private func selectionOriginalIndicesForDisplay() -> Set<Int> {
        if !multiSelectedOriginalIndices.isEmpty {
            return multiSelectedOriginalIndices
        }

        let indices = displayedIndices()
        guard let selectedDisplayIndex,
              indices.indices.contains(selectedDisplayIndex)
        else { return [] }
        return [indices[selectedDisplayIndex]]
    }

    private func entriesForAction(fallbackOriginalIndex: Int?) -> [ClipEntry] {
        let visibleIndices = displayedIndices()
        let selectedOriginalIndices = !multiSelectedOriginalIndices.isEmpty
            ? multiSelectedOriginalIndices
            : Set(fallbackOriginalIndex.map { [$0] } ?? [])

        return visibleIndices
            .filter { selectedOriginalIndices.contains($0) }
            .compactMap { currentSlots.indices.contains($0) ? currentSlots[$0] : nil }
    }

    private func scrollSelectedRowToVisible() {
        guard let selectedDisplayIndex,
              rowViews.indices.contains(selectedDisplayIndex)
        else { return }
        rowContainer.scrollToVisible(rowViews[selectedDisplayIndex].frame.insetBy(dx: 0, dy: -Layout.rowGap))
    }

    // MARK: - Layout

    private func layoutPanel() {
        let rowCount = max(rowViews.count, 1)
        let visibleCount = min(rowCount, Layout.visibleRows)
        let documentHeight = rowsHeight(count: rowCount)
        let visibleRowsHeight = rowsHeight(count: visibleCount)
        let padding = scaled(Layout.padding)
        let needsScroller = rowCount > visibleCount
        let gutter = needsScroller ? scaled(Layout.scrollbarGutter) : 0
        let height = padding + scaled(Layout.headerHeight) + visibleRowsHeight + padding
        let width = currentPanelWidth
        let size = NSSize(width: width, height: height)

        panel.setContentSize(size)
        rootView.frame = NSRect(origin: .zero, size: size)

        let contentX = padding
        let cardWidth = max(120, width - padding * 2 - gutter)
        let scrollWidth = cardWidth + gutter
        scrollView.hasVerticalScroller = needsScroller
        scrollView.frame = NSRect(
            x: contentX,
            y: padding,
            width: scrollWidth,
            height: visibleRowsHeight
        )
        topScrollFade.isHidden = true
        bottomScrollFade.isHidden = true
        rowContainer.frame = NSRect(
            x: 0,
            y: 0,
            width: cardWidth,
            height: documentHeight
        )

        for (index, row) in rowViews.enumerated() {
            let rowHeight = scaled(Layout.rowHeight)
            let y = CGFloat(index) * (rowHeight + scaled(Layout.rowGap))
            row.frame = NSRect(x: 0, y: y, width: cardWidth, height: rowHeight)
        }

        layoutSelectionBadge()
        panel.setFrameOrigin(panelOrigin(size: size, focusedTextFrame: focusedTextFrame))
    }

    private func visibleFrame(containing point: NSPoint) -> NSRect {
        (NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first)?
            .visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    }

    private func preferredPanelWidth(for textFrame: NSRect?) -> CGFloat {
        let fallbackWidth = Layout.fallbackWidth
        let anchorFrame = textFrame ?? NSRect(
            x: lastCursorLocation.x - fallbackWidth / 2,
            y: lastCursorLocation.y,
            width: fallbackWidth,
            height: 1
        )
        let sf = visibleFrame(containing: NSPoint(x: anchorFrame.midX, y: anchorFrame.midY))
        let padding = scaled(Layout.padding)
        let gutter = currentSlots.count > Layout.visibleRows ? scaled(Layout.scrollbarGutter) : 0
        let minPanelWidth = Layout.minWidth
        let availableWidth = max(minPanelWidth, sf.width - scaled(Layout.screenInset) * 2)
        let maxPanelWidth = min(Layout.maxWidth, availableWidth)
        let minCardWidth = max(120, minPanelWidth - padding * 2 - gutter)
        let maxCardWidth = max(minCardWidth, maxPanelWidth - padding * 2 - gutter)
        let fallbackCardWidth = fallbackWidth - padding * 2

        // Size presets change density, not anchoring. When a focused text box is
        // available, the visible cards keep that text box's width so the HUD
        // visually grows out of the input instead of becoming three different
        // window sizes for Compact / Standard / Large.
        let targetCardWidth = textFrame.map {
            $0.width.clamped(to: minCardWidth...maxCardWidth)
        } ?? fallbackCardWidth.clamped(to: minCardWidth...maxCardWidth)
        let targetPanelWidth = targetCardWidth + padding * 2 + gutter
        return targetPanelWidth.clamped(to: minPanelWidth...maxPanelWidth).rounded()
    }

    private func panelOrigin(size: NSSize, focusedTextFrame textFrame: NSRect?) -> NSPoint {
        if let textFrame {
            return textAnchoredPanelOrigin(size: size, textFrame: textFrame)
        }

        let sf = visibleFrame(containing: lastCursorLocation)
        let minX = sf.minX + scaled(Layout.screenInset)
        let maxX = max(minX, sf.maxX - size.width - scaled(Layout.screenInset))
        let x = (lastCursorLocation.x - size.width / 2).clamped(to: minX...maxX)
        let y = sf.maxY - max(128, sf.height * 0.16) - size.height
        return NSPoint(x: x.rounded(), y: max(sf.minY + 24, y.rounded()))
    }

    private func textAnchoredPanelOrigin(size: NSSize, textFrame: NSRect) -> NSPoint {
        let anchorPoint = NSPoint(x: textFrame.midX, y: textFrame.midY)
        let sf = visibleFrame(containing: anchorPoint)
        let minX = sf.minX + scaled(Layout.screenInset)
        let maxX = max(minX, sf.maxX - size.width - scaled(Layout.screenInset))
        let alignedX = (textFrame.minX - scaled(Layout.padding)).clamped(to: minX...maxX)

        let minY = sf.minY + scaled(Layout.screenInset)
        let maxY = max(minY, sf.maxY - size.height - scaled(Layout.screenInset))
        let aboveY = textFrame.maxY + scaled(Layout.textFieldGap)
        let belowY = textFrame.minY - scaled(Layout.textFieldGap) - size.height

        let y: CGFloat
        if aboveY <= maxY {
            y = aboveY
        } else if belowY >= minY {
            y = belowY
        } else {
            y = aboveY.clamped(to: minY...maxY)
        }

        return NSPoint(x: alignedX.rounded(), y: y.rounded())
    }

    private func animationOrigin(for textFrame: NSRect?, panelFrame: NSRect) -> NSPoint {
        guard let textFrame else { return lastCursorLocation }
        let horizontal = textFrame.midX.clamped(to: panelFrame.minX...panelFrame.maxX)
        let y: CGFloat
        if panelFrame.minY >= textFrame.maxY {
            y = textFrame.maxY
        } else if panelFrame.maxY <= textFrame.minY {
            y = textFrame.minY
        } else {
            y = textFrame.midY
        }
        return NSPoint(x: horizontal, y: y)
    }

    private func rowsHeight(count: Int) -> CGFloat {
        CGFloat(count) * scaled(Layout.rowHeight) + CGFloat(max(count - 1, 0)) * scaled(Layout.rowGap)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        (value * currentHUDScale).rounded()
    }

    private func scrollToTop() {
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: - Animation

    private func animateIn() {
        guard !reduceMotion else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                panel.animator().alphaValue = 1
            }
            return
        }

        let style = currentTransitionStyle
        guard let layer = rootView.layer else {
            panel.alphaValue = 1
            return
        }
        setTransitionPerformanceMode(true)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = style.inDuration
            context.timingFunction = style.inTiming
            panel.animator().alphaValue = 1
        }

        CATransaction.begin()
        CATransaction.setAnimationDuration(style.inDuration)
        CATransaction.setAnimationTimingFunction(style.inTiming)
        layer.transform = CATransform3DIdentity
        CATransaction.commit()

        animateRowsIn()

        let generation = animationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + style.inDuration + 0.03) { [weak self] in
            guard let self, self.animationGeneration == generation, self.isVisible else { return }
            self.resetRootLayer()
            self.resetRows()
            self.setTransitionPerformanceMode(false)
        }
    }

    private func animateOut(to cursor: NSPoint, selectedOriginalIndex: Int? = nil) {
        animationGeneration &+= 1
        let generation = animationGeneration

        guard !reduceMotion else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.10
                panel.animator().alphaValue = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.animationGeneration == generation, !self.isVisible else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
            }
            return
        }

        let style = currentTransitionStyle
        setTransitionPerformanceMode(true)
        setCursorAnchorPoint(from: cursor)
        animateRowsOut(to: cursor, selectedOriginalIndex: selectedOriginalIndex)

        if let layer = rootView.layer {
            CATransaction.begin()
            CATransaction.setAnimationDuration(style.outDuration)
            CATransaction.setAnimationTimingFunction(style.outTiming)
            layer.transform = rootExitTransform(for: style)
            CATransaction.commit()
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = style.outDuration
            context.timingFunction = style.outTiming
            panel.animator().alphaValue = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + style.outDuration + 0.02) { [weak self] in
            guard let self, self.animationGeneration == generation, !self.isVisible else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.resetRootLayer()
            self.resetRows()
            self.setTransitionPerformanceMode(false)
        }
    }

    private func prepareCursorOriginTransform(from cursor: NSPoint) {
        guard let layer = rootView.layer else { return }
        setCursorAnchorPoint(from: cursor)
        layer.transform = rootEntryTransform(for: currentTransitionStyle)
    }

    private func setCursorAnchorPoint(from cursor: NSPoint) {
        guard let layer = rootView.layer else { return }
        setAnchorPoint(
            CGPoint(
                x: (cursor.x - panel.frame.minX) / max(panel.frame.width, 1),
                y: (cursor.y - panel.frame.minY) / max(panel.frame.height, 1)
            ),
            for: layer
        )
    }

    private func rootEntryTransform(for style: TransitionStyle) -> CATransform3D {
        switch style {
        case .genie:
            return CATransform3DMakeScale(style.initialRootScale, max(0.06, style.initialRootScale * 0.58), 1)
        default:
            return CATransform3DMakeScale(style.initialRootScale, style.initialRootScale, 1)
        }
    }

    private func rootExitTransform(for style: TransitionStyle) -> CATransform3D {
        switch style {
        case .genie:
            return CATransform3DMakeScale(style.exitRootScale, max(0.018, style.exitRootScale * 0.42), 1)
        default:
            return CATransform3DMakeScale(style.exitRootScale, style.exitRootScale, 1)
        }
    }

    private func prepareRowsForEntry(from cursor: NSPoint) {
        let style = currentTransitionStyle
        let cursorPoint = cursorPointInRoot(from: cursor)
        for row in rowViews {
            guard let layer = row.layer else { continue }
            let center = rootView.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), from: row)
            let dx = (cursorPoint.x - center.x) * style.rowTranslationMultiplier
            let dy = (cursorPoint.y - center.y) * style.rowTranslationMultiplier

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAllAnimations()
            layer.opacity = style == .calm ? 0.18 : 0
            layer.transform = CATransform3DConcat(
                CATransform3DMakeTranslation(dx, dy, 0),
                CATransform3DMakeScale(style.rowEntryScale, style.rowEntryScale, 1)
            )
            CATransaction.commit()
        }
    }

    private func animateRowsIn() {
        let style = currentTransitionStyle
        let begin = CACurrentMediaTime()
        let originPoint = cursorPointInRoot(from: lastAnimationOrigin)
        let orderedRows = rowViews
            .compactMap { row -> (row: HUDRowView, distance: CGFloat)? in
                guard row.layer != nil else { return nil }
                let center = rootView.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), from: row)
                return (row, hypot(originPoint.x - center.x, originPoint.y - center.y))
            }
            .sorted { $0.distance < $1.distance }

        for (index, item) in orderedRows.enumerated() {
            let delay = min(TimeInterval(index) * style.rowStagger, 0.12)
            guard let layer = item.row.layer else { continue }
            animateRowLayer(
                layer,
                toTransform: CATransform3DIdentity,
                toOpacity: 1,
                duration: style.inDuration,
                delay: delay,
                timing: style.inTiming,
                beginTime: begin
            )
        }
    }

    private func animateRowsOut(to cursor: NSPoint, selectedOriginalIndex: Int?) {
        let style = currentTransitionStyle
        let cursorPoint = cursorPointInRoot(from: cursor)
        let orderedRows = rowViews.compactMap { row -> (row: HUDRowView, dx: CGFloat, dy: CGFloat, distance: CGFloat, selected: Bool)? in
            guard row.layer != nil else { return nil }
            let center = rootView.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), from: row)
            let dx = (cursorPoint.x - center.x) * style.rowTranslationMultiplier
            let dy = (cursorPoint.y - center.y) * style.rowTranslationMultiplier
            let distance = hypot(dx, dy)
            return (
                row,
                dx,
                dy,
                distance,
                selectedOriginalIndex != nil && row.originalIndex == selectedOriginalIndex
            )
        }
        .sorted { left, right in
            if left.selected != right.selected {
                return left.selected
            }
            return left.distance < right.distance
        }

        for (index, item) in orderedRows.enumerated() {
            guard let layer = item.row.layer else { continue }
            let delay = min(TimeInterval(index) * style.rowStagger * 0.70, 0.08)
            let scale: CGFloat = item.selected ? style.rowExitScale * 0.82 : style.rowExitScale
            let duration = style.outDuration * (item.selected ? 0.78 : 0.92)
            let target = CATransform3DConcat(
                CATransform3DMakeTranslation(item.dx, item.dy, 0),
                CATransform3DMakeScale(scale, scale, 1)
            )
            animateRowLayer(
                layer,
                toTransform: target,
                toOpacity: 0,
                duration: duration,
                delay: delay,
                timing: style.outTiming,
                beginTime: CACurrentMediaTime()
            )
        }
    }

    private func animateRowLayer(
        _ layer: CALayer,
        toTransform: CATransform3D,
        toOpacity: Float,
        duration: TimeInterval,
        delay: TimeInterval,
        timing: CAMediaTimingFunction,
        beginTime: CFTimeInterval
    ) {
        let fromTransform = layer.presentation()?.transform ?? layer.transform
        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = toTransform
        layer.opacity = toOpacity
        CATransaction.commit()

        let transform = CABasicAnimation(keyPath: "transform")
        transform.fromValue = NSValue(caTransform3D: fromTransform)
        transform.toValue = NSValue(caTransform3D: toTransform)

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = fromOpacity
        opacity.toValue = toOpacity

        let group = CAAnimationGroup()
        group.animations = [transform, opacity]
        group.duration = duration
        group.beginTime = beginTime + delay
        group.timingFunction = timing
        group.fillMode = .both
        group.isRemovedOnCompletion = true
        layer.add(group, forKey: "cmd.hud.row.motion")
    }

    private func setTransitionPerformanceMode(_ enabled: Bool) {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        [rootView.layer, scrollView.layer, rowContainer.layer].compactMap { $0 }.forEach { layer in
            layer.drawsAsynchronously = enabled
            layer.allowsGroupOpacity = true
        }

        for row in rowViews {
            guard let layer = row.layer else { continue }
            layer.drawsAsynchronously = enabled
            layer.allowsGroupOpacity = true
            layer.shouldRasterize = enabled
            layer.rasterizationScale = scale
        }
    }

    private func resetRows() {
        for row in rowViews {
            guard let layer = row.layer else { continue }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAllAnimations()
            layer.opacity = 1
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        updateSelection()
    }

    private func cursorPointInRoot(from cursor: NSPoint) -> NSPoint {
        NSPoint(x: cursor.x - panel.frame.minX, y: cursor.y - panel.frame.minY)
    }

    private func resetRootLayer() {
        guard let layer = rootView.layer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        setAnchorPoint(CGPoint(x: 0.5, y: 0.5), for: layer)
        CATransaction.commit()
    }

    private func setAnchorPoint(_ anchorPoint: CGPoint, for layer: CALayer) {
        let oldAnchor = layer.anchorPoint
        guard oldAnchor != anchorPoint else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = layer.bounds.size
        layer.anchorPoint = anchorPoint
        layer.position = CGPoint(
            x: layer.position.x + (anchorPoint.x - oldAnchor.x) * size.width,
            y: layer.position.y + (anchorPoint.y - oldAnchor.y) * size.height
        )
        CATransaction.commit()
    }

    // MARK: - Dismiss Guards

    private func installDismissGuards(sessionID: UInt64) {
        guard isCurrentSession(sessionID) else { return }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss(sessionID: sessionID)
            }
        }

        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dismiss(sessionID: sessionID)
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.dismiss(sessionID: sessionID)
        }
    }

    private func removeDismissGuards() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
    }

    private func setVisible(_ visible: Bool, sessionID: UInt64?) {
        visibilityLock.withLock {
            _isVisible = visible
            activeSessionID = visible ? sessionID : nil
        }
    }

    private func beginDismiss(sessionID requestedSessionID: UInt64?) -> UInt64? {
        visibilityLock.withLock {
            guard _isVisible, let currentSessionID = activeSessionID else { return nil }
            if let requestedSessionID, requestedSessionID != currentSessionID { return nil }
            _isVisible = false
            activeSessionID = nil
            return currentSessionID
        }
    }

    private func isCurrentSession(_ sessionID: UInt64) -> Bool {
        visibilityLock.withLock {
            _isVisible && activeSessionID == sessionID
        }
    }
}

private enum FocusedTextInputLocator {
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

private final class HUDRootView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

private final class HUDHeaderScrimView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class HUDScrollFadeView: NSView {
    private let isTop: Bool
    private let gradient = CAGradientLayer()

    init(isTop: Bool) {
        self.isTop = isTop
        super.init(frame: .zero)
        wantsLayer = true
        layer = gradient
        gradient.colors = [
            NSColor(calibratedWhite: 0.02, alpha: isTop ? 0.30 : 0.0).cgColor,
            NSColor(calibratedWhite: 0.02, alpha: isTop ? 0.0 : 0.30).cgColor,
        ]
        gradient.locations = [0, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        gradient.cornerRadius = 18
        gradient.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private final class HUDRowsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class HUDRowView: NSView {

    var onPaste: ((Int) -> Void)?
    var onModifiedClick: ((Int, NSEvent.ModifierFlags) -> Void)?
    var onCopy: ((Int) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragEnd: ((NSDragOperation) -> Void)?
    var dragEntriesProvider: ((Int) -> [ClipEntry])?

    private let appIconView = NSImageView()
    private let appNameLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let timestampLabel = NSTextField(labelWithString: "")
    private let typeLabel = NSTextField(labelWithString: "")
    private let copyButton = NSButton()

    private var entry: ClipEntry?
    private var index: Int?
    private var isEmptyRow = false
    private var isSelected = false
    private var highlighted = true
    private var hovering = false
    private var dragStarted = false
    private var mouseDownLocation = NSPoint.zero
    private var copyResetTimer: Timer?
    private var cardOpacity: CGFloat = 1.0
    private var sizeScale: CGFloat = 1.0
    private var cachedDragImage: NSImage?
    private var cachedDragWriters: [NSPasteboardWriting] = []

    var originalIndex: Int? {
        index
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    private func build() {
        wantsLayer = true
        layer?.borderWidth = 0.5
        layer?.masksToBounds = true

        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.wantsLayer = true
        appIconView.layer?.masksToBounds = true

        appNameLabel.textColor = .white
        appNameLabel.lineBreakMode = .byTruncatingTail

        previewLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.maximumNumberOfLines = 2

        timestampLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        timestampLabel.alignment = .right

        typeLabel.textColor = NSColor.white.withAlphaComponent(0.42)
        typeLabel.lineBreakMode = .byTruncatingTail

        copyButton.isBordered = false
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.imageScaling = .scaleProportionallyDown
        copyButton.contentTintColor = NSColor.white.withAlphaComponent(0.64)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        copyButton.wantsLayer = true

        [appIconView, appNameLabel, previewLabel, timestampLabel, typeLabel, copyButton].forEach {
            addSubview($0)
        }
        applySizeMetrics()
        applyChrome()
    }

    func configure(entry: ClipEntry, index: Int) {
        self.entry = entry
        self.index = index
        isEmptyRow = false

        appIconView.isHidden = false
        appIconView.image = icon(for: entry)
        appNameLabel.stringValue = entry.sourceAppName
        previewLabel.stringValue = previewText(for: entry)
        timestampLabel.stringValue = Self.relativeTimestamp(from: entry.copiedAt)
        typeLabel.stringValue = entry.isSensitive ? "SENSITIVE" : CmdVisualStyle.label(for: entry.contentType, uppercase: true)
        copyButton.isHidden = false
        resetCopyButton()
        buildDragCache(for: entry)

        highlighted = true
        applyChrome()
        needsLayout = true
    }

    func configureEmpty(title: String, message: String) {
        entry = nil
        index = nil
        isEmptyRow = true
        appIconView.isHidden = true
        appNameLabel.stringValue = title
        previewLabel.stringValue = message
        timestampLabel.stringValue = ""
        typeLabel.stringValue = ""
        copyButton.isHidden = true
        clearDragCache()
        highlighted = true
        applyChrome()
        needsLayout = true
    }

    func setHighlighted(_ highlighted: Bool) {
        self.highlighted = highlighted
        applyChrome()
    }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        applyChrome()
    }

    func applyOpacity(_ opacity: Double) {
        cardOpacity = CGFloat(opacity.clamped(to: 0.55...1.0))
        applyChrome()
    }

    func applySizeScale(_ scale: Double) {
        sizeScale = CGFloat(scale.clamped(to: 0.85...1.20))
        applySizeMetrics()
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let left = scaled(16)
        let right = scaled(14)
        let iconSize: CGFloat = isEmptyRow ? 0 : scaled(46)
        let buttonSize: CGFloat = copyButton.isHidden ? 0 : scaled(30)
        let timeWidth: CGFloat = timestampLabel.stringValue.isEmpty ? 0 : scaled(76)

        appIconView.frame = NSRect(
            x: left,
            y: (bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )

        let textX = isEmptyRow ? left : left + iconSize + scaled(14)
        let trailingControls = timeWidth + buttonSize + (buttonSize > 0 ? scaled(12) : 0) + scaled(8)
        let textWidth = max(80, bounds.width - textX - right - trailingControls)

        appNameLabel.frame = NSRect(x: textX, y: bounds.height - scaled(32), width: textWidth, height: scaled(18))
        previewLabel.frame = NSRect(x: textX, y: scaled(29), width: textWidth, height: scaled(34))
        typeLabel.frame = NSRect(x: textX, y: scaled(12), width: textWidth, height: scaled(14))

        timestampLabel.frame = NSRect(
            x: bounds.width - right - buttonSize - scaled(8) - timeWidth,
            y: bounds.height - scaled(32),
            width: timeWidth,
            height: scaled(18)
        )

        if !copyButton.isHidden {
            copyButton.frame = NSRect(
                x: bounds.width - right - buttonSize,
                y: (bounds.height - buttonSize) / 2,
                width: buttonSize,
                height: buttonSize
            )
        }

        if let layer {
            layer.shadowPath = CGPath(
                roundedRect: bounds.insetBy(dx: 1, dy: 1),
                cornerWidth: layer.cornerRadius,
                cornerHeight: layer.cornerRadius,
                transform: nil
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        dragStarted = false
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        if !isEmptyRow {
            NSCursor.closedHand.set()
        }
        animateDragLift(active: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isEmptyRow, let index, !dragStarted else { return }
        let dragStart = Date()
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - mouseDownLocation.x
        let dy = point.y - mouseDownLocation.y
        guard dx * dx + dy * dy > 16 else { return }

        let dragEntries = dragEntriesProvider?(index) ?? entry.map { [$0] } ?? []
        let writers = dragEntries.count > 1
            ? ClipPasteboardWriter.dragPasteboardWriters(for: dragEntries)
            : cachedDragWriters
        guard !writers.isEmpty else { return }
        let image = dragEntries.count > 1
            ? lightweightStackDragImage(for: dragEntries)
            : cachedDragImage
        guard let image else { return }
        dragStarted = true
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)

        let ghostSize = image.size
        let dragFrame = NSRect(
            x: mouseDownLocation.x - ghostSize.width / 2,
            y: mouseDownLocation.y - ghostSize.height / 2,
            width: ghostSize.width,
            height: ghostSize.height
        )
        let items = writers.enumerated().map { offset, writer -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(dragFrame, contents: offset == 0 ? image : nil)
            return item
        }
        let elapsedMs = Int(Date().timeIntervalSince(dragStart) * 1000)
        if elapsedMs >= 50 {
            DiagnosticsLogbook.shared.record(
                "slow_drag_session_start",
                category: "performance",
                details: [
                    "durationMs": "\(elapsedMs)",
                    "entryCount": "\(dragEntries.count)",
                    "writerCount": "\(writers.count)"
                ]
            )
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if !isEmptyRow {
            NSCursor.openHand.set()
        }
        applyChrome()
        animateHoverLift(active: true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        NSCursor.arrow.set()
        applyChrome()
        animateHoverLift(active: false)
    }

    override func mouseUp(with event: NSEvent) {
        if hovering && !isEmptyRow {
            NSCursor.openHand.set()
        }
        animateDragLift(active: false)
        guard !dragStarted, let index else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard !copyButton.frame.contains(point) else { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift) {
            onModifiedClick?(index, event.modifierFlags)
            return
        }
        onPaste?(index)
    }

    @objc private func copyTapped() {
        guard let index else { return }
        onCopy?(index)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        copyButton.contentTintColor = .systemGreen
        animateCopyConfirmation()
        copyResetTimer?.invalidate()
        copyResetTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            self?.resetCopyButton()
        }
    }

    private func resetCopyButton() {
        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.contentTintColor = NSColor.white.withAlphaComponent(0.64)
    }

    private func applyChrome() {
        alphaValue = highlighted ? 1 : 0.34

        let background: NSColor
        if isSelected && highlighted {
            background = NSColor(calibratedWhite: 0.24, alpha: min(1.0, cardOpacity + 0.08))
        } else if hovering && highlighted {
            background = NSColor(calibratedWhite: 0.20, alpha: min(1.0, cardOpacity + 0.04))
        } else {
            background = NSColor(calibratedWhite: 0.15, alpha: cardOpacity)
        }
        layer?.backgroundColor = background.cgColor
        layer?.borderColor = (isSelected && highlighted
            ? CmdVisualStyle.cardBorderSelected
            : (hovering && highlighted ? CmdVisualStyle.cardBorderHover : CmdVisualStyle.cardBorder)
        ).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(isSelected ? 0.32 : 0.22).cgColor
        layer?.shadowOpacity = highlighted ? 1 : 0
        layer?.shadowRadius = isSelected ? 20 : 13
        layer?.shadowOffset = CGSize(width: 0, height: -5)
    }

    private func applySizeMetrics() {
        layer?.cornerRadius = scaled(CmdVisualStyle.cardCornerRadius)
        appIconView.layer?.cornerRadius = scaled(12)
        copyButton.layer?.cornerRadius = scaled(8)
        appNameLabel.font = .systemFont(ofSize: scaled(14), weight: .bold)
        previewLabel.font = .systemFont(ofSize: scaled(13), weight: .medium)
        timestampLabel.font = .systemFont(ofSize: scaled(12), weight: .bold)
        typeLabel.font = .systemFont(ofSize: scaled(11), weight: .bold)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        (value * sizeScale).rounded()
    }

    private func animateDragLift(active: Bool) {
        guard !isEmptyRow, let layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.08)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1.0))
        layer.transform = active ? CATransform3DMakeScale(1.012, 1.012, 1) : CATransform3DIdentity
        layer.shadowRadius = active ? 20 : (isSelected ? 18 : 10)
        CATransaction.commit()
    }

    private func animateHoverLift(active: Bool) {
        guard !dragStarted, !isEmptyRow, let layer else { return }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.11)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.18, 0.82, 0.20, 1.0))
        layer.transform = active ? CATransform3DMakeScale(1.006, 1.006, 1) : CATransform3DIdentity
        layer.shadowRadius = active ? 16 : (isSelected ? 18 : 10)
        CATransaction.commit()
    }

    private func animateCopyConfirmation() {
        guard let layer = copyButton.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeScale(0.76, 0.76, 1)
        CATransaction.commit()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.16, 0.92, 0.22, 1.0))
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func buildDragCache(for entry: ClipEntry) {
        cachedDragWriters = pasteboardWriters(for: entry)
        cachedDragImage = lightweightDragImage(for: entry)
    }

    private func clearDragCache() {
        cachedDragImage = nil
        cachedDragWriters = []
    }

    private static let ghostSize = NSSize(width: 360, height: 68)

    private func lightweightDragImage(for entry: ClipEntry) -> NSImage {
        let size = Self.ghostSize
        let image = NSImage(size: size)
        let icon = appIconView.image
        let appName = entry.sourceAppName
        let preview = previewText(for: entry)
        let type = CmdVisualStyle.label(for: entry.contentType, uppercase: true)

        effectiveAppearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            defer { image.unlockFocus() }

            let rect = NSRect(origin: .zero, size: size)
            let path = NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18)
            NSGraphicsContext.current?.cgContext.setShadow(
                offset: CGSize(width: 0, height: -5),
                blur: 18,
                color: NSColor.black.withAlphaComponent(0.34).cgColor
            )
            NSColor(calibratedWhite: 0.16, alpha: max(0.86, cardOpacity * 0.96)).setFill()
            path.fill()

            NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            NSColor.white.withAlphaComponent(0.12).setStroke()
            path.lineWidth = 0.6
            path.stroke()

            let iconRect = NSRect(x: 14, y: 14, width: 40, height: 40)
            if let icon {
                NSGraphicsContext.current?.cgContext.saveGState()
                NSBezierPath(roundedRect: iconRect, xRadius: 10, yRadius: 10).addClip()
                icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.current?.cgContext.restoreGState()
            }

            let textX: CGFloat = 66
            let textWidth = size.width - textX - 16
            (appName as NSString).draw(
                with: NSRect(x: textX, y: 39, width: textWidth, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: NSColor.white,
                ]
            )
            (preview as NSString).draw(
                with: NSRect(x: textX, y: 22, width: textWidth, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.70),
                ]
            )
            (type as NSString).draw(
                with: NSRect(x: textX, y: 7, width: textWidth, height: 13),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.42),
                ]
            )
        }
        return image
    }

    private func lightweightStackDragImage(for entries: [ClipEntry]) -> NSImage {
        let size = Self.ghostSize
        let image = NSImage(size: size)
        let count = entries.count
        let title = "\(count) selected item\(count == 1 ? "" : "s")"
        let chips = typeChips(for: entries)
        let preview = entries
            .prefix(3)
            .map { previewText(for: $0) }
            .joined(separator: "  +  ")

        effectiveAppearance.performAsCurrentDrawingAppearance {
            image.lockFocus()
            defer { image.unlockFocus() }

            let rect = NSRect(origin: .zero, size: size)
            for offset in stride(from: 2, through: 0, by: -1) {
                let inset = CGFloat(offset) * 5
                let stackRect = rect.offsetBy(dx: inset, dy: -inset).insetBy(dx: CGFloat(offset) * 2, dy: CGFloat(offset) * 2)
                let path = NSBezierPath(roundedRect: stackRect, xRadius: 18, yRadius: 18)
                NSColor(calibratedWhite: 0.16 + CGFloat(offset) * 0.025, alpha: max(0.82, cardOpacity * 0.94)).setFill()
                path.fill()
            }

            NSColor.systemBlue.withAlphaComponent(0.82).setFill()
            NSBezierPath(ovalIn: NSRect(x: 16, y: 18, width: 32, height: 32)).fill()
            ("\(count)" as NSString).draw(
                with: NSRect(x: 16, y: 24, width: 32, height: 18),
                options: [.usesLineFragmentOrigin],
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: NSColor.white,
                    .paragraphStyle: centeredParagraphStyle()
                ]
            )

            let textX: CGFloat = 64
            let textWidth = size.width - textX - 16
            (title as NSString).draw(
                with: NSRect(x: textX, y: 39, width: textWidth, height: 18),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                    .foregroundColor: NSColor.white,
                ]
            )
            (preview as NSString).draw(
                with: NSRect(x: textX, y: 23, width: textWidth, height: 16),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.70),
                ]
            )
            drawTypeChips(chips, startX: textX, y: 7, maxWidth: textWidth)
        }
        return image
    }

    private func typeChips(for entries: [ClipEntry]) -> [String] {
        var seen: Set<String> = []
        var chips: [String] = []
        for entry in entries {
            let label = CmdVisualStyle.label(for: entry.contentType, uppercase: true)
            guard seen.insert(label).inserted else { continue }
            chips.append(label)
            if chips.count == 3 { break }
        }
        return chips
    }

    private func drawTypeChips(_ chips: [String], startX: CGFloat, y: CGFloat, maxWidth: CGFloat) {
        var x = startX
        let gap: CGFloat = 6
        for chip in chips {
            let textWidth = (chip as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .bold)
            ]).width
            let chipWidth = textWidth + 14
            guard x + chipWidth <= startX + maxWidth else { return }
            let rect = NSRect(x: x, y: y, width: chipWidth, height: 14)
            NSColor.white.withAlphaComponent(0.11).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            (chip as NSString).draw(
                with: rect.insetBy(dx: 7, dy: 1),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9, weight: .bold),
                    .foregroundColor: NSColor.white.withAlphaComponent(0.58)
                ]
            )
            x += chipWidth + gap
        }
    }

    private func centeredParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return style
    }

    private func pasteboardWriters(for entry: ClipEntry) -> [NSPasteboardWriting] {
        ClipPasteboardWriter.dragPasteboardWriters(for: entry)
    }

    private func previewText(for entry: ClipEntry) -> String {
        return entry.previewText.isEmpty ? "(empty text)" : entry.previewText
    }

    private func icon(for entry: ClipEntry) -> NSImage {
        if let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: entry.sourceBundleID)
            .first,
           let icon = app.icon {
            return icon
        }

        switch entry.contentType {
        case .image:
            return fallbackIcon(systemName: "photo", fileExtension: "png")
        case .rich:
            return fallbackIcon(systemName: "photo.on.rectangle", fileExtension: "rtfd")
        case .file:
            return fallbackIcon(systemName: "doc", fileExtension: "txt")
        case .url:
            return fallbackIcon(systemName: "link", fileExtension: "webloc")
        case .color:
            return fallbackIcon(systemName: "eyedropper", fileExtension: "txt")
        case .code:
            return fallbackIcon(systemName: "curlybraces", fileExtension: "swift")
        case .text:
            return fallbackIcon(systemName: "text.alignleft", fileExtension: "txt")
        }
    }

    private func fallbackIcon(systemName: String, fileExtension: String) -> NSImage {
        if let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil) {
            return image
        }
        if let type = UTType(filenameExtension: fileExtension) {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: .plainText)
    }

    private static func relativeTimestamp(from date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

extension HUDRowView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        onDragStart?()
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NSCursor.arrow.set()
        animateDragLift(active: false)
        onDragEnd?(operation)
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }
}

private extension NSColor {
    convenience init?(hexString: String) {
        let raw = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard raw.count == 6 || raw.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: raw).scanHexInt64(&value) else { return nil }

        let hasAlpha = raw.count == 8
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat

        if hasAlpha {
            red = CGFloat((value >> 24) & 0xff) / 255
            green = CGFloat((value >> 16) & 0xff) / 255
            blue = CGFloat((value >> 8) & 0xff) / 255
            alpha = CGFloat(value & 0xff) / 255
        } else {
            red = CGFloat((value >> 16) & 0xff) / 255
            green = CGFloat((value >> 8) & 0xff) / 255
            blue = CGFloat(value & 0xff) / 255
            alpha = 1
        }

        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
