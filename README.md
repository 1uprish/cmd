# cmd

`CMD` is a native macOS clipboard register. Copy normally, then hold `Cmd+V` to open a lightweight HUD beside the current text field and choose from recent clipboard items.

The app is built for the everyday Mac flow: text, links, code, files, images, mixed clipboard payloads, Gather sessions, drag-and-drop, and quick paste without leaving the app you are already using.

## Features

- **Hold `Cmd+V` HUD**: opens a compact floating register near the active text field.
- **Clipboard history**: keeps reusable text, URLs, code, files, colors, rich text, and images.
- **Gather mode**: double `Cmd` opens a cursor-anchored Gather Lens so multiple copied items can become one paste-ready payload.
- **Image and mixed-content support**: handles image-only and text-plus-image clipboard payloads.
- **Drag and drop**: drag saved clips into compatible apps.
- **Sensitive item handling**: secrets and password-like values can be hidden and expired.
- **Settings controls**: opacity, HUD sizing, animation style, retention, excluded apps, and sensitive data behavior.
- **Diagnostics logbook**: local JSONL diagnostics for lifecycle, event tap, pasteboard, append, and performance issues.

## Requirements

- macOS 14 or newer recommended.
- Swift Package Manager.
- Xcode command line tools for building.
- Accessibility permission for global keyboard monitoring and paste orchestration.

For running tests, the active developer directory must provide `XCTest`. A Command Line Tools-only setup may build the app but fail tests with `no such module 'XCTest'`.

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
build/CMD-1.0.0.dmg
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
Sources/ClipLog/       macOS app shell, HUD, menu bar, settings, windows
Sources/ClipLogCore/   clipboard store, pasteboard watcher, event tap, diagnostics
Tests/ClipLogTests/    unit tests for core behavior
scripts/               release, DMG, notarization, and packaging scripts
```

Internal module names still use `ClipLog` / `ClipLogCore` for source stability. The product-facing name is `CMD`.

## Development Notes

- Keep global event handling fast. Anything expensive should leave the event tap path immediately.
- Do not log clipboard contents.
- Do not commit `.build`, `build`, `.app`, `.dmg`, local diagnostics, or user Application Support data.
- Treat Accessibility and pasteboard behavior as high-risk UX paths: verify with the packaged app, not only debug builds.
- Keep storage migrations backward-compatible. Users should not lose history after a rename or rebuild.

## License

This repository is currently **all rights reserved**. Do not redistribute or relicense without explicit permission from the project owner.
