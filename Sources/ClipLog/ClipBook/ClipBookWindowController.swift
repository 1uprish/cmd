import AppKit
import ClipLogCore
import CoreGraphics

// MARK: - ClipBookWindowController

/// A full-window card-grid browser for all clipboard history.
///
/// Layout:
///
///  ┌─────────────────────────────────────────────────────┐
///  │  cmd                        [All ▾]  [🔍 Search…]  │  ← header bar
///  ├─────────────────────────────────────────────────────┤
///  │                                                      │
///  │  ╔══════════╗  ╔══════════╗  ╔══════════╗           │
///  │  ║  card    ║  ║  card    ║  ║  card    ║           │  ← NSCollectionView
///  │  ╚══════════╝  ╚══════════╝  ╚══════════╝           │
///  │                                                      │
///  └─────────────────────────────────────────────────────┘

public final class ClipBookWindowController: NSWindowController, NSWindowDelegate {

    // MARK: Store

    private weak var store: ClipStore?

    /// The app that was frontmost when history was opened.
    /// We re-activate it before synthesising ⌘V so paste lands in the right window.
    private var previousApp: NSRunningApplication?

    // MARK: Data

    private var allEntries: [ClipEntry] = []
    private var displayedEntries: [ClipEntry] = []

    // Filter state
    private var searchQuery: String = ""
    private var selectedType: ClipContentType? = nil   // nil == "All"
    private enum SearchMode { case text, semantic }
    private var searchMode: SearchMode = .text

    // MARK: UI

    private let headerBar       = NSView()
    private let titleLabel      = NSTextField(labelWithString: "cmd")
    private let filterPopUp     = NSPopUpButton()
    private let searchField     = NSSearchField()
    private let searchModeSegment = NSSegmentedControl()

    private let scrollView      = NSScrollView()
    private let collectionView  = NSCollectionView()
    private let flowLayout      = NSCollectionViewFlowLayout()

    // Empty state
    private let emptyStateView  = NSView()
    private let emptyIcon       = NSImageView()
    private let emptyLabel      = NSTextField(labelWithString: "Nothing here yet. Start copying.")

    // Background blur
    private let backdropEffect  = NSVisualEffectView()

    // MARK: Constants

    private let headerHeight:  CGFloat = 58
    private let cardHeight:    CGFloat = 132
    private let itemSpacing:   CGFloat = 16
    private let lineSpacing:   CGFloat = 16
    private let sectionInsets          = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
    private let numberOfColumns: CGFloat = 3

    // MARK: - Init

    public init(store: ClipStore, previousApp: NSRunningApplication? = nil) {
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "open",
            details: ["previousApp": previousApp?.bundleIdentifier ?? "unknown"]
        )
        self.store = store
        self.previousApp = previousApp
        let window = Self.makeWindow()
        super.init(window: window)
        window.delegate = self
        buildUI()
        reloadData()
        DiagnosticsLogbook.shared.actionOutput(feature: "history_window", action: "open", details: ["success": "true"])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use init(store:)") }

    // MARK: - Window factory

    private static func makeWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 640),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title                       = ""          // hidden — custom label in header replaces it
        w.titleVisibility             = .hidden
        w.minSize                     = NSSize(width: 900, height: 520)
        w.titlebarAppearsTransparent  = true
        w.isMovableByWindowBackground = true
        w.center()
        return w
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }
        contentView.wantsLayer = true

        // ── Full-window backdrop blur ───────────────────────────────────
        backdropEffect.material     = .hudWindow
        backdropEffect.blendingMode = .behindWindow
        backdropEffect.state        = .active
        backdropEffect.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backdropEffect)
        NSLayoutConstraint.activate([
            backdropEffect.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdropEffect.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdropEffect.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdropEffect.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        buildHeader(in: contentView)
        buildGrid(in: contentView)
        buildEmptyState(in: contentView)

        NotificationCenter.default.addObserver(
            forName: .clipLogOCRCompleted, object: nil, queue: .main
        ) { [weak self] _ in
            self?.reloadData()
        }
    }

    // MARK: Header bar

    private func buildHeader(in contentView: NSView) {
        headerBar.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(headerBar)

        // ── Title ─────────────────────────────────────────────────────
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font        = .systemFont(ofSize: 19, weight: .bold)
        titleLabel.textColor   = .labelColor
        titleLabel.isEditable  = false
        titleLabel.isBordered  = false
        titleLabel.drawsBackground = false
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        headerBar.addSubview(titleLabel)

        // ── Filter popup ───────────────────────────────────────────────
        filterPopUp.translatesAutoresizingMaskIntoConstraints = false
        filterPopUp.bezelStyle = .regularSquare
        filterPopUp.font       = .systemFont(ofSize: 12)
        filterPopUp.controlSize = .large

        let allTypes: [(String, ClipContentType?)] = [
            ("All",    nil),
            ("Text",   .text),
            ("URLs",   .url),
            ("Code",   .code),
            ("Images", .image),
            ("Mixed",  .rich),
            ("Files",  .file),
            ("Colors", .color),
        ]
        for (label, _) in allTypes {
            filterPopUp.addItem(withTitle: label)
        }
        filterPopUp.target = self
        filterPopUp.action = #selector(filterChanged(_:))
        // Store type mapping by tag
        for (index, (_, type)) in allTypes.enumerated() {
            filterPopUp.item(at: index)?.tag = index
            // Encode optional type as tag; nil == 0 handled in filterChanged
            _ = type // tags 0-6 correspond to the array order
        }
        headerBar.addSubview(filterPopUp)

        // ── Queue Paste button (⌘⇧V) ──────────────────────────────────
        let queueButton = NSButton(
            image: NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "Queue Paste")
                ?? NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Queue Paste")!,
            target: self,
            action: #selector(queuePasteTapped)
        )
        queueButton.isBordered      = false
        queueButton.bezelStyle      = .regularSquare
        queueButton.contentTintColor = .secondaryLabelColor
        queueButton.translatesAutoresizingMaskIntoConstraints = false
        queueButton.toolTip = "Queue Paste — selects multiple items for sequential pasting (⌘⇧V)"
        headerBar.addSubview(queueButton)

        // ── Refresh button ─────────────────────────────────────────────
        let refreshButton = NSButton(
            image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh")!,
            target: self,
            action: #selector(refreshTapped)
        )
        refreshButton.isBordered    = false
        refreshButton.bezelStyle    = .regularSquare
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.translatesAutoresizingMaskIntoConstraints = false
        refreshButton.toolTip = "Refresh"
        headerBar.addSubview(refreshButton)

        // ── Search mode toggle (Text | Semantic) ───────────────────────
        searchModeSegment.segmentCount = 2
        searchModeSegment.setLabel("Text",     forSegment: 0)
        searchModeSegment.setLabel("Semantic", forSegment: 1)
        searchModeSegment.selectedSegment = 0
        searchModeSegment.segmentStyle = .capsule
        searchModeSegment.font = .systemFont(ofSize: 11)
        searchModeSegment.controlSize = .large
        searchModeSegment.target = self
        searchModeSegment.action = #selector(searchModeChanged(_:))
        searchModeSegment.translatesAutoresizingMaskIntoConstraints = false
        searchModeSegment.toolTip = "Text: keyword search   Semantic: meaning-based search"
        headerBar.addSubview(searchModeSegment)

        // ── Search field ───────────────────────────────────────────────
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search…"
        searchField.delegate          = self
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        headerBar.addSubview(searchField)

        // ── Thin separator ─────────────────────────────────────────────
        let separator = NSBox()
        separator.boxType  = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator)

        NSLayoutConstraint.activate([
            // Header bar fills top below the transparent titlebar.
            headerBar.topAnchor.constraint(equalTo: contentView.topAnchor),
            headerBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            headerBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            headerBar.heightAnchor.constraint(equalToConstant: headerHeight),

            // Title: offset 80pt from left to clear the traffic-light buttons (close/min/zoom)
            titleLabel.leadingAnchor.constraint(equalTo: headerBar.leadingAnchor, constant: 96),
            titleLabel.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: filterPopUp.leadingAnchor, constant: -24),

            // Refresh button: far right
            refreshButton.widthAnchor.constraint(equalToConstant: 30),
            refreshButton.heightAnchor.constraint(equalToConstant: 30),
            refreshButton.trailingAnchor.constraint(equalTo: headerBar.trailingAnchor, constant: -18),
            refreshButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            // Queue Paste button: left of refresh
            queueButton.widthAnchor.constraint(equalToConstant: 30),
            queueButton.heightAnchor.constraint(equalToConstant: 30),
            queueButton.trailingAnchor.constraint(equalTo: refreshButton.leadingAnchor, constant: -8),
            queueButton.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            // Search field: fixed enough to read, not so wide it crowds filters.
            searchField.widthAnchor.constraint(equalToConstant: 240),
            searchField.trailingAnchor.constraint(equalTo: queueButton.leadingAnchor, constant: -12),
            searchField.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            // Search mode toggle: left of search field
            searchModeSegment.widthAnchor.constraint(equalToConstant: 150),
            searchModeSegment.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -10),
            searchModeSegment.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            // Filter popup: left of toggle
            filterPopUp.widthAnchor.constraint(equalToConstant: 116),
            filterPopUp.trailingAnchor.constraint(equalTo: searchModeSegment.leadingAnchor, constant: -10),
            filterPopUp.centerYAnchor.constraint(equalTo: headerBar.centerYAnchor),

            // Separator
            separator.topAnchor.constraint(equalTo: headerBar.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    // MARK: Grid

    private func buildGrid(in contentView: NSView) {
        // Flow layout
        flowLayout.minimumInteritemSpacing = itemSpacing
        flowLayout.minimumLineSpacing      = lineSpacing
        flowLayout.sectionInset            = sectionInsets
        // itemSize is set in updateItemSize()

        collectionView.collectionViewLayout = flowLayout
        collectionView.dataSource           = self
        collectionView.delegate             = self
        collectionView.isSelectable         = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors     = [.clear]
        collectionView.register(
            ClipBookCardItem.self,
            forItemWithIdentifier: ClipBookCardItem.reuseIdentifier
        )

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView        = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers  = true
        scrollView.drawsBackground     = false
        scrollView.borderType          = .noBorder

        contentView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: headerHeight + 1),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    // MARK: Empty state

    private func buildEmptyState(in contentView: NSView) {
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        contentView.addSubview(emptyStateView)

        if let sym = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: 48, weight: .thin)
            emptyIcon.image = sym.withSymbolConfiguration(cfg)
        }
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyIcon.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font      = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isEditable   = false
        emptyLabel.isBordered   = false
        emptyLabel.drawsBackground = false

        emptyStateView.addSubview(emptyIcon)
        emptyStateView.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            emptyStateView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            emptyStateView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: headerHeight),
            emptyStateView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            emptyIcon.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyIcon.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor, constant: -16),

            emptyLabel.topAnchor.constraint(equalTo: emptyIcon.bottomAnchor, constant: 12),
            emptyLabel.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
        ])
    }

    // MARK: - Public API

    /// Reload all entries from the store. Safe to call from any queue.
    public func reloadData() {
        DiagnosticsLogbook.shared.actionInput(feature: "history_window", action: "reload")
        let entries = (try? store?.all()) ?? []
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            DiagnosticsLogbook.shared.actionProcess(
                feature: "history_window",
                action: "reload",
                details: ["step": "apply_entries", "entryCount": "\(entries.count)"]
            )
            self.allEntries = entries
            self.applyFilters()
            DiagnosticsLogbook.shared.actionOutput(
                feature: "history_window",
                action: "reload",
                details: ["success": "true", "entryCount": "\(entries.count)"]
            )
        }
    }

    // MARK: - Filtering

    private static let filterTypes: [ClipContentType?] = [
        nil, .text, .url, .code, .image, .rich, .file, .color
    ]

    @objc private func filterChanged(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "filter_type",
            details: ["selectedIndex": "\(idx)"]
        )
        selectedType = Self.filterTypes[safe: idx] ?? nil
        applyFilters()
        DiagnosticsLogbook.shared.actionOutput(
            feature: "history_window",
            action: "filter_type",
            details: [
                "success": "true",
                "selectedType": selectedType?.rawValue ?? "all",
                "resultCount": "\(displayedEntries.count)"
            ]
        )
    }

    @objc private func searchModeChanged(_ sender: NSSegmentedControl) {
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "search_mode",
            details: ["selectedSegment": "\(sender.selectedSegment)"]
        )
        searchMode = sender.selectedSegment == 1 ? .semantic : .text
        applyFilters()
        DiagnosticsLogbook.shared.actionOutput(
            feature: "history_window",
            action: "search_mode",
            details: ["success": "true", "mode": searchMode == .semantic ? "semantic" : "text"]
        )
    }

    private func applyFilters() {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        let startedAt = Date()
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "apply_filters",
            details: [
                "queryLength": "\(q.count)",
                "mode": searchMode == .semantic ? "semantic" : "text",
                "selectedType": selectedType?.rawValue ?? "all",
                "entryCount": "\(allEntries.count)"
            ]
        )

        // Semantic search: when a query is present and mode == .semantic, rank by NL similarity.
        if searchMode == .semantic, !q.isEmpty {
            DiagnosticsLogbook.shared.actionProcess(
                feature: "history_window",
                action: "apply_filters",
                details: ["step": "semantic_search"]
            )
            applySemanticSearch(query: q)
            return
        }

        DiagnosticsLogbook.shared.actionProcess(
            feature: "history_window",
            action: "apply_filters",
            details: ["step": "keyword_filter"]
        )
        let lowerQ = q.lowercased()
        displayedEntries = allEntries.filter { entry in
            // Type filter
            if let t = selectedType, entry.contentType != t { return false }
            // Keyword search
            if !lowerQ.isEmpty {
                let inPreview = entry.previewText.lowercased().contains(lowerQ)
                let inApp     = entry.sourceAppName.lowercased().contains(lowerQ)
                let inOCR     = entry.ocrText?.localizedCaseInsensitiveContains(lowerQ) == true
                let inTitle   = entry.sourceWindowTitle?.localizedCaseInsensitiveContains(lowerQ) == true
                if !inPreview && !inApp && !inOCR && !inTitle { return false }
            }
            return true
        }

        collectionView.reloadData()
        emptyStateView.isHidden = !displayedEntries.isEmpty
        scrollView.isHidden     = displayedEntries.isEmpty
        DiagnosticsLogbook.shared.actionOutput(
            feature: "history_window",
            action: "apply_filters",
            details: [
                "success": "true",
                "resultCount": "\(displayedEntries.count)",
                "durationMs": "\(Self.milliseconds(since: startedAt))"
            ]
        )
    }

    private func applySemanticSearch(query: String) {
        let startedAt = Date()
        // Run entirely on background — NLEmbedding is slow on first call.
        let typeFilter = selectedType
        let capturedStore = store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            // Fast path: use pre-computed embeddings from the DB (written by EmbeddingService
            // after each new capture). Fall back to on-the-fly embedding for entries that
            // don't have a stored vector yet (e.g. older items or non-text types).
            let storedPairs: [(ClipEntry, [Double])] = (try? capturedStore?.allWithEmbeddings()) ?? []

            // Apply type filter.
            let filtered = storedPairs.filter { entry, _ in
                guard let t = typeFilter else { return true }
                return entry.contentType == t
            }

            // For entries with no stored embedding, embed on-the-fly (text only).
            let candidates: [(ClipEntry, [Double])]
            if filtered.isEmpty {
                // Nothing in DB yet — embed current allEntries on-the-fly.
                let fallback = self.allEntries.filter { entry in
                    if let t = typeFilter, entry.contentType != t { return false }
                    return [.text, .url, .code, .rich].contains(entry.contentType)
                }
                candidates = fallback.compactMap { entry in
                    SemanticSearch.shared.embed(entry.previewText).map { (entry, $0) }
                }
            } else {
                candidates = filtered
            }

            let ranked = SemanticSearch.shared.rank(query: query, entries: candidates)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.displayedEntries = ranked
                self.collectionView.reloadData()
                self.emptyStateView.isHidden = !ranked.isEmpty
                self.scrollView.isHidden     = ranked.isEmpty
                DiagnosticsLogbook.shared.actionOutput(
                    feature: "history_window",
                    action: "apply_filters",
                    details: [
                        "success": "true",
                        "mode": "semantic",
                        "resultCount": "\(ranked.count)",
                        "durationMs": "\(Self.milliseconds(since: startedAt))"
                    ]
                )
            }
        }
    }

    // MARK: - Item size

    private func updateItemSize() {
        guard let scrollView = collectionView.enclosingScrollView else { return }
        let availableWidth = scrollView.contentSize.width
            - sectionInsets.left
            - sectionInsets.right
            - itemSpacing * (numberOfColumns - 1)
        let itemWidth = max(160, floor(availableWidth / numberOfColumns))
        flowLayout.itemSize = NSSize(width: itemWidth, height: cardHeight)
    }

    // MARK: - Window delegate

    public func windowDidResize(_ notification: Notification) {
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "resize",
            details: ["width": "\(Int(window?.frame.width ?? 0))", "height": "\(Int(window?.frame.height ?? 0))"]
        )
        updateItemSize()
        flowLayout.invalidateLayout()
        DiagnosticsLogbook.shared.actionOutput(feature: "history_window", action: "resize", details: ["success": "true"])
    }

    public func windowWillClose(_ notification: Notification) {
        DiagnosticsLogbook.shared.actionOutput(feature: "history_window", action: "close", details: ["success": "true"])
        onClose?()
    }

    /// Set by MenuBarController so it can nil its reference when the window closes,
    /// allowing this controller to be deallocated (stops background observers).
    var onClose: (() -> Void)?

    // MARK: - Keyboard

    public override func keyDown(with event: NSEvent) {
        // Enter / Return → paste selected card
        if event.keyCode == 36 || event.keyCode == 76 {
            if let indexPath = collectionView.selectionIndexPaths.first,
               indexPath.item < displayedEntries.count {
                paste(entry: displayedEntries[indexPath.item])
                return
            }
        }

        // ⌥1–⌥5 → paste card at that position (⌘1-5 is reserved by system)
        // kVK_ANSI_1=18, 2=19, 3=20, 4=21, 5=23 (non-contiguous — explicit map)
        let optionOnly = event.modifierFlags.intersection([.option, .command, .control, .shift]) == .option
        if optionOnly {
            let slotMap: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4]
            if let idx = slotMap[event.keyCode], idx < displayedEntries.count {
                collectionView.selectionIndexPaths = [IndexPath(item: idx, section: 0)]
                paste(entry: displayedEntries[idx])
                return
            }
        }

        // ⌘⇧V → queue paste (selected cards pasted sequentially on each ⌘V)
        let cmdShift = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if cmdShift == [.command, .shift], event.charactersIgnoringModifiers == "v" {
            queuePasteTapped()
            return
        }

        // ⌘R → refresh
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "r" {
            reloadData()
            return
        }

        super.keyDown(with: event)
    }

    @objc private func refreshTapped() {
        DiagnosticsLogbook.shared.actionInput(feature: "history_window", action: "refresh")
        reloadData()
        DiagnosticsLogbook.shared.actionOutput(feature: "history_window", action: "refresh", details: ["success": "true"])
    }

    @objc private func queuePasteTapped() {
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "queue_paste",
            details: ["selectedCount": "\(collectionView.selectionIndexPaths.count)"]
        )
        let selected = collectionView.selectionIndexPaths
            .sorted { $0.item < $1.item }
            .compactMap { displayedEntries[safe: $0.item] }
        guard !selected.isEmpty else {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "history_window",
                action: "queue_paste",
                details: ["success": "false", "reason": "empty_selection"]
            )
            return
        }
        DiagnosticsLogbook.shared.actionProcess(
            feature: "history_window",
            action: "queue_paste",
            details: ["step": "enqueue", "entryCount": "\(selected.count)"]
        )
        PasteQueue.shared.enqueue(selected)
        window?.orderOut(nil)
        // Re-activate the previous app so the user's ⌘V presses land in the right place.
        let target = previousApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let app = target, !app.isTerminated {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        DiagnosticsLogbook.shared.actionOutput(
            feature: "history_window",
            action: "queue_paste",
            details: ["success": "true", "entryCount": "\(selected.count)"]
        )
    }

    // MARK: - Paste

    /// Write `entry` to the pasteboard and synthesise ⌘V into the app that was
    /// active before history was opened.
    ///
    /// Order of operations matters:
    ///   1. Write data to pasteboard (before any window change).
    ///   2. Hide the history window.
    ///   3. Re-activate the previous app (so focus is back where it belongs).
    ///   4. Wait one run-loop tick for the activation to propagate.
    ///   5. Synthesise ⌘V at .cgSessionEventTap — it now lands in the right app.
    private func paste(entry: ClipEntry) {
        let startedAt = Date()
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "paste",
            details: [
                "entryType": entry.contentType.rawValue,
                "entrySourceApp": entry.sourceBundleID,
                "targetApp": previousApp?.bundleIdentifier ?? "unknown"
            ]
        )
        DiagnosticsLogbook.shared.record(
            "paste_requested",
            category: "interaction",
            details: [
                "source": "history_window",
                "entryType": entry.contentType.rawValue,
                "entrySourceApp": entry.sourceBundleID,
                "targetApp": previousApp?.bundleIdentifier ?? "unknown"
            ]
        )
        // Step 1: write to pasteboard while we still have focus.
        DiagnosticsLogbook.shared.actionProcess(feature: "history_window", action: "paste", details: ["step": "write_pasteboard"])
        ClipPasteboardWriter.write(entry)

        // Step 2: hide window.
        DiagnosticsLogbook.shared.actionProcess(feature: "history_window", action: "paste", details: ["step": "hide_window"])
        window?.orderOut(nil)

        // Step 3+4+5: re-activate target app, then synthesise paste.
        let target = previousApp
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let app = target, !app.isTerminated {
                app.activate(options: [.activateIgnoringOtherApps])
            }
            // Small second delay so the activation window change commits before ⌘V.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.synthesiseCmdV()
                DiagnosticsLogbook.shared.actionOutput(
                    feature: "history_window",
                    action: "paste",
                    details: [
                        "success": "true",
                        "durationMs": "\(Self.milliseconds(since: startedAt))"
                    ]
                )
            }
        }
    }

    private func synthesiseCmdV() {
        let source = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 0x09
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgSessionEventTap)
        DiagnosticsLogbook.shared.record(
            "synthetic_paste_posted",
            category: "interaction",
            details: ["targetApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"]
        )
    }

    private func copy(entry: ClipEntry) {
        let startedAt = Date()
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "copy",
            details: ["entryType": entry.contentType.rawValue, "entrySourceApp": entry.sourceBundleID]
        )
        DiagnosticsLogbook.shared.record(
            "copy_requested",
            category: "interaction",
            details: [
                "source": "history_window",
                "entryType": entry.contentType.rawValue,
                "entrySourceApp": entry.sourceBundleID
            ]
        )
        DiagnosticsLogbook.shared.actionProcess(feature: "history_window", action: "copy", details: ["step": "write_pasteboard"])
        ClipPasteboardWriter.write(entry)
        DiagnosticsLogbook.shared.actionOutput(
            feature: "history_window",
            action: "copy",
            details: ["success": "true", "durationMs": "\(Self.milliseconds(since: startedAt))"]
        )
    }

    private func togglePin(entry: ClipEntry, pinned: Bool) {
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "toggle_pin",
            details: ["entryType": entry.contentType.rawValue, "pinned": "\(pinned)"]
        )
        do {
            try store?.pin(entry.id, pinned: pinned)
        } catch {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "history_window",
                action: "toggle_pin",
                details: ["success": "false", "reason": "store_error"]
            )
            return
        }
        if let idx = allEntries.firstIndex(where: { $0.id == entry.id }) {
            allEntries[idx].isPinned = pinned
        }
        if let idx = displayedEntries.firstIndex(where: { $0.id == entry.id }) {
            displayedEntries[idx].isPinned = pinned
        }
        DiagnosticsLogbook.shared.actionOutput(
            feature: "history_window",
            action: "toggle_pin",
            details: ["success": "true", "pinned": "\(pinned)"]
        )
    }

    private func delete(entryID: UUID) {
        DiagnosticsLogbook.shared.actionInput(feature: "history_window", action: "delete", details: ["entryID": entryID.uuidString])
        do {
            try store?.delete(entryID)
        } catch {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "history_window",
                action: "delete",
                details: ["success": "false", "reason": "store_error"]
            )
            return
        }
        allEntries.removeAll { $0.id == entryID }
        applyFilters()
        DiagnosticsLogbook.shared.actionOutput(feature: "history_window", action: "delete", details: ["success": "true"])
    }
}

// MARK: - NSCollectionViewDataSource

extension ClipBookWindowController: NSCollectionViewDataSource {

    public func collectionView(
        _ collectionView: NSCollectionView,
        numberOfItemsInSection section: Int
    ) -> Int {
        displayedEntries.count
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        itemForRepresentedObjectAt indexPath: IndexPath
    ) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: ClipBookCardItem.reuseIdentifier,
            for: indexPath
        ) as! ClipBookCardItem

        let entry = displayedEntries[indexPath.item]
        item.configure(with: entry)

        item.onCopy   = { [weak self] e in self?.copy(entry: e) }
        item.onPin    = { [weak self] e, pinned in self?.togglePin(entry: e, pinned: pinned) }
        item.onPaste  = { [weak self] e in self?.paste(entry: e) }
        item.onDelete = { [weak self] id in self?.delete(entryID: id) }

        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension ClipBookWindowController: NSCollectionViewDelegate {

    public func collectionView(
        _ collectionView: NSCollectionView,
        didSelectItemsAt indexPaths: Set<IndexPath>
    ) {
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "select_cards",
            details: ["selectedCount": "\(indexPaths.count)"]
        )
        DiagnosticsLogbook.shared.actionOutput(
            feature: "history_window",
            action: "select_cards",
            details: ["success": "true", "selectedCount": "\(collectionView.selectionIndexPaths.count)"]
        )
        // Selection visualised by ClipBookCardItem.isSelected setter — nothing extra needed.
    }

    // NSDraggingDestination: accept drops to reorder pinned items
    public func collectionView(
        _ collectionView: NSCollectionView,
        validateDrop draggingInfo: any NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        proposedDropOperation.pointee = .before
        return .move
    }

    public func collectionView(
        _ collectionView: NSCollectionView,
        acceptDrop draggingInfo: any NSDraggingInfo,
        indexPath: IndexPath,
        dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "reorder_drop",
            details: ["destinationIndex": "\(indexPath.item)"]
        )
        // Pinned-item reordering: find the dragged entry and move it.
        // (Full persistence of order would require an order column in the DB;
        //  here we do an in-memory re-sort and update the view.)
        guard let pb = draggingInfo.draggingPasteboard.string(forType: .string),
              let srcIdx = displayedEntries.firstIndex(where: { $0.id.uuidString == pb })
        else {
            DiagnosticsLogbook.shared.actionOutput(
                feature: "history_window",
                action: "reorder_drop",
                details: ["success": "false", "reason": "missing_source"]
            )
            return false
        }

        DiagnosticsLogbook.shared.actionProcess(
            feature: "history_window",
            action: "reorder_drop",
            details: ["step": "move_entry", "sourceIndex": "\(srcIdx)", "destinationIndex": "\(indexPath.item)"]
        )
        var entries = displayedEntries
        let moving  = entries.remove(at: srcIdx)
        let dest    = min(indexPath.item, entries.count)
        entries.insert(moving, at: dest)
        displayedEntries = entries
        collectionView.reloadData()
        DiagnosticsLogbook.shared.actionOutput(
            feature: "history_window",
            action: "reorder_drop",
            details: ["success": "true", "sourceIndex": "\(srcIdx)", "destinationIndex": "\(dest)"]
        )
        return true
    }
}

// MARK: - NSCollectionViewDelegateFlowLayout

extension ClipBookWindowController: NSCollectionViewDelegateFlowLayout {

    public func collectionView(
        _ collectionView: NSCollectionView,
        layout collectionViewLayout: NSCollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> NSSize {
        // Recalculate each time to handle window resizes smoothly
        let available = collectionView.enclosingScrollView.map {
            $0.contentSize.width
        } ?? collectionView.bounds.width
        let usable = available
            - sectionInsets.left
            - sectionInsets.right
            - itemSpacing * (numberOfColumns - 1)
        let w = max(160, floor(usable / numberOfColumns))
        return NSSize(width: w, height: cardHeight)
    }
}

// MARK: - NSSearchFieldDelegate

extension ClipBookWindowController: NSSearchFieldDelegate {

    public func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSSearchField else { return }
        DiagnosticsLogbook.shared.actionInput(
            feature: "history_window",
            action: "search_text",
            details: ["queryLength": "\(field.stringValue.count)"]
        )
        searchQuery = field.stringValue
        applyFilters()
        DiagnosticsLogbook.shared.actionOutput(
            feature: "history_window",
            action: "search_text",
            details: ["success": "true", "queryLength": "\(searchQuery.count)"]
        )
    }
}

// MARK: - Safe subscript helper

private extension ClipBookWindowController {
    static func milliseconds(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1000)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - NSColor hex helper (module-private)

private extension NSColor {
    convenience init?(hex: String) {
        let raw = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard raw.count == 6 || raw.count == 8 else { return nil }
        var value: UInt64 = 0
        guard Scanner(string: raw).scanHexInt64(&value) else { return nil }
        let hasAlpha = raw.count == 8
        let r, g, b, a: CGFloat
        if hasAlpha {
            r = CGFloat((value >> 24) & 0xFF) / 255
            g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >>  8) & 0xFF) / 255
            a = CGFloat( value        & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255
            g = CGFloat((value >>  8) & 0xFF) / 255
            b = CGFloat( value        & 0xFF) / 255
            a = 1
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}
