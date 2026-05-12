import AppKit
import ClipLogCore
import WebKit

final class CursorPiPContentView: NSView, WKNavigationDelegate, WKScriptMessageHandler {
    private enum PlaybackMode {
        case embedShell
        case watchCrop
    }

    private enum Constants {
        static let appOrigin = "https://com.cmd.app"
        static let appBaseURL = URL(string: "https://com.cmd.app/")!
        static let cornerRadius: CGFloat = 22
    }

    private let webView: WKWebView
    private let chromeView = CursorPiPChromeView()
    private let interactionOverlay = CursorPiPInteractionOverlay()
    private let closeButton = NSButton()
    private let pinButton = NSButton()
    private let browserButton = NSButton()
    private let controlsView = NSView()
    private let backwardButton = NSButton()
    private let forwardButton = NSButton()
    private var currentCandidate: CursorPiPVideoCandidate?
    private var playbackMode: PlaybackMode = .embedShell
    private var hasTriedWatchCrop = false
    private var currentCornerRadius: CGFloat = Constants.cornerRadius
    private var currentEdgeBlur: CGFloat = 8
    private var chromeVisiblePreference = true
    private var isPointerInsideSurface = false
    private var isChromeRevealed = false
    private var hoverTrackingArea: NSTrackingArea?
    private var hoverRevealTimer: Timer?

    var onSubmitURL: ((String) -> Void)?
    var onClose: (() -> Void)?
    var onTogglePin: (() -> Void)?
    var onToggleFollow: (() -> Void)?
    var onSizePreset: ((CursorPiPSizePreset) -> Void)?
    var onOpenInBrowser: (() -> Void)?
    private(set) var currentOriginalURLString: String?

    var urlString: String {
        get { currentOriginalURLString ?? "" }
        set { currentOriginalURLString = newValue }
    }

    override init(frame frameRect: NSRect) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.userContentController.addUserScript(Self.viewportUserScript)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(frame: frameRect)
        webView.configuration.userContentController.add(self, name: "cursorPiP")
        setup()
    }

    required init?(coder: NSCoder) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.addUserScript(Self.viewportUserScript)
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init(coder: coder)
        webView.configuration.userContentController.add(self, name: "cursorPiP")
        setup()
    }

    deinit {
        hoverRevealTimer?.invalidate()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "cursorPiP")
    }

    override func layout() {
        super.layout()
        webView.frame = bounds
        chromeView.frame = bounds
        interactionOverlay.frame = bounds
        let top = bounds.height - 34
        closeButton.frame = NSRect(x: bounds.width - 34, y: top, width: 24, height: 24)
        pinButton.frame = NSRect(x: bounds.width - 64, y: top, width: 24, height: 24)
        browserButton.frame = NSRect(x: bounds.width - 94, y: top, width: 24, height: 24)
        layoutPlaybackControls()
        updateSurfaceMask()
    }

    func load(candidate: CursorPiPVideoCandidate) {
        currentCandidate = candidate
        currentOriginalURLString = candidate.originalURL.absoluteString
        playbackMode = .embedShell
        hasTriedWatchCrop = false
        loadEmbedShell(candidate)
    }

    func pausePlayback() {
        webView.evaluateJavaScript("""
        document.querySelectorAll('video,audio').forEach(media => {
          try { media.pause(); } catch (_) {}
          try { media.muted = true; } catch (_) {}
          try { media.src = ''; media.load(); } catch (_) {}
        });
        document.querySelectorAll('iframe').forEach(frame => {
          try { frame.src = 'about:blank'; } catch (_) {}
        });
        """, completionHandler: nil)
        webView.stopLoading()
        webView.loadHTMLString("<!doctype html><html><body style='background:#000'></body></html>", baseURL: nil)
    }

    func updateState(following: Bool, pinned: Bool) {
        pinButton.contentTintColor = pinned ? .systemOrange : .white
    }

    func applyAppearance(cornerRadius: CGFloat, edgeBlur: CGFloat, opacity: Double, chromeVisible: Bool) {
        currentCornerRadius = cornerRadius
        currentEdgeBlur = edgeBlur
        chromeVisiblePreference = chromeVisible
        alphaValue = opacity
        updateSurfaceMask()
        updateChromeVisibility(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInsideSurface = true
        scheduleChromeReveal()
    }

    override func mouseMoved(with event: NSEvent) {
        guard isPointerInsideSurface else { return }
        if !isChromeRevealed {
            scheduleChromeReveal()
        }
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInsideSurface = false
        hoverRevealTimer?.invalidate()
        hoverRevealTimer = nil
        isChromeRevealed = false
        updateChromeVisibility(animated: true)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = 0
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = false

        webView.navigationDelegate = self
        webView.wantsLayer = true
        webView.layer?.backgroundColor = NSColor.black.cgColor
        webView.layer?.cornerRadius = 0
        webView.layer?.cornerCurve = .continuous
        webView.layer?.masksToBounds = false
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        webView.setValue(false, forKey: "drawsBackground")
        addSubview(webView)

        chromeView.autoresizingMask = [.width, .height]
        addSubview(chromeView)

        interactionOverlay.autoresizingMask = [.width, .height]
        interactionOverlay.prefersBroadDrag = { [weak self] in
            guard let self else { return false }
            return self.chromeVisiblePreference && !self.isChromeRevealed
        }
        addSubview(interactionOverlay)

        configureOverlayButton(browserButton, symbol: "safari", tooltip: "Open in browser", action: #selector(openInBrowser))
        configureOverlayButton(pinButton, symbol: "pin.fill", tooltip: "Pin", action: #selector(togglePin))
        configureOverlayButton(closeButton, symbol: "xmark", tooltip: "Close", action: #selector(close))
        configurePlaybackControls()
        applyAppearance(
            cornerRadius: CGFloat(ClipLogSettings.shared.cursorPiPCornerRadius),
            edgeBlur: CGFloat(ClipLogSettings.shared.cursorPiPEdgeBlur),
            opacity: ClipLogSettings.shared.cursorPiPOpacity,
            chromeVisible: ClipLogSettings.shared.cursorPiPChromeVisible
        )
    }

    private func configureOverlayButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.isBordered = false
        button.contentTintColor = .white
        button.alphaValue = 0.9
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
        button.layer?.cornerRadius = 12
        button.target = self
        button.action = action
        button.toolTip = tooltip
        addSubview(button)
    }

    private func configurePlaybackControls() {
        controlsView.wantsLayer = true
        controlsView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
        controlsView.layer?.cornerRadius = 17
        controlsView.layer?.cornerCurve = .continuous
        addSubview(controlsView)

        configureControlButton(backwardButton, symbol: "gobackward.10", tooltip: "Back 10 seconds", action: #selector(skipBackward))
        configureControlButton(forwardButton, symbol: "goforward.10", tooltip: "Forward 10 seconds", action: #selector(skipForward))
    }

    private func configureControlButton(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.isBordered = false
        button.contentTintColor = .white
        button.alphaValue = 0.95
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor
        button.target = self
        button.action = action
        button.toolTip = tooltip
        controlsView.addSubview(button)
    }

    private func layoutPlaybackControls() {
        let controlWidth: CGFloat = 84
        let controlHeight: CGFloat = 34
        controlsView.frame = NSRect(
            x: 14,
            y: 14,
            width: controlWidth,
            height: controlHeight
        )

        let buttonSize: CGFloat = 28
        let y = (controlHeight - buttonSize) / 2
        backwardButton.frame = NSRect(x: 8, y: y, width: buttonSize, height: buttonSize)
        forwardButton.frame = NSRect(x: 44, y: y, width: buttonSize, height: buttonSize)
    }

    @objc private func close() {
        onClose?()
    }

    @objc private func togglePin() {
        onTogglePin?()
    }

    @objc private func openInBrowser() {
        onOpenInBrowser?()
    }

    @objc private func skipBackward() {
        evaluatePlayerCommand("seekBy", value: -10)
    }

    @objc private func skipForward() {
        evaluatePlayerCommand("seekBy", value: 10)
    }

    private func scheduleChromeReveal() {
        hoverRevealTimer?.invalidate()
        hoverRevealTimer = Timer.scheduledTimer(withTimeInterval: 0.24, repeats: false) { [weak self] _ in
            guard let self, self.isPointerInsideSurface else { return }
            self.isChromeRevealed = true
            self.updateChromeVisibility(animated: true)
        }
    }

    private func updateChromeVisibility(animated: Bool) {
        let shouldShow = chromeVisiblePreference && isChromeRevealed
        chromeView.isHidden = !chromeVisiblePreference

        if !chromeVisiblePreference {
            closeButton.isHidden = true
            pinButton.isHidden = true
            browserButton.isHidden = true
            controlsView.isHidden = true
            closeButton.alphaValue = 0
            pinButton.alphaValue = 0
            browserButton.alphaValue = 0
            controlsView.alphaValue = 0
            return
        }

        closeButton.isHidden = false
        pinButton.isHidden = false
        browserButton.isHidden = false
        controlsView.isHidden = false

        let alpha: CGFloat = shouldShow ? 1 : 0
        let updates = {
            self.closeButton.alphaValue = alpha
            self.pinButton.alphaValue = alpha
            self.browserButton.alphaValue = alpha
            self.controlsView.alphaValue = alpha
            self.chromeView.alphaValue = shouldShow ? 1 : 0.25
        }

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                self.closeButton.animator().alphaValue = alpha
                self.pinButton.animator().alphaValue = alpha
                self.browserButton.animator().alphaValue = alpha
                self.controlsView.animator().alphaValue = alpha
                self.chromeView.animator().alphaValue = shouldShow ? 1 : 0.25
            }
        } else {
            updates()
        }
    }

    private func updateSurfaceMask() {
        guard bounds.width > 0,
              bounds.height > 0,
              let layer
        else { return }

        let radius = CursorPiPGeometry.clampedRadius(cornerRadius: currentCornerRadius, size: bounds.size)
        let edgeBlur = CursorPiPGeometry.clampedEdgeBlur(edgeBlur: currentEdgeBlur, size: bounds.size)
        webView.layer?.cornerRadius = edgeBlur == 0 ? radius : 0
        webView.layer?.masksToBounds = edgeBlur == 0

        if edgeBlur == 0 {
            layer.mask = nil
            layer.cornerRadius = radius
            layer.cornerCurve = .continuous
            layer.masksToBounds = true
            return
        }

        layer.cornerRadius = 0
        layer.masksToBounds = false
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        guard let image = CursorPiPSoftMask.make(
            size: bounds.size,
            radius: radius,
            edgeBlur: edgeBlur,
            scale: scale
        ) else { return }

        let mask = layer.mask ?? CALayer()
        mask.frame = bounds
        mask.contentsScale = scale
        mask.contentsGravity = .resize
        mask.contents = image
        layer.mask = mask
    }

    private func loadEmbedShell(_ candidate: CursorPiPVideoCandidate) {
        let html = Self.embedShellHTML(embedURL: candidate.embedURL)
        webView.loadHTMLString(html, baseURL: Constants.appBaseURL)
    }

    private func loadWatchCrop(_ candidate: CursorPiPVideoCandidate) {
        playbackMode = .watchCrop
        var request = URLRequest(url: candidate.watchURL)
        request.setValue("\(Constants.appOrigin)/", forHTTPHeaderField: "Referer")
        webView.load(request)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        switch playbackMode {
        case .embedShell:
            break
        case .watchCrop:
            webView.evaluateJavaScript(Self.watchCropScript, completionHandler: nil)
        }
    }

    private func evaluatePlayerCommand(_ command: String, value: Double? = nil) {
        let script = Self.playerCommandScript(command: command, value: value)
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "cursorPiP",
              let payload = message.body as? [String: Any],
              payload["event"] as? String == "youtubeError"
        else { return }
        let code = payload["code"] as? String
        if ["101", "150", "153"].contains(code) {
            fallbackToWatchCropIfNeeded()
        }
    }

    private func fallbackToWatchCropIfNeeded() {
        guard !hasTriedWatchCrop,
              let currentCandidate
        else { return }
        hasTriedWatchCrop = true
        loadWatchCrop(currentCandidate)
    }

    private static let viewportUserScript = WKUserScript(
        source: """
        const style = document.createElement('style');
        style.textContent = 'html,body{background:#000!important;}';
        document.documentElement.appendChild(style);
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true
    )

    private static func playerCommandScript(command: String, value: Double?) -> String {
        let valueLiteral = value.map { String($0) } ?? "null"
        let commandLiteral = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        (() => {
          const command = "\(commandLiteral)";
          const value = \(valueLiteral);
          try {
            if (window.player && typeof window.player.getCurrentTime === "function") {
              if (command === "toggle") {
                const state = window.player.getPlayerState?.();
                if (state === 1) window.player.pauseVideo?.();
                else window.player.playVideo?.();
              }
              if (command === "seekBy") {
                const next = Math.max(0, Number(window.player.getCurrentTime() || 0) + Number(value || 0));
                window.player.seekTo?.(next, true);
              }
              if (command === "seekTo") {
                window.player.seekTo?.(Math.max(0, Number(value || 0)), true);
              }
              if (command === "volume") {
                window.player.setVolume?.(Math.max(0, Math.min(100, Number(value || 0) * 100)));
                window.player.unMute?.();
              }
              return true;
            }
            const media = document.querySelector("video,audio");
            if (!media) return false;
            if (command === "toggle") {
              if (media.paused) media.play().catch(() => {});
              else media.pause();
            }
            if (command === "seekBy") {
              media.currentTime = Math.max(0, Number(media.currentTime || 0) + Number(value || 0));
            }
            if (command === "seekTo") {
              media.currentTime = Math.max(0, Number(value || 0));
            }
            if (command === "volume") {
              media.volume = Math.max(0, Math.min(1, Number(value || 0)));
              media.muted = false;
            }
            return true;
          } catch (_) {
            return false;
          }
        })();
        """
    }

    private static func embedShellHTML(embedURL: URL) -> String {
        let escapedURL = embedURL.absoluteString
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1.0, viewport-fit=cover">
          <style>
            html, body {
              width: 100%;
              height: 100%;
              margin: 0;
              overflow: hidden;
              background: #000;
            }
            #player {
              position: fixed;
              inset: 0;
              width: 100vw;
              height: 100vh;
              border: 0;
              background: #000;
            }
          </style>
        </head>
        <body>
          <iframe
            id="player"
            src="\(escapedURL)"
            title="YouTube"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture; web-share"
            allowfullscreen
            referrerpolicy="strict-origin-when-cross-origin">
          </iframe>
          <script src="https://www.youtube.com/iframe_api"></script>
          <script>
            window.player = null;
            function onYouTubeIframeAPIReady() {
              window.player = new YT.Player('player', {
                events: {
                  onReady: event => {
                    try { event.target.playVideo(); } catch (_) {}
                  },
                  onError: event => {
                    window.webkit?.messageHandlers?.cursorPiP?.postMessage({
                      event: 'youtubeError',
                      code: String(event.data || '')
                    });
                  }
                }
              });
            }
          </script>
        </body>
        </html>
        """
    }

    private static let watchCropScript = """
    (() => {
      if (window.__cmdCursorPiPInstalled) {
        window.__cmdCursorPiPApply?.();
        return;
      }
      window.__cmdCursorPiPInstalled = true;
      const css = `
        html, body {
          margin: 0 !important;
          overflow: hidden !important;
          background: #000 !important;
        }
        ytd-app, #content, #page-manager, ytd-watch-flexy {
          background: #000 !important;
        }
        ytd-masthead,
        #secondary,
        #below,
        #comments,
        #chat,
        ytd-watch-metadata,
        ytd-merch-shelf-renderer,
        ytd-playlist-panel-renderer,
        #related,
        #clarify-box,
        #alerts,
        tp-yt-paper-dialog,
        ytd-popup-container {
          display: none !important;
          visibility: hidden !important;
        }
        #primary,
        #primary-inner,
        #player,
        #player-container-outer,
        #player-container-inner,
        #player-container,
        #movie_player,
        .html5-video-player,
        video {
          position: fixed !important;
          inset: 0 !important;
          width: 100vw !important;
          height: 100vh !important;
          max-width: none !important;
          max-height: none !important;
          margin: 0 !important;
          padding: 0 !important;
          background: #000 !important;
        }
        video {
          object-fit: contain !important;
        }
      `;
      let style = document.getElementById('cmd-cursor-pip-style');
      if (!style) {
        style = document.createElement('style');
        style.id = 'cmd-cursor-pip-style';
        document.documentElement.appendChild(style);
      }
      style.textContent = css;
      document.querySelectorAll('video').forEach(video => {
        video.setAttribute('playsinline', '1');
        video.play().catch(() => {});
      });
      window.__cmdCursorPiPApply = () => {
        document.querySelectorAll('video').forEach(video => {
          video.setAttribute('playsinline', '1');
          video.play().catch(() => {});
        });
      };
      new MutationObserver(() => window.__cmdCursorPiPApply())
        .observe(document.documentElement, { childList: true, subtree: true });
    })();
    """
}

private final class CursorPiPChromeView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds
        let gradientHeight = min(88, rect.height * 0.42)
        let topRect = CGRect(x: 0, y: rect.maxY - gradientHeight, width: rect.width, height: gradientHeight)
        let bottomRect = CGRect(x: 0, y: 0, width: rect.width, height: min(54, rect.height * 0.28))

        drawGradient(in: topRect, alphaTop: 0.52, alphaBottom: 0.0, context: context)
        drawGradient(in: bottomRect, alphaTop: 0.0, alphaBottom: 0.34, context: context)
    }

    private func drawGradient(in rect: CGRect, alphaTop: CGFloat, alphaBottom: CGFloat, context: CGContext) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                NSColor.black.withAlphaComponent(alphaBottom).cgColor,
                NSColor.black.withAlphaComponent(alphaTop).cgColor
            ] as CFArray,
            locations: [0, 1]
        ) else { return }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: rect.midX, y: rect.minY),
            end: CGPoint(x: rect.midX, y: rect.maxY),
            options: []
        )
    }
}

private final class CursorPiPInteractionOverlay: NSView {
    private enum Zone {
        case drag
        case north
        case south
        case east
        case west
        case northEast
        case northWest
        case southEast
        case southWest

        var includesNorth: Bool {
            switch self {
            case .north, .northEast, .northWest: return true
            default: return false
            }
        }

        var includesSouth: Bool {
            switch self {
            case .south, .southEast, .southWest: return true
            default: return false
            }
        }

        var includesEast: Bool {
            switch self {
            case .east, .northEast, .southEast: return true
            default: return false
            }
        }

        var includesWest: Bool {
            switch self {
            case .west, .northWest, .southWest: return true
            default: return false
            }
        }
    }

    private enum Constants {
        static let edgeWidth: CGFloat = 14
        static let cornerSize: CGFloat = 44
        static let aspectRatio: CGFloat = 16.0 / 9.0
    }

    private var activeZone: Zone?
    private var startFrame: NSRect = .zero
    private var startPointer: NSPoint = .zero
    var prefersBroadDrag: (() -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden,
              alphaValue > 0,
              zone(at: point) != nil
        else { return nil }
        return self
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(dragRect, cursor: .openHand)
        addCursorRect(northRect, cursor: .resizeUpDown)
        addCursorRect(southRect, cursor: .resizeUpDown)
        addCursorRect(eastRect, cursor: .resizeLeftRight)
        addCursorRect(westRect, cursor: .resizeLeftRight)
        addCursorRect(northEastRect, cursor: Self.northEastSouthWestCursor)
        addCursorRect(southWestRect, cursor: Self.northEastSouthWestCursor)
        addCursorRect(northWestRect, cursor: Self.northWestSouthEastCursor)
        addCursorRect(southEastRect, cursor: Self.northWestSouthEastCursor)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        activeZone = zone(at: convert(event.locationInWindow, from: nil))
        startFrame = window.frame
        startPointer = NSEvent.mouseLocation
        if activeZone == .drag {
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let activeZone
        else { return }

        let pointer = NSEvent.mouseLocation
        let delta = NSPoint(x: pointer.x - startPointer.x, y: pointer.y - startPointer.y)
        let nextFrame: NSRect
        switch activeZone {
        case .drag:
            nextFrame = clampedToVisibleScreen(NSRect(
                x: startFrame.origin.x + delta.x,
                y: startFrame.origin.y + delta.y,
                width: startFrame.width,
                height: startFrame.height
            ))
        default:
            nextFrame = resizedFrame(zone: activeZone, delta: delta, minSize: window.minSize)
        }
        window.setFrame(nextFrame, display: false)
        window.contentView?.layoutSubtreeIfNeeded()
        window.invalidateShadow()
    }

    override func mouseUp(with event: NSEvent) {
        activeZone = nil
        NSCursor.arrow.set()
    }

    override func mouseExited(with event: NSEvent) {
        if activeZone == nil {
            NSCursor.arrow.set()
        }
    }

    private func zone(at point: NSPoint) -> Zone? {
        if northEastRect.contains(point) { return .northEast }
        if northWestRect.contains(point) { return .northWest }
        if southEastRect.contains(point) { return .southEast }
        if southWestRect.contains(point) { return .southWest }
        if northRect.contains(point) { return .north }
        if southRect.contains(point) { return .south }
        if eastRect.contains(point) { return .east }
        if westRect.contains(point) { return .west }
        if prefersBroadDrag?() == true,
           broadDragRect.contains(point) {
            return .drag
        }
        if dragRect.contains(point) { return .drag }
        return nil
    }

    private func resizedFrame(zone: Zone, delta: NSPoint, minSize: NSSize) -> NSRect {
        let minWidth = max(minSize.width, minSize.height * Constants.aspectRatio)
        let minHeight = max(minSize.height, minWidth / Constants.aspectRatio)
        var width = startFrame.width
        var height = startFrame.height

        if zone.includesEast {
            width = startFrame.width + delta.x
        } else if zone.includesWest {
            width = startFrame.width - delta.x
        }

        if zone.includesNorth {
            height = startFrame.height + delta.y
        } else if zone.includesSouth {
            height = startFrame.height - delta.y
        }

        if zone.includesEast || zone.includesWest {
            height = width / Constants.aspectRatio
        }
        if (zone.includesNorth || zone.includesSouth)
            && !(zone.includesEast || zone.includesWest) {
            width = height * Constants.aspectRatio
        }
        if (zone.includesNorth || zone.includesSouth)
            && (zone.includesEast || zone.includesWest)
            && abs(delta.y) > abs(delta.x / Constants.aspectRatio) {
            width = height * Constants.aspectRatio
        }

        width = max(minWidth, width)
        height = max(minHeight, width / Constants.aspectRatio)

        var frame = NSRect(origin: startFrame.origin, size: NSSize(width: width, height: height))
        if zone.includesWest {
            frame.origin.x = startFrame.maxX - width
        }
        if zone.includesSouth {
            frame.origin.y = startFrame.maxY - height
        }
        if (zone.includesNorth || zone.includesSouth)
            && !(zone.includesEast || zone.includesWest) {
            frame.origin.x = startFrame.midX - width / 2
        }
        if (zone.includesEast || zone.includesWest)
            && !(zone.includesNorth || zone.includesSouth) {
            frame.origin.y = startFrame.midY - height / 2
        }
        return clampedToVisibleScreen(frame)
    }

    private var dragRect: NSRect {
        NSRect(
            x: Constants.cornerSize,
            y: bounds.maxY - 52,
            width: max(0, bounds.width - Constants.cornerSize * 2),
            height: 52
        )
    }

    private var broadDragRect: NSRect {
        bounds.insetBy(dx: Constants.edgeWidth, dy: Constants.edgeWidth)
    }

    private var northRect: NSRect {
        NSRect(
            x: Constants.cornerSize,
            y: bounds.maxY - Constants.edgeWidth,
            width: max(0, bounds.width - Constants.cornerSize * 2),
            height: Constants.edgeWidth
        )
    }

    private var southRect: NSRect {
        NSRect(
            x: Constants.cornerSize,
            y: 0,
            width: max(0, bounds.width - Constants.cornerSize * 2),
            height: Constants.edgeWidth
        )
    }

    private var eastRect: NSRect {
        NSRect(
            x: bounds.maxX - Constants.edgeWidth,
            y: Constants.cornerSize,
            width: Constants.edgeWidth,
            height: max(0, bounds.height - Constants.cornerSize * 2)
        )
    }

    private var westRect: NSRect {
        NSRect(
            x: 0,
            y: Constants.cornerSize,
            width: Constants.edgeWidth,
            height: max(0, bounds.height - Constants.cornerSize * 2)
        )
    }

    private var northEastRect: NSRect {
        NSRect(
            x: bounds.maxX - Constants.cornerSize,
            y: bounds.maxY - Constants.cornerSize,
            width: Constants.cornerSize,
            height: Constants.cornerSize
        )
    }

    private var northWestRect: NSRect {
        NSRect(
            x: 0,
            y: bounds.maxY - Constants.cornerSize,
            width: Constants.cornerSize,
            height: Constants.cornerSize
        )
    }

    private var southEastRect: NSRect {
        NSRect(
            x: bounds.maxX - Constants.cornerSize,
            y: 0,
            width: Constants.cornerSize,
            height: Constants.cornerSize
        )
    }

    private var southWestRect: NSRect {
        NSRect(x: 0, y: 0, width: Constants.cornerSize, height: Constants.cornerSize)
    }

    private func clampedToVisibleScreen(_ frame: NSRect) -> NSRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }
        var next = frame
        if next.width > visible.width {
            next.size.width = visible.width
            next.size.height = next.width / Constants.aspectRatio
        }
        if next.height > visible.height {
            next.size.height = visible.height
            next.size.width = next.height * Constants.aspectRatio
        }
        next.origin.x = min(max(next.origin.x, visible.minX), visible.maxX - next.width)
        next.origin.y = min(max(next.origin.y, visible.minY), visible.maxY - next.height)
        return next
    }

    private static let northWestSouthEastCursor = diagonalCursor(flipped: false)
    private static let northEastSouthWestCursor = diagonalCursor(flipped: true)

    private static func diagonalCursor(flipped: Bool) -> NSCursor {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        let path = NSBezierPath()
        path.lineCapStyle = .round
        if flipped {
            path.move(to: NSPoint(x: 4, y: 14))
            path.line(to: NSPoint(x: 14, y: 4))
        } else {
            path.move(to: NSPoint(x: 4, y: 4))
            path.line(to: NSPoint(x: 14, y: 14))
        }
        NSColor.black.withAlphaComponent(0.85).setStroke()
        path.lineWidth = 4
        path.stroke()
        NSColor.white.setStroke()
        path.lineWidth = 2
        path.stroke()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: NSPoint(x: 9, y: 9))
    }
}

private enum CursorPiPSoftMask {
    static func make(size: CGSize, radius: CGFloat, edgeBlur: CGFloat, scale: CGFloat) -> CGImage? {
        let pixelWidth = max(1, Int((size.width * scale).rounded(.up)))
        let pixelHeight = max(1, Int((size.height * scale).rounded(.up)))
        let bytesPerPixel = 4
        let bytesPerRow = pixelWidth * bytesPerPixel
        let pointScale = max(scale, 0.001)
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let clampedRadius = CursorPiPGeometry.clampedRadius(cornerRadius: radius, size: size)
        let clampedBlur = CursorPiPGeometry.clampedEdgeBlur(edgeBlur: edgeBlur, size: size)

        var pixels = [UInt8](repeating: 0, count: pixelHeight * bytesPerRow)
        for y in 0..<pixelHeight {
            let pointY = (CGFloat(y) + 0.5) / pointScale
            let centeredY = pointY - halfHeight
            for x in 0..<pixelWidth {
                let pointX = (CGFloat(x) + 0.5) / pointScale
                let centeredX = pointX - halfWidth
                let signedDistance = roundedRectangleSignedDistance(
                    point: CGPoint(x: centeredX, y: centeredY),
                    halfSize: CGSize(width: halfWidth, height: halfHeight),
                    radius: clampedRadius
                )
                let alpha = maskAlpha(signedDistance: signedDistance, edgeBlur: clampedBlur)
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels[offset] = 255
                pixels[offset + 1] = 255
                pixels[offset + 2] = 255
                pixels[offset + 3] = UInt8((alpha * 255).rounded().clamped(to: 0...255))
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func roundedRectangleSignedDistance(
        point: CGPoint,
        halfSize: CGSize,
        radius: CGFloat
    ) -> CGFloat {
        let qx = abs(point.x) - halfSize.width + radius
        let qy = abs(point.y) - halfSize.height + radius
        let outsideX = max(qx, 0)
        let outsideY = max(qy, 0)
        let outsideDistance = sqrt(outsideX * outsideX + outsideY * outsideY)
        let insideDistance = min(max(qx, qy), 0)
        return outsideDistance + insideDistance - radius
    }

    private static func maskAlpha(signedDistance: CGFloat, edgeBlur: CGFloat) -> CGFloat {
        guard edgeBlur > 0 else {
            return signedDistance <= 0 ? 1 : 0
        }
        let t = ((-signedDistance) / edgeBlur).clamped(to: 0...1)
        return t * t * (3 - 2 * t)
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
