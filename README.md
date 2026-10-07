# cmd

`CMD` is a native macOS clipboard register. Copy normally, then hold `Cmd+V` to open a lightweight HUD beside the current text field and choose from recent clipboard items.

It is built for the everyday Mac flow: text, links, code, files, images, colors, rich text, mixed payloads, Gather sessions, drag-and-drop, and quick paste without leaving the app you are already using.

## Features

### Hold `Cmd+V` HUD
- A compact floating register that opens from the cursor and sizes itself to the active text box.
- Spring-based open/dismiss that is interruptible and starts from the current on-screen value.
- Live type-to-filter with a light search bar; search covers the full history (not just the visible cards) and the full stored text, plus OCR text.
- Multi-select (`⌘`/`⇧` click) with an accent ring on the primary row, and `⌘C` to copy the selection.
- Drag a clip into any compatible app. Text drags carry both plain text and a `.txt` file so file-only drop targets still work.
- Image thumbnails are cropped to fill (Photos-style) with a source-app badge; hover a card to peek at the full image.
- Press-and-hold a sensitive clip to reveal it.
- Configurable cards shown (10–60), card opacity, HUD size, and transition style.

### Gather mode
- Double-tap `Cmd` opens a cursor-anchored Gather Lens so multiple copied items become one paste-ready payload (text and images).

### History window
- Browse, search (text + on-device semantic), pin, and re-paste the full archive.
- `⌥1`–`⌥5` quick paste, `⌘⇧V` to queue a selection for sequential pasting.

### Menu bar
- Recent clips submenu, Show History, Features & Guide, Settings, diagnostics, and About.
- Pause capturing (15 minutes / 1 hour / until you resume); the status icon reflects paused, degraded, or normal.
- Prompts to grant Accessibility permission and jumps straight to the right System Settings pane.

### Privacy & security
- Clipboard data is encrypted at rest with AES-256-GCM; the key lives at `~/Library/Application Support/cmd` with `0600` permissions.
- Sensitive content (password-manager concealed types, known apps) is detected, redacted, and can expire.
- Exclude any app from capture; retention control (7/30/90 days or forever).
- Local diagnostics only by default; optional remote anomaly reporting is off unless you enable it.

### Craft & accessibility
- System font with the user's text-size preference; reduced-motion, reduced-transparency, and increased-contrast are honored across the HUD, history window, and Gather lens.
- Optional feedback sounds (copy/paste/capture) harmonized with haptics.

## Requirements

- macOS 14 or newer recommended.
- Swift Package Manager.
- Xcode command line tools for building.
- Accessibility permission for global keyboard monitoring and paste orchestration.

For running tests, the active developer directory must provide `XCTest`. A Command Line Tools-only setup may build the app but fail tests with `no such module 'XCTest'`.

## Install

Download the latest `CMD-1.1.2.dmg` from the [Releases](https://github.com/1uprish/cmd/releases) page, open it, and drag `CMD.app` to Applications. On first launch, grant Accessibility access when prompted (or from the menu bar item).

> Builds are ad-hoc signed unless built with a Developer ID certificate, so Gatekeeper may warn on first open. To bypass for a local build: right-click the app → Open, or `xattr -dr com.apple.quarantine /Applications/CMD.app`.

## Permissions

`cmd` needs **Accessibility** to intercept `⌘V` at the HID level and to synthesize paste. The menu bar shows a warning icon and a **Grant Accessibility Permission…** item until it is granted; that item opens System Settings → Privacy & Security → Accessibility directly.

## Setup

For install, first-run, development, permissions, diagnostics, and release signing instructions, read [SETUP.md](SETUP.md).

## Build Locally

```bash
swift build
```

## Build A Local App Bundle

For local testing without a Developer ID certificate:

```bash
ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh
open build/CMD.app
```

## Build A DMG

```bash
ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh
./scripts/build-dmg.sh
```

The DMG is written to:

```text
build/CMD-1.1.2.dmg
```

Ad-hoc DMGs are useful for local testing. For friends or public distribution, use a Developer ID Application certificate and notarize the release.

## Professional Release Flow

1. Install a Developer ID Application certificate in Keychain.
2. Build the signed app:

   ```bash
   SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-release.sh
   ```

3. Notarize:

   ```bash
   TARGET_PATH="build/CMD.app" NOTARY_PROFILE=cmdNotary ./scripts/notarise.sh
   ```

4. Package the release:

   ```bash
   NOTARY_PROFILE=cmdNotary ./scripts/package-release.sh
   ```

Without Apple Developer Program membership, you can still build and share an ad-hoc DMG, but Gatekeeper will warn recipients because the app is not Developer ID signed and notarized.

## Diagnostics

`cmd` writes local operational diagnostics to:

```text
~/Library/Application Support/cmd/Diagnostics/cmd.log
```

The log is JSON Lines and intentionally avoids clipboard contents. It records events such as app launch, event tap state, append sessions, slow pasteboard polls, and main-thread stalls.

## Repository Layout

```text
Sources/ClipLog/        macOS app shell, HUD, history window, menu bar, settings, design system
Sources/ClipLogCore/    clipboard store, pasteboard watcher, event tap, search, OCR, transforms
Tests/ClipLogTests/     unit tests for core behavior
scripts/                release, DMG, notarization, packaging, and icon scripts
```

Internal module names still use `ClipLog` / `ClipLogCore` for source stability. The product-facing name is `CMD`.

## Development Notes

- Keep global event handling fast. Anything expensive should leave the event tap path immediately.
- Do not log clipboard contents.
- Do not commit `.build`, `.build-release-scratch`, `build`, `.app`, `.dmg`, local diagnostics, or user Application Support data.
- Treat Accessibility and pasteboard behavior as high-risk UX paths: verify with the packaged app, not only debug builds.
- Keep storage migrations backward-compatible. Users should not lose history after a rename or rebuild.

## License

This repository is currently **all rights reserved**. Do not redistribute or relicense without explicit permission from the project owner.
