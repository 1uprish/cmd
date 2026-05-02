import AppKit
import SwiftUI

final class OnboardingWindowController: NSWindowController {
    init(
        onRequestAccessibility: @escaping () -> Void,
        onFinish: @escaping () -> Void
    ) {
        let root = OnboardingView(
            onRequestAccessibility: onRequestAccessibility,
            onFinish: onFinish
        )
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to cmd"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 1000, height: 660))
        window.minSize = NSSize(width: 920, height: 620)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError()
    }
}

private struct OnboardingView: View {
    @StateObject private var model = OnboardingWalkthroughModel()
    @ObservedObject private var settings = ClipLogSettings.shared

    let onRequestAccessibility: () -> Void
    let onFinish: () -> Void

    private let poll = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
            VStack(spacing: 0) {
                topBar
                OnboardingDesktopStageView(model: model, onRequestAccessibility: onRequestAccessibility)
                    .frame(maxWidth: .infinity)
                    .frame(height: 438)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 14)
                footer
                    .frame(height: 76)
            }
        }
        .frame(width: 1000, height: 660)
        .background(windowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .onReceive(poll) { _ in
            model.refreshAccessibilityStatus()
        }
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 9, y: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text("cmd")
                    .font(.system(size: 21, weight: .heavy))
                    .foregroundStyle(.white)
                Text(model.step.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white.opacity(0.52))
            }

            Spacer()

            StepProgressView(step: model.step)
                .frame(width: 260)
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(FooterButtonStyle(prominent: false))
            .disabled(model.step == .welcome)
            .opacity(model.step == .welcome ? 0.4 : 1)

            Button {
                model.clearDemo()
            } label: {
                Label("Reset rehearsal", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(FooterButtonStyle(prominent: false))
            .disabled(model.registerEntries.isEmpty)
            .opacity(model.registerEntries.isEmpty ? 0.4 : 1)

            Spacer()

            Button {
                model.advance {
                    if !model.keepDemoItems {
                        model.clearDemo()
                    }
                    settings.onboardingCompleted = true
                    onFinish()
                }
            } label: {
                Label(primaryButtonTitle, systemImage: primaryButtonIcon)
            }
            .buttonStyle(FooterButtonStyle(prominent: true))
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            Rectangle()
                .fill(Color.black.opacity(0.24))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(height: 1)
                }
        )
    }

    private var primaryButtonTitle: String {
        if model.step == .finish { return model.step.primaryLabel }
        if model.step == .commandV, model.selectedEntryID != nil { return "Finish rehearsal" }
        if model.hasCopiedCurrentStep, model.step != .welcome { return "Continue" }
        return model.step.primaryLabel
    }

    private var primaryButtonIcon: String {
        switch model.step {
        case .welcome: return "play.fill"
        case .commandV: return model.selectedEntryID == nil ? "command" : "checkmark.circle.fill"
        case .finish: return "sparkles"
        default: return model.hasCopiedCurrentStep ? "arrow.right" : "doc.on.doc"
        }
    }

    private var windowBackground: some View {
        RoundedRectangle(cornerRadius: 26, style: .continuous)
            .fill(Color(red: 0.045, green: 0.048, blue: 0.058).opacity(0.98))
            .shadow(color: .black.opacity(0.55), radius: 42, y: 26)
    }
}

private struct StepProgressView: View {
    let step: OnboardingStep

    var body: some View {
        VStack(alignment: .trailing, spacing: 7) {
            HStack(spacing: 5) {
                ForEach(OnboardingStep.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.white.opacity(0.9) : Color.white.opacity(0.17))
                        .frame(height: 5)
                }
            }
            Text("\(step.rawValue + 1) / \(OnboardingStep.allCases.count)")
                .font(.system(size: 11, weight: .heavy, design: .monospaced))
                .foregroundStyle(.white.opacity(0.46))
        }
    }
}

private struct FooterButtonStyle: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(prominent ? Color.blue.opacity(configuration.isPressed ? 0.66 : 0.9) : Color.white.opacity(configuration.isPressed ? 0.11 : 0.07))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(prominent ? 0.24 : 0.13), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.82), value: configuration.isPressed)
    }
}
