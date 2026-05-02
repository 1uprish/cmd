import SwiftUI

// MARK: - FeaturesView
//
// Native help surface listing cmd capabilities with restrained styling.

struct FeaturesView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                ForEach(Feature.all) { section in
                    featureSection(section)
                }
            }
            .padding(24)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 620, minHeight: 520)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "command.square")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("cmd")
                        .font(.system(size: 25, weight: .bold))
                    Text("Clipboard history for macOS")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
                .padding(.top, 8)
        }
    }

    // MARK: - Section

    private func featureSection(_ section: Feature) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                Text(section.title)
                    .font(.system(size: 16, weight: .bold))
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(section.items, id: \.title) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "circle")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 7, weight: .semibold))
                            .padding(.top, 8)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.title)
                                    .font(.system(size: 13, weight: .semibold))
                                if let shortcut = item.shortcut {
                                    Text(shortcut)
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.12))
                                        .cornerRadius(5)
                                }
                            }
                            Text(item.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.leading, 34)

            Divider()
        }
    }
}

// MARK: - Data model

private struct Feature: Identifiable {
    let id = UUID()
    let icon:  String
    let title: String
    let items: [Item]

    struct Item {
        let title:       String
        let shortcut:    String?
        let description: String
    }

    static let all: [Feature] = [
        Feature(
            icon: "macwindow.on.rectangle",
            title: "Clipboard History HUD",
            items: [
                Item(title: "Open HUD", shortcut: "Hold ⌘V",
                     description: "Hold Command+V for 200 ms (adjustable in Settings) to reveal your floating clipboard history. A quick tap still pastes normally."),
                Item(title: "Click to paste", shortcut: nil,
                     description: "Click any card to instantly paste that item into the previously active app. The HUD closes and focus returns seamlessly."),
                Item(title: "Scroll through history", shortcut: nil,
                     description: "The HUD shows up to 20 recent clipboard items as independent floating cards. Scroll through them with a trackpad or scroll wheel."),
                Item(title: "Dismiss without pasting", shortcut: "ESC",
                     description: "Press Escape or click anywhere outside the HUD to close it without changing the clipboard."),
                Item(title: "Cursor-origin animation", shortcut: nil,
                     description: "The HUD springs open from your cursor position and shrinks back to it on dismiss — giving it a satisfying, physical feel."),
            ]
        ),
        Feature(
            icon: "hand.draw.fill",
            title: "Drag & Drop from HUD",
            items: [
                Item(title: "Drag any card", shortcut: nil,
                     description: "Click and drag a card out of the HUD to drop its content — text, image, file, URL, or colour — directly into any app. Works with Finder, Pages, Slack, Figma, and more."),
                Item(title: "Instant dismiss on drag", shortcut: nil,
                     description: "The HUD vanishes the moment a drag session begins, giving you a completely clear drop target with no interference."),
                Item(title: "Rich content types", shortcut: nil,
                     description: "Text drags as plain text. URLs drop as links. Images transfer as native image data. Files land exactly as if dragged from Finder. Colours carry both NSColor data and hex string so design tools like Sketch and Figma pick them up."),
            ]
        ),
        Feature(
            icon: "text.magnifyingglass",
            title: "Live Filter",
            items: [
                Item(title: "Type to filter", shortcut: nil,
                     description: "While the HUD is open, type any letter or number and cards are instantly dimmed or highlighted to show only matching items."),
                Item(title: "Clear filter", shortcut: "⌫",
                     description: "Press Backspace/Delete to clear the current filter and see all cards again."),
            ]
        ),
        Feature(
            icon: "doc.on.doc.fill",
            title: "Append Mode",
            items: [
                Item(title: "Collect multiple copies", shortcut: "⌘ ⌘",
                     description: "Tap Command twice to turn Append On. Copied text joins one combined clipboard item, and copied images are carried with it for rich paste targets."),
                Item(title: "Visible collection state", shortcut: nil,
                     description: "A small bottom indicator follows your active screen and shows the live clip count, character count, and combined preview."),
                Item(title: "Toggle off", shortcut: "⌘ ⌘",
                     description: "Tap Command twice again to end the append session. It also turns off automatically after a short idle timeout."),
            ]
        ),
        Feature(
            icon: "books.vertical.fill",
            title: "cmd History",
            items: [
                Item(title: "Open full history", shortcut: nil,
                     description: "Open cmd from the menu bar → Show History to browse, search, and re-paste your entire clipboard archive."),
                Item(title: "Semantic search", shortcut: nil,
                     description: "cmd embeds text items so you can search by meaning, not just exact words."),
                Item(title: "Pin items", shortcut: nil,
                     description: "Pin frequently used snippets so they survive history clears and appear at the top."),
            ]
        ),
        Feature(
            icon: "lock.shield.fill",
            title: "Privacy & Security",
            items: [
                Item(title: "Password field detection", shortcut: nil,
                     description: "cmd automatically detects copies from password-manager fields and marks them as sensitive. The content is never shown in plain text."),
                Item(title: "Exclude apps", shortcut: nil,
                     description: "In Settings → Privacy, choose any app whose clipboard content cmd should completely ignore — financial apps, 1Password, etc."),
                Item(title: "Encrypted storage", shortcut: nil,
                     description: "All clipboard data is encrypted at rest with AES-256 GCM. The key lives in ~/Library/Application Support/cmd at permissions 0600."),
                Item(title: "Retention control", shortcut: nil,
                     description: "Set history to auto-delete after 7, 30, or 90 days, or keep forever. Old entries are purged on every launch."),
            ]
        ),
        Feature(
            icon: "gearshape.2.fill",
            title: "Customisation",
            items: [
                Item(title: "Hold threshold", shortcut: nil,
                     description: "Adjust how long you hold ⌘V before the HUD appears — from 100 ms (hair-trigger) to 500 ms (deliberate) in Settings → Trigger."),
                Item(title: "Card opacity", shortcut: nil,
                     description: "Slide the card opacity from fully opaque glass to almost-transparent so the HUD never hides what's beneath it."),
                Item(title: "Launch at login", shortcut: nil,
                     description: "cmd installs a LaunchAgent so it starts automatically at login and works from any path — not just /Applications."),
            ]
        ),
    ]
}
