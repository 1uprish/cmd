import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CopyRegisterPreviewView: View {
    @ObservedObject var model: OnboardingWalkthroughModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.registerEntries.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 10) {
                            ForEach(model.filteredEntries) { entry in
                                CopyRegisterPreviewRow(
                                    entry: entry,
                                    isSelected: model.selectedEntryID == entry.id,
                                    isCopied: model.copiedEntryID == entry.id,
                                    isDropped: model.droppedEntryID == entry.id,
                                    onSelect: { model.select(entry) },
                                    onCopy: { model.copyFromRegister(entry) },
                                    onPaste: { model.paste(entry) }
                                )
                                .id(entry.id)
                                .transition(.asymmetric(
                                    insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.97)),
                                    removal: .opacity.combined(with: .scale(scale: 0.98))
                                ))
                            }
                        }
                        .padding(.top, 1)
                        .padding(.bottom, 8)
                    }
                    .frame(maxHeight: compact ? 394 : 520)
                    .mask(LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.035),
                            .init(color: .black, location: 0.94),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .onChange(of: model.registerEntries.count) { _ in
                        scrollToNewest(using: proxy)
                    }
                    .onChange(of: model.copiedEntryID) { _ in
                        scrollToNewest(using: proxy)
                    }
                }
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(0.18))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("cmd")
                    .font(.system(size: compact ? 22 : 26, weight: .heavy))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.65), radius: 5, y: 1)
                Spacer()
                if !model.filterText.isEmpty {
                    Text(model.filterText)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.blue.opacity(0.85)))
                }
            }

            Text("Type to filter · ↑↓ select · Return paste · Esc close")
                .font(.system(size: compact ? 12 : 13, weight: .bold))
                .foregroundStyle(.white.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "command.square")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text("Copy something in the rehearsal.")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white.opacity(0.86))
            Text("Each demo copy appears here exactly like the real Cmd-V register.")
                .font(.system(size: 13, weight: .semibold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.55))
        }
        .frame(maxWidth: .infinity, minHeight: 230)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        )
    }

    private func scrollToNewest(using proxy: ScrollViewProxy) {
        guard let firstID = model.filteredEntries.first?.id else { return }
        DispatchQueue.main.async {
            withAnimation(.interpolatingSpring(stiffness: 260, damping: 30)) {
                proxy.scrollTo(firstID, anchor: .top)
            }
        }
    }
}

private struct CopyRegisterPreviewRow: View {
    let entry: DemoRegisterEntry
    let isSelected: Bool
    let isCopied: Bool
    let isDropped: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onPaste: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onPaste) {
            HStack(spacing: 14) {
                icon
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(entry.sourceApp)
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if entry.isSensitive {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.orange.opacity(0.95))
                        }
                    }

                    Text(entry.registerPreview)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)

                    Text(entry.kind.registerLabel)
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.48))
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 14) {
                    Text(relativeTime)
                        .font(.system(size: 14, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.62))
                    Button(action: onCopy) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isCopied ? .green : .white.opacity(0.72))
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.white.opacity(isHovering ? 0.12 : 0.04)))
                    }
                    .buttonStyle(.plain)
                    .help("Copy this item")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 92)
            .background(rowBackground)
            .scaleEffect(isCopied || isDropped ? 1.018 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.76), value: isCopied)
            .animation(.spring(response: 0.28, dampingFraction: 0.76), value: isDropped)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
            if hovering { onSelect() }
        }
        .onDrag {
            onSelect()
            return NSItemProvider(object: entry.dragPayload as NSString)
        } preview: {
            DragPreview(entry: entry)
        }
        .help("Click to paste, drag to drop, or use the copy button")
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(iconFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(entry.kind == .color ? 0.16 : 0.08))
                        .blendMode(.screen)
                )

            if let thumbnail = entry.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else if entry.kind == .color {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(nsColor: entry.accent))
                    .frame(width: 34, height: 34)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(.white.opacity(0.72), lineWidth: 2)
                    )
            } else {
                Image(systemName: entry.sourceSymbolName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .shadow(color: .black.opacity(0.28), radius: 10, y: 4)
    }

    private var iconFill: Color {
        entry.kind == .color ? Color(nsColor: entry.accent).opacity(0.92) : Color.white.opacity(0.16)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 21, style: .continuous)
            .fill(Color.white.opacity(isSelected ? 0.22 : 0.15))
            .background(
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .fill(.ultraThinMaterial.opacity(0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 21, style: .continuous)
                    .stroke(isSelected ? Color.blue.opacity(0.78) : Color.white.opacity(0.14), lineWidth: isSelected ? 1.2 : 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    private var relativeTime: String {
        let seconds = max(0, Int(Date().timeIntervalSince(entry.timestamp)))
        if seconds < 5 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        return "\(seconds / 60)m ago"
    }
}

private struct DragPreview: View {
    let entry: DemoRegisterEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.kind.symbolName)
            Text(entry.kind == .image ? "Image" : entry.registerPreview)
                .lineLimit(1)
        }
        .font(.system(size: 13, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.7))
                .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 1))
        )
    }
}
