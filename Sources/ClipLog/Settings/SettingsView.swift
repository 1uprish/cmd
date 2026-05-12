import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ClipLogCore

public struct SettingsView: View {

    @ObservedObject private var settings = ClipLogSettings.shared

    // All modal state at the top level so SwiftUI can find the window context
    @State private var showClearConfirm  = false
    @State private var clearResult: String? = nil
    @State private var transitionPreviewToken = 0

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                triggerCard
                appearanceCard
                cursorPiPCard
                privacyCard
                storageCard
                diagnosticsCard
                generalCard
            }
            .padding(22)
        }
        .frame(width: 500)
        // Confirmation dialog must live at body level to attach to the window
        .alert("Clear all clipboard history?", isPresented: $showClearConfirm) {
            Button("Clear All", role: .destructive) {
                NotificationCenter.default.post(name: .cmdClearAllHistory, object: nil)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pinned items will not be removed. This cannot be undone.")
        }
    }

    // MARK: - Card shell

    private func card<Content: View>(
        _ title: String,
        icon: String,
        color: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.72))

            Divider()

            // Body
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.96))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 0.5)
        )
    }

    // MARK: - Trigger

    private var triggerCard: some View {
        card("Trigger", icon: "hand.tap.fill", color: .secondary) {
            row(label: "Hold ⌘V for") {
                Text("\(settings.holdThresholdMs) ms")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
            }
            Slider(
                value: Binding(
                    get: { Double(settings.holdThresholdMs) },
                    set: { settings.holdThresholdMs = Int($0) }
                ),
                in: 100...500, step: 50
            )
            HStack {
                Text("100 ms").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("500 ms").font(.caption2).foregroundStyle(.tertiary)
            }
            note("Quick tap pastes normally. Hold longer to reveal clipboard history.")
        }
    }

    // MARK: - HUD Appearance

    private var appearanceCard: some View {
        card("HUD Appearance", icon: "rectangle.inset.filled", color: .secondary) {
            row(label: "Card opacity") {
                Text(String(format: "%.0f%%", settings.hudOpacity * 100))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 44, alignment: .trailing)
            }

            Slider(
                value: Binding(
                    get: { settings.hudOpacity },
                    set: { settings.hudOpacity = $0 }
                ),
                in: 0.55...1.0, step: 0.05
            )

            HStack {
                Text("Transparent").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("Solid glass").font(.caption2).foregroundStyle(.tertiary)
            }

            Divider()

            row(label: "HUD size") {
                Text("\(hudSizeName) · \(String(format: "%.0f%%", settings.hudSizeScale * 100))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 132, alignment: .trailing)
            }

            Picker("HUD size", selection: hudSizePresetBinding) {
                Text("Compact").tag(0.90)
                Text("Standard").tag(1.00)
                Text("Large").tag(1.12)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 10) {
                Image(systemName: "textformat.size.smaller")
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
                Slider(
                    value: Binding(
                        get: { settings.hudSizeScale },
                        set: { settings.hudSizeScale = $0 }
                    ),
                    in: 0.85...1.20, step: 0.01
                )
                Image(systemName: "textformat.size.larger")
                    .foregroundStyle(.tertiary)
                    .frame(width: 18)
            }

            HStack {
                Text("Smaller cards").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text("Larger cards").font(.caption2).foregroundStyle(.tertiary)
            }

            Divider()

            row(label: "Visible rows") {
                Text("6 with scroll")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            note("Size changes keep the card proportions, text, icons, spacing, and scrollbar gutter aligned.")

            Divider()

            row(label: "Transition") {
                Text(hudTransitionName)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 96, alignment: .trailing)
            }

            Picker("Transition", selection: Binding(
                get: { settings.hudAnimationStyle },
                set: {
                    settings.hudAnimationStyle = $0
                    transitionPreviewToken += 1
                }
            )) {
                Text("Magnetic").tag("magnetic")
                Text("Genie").tag("genie")
                Text("Cascade").tag("cascade")
                Text("Calm").tag("calm")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            note(hudTransitionDescription)

            HStack {
                Text("Live preview")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    transitionPreviewToken += 1
                } label: {
                    Label("Replay", systemImage: "play.circle")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            hudLivePreview

            note("Preview uses the same scale, opacity, and motion setting as the real HUD.")
        }
    }

    private var hudSizeName: String {
        switch settings.hudSizeScale {
        case ..<0.96:
            return "Compact"
        case 1.06...:
            return "Large"
        default:
            return "Standard"
        }
    }

    private var hudSizePresetBinding: Binding<Double> {
        Binding(
            get: {
                let value = settings.hudSizeScale
                let presets = [0.90, 1.00, 1.12]
                return presets.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1.00
            },
            set: { settings.hudSizeScale = $0 }
        )
    }

    private var hudTransitionName: String {
        switch settings.hudAnimationStyle {
        case "genie": return "Genie"
        case "cascade": return "Cascade"
        case "calm": return "Calm"
        default: return "Magnetic"
        }
    }

    private var hudTransitionDescription: String {
        switch settings.hudAnimationStyle {
        case "genie":
            return "Strongly pulls cards out from the cursor and squeezes them back into it."
        case "cascade":
            return "Cards arrive in a quick ordered cascade while the panel blooms from the cursor."
        case "calm":
            return "Uses a quieter fade and scale for a restrained, low-motion feel."
        default:
            return "Default. The HUD blooms from the cursor and collapses back into the same point."
        }
    }

    private var hudLivePreview: some View {
        HUDTransitionPreview(
            style: settings.hudAnimationStyle,
            opacity: settings.hudOpacity,
            sizeScale: CGFloat(settings.hudSizeScale),
            replayToken: transitionPreviewToken
        )
        .frame(maxWidth: .infinity)
        .frame(height: 258 * CGFloat(settings.hudSizeScale))
    }

    // MARK: - CursorPiP Beta

    private var cursorPiPCard: some View {
        card("CursorPiP Beta", icon: "pip.fill", color: .secondary) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enable CursorPiP")
                        .font(.body)
                    Text("YouTube first. CMD stays clipboard-first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settings.cursorPiPEnabled },
                    set: { settings.cursorPiPEnabled = $0 }
                ))
                .labelsHidden()
            }

            Toggle("Suggest PiP after copying YouTube links", isOn: Binding(
                get: { settings.cursorPiPAutoSuggest },
                set: { settings.cursorPiPAutoSuggest = $0 }
            ))
            .disabled(!settings.cursorPiPEnabled)

            HStack {
                Toggle("Pinned", isOn: Binding(
                    get: { settings.cursorPiPPinned },
                    set: { settings.cursorPiPPinned = $0 }
                ))
                .disabled(!settings.cursorPiPEnabled)
            }

            Divider()

            row(label: "Offset X") {
                Text("\(Int(settings.cursorPiPOffsetX)) px")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 70, alignment: .trailing)
            }
            Slider(value: Binding(
                get: { settings.cursorPiPOffsetX },
                set: { settings.cursorPiPOffsetX = $0 }
            ), in: -240...240, step: 4)
            .disabled(!settings.cursorPiPEnabled)

            row(label: "Offset Y") {
                Text("\(Int(settings.cursorPiPOffsetY)) px")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 70, alignment: .trailing)
            }
            Slider(value: Binding(
                get: { settings.cursorPiPOffsetY },
                set: { settings.cursorPiPOffsetY = $0 }
            ), in: -240...240, step: 4)
            .disabled(!settings.cursorPiPEnabled)

            HStack {
                Button("Small") {
                    applyCursorPiPSize(.small)
                }
                Button("Medium") {
                    applyCursorPiPSize(.medium)
                }
                Button("Large") {
                    applyCursorPiPSize(.large)
                }
            }
            .disabled(!settings.cursorPiPEnabled)

            Divider()

            Toggle("Show hover controls", isOn: Binding(
                get: { settings.cursorPiPChromeVisible },
                set: { settings.cursorPiPChromeVisible = $0 }
            ))
            .disabled(!settings.cursorPiPEnabled)

            row(label: "Corner radius") {
                Text("\(Int(settings.cursorPiPCornerRadius)) px")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 70, alignment: .trailing)
            }
            Slider(value: Binding(
                get: { settings.cursorPiPCornerRadius },
                set: { settings.cursorPiPCornerRadius = $0 }
            ), in: 0...140, step: 1)
            .disabled(!settings.cursorPiPEnabled)

            row(label: "Edge blend") {
                Text("\(Int(settings.cursorPiPEdgeBlur)) px")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 70, alignment: .trailing)
            }
            Slider(value: Binding(
                get: { settings.cursorPiPEdgeBlur },
                set: { settings.cursorPiPEdgeBlur = $0 }
            ), in: 0...48, step: 1)
            .disabled(!settings.cursorPiPEnabled)

            row(label: "Panel opacity") {
                Text("\(Int(settings.cursorPiPOpacity * 100))%")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .frame(width: 70, alignment: .trailing)
            }
            Slider(value: Binding(
                get: { settings.cursorPiPOpacity },
                set: { settings.cursorPiPOpacity = $0 }
            ), in: 0.55...1.0, step: 0.05)
            .disabled(!settings.cursorPiPEnabled)

            note("YouTube and open-web video use the native CMD panel. OTT services use Chrome PiP where DRM requires it.")
        }
    }

    // MARK: - Privacy

    private var privacyCard: some View {
        card("Privacy", icon: "lock.shield.fill", color: .secondary) {
            if settings.userExcludedBundles.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text("Clipboard captured from all apps")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(settings.userExcludedBundles, id: \.self) { bundle in
                        HStack {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(bundle)
                                .font(.system(.callout, design: .monospaced))
                            Spacer()
                            Button {
                                settings.userExcludedBundles.removeAll { $0 == bundle }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.title3)
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(bundle) from exclusion list")
                        }
                        .padding(.vertical, 2)
                    }
                }
                Divider()
            }

            Divider()

            row(label: "Sensitive items expire after") {
                Picker("Sensitive expiry", selection: Binding(
                    get: { settings.sensitiveRetentionMinutes },
                    set: { settings.sensitiveRetentionMinutes = $0 }
                )) {
                    Text("5 minutes").tag(5)
                    Text("15 minutes").tag(15)
                    Text("1 hour").tag(60)
                    Text("24 hours").tag(1_440)
                    Text("7 days").tag(10_080)
                    Text("Normal retention").tag(0)
                }
                .labelsHidden()
                .fixedSize()
            }

            note("Passwords, API keys, tokens, and private keys stay hidden in previews. Copy, paste, and drag still work when you intentionally choose them.")

            Button("Add excluded app…") {
                // NSOpenPanel must run after the button's click handling is complete
                DispatchQueue.main.async { pickExcludedApp() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            note("Excluded apps' clipboard content is never captured or stored.")
        }
    }

    // MARK: - Storage

    private var storageCard: some View {
        card("Storage", icon: "externaldrive.fill", color: .secondary) {
            row(label: "Keep history for") {
                Picker("Retention", selection: Binding(
                    get: { settings.retentionDays },
                    set: { settings.retentionDays = $0 }
                )) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
                .labelsHidden()
                .fixedSize()
            }

            Divider()

            row(label: "Show in history window") {
                Picker("History window limit", selection: Binding(
                    get: { settings.historyDisplayLimit },
                    set: { settings.historyDisplayLimit = $0 }
                )) {
                    Text("100 items").tag(100)
                    Text("200 items").tag(200)
                }
                .labelsHidden()
                .fixedSize()
            }

            Divider()

            HStack {
                Button("Clear all history…") {
                    showClearConfirm = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.regular)

                Text("Pinned items are preserved.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsCard: some View {
        card("Diagnostics", icon: "waveform.path.ecg", color: .secondary) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Remote anomaly reports")
                        .font(.body)
                    Text("Sends redacted performance and crash-adjacent events only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settings.remoteDiagnosticsEnabled },
                    set: { settings.remoteDiagnosticsEnabled = $0 }
                ))
                .labelsHidden()
            }

            row(label: "Endpoint") {
                TextField("https://example.com/api/cmd/anomalies", text: Binding(
                    get: { settings.remoteDiagnosticsEndpoint },
                    set: { settings.remoteDiagnosticsEndpoint = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 286)
            }

            row(label: "Bearer token") {
                SecureField("Optional", text: Binding(
                    get: { settings.remoteDiagnosticsToken },
                    set: { settings.remoteDiagnosticsToken = $0 }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 286)
            }

            note("Local diagnostics always stay on. Remote reporting is off unless a user enables it and an endpoint is configured.")
        }
    }

    // MARK: - General

    private var generalCard: some View {
        card("General", icon: "gearshape.fill", color: .gray) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login")
                        .font(.body)
                    Text("Starts cmd automatically when you log in.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0 }
                ))
                .labelsHidden()
            }
        }
    }

    // MARK: - Row / note helpers

    private func row<T: View>(label: String, @ViewBuilder trailing: () -> T) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            trailing()
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func applyCursorPiPSize(_ preset: CursorPiPSizePreset) {
        settings.cursorPiPWidth = Double(preset.size.width)
        settings.cursorPiPHeight = Double(preset.size.height)
    }

    // MARK: - App picker

    private func pickExcludedApp() {
        guard let window = NSApp.windows.first(where: { $0.title == "cmd Settings" }) else { return }
        let panel = NSOpenPanel()
        panel.title              = "Choose an app to exclude"
        panel.canChooseFiles     = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL       = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
            guard !settings.userExcludedBundles.contains(bundleID) else { return }
            settings.userExcludedBundles.append(bundleID)
        }
    }
}

// MARK: - HUD transition preview

private struct HUDTransitionPreview: View {
    let style: String
    let opacity: Double
    let sizeScale: CGFloat
    let replayToken: Int

    @State private var phase: PreviewPhase = .open
    @State private var cycleID = UUID()

    private enum PreviewPhase {
        case collapsed
        case opening
        case open
        case closing
    }

    private struct Motion {
        let entryDuration: Double
        let exitDuration: Double
        let rootEntryScale: CGSize
        let rootExitScale: CGSize
        let rootEntryOpacity: Double
        let rootExitOpacity: Double
        let rowTranslation: CGFloat
        let rowDelay: Double
        let rowInitialScale: CGFloat
        let timing: Animation
    }

    private var motion: Motion {
        switch style {
        case "genie":
            return Motion(
                entryDuration: 0.27,
                exitDuration: 0.23,
                rootEntryScale: CGSize(width: 0.20, height: 0.12),
                rootExitScale: CGSize(width: 0.12, height: 0.05),
                rootEntryOpacity: 0.0,
                rootExitOpacity: 0.0,
                rowTranslation: 0.48,
                rowDelay: 0.018,
                rowInitialScale: 0.62,
                timing: .interpolatingSpring(stiffness: 310, damping: 28)
            )
        case "cascade":
            return Motion(
                entryDuration: 0.23,
                exitDuration: 0.18,
                rootEntryScale: CGSize(width: 0.62, height: 0.62),
                rootExitScale: CGSize(width: 0.32, height: 0.32),
                rootEntryOpacity: 0.0,
                rootExitOpacity: 0.0,
                rowTranslation: 0.28,
                rowDelay: 0.030,
                rowInitialScale: 0.80,
                timing: .easeOut(duration: 0.23)
            )
        case "calm":
            return Motion(
                entryDuration: 0.17,
                exitDuration: 0.14,
                rootEntryScale: CGSize(width: 0.94, height: 0.94),
                rootExitScale: CGSize(width: 0.94, height: 0.94),
                rootEntryOpacity: 0.0,
                rootExitOpacity: 0.0,
                rowTranslation: 0.08,
                rowDelay: 0.006,
                rowInitialScale: 0.96,
                timing: .easeInOut(duration: 0.18)
            )
        default:
            return Motion(
                entryDuration: 0.24,
                exitDuration: 0.19,
                rootEntryScale: CGSize(width: 0.34, height: 0.34),
                rootExitScale: CGSize(width: 0.18, height: 0.18),
                rootEntryOpacity: 0.0,
                rootExitOpacity: 0.0,
                rowTranslation: 0.36,
                rowDelay: 0.014,
                rowInitialScale: 0.72,
                timing: .interpolatingSpring(stiffness: 340, damping: 30)
            )
        }
    }

    private var isOpenLike: Bool {
        phase == .opening || phase == .open
    }

    var body: some View {
        GeometryReader { proxy in
            let scale = sizeScale
            let textFieldFrame = CGRect(
                x: 18,
                y: 48,
                width: max(120, proxy.size.width - 36),
                height: 36
            )
            let anchor = CGPoint(
                x: textFieldFrame.midX,
                y: textFieldFrame.maxY
            )

            ZStack(alignment: .center) {
                desktopMock

                cursorGuide(anchor: anchor)

                VStack(spacing: 7 * scale) {
                    previewCard(
                        icon: "safari",
                        appName: "Safari",
                        time: "just now",
                        preview: "https://developer.apple.com/design/human-interface-guidelines",
                        index: 0,
                        anchor: anchor,
                        proxy: proxy
                    )
                    previewCard(
                        icon: "hammer",
                        appName: "Xcode",
                        time: "2m ago",
                        preview: "let greeting = \"Hello, World!\"",
                        index: 1,
                        anchor: anchor,
                        proxy: proxy
                    )
                    previewCard(
                        icon: "note.text",
                        appName: "Notes",
                        time: "8m ago",
                        preview: "Ship the settings redesign by Friday — remember tests",
                        index: 2,
                        anchor: anchor,
                        proxy: proxy
                    )
                }
                .padding(16 * scale)
                .scaleEffect(
                    rootScale,
                    anchor: UnitPoint(
                        x: anchor.x / max(proxy.size.width, 1),
                        y: anchor.y / max(proxy.size.height, 1)
                    )
                )
                .opacity(rootOpacity)
                .animation(rootAnimation, value: phase)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .onAppear { replay() }
            .onChange(of: style) { _ in replay() }
            .onChange(of: replayToken) { _ in replay() }
        }
    }

    private var desktopMock: some View {
        ZStack {
            LinearGradient(
                stops: [
                    .init(color: Color(red: 0.08, green: 0.085, blue: 0.095), location: 0.0),
                    .init(color: Color(red: 0.13, green: 0.135, blue: 0.145), location: 0.55),
                    .init(color: Color(red: 0.055, green: 0.058, blue: 0.066), location: 1.0),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 22)
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 36)
                    .overlay(alignment: .leading) {
                        Text("Focused text field")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.34))
                            .padding(.leading, 12)
                    }
                Spacer()
            }
            .padding(18)
        }
    }

    private func cursorGuide(anchor: CGPoint) -> some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: 6, height: 6)
            Circle()
                .stroke(Color.white.opacity(0.34), lineWidth: 1)
                .frame(width: phase == .open ? 18 : 8, height: phase == .open ? 18 : 8)
                .animation(.easeOut(duration: 0.24), value: phase)
        }
        .position(anchor)
    }

    private var rootScale: CGSize {
        switch phase {
        case .collapsed:
            return motion.rootEntryScale
        case .opening, .open:
            return CGSize(width: 1, height: 1)
        case .closing:
            return motion.rootExitScale
        }
    }

    private var rootOpacity: Double {
        switch phase {
        case .collapsed:
            return motion.rootEntryOpacity
        case .opening, .open:
            return 1
        case .closing:
            return motion.rootExitOpacity
        }
    }

    private var rootAnimation: Animation {
        switch phase {
        case .closing:
            return .easeIn(duration: motion.exitDuration)
        default:
            return motion.timing
        }
    }

    private func previewCard(
        icon: String,
        appName: String,
        time: String,
        preview: String,
        index: Int,
        anchor: CGPoint,
        proxy: GeometryProxy
    ) -> some View {
        let scale = sizeScale
        let cardHeight = 56 * scale
        let rowCenterY = proxy.size.height / 2 - CGFloat(index - 1) * (cardHeight + 7 * scale)
        let rowCenter = CGPoint(x: proxy.size.width / 2, y: rowCenterY)
        let offset = rowOffset(rowCenter: rowCenter, anchor: anchor, index: index)
        let rank = rowDistanceRank(rowCenter: rowCenter, anchor: anchor, proxy: proxy)
        let delay = Double(rank) * motion.rowDelay

        return HStack(spacing: 10 * scale) {
            Image(systemName: icon)
                .font(.system(size: 14 * scale, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28 * scale, height: 28 * scale)
                .background(Color.white.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 7 * scale))

            VStack(alignment: .leading, spacing: 1 * scale) {
                HStack(spacing: 4 * scale) {
                    Text(appName)
                        .font(.system(size: 11 * scale, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(time)
                        .font(.system(size: 10 * scale))
                        .foregroundStyle(.secondary)
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11 * scale, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22 * scale, height: 22 * scale)
                        .background(Circle().fill(Color.white.opacity(0.10 * opacity)))
                }
                Text(preview)
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 12 * scale)
        .padding(.vertical, 9 * scale)
        .background {
            RoundedRectangle(cornerRadius: 14 * scale)
                .fill(.ultraThinMaterial)
                .opacity(opacity)
            RoundedRectangle(cornerRadius: 14 * scale)
                .stroke(Color.white.opacity(0.18 * opacity), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.28 * opacity), radius: 10, x: 0, y: 3)
        .offset(x: offset.width, y: offset.height)
        .scaleEffect(isOpenLike ? 1 : motion.rowInitialScale)
        .opacity(isOpenLike ? 1 : (style == "calm" ? 0.18 : 0))
        .animation(rowAnimation.delay(delay), value: phase)
    }

    private func rowOffset(rowCenter: CGPoint, anchor: CGPoint, index: Int) -> CGSize {
        guard !isOpenLike else { return .zero }

        let multiplier = motion.rowTranslation
        return CGSize(
            width: (anchor.x - rowCenter.x) * multiplier,
            height: (anchor.y - rowCenter.y) * multiplier
        )
    }

    private func rowDistanceRank(rowCenter: CGPoint, anchor: CGPoint, proxy: GeometryProxy) -> Int {
        let scale = sizeScale
        let cardHeight = 56 * scale
        let distances = (0..<3).map { index -> (index: Int, distance: CGFloat) in
            let centerY = proxy.size.height / 2 - CGFloat(index - 1) * (cardHeight + 7 * scale)
            let center = CGPoint(x: proxy.size.width / 2, y: centerY)
            return (index, hypot(anchor.x - center.x, anchor.y - center.y))
        }
        let sorted = distances.sorted { $0.distance < $1.distance }
        return sorted.firstIndex { abs($0.distance - hypot(anchor.x - rowCenter.x, anchor.y - rowCenter.y)) < 0.5 } ?? 0
    }

    private var rowAnimation: Animation {
        switch phase {
        case .closing:
            return .easeIn(duration: motion.exitDuration)
        default:
            return motion.timing
        }
    }

    private func replay() {
        let id = UUID()
        cycleID = id
        phase = .collapsed

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            guard cycleID == id else { return }
            phase = .opening
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard cycleID == id else { return }
            phase = .open
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            guard cycleID == id else { return }
            phase = .closing
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.45) {
            guard cycleID == id else { return }
            phase = .open
        }
    }
}
