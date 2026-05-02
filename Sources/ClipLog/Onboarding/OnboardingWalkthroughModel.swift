import AppKit
import Combine
import Foundation
import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome
    case text
    case image
    case link
    case secret
    case mixed
    case commandV
    case finish

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome to cmd"
        case .text: return "Copy text"
        case .image: return "Copy images"
        case .link: return "Copy links"
        case .secret: return "Private things stay private"
        case .mixed: return "Copy anything"
        case .commandV: return "Rehearse Cmd-V"
        case .finish: return "You are ready"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return "A live rehearsal: copy something, watch the register update, then choose what you want to paste."
        case .text:
            return "One ordinary copy becomes a reusable memory."
        case .image:
            return "Images land beside text, with the same drag and copy actions."
        case .link:
            return "Links are captured as first-class clipboard items."
        case .secret:
            return "Secrets can be hidden and set to expire without losing copy, paste, or drag behavior."
        case .mixed:
            return "Color chips and files make the register feel like a real workspace, not a text list."
        case .commandV:
            return "This is the muscle memory: hold Cmd-V, choose, copy, drag, or press Return."
        case .finish:
            return "cmd keeps running in the menu bar. Copy anything, then hold Cmd-V."
        }
    }

    var primaryLabel: String {
        switch self {
        case .welcome: return "Start rehearsal"
        case .text: return "Copy text"
        case .image: return "Copy image"
        case .link: return "Copy link"
        case .secret: return "Copy fake API key"
        case .mixed: return "Copy color and file"
        case .commandV: return "Try the register"
        case .finish: return "Start using cmd"
        }
    }

    var demoEntry: DemoRegisterEntry? {
        switch self {
        case .text: return OnboardingDemoEntries.text
        case .image: return OnboardingDemoEntries.image
        case .link: return OnboardingDemoEntries.url
        case .secret: return OnboardingDemoEntries.secret
        default: return nil
        }
    }
}

@MainActor
final class OnboardingWalkthroughModel: ObservableObject {
    @Published var step: OnboardingStep = .welcome
    @Published private(set) var registerEntries: [DemoRegisterEntry] = []
    @Published var selectedEntryID: DemoRegisterEntry.ID?
    @Published var copiedEntryID: DemoRegisterEntry.ID?
    @Published var droppedEntryID: DemoRegisterEntry.ID?
    @Published var pastedText = ""
    @Published var filterText = ""
    @Published var commandRegisterVisible = false
    @Published var keepDemoItems = false
    @Published var accessibilityGranted = AXIsProcessTrusted()

    private var insertedFingerprints = Set<String>()

    var progress: Double {
        Double(step.rawValue + 1) / Double(OnboardingStep.allCases.count)
    }

    var filteredEntries: [DemoRegisterEntry] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return registerEntries }
        return registerEntries.filter {
            $0.registerPreview.lowercased().contains(query)
                || $0.sourceApp.lowercased().contains(query)
                || $0.kind.registerLabel.lowercased().contains(query)
        }
    }

    var currentDemoEntry: DemoRegisterEntry? {
        if step == .mixed { return nil }
        return step.demoEntry
    }

    var hasCopiedCurrentStep: Bool {
        if step == .mixed {
            return insertedFingerprints.contains(OnboardingDemoEntries.color.fingerprint)
                && insertedFingerprints.contains(OnboardingDemoEntries.file.fingerprint)
        }
        guard let entry = currentDemoEntry else { return true }
        return insertedFingerprints.contains(entry.fingerprint)
    }

    func refreshAccessibilityStatus() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    func goBack() {
        guard let previous = OnboardingStep(rawValue: max(0, step.rawValue - 1)) else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            step = previous
            commandRegisterVisible = previous == .commandV
        }
    }

    func advance(onFinish: () -> Void) {
        switch step {
        case .welcome:
            move(to: .text)
        case .text, .image, .link, .secret:
            if let entry = currentDemoEntry, !hasCopiedCurrentStep {
                copyDemo(entry)
            } else {
                moveToNextStep()
            }
        case .mixed:
            if !hasCopiedCurrentStep {
                copyDemo(OnboardingDemoEntries.color)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                    self?.copyDemo(OnboardingDemoEntries.file)
                }
            } else {
                move(to: .commandV)
            }
        case .commandV:
            commandRegisterVisible = true
            if selectedEntryID == nil {
                selectedEntryID = registerEntries.first?.id
            } else {
                move(to: .finish)
            }
        case .finish:
            onFinish()
        }
    }

    func copyCurrentDemo() {
        if step == .mixed {
            copyDemo(OnboardingDemoEntries.color)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.copyDemo(OnboardingDemoEntries.file)
            }
            return
        }
        guard let entry = currentDemoEntry else { return }
        copyDemo(entry)
    }

    func copyDemo(_ entry: DemoRegisterEntry) {
        guard !insertedFingerprints.contains(entry.fingerprint) else {
            select(entry)
            copiedEntryID = entry.id
            return
        }
        insertedFingerprints.insert(entry.fingerprint)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            registerEntries.insert(entry, at: 0)
            selectedEntryID = entry.id
            copiedEntryID = entry.id
            commandRegisterVisible = step == .commandV
        }
        clearCopyPulse(after: entry.id)
    }

    func select(_ entry: DemoRegisterEntry) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            selectedEntryID = entry.id
        }
    }

    func copyFromRegister(_ entry: DemoRegisterEntry) {
        copiedEntryID = entry.id
        select(entry)
        clearCopyPulse(after: entry.id)
    }

    func paste(_ entry: DemoRegisterEntry) {
        select(entry)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            pastedText = entry.rawValue
            commandRegisterVisible = false
        }
    }

    func drop(_ entry: DemoRegisterEntry) {
        select(entry)
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            droppedEntryID = entry.id
            pastedText = entry.kind == .image ? "Dropped image: Launch image card" : entry.rawValue
        }
        clearDropPulse(after: entry.id)
    }

    func clearDemo() {
        withAnimation(.spring(response: 0.36, dampingFraction: 0.9)) {
            registerEntries.removeAll()
            insertedFingerprints.removeAll()
            selectedEntryID = nil
            copiedEntryID = nil
            droppedEntryID = nil
            pastedText = ""
            filterText = ""
        }
    }

    private func moveToNextStep() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        move(to: next)
    }

    private func move(to next: OnboardingStep) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
            step = next
            commandRegisterVisible = next == .commandV
            if next == .commandV, selectedEntryID == nil {
                selectedEntryID = registerEntries.first?.id
            }
        }
    }

    private func clearCopyPulse(after id: DemoRegisterEntry.ID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard self?.copiedEntryID == id else { return }
            self?.copiedEntryID = nil
        }
    }

    private func clearDropPulse(after id: DemoRegisterEntry.ID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { [weak self] in
            guard self?.droppedEntryID == id else { return }
            self?.droppedEntryID = nil
        }
    }
}
