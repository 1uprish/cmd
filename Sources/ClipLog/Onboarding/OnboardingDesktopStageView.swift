import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct OnboardingDesktopStageView: View {
    @ObservedObject var model: OnboardingWalkthroughModel
    let onRequestAccessibility: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            desktopBackground
            VStack(spacing: 0) {
                menuBar
                HStack(spacing: 18) {
                    sourceWindow
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    CopyRegisterPreviewView(model: model, compact: true)
                        .frame(width: 398)
                        .scaleEffect(model.step == .commandV && model.commandRegisterVisible ? 1.018 : 1, anchor: .center)
                        .shadow(
                            color: model.step == .commandV && model.commandRegisterVisible ? Color.white.opacity(0.08) : .clear,
                            radius: 28,
                            y: 0
                        )
                        .animation(.interpolatingSpring(stiffness: 280, damping: 30), value: model.commandRegisterVisible)
                }
                .padding(20)
            }

            if let copiedID = model.copiedEntryID,
               let copiedEntry = model.registerEntries.first(where: { $0.id == copiedID }) {
                CopyFlightView(entry: copiedEntry)
                    .id(copiedID)
                    .allowsHitTesting(false)
            }

            if let guide = guideCue {
                GuidedCursorView(text: guide.text)
                    .offset(x: guide.point.x, y: guide.point.y)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.13), lineWidth: 1)
        )
    }

    private var desktopBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.052, green: 0.055, blue: 0.060),
                Color(red: 0.075, green: 0.078, blue: 0.086),
                Color(red: 0.040, green: 0.042, blue: 0.048),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var menuBar: some View {
        HStack(spacing: 12) {
            Circle().fill(.white.opacity(0.88)).frame(width: 10, height: 10)
            Text("cmd")
                .font(.system(size: 13, weight: .heavy))
            Spacer()
            Image(systemName: "wifi")
            Image(systemName: "battery.100")
            Text("Sat 9:41")
                .font(.system(size: 12, weight: .bold))
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 18)
        .frame(height: 34)
        .background(Color.black.opacity(0.22))
    }

    private var sourceWindow: some View {
        VStack(alignment: .leading, spacing: 14) {
            windowChrome
            Text(model.step.title)
                .font(.system(size: model.step == .welcome ? 29 : 26, weight: .heavy))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.step.subtitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.62))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)

            stepContent
                .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)

            Spacer(minLength: 0)
            dropAndPasteTarget
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private var windowChrome: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.white.opacity(0.26)).frame(width: 11, height: 11)
            Circle().fill(Color.white.opacity(0.18)).frame(width: 11, height: 11)
            Circle().fill(Color.white.opacity(0.13)).frame(width: 11, height: 11)
            Spacer()
            Text(stageLabel)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white.opacity(0.42))
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .welcome:
            WelcomeRehearsalCard()
        case .text, .image, .link, .secret:
            if let entry = model.currentDemoEntry {
                DemoSourceCard(entry: entry, copied: model.hasCopiedCurrentStep) {
                    model.copyCurrentDemo()
                }
            }
        case .mixed:
            MixedSourceCard(copied: model.hasCopiedCurrentStep) {
                model.copyCurrentDemo()
            }
        case .commandV:
            CommandVPracticeCard(model: model, onRequestAccessibility: onRequestAccessibility)
        case .finish:
            FinishRehearsalCard(model: model)
        }
    }

    private var dropAndPasteTarget: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Demo message field", systemImage: "text.bubble.fill")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.72))
                Spacer()
                Text("Drop or paste here")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Text(model.pastedText.isEmpty ? "Your selected item appears here during the rehearsal." : model.pastedText)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(model.pastedText.isEmpty ? .white.opacity(0.38) : .white.opacity(0.88))
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 62, alignment: .topLeading)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.075))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        )
                )
        }
        .onDrop(of: [.text, .url, .fileURL, .image], isTargeted: nil) { _ in
            if let selected = model.registerEntries.first(where: { $0.id == model.selectedEntryID }) {
                model.drop(selected)
            }
            return true
        }
    }

    private var stageLabel: String {
        "\(model.step.rawValue + 1) of \(OnboardingStep.allCases.count)"
    }

    private var guideCue: (point: CGPoint, text: String)? {
        switch model.step {
        case .welcome:
            return (CGPoint(x: 92, y: 300), "Start here")
        case .text:
            return model.hasCopiedCurrentStep
                ? (CGPoint(x: 765, y: 172), "It appears here")
                : (CGPoint(x: 260, y: 392), "Copy this")
        case .image:
            return model.hasCopiedCurrentStep
                ? (CGPoint(x: 765, y: 172), "Image is ready")
                : (CGPoint(x: 260, y: 392), "Copy image")
        case .link:
            return model.hasCopiedCurrentStep
                ? (CGPoint(x: 765, y: 172), "Link is ready")
                : (CGPoint(x: 260, y: 392), "Copy link")
        case .secret:
            return model.hasCopiedCurrentStep
                ? (CGPoint(x: 765, y: 172), "Hidden, still usable")
                : (CGPoint(x: 260, y: 392), "Copy fake key")
        case .mixed:
            return model.hasCopiedCurrentStep
                ? (CGPoint(x: 765, y: 172), "Newest stays on top")
                : (CGPoint(x: 260, y: 392), "Copy both")
        case .commandV:
            return model.commandRegisterVisible
                ? (CGPoint(x: 688, y: 150), "Choose a card")
                : (CGPoint(x: 214, y: 292), "Open register")
        case .finish:
            return nil
        }
    }
}

private struct WelcomeRehearsalCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 66, height: 66)
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Welcome to cmd")
                        .font(.system(size: 24, weight: .heavy))
                        .foregroundStyle(.white)
                    Text("You will learn by doing, inside a safe simulated Mac workspace.")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }

            HStack(spacing: 10) {
                RehearsalPill(title: "copy", icon: "doc.on.doc")
                RehearsalPill(title: "register", icon: "rectangle.stack.fill")
                RehearsalPill(title: "choose", icon: "cursorarrow.click.2")
                RehearsalPill(title: "paste", icon: "return")
            }
        }
        .padding(18)
        .background(cardBackground)
    }
}

private struct DemoSourceCard: View {
    let entry: DemoRegisterEntry
    let copied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(entry.sourceApp, systemImage: entry.sourceSymbolName)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.68))
                Spacer()
                Text(entry.kind.registerLabel)
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.44))
            }

            content

            Button(action: onCopy) {
                Label(copied ? "Copied into register" : copyButtonTitle, systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryRehearsalButton(prominent: !copied))
        }
        .padding(18)
        .background(cardBackground)
    }

    private var copyButtonTitle: String {
        switch entry.kind {
        case .text: return "Copy this text"
        case .image: return "Copy this image"
        case .url: return "Copy this link"
        case .secret: return "Copy fake API key"
        case .color: return "Copy this color"
        case .file: return "Copy this file"
        }
    }

    @ViewBuilder
    private var content: some View {
        if let thumbnail = entry.thumbnail {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.065))
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 106)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 14)
            }
            .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 132)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(0.13), lineWidth: 1)
            )
        } else if entry.isSensitive {
            VStack(alignment: .leading, spacing: 10) {
                Text("Fake demo API key")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.white.opacity(0.66))
                Text("sk-demo_copy_this_is_fake_9x4Tqv7L")
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.84))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Label("Shown hidden in the register, but copy/drag/paste still work.", systemImage: "lock.shield.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
            )
        } else {
            Text(entry.rawValue)
                .font(.system(size: entry.kind == .url ? 18 : 21, weight: .bold, design: entry.kind == .url ? .rounded : .default))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .center)
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
    }
}

private struct MixedSourceCard: View {
    let copied: Bool
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                mixedTile(OnboardingDemoEntries.color)
                mixedTile(OnboardingDemoEntries.file)
            }

            Button(action: onCopy) {
                Label(copied ? "Both items are in the register" : "Copy color and file", systemImage: copied ? "checkmark.circle.fill" : "square.stack.3d.up.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryRehearsalButton(prominent: !copied))
        }
        .padding(18)
        .background(cardBackground)
    }

    private func mixedTile(_ entry: DemoRegisterEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: entry.kind.symbolName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(entry.kind == .color ? Color(nsColor: entry.accent) : Color.white.opacity(0.72))
            Text(entry.displayValue)
                .font(.system(size: 16, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(entry.kind.registerLabel)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        )
    }
}

private struct CommandVPracticeCard: View {
    @ObservedObject var model: OnboardingWalkthroughModel
    let onRequestAccessibility: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                CommandKeyView(text: "Cmd")
                CommandKeyView(text: "V")
                Text("Hold for 200 ms")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(.white)
            }

            Text("Click a row to paste into the demo field, drag a row into the field, or use the copy button on a card.")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white.opacity(0.58))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                        model.commandRegisterVisible.toggle()
                    }
                } label: {
                    Label(model.commandRegisterVisible ? "Hide register" : "Show register", systemImage: "cursorarrow.rays")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryRehearsalButton(prominent: true))

                Button(action: onRequestAccessibility) {
                    Label(model.accessibilityGranted ? "Accessibility ready" : "Enable access", systemImage: model.accessibilityGranted ? "checkmark.shield.fill" : "accessibility")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryRehearsalButton(prominent: false))
            }
        }
        .padding(18)
        .background(cardBackground)
    }
}

private struct FinishRehearsalCard: View {
    @ObservedObject var model: OnboardingWalkthroughModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("cmd is running", systemImage: "checkmark.seal.fill")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(.white)
            Text("Copy anything in any app. Hold Cmd-V to open the register from your cursor.")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $model.keepDemoItems) {
                Text("Keep demo items for practice")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .toggleStyle(.checkbox)
        }
        .padding(18)
        .background(cardBackground)
    }
}

private struct CopyFlightView: View {
    let entry: DemoRegisterEntry

    @State private var didFly = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.kind.symbolName)
                .font(.system(size: 13, weight: .heavy))
            Text(entry.kind == .secret ? "hidden secret" : entry.kind.registerLabel.lowercased())
                .font(.system(size: 13, weight: .heavy))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 13)
        .frame(height: 34)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.20))
                .overlay(Capsule().stroke(.white.opacity(0.36), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.32), radius: didFly ? 10 : 22, y: didFly ? 4 : 10)
        )
        .scaleEffect(didFly ? 0.74 : 1.08)
        .blur(radius: didFly ? 0.8 : 0)
        .opacity(didFly ? 0 : 1)
        .offset(x: didFly ? 650 : 190, y: didFly ? 114 : 342)
        .animation(.interpolatingSpring(stiffness: 260, damping: 28), value: didFly)
        .onAppear {
            didFly = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                didFly = true
            }
        }
    }
}

private struct GuidedCursorView: View {
    let text: String

    @State private var pulse = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.55), radius: 6, y: 2)

            Text(text)
                .font(.system(size: 12, weight: .heavy))
                .foregroundStyle(.white.opacity(0.92))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.58))
                        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
                )
        }
        .scaleEffect(pulse ? 1.025 : 1)
        .animation(.easeInOut(duration: 0.82).repeatForever(autoreverses: true), value: pulse)
        .animation(.interpolatingSpring(stiffness: 260, damping: 28), value: text)
        .onAppear {
            pulse = true
        }
    }
}

private struct RehearsalPill: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .heavy))
            .foregroundStyle(.white.opacity(0.78))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Capsule().fill(.white.opacity(0.09)))
    }
}

private struct CommandKeyView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 58, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.white.opacity(0.13))
                    .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(.white.opacity(0.2), lineWidth: 1))
            )
    }
}

private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 20, style: .continuous)
        .fill(Color.white.opacity(0.085))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
}

struct PrimaryRehearsalButton: ButtonStyle {
    var prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(prominent ? Color.blue.opacity(configuration.isPressed ? 0.62 : 0.84) : Color.white.opacity(configuration.isPressed ? 0.1 : 0.075))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(.white.opacity(prominent ? 0.22 : 0.12), lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
