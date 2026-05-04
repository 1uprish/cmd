# Setup

This guide covers installing, building, and preparing `CMD` for local development or direct distribution.

## Install From A DMG

1. Open the DMG.
2. Drag `CMD.app` into `Applications`.
3. Open `CMD.app`.
4. If macOS warns that the app cannot be verified, open **System Settings -> Privacy & Security**, scroll to the blocked app message, and choose **Open Anyway**.
5. Grant Accessibility permission when prompted.

Accessibility is required because `cmd` needs to detect the hold `Cmd+V` gesture and paste the selected clipboard item back into the active app.

## First Run

After launch:

1. Confirm the `cmd` menu bar icon appears.
2. Copy any text.
3. Focus a text field in another app.
4. Hold `Cmd+V`.
5. Choose an item from the HUD or press `Return` to paste the selected item.

Append mode:

1. Double tap `Cmd`.
2. Copy multiple text or image items.
3. Paste normally to use the combined append payload.
4. The append session auto-expires after a short timeout.

## Build From Source

Requirements:

- macOS 14 or newer recommended.
- Xcode or Xcode Command Line Tools.
- Swift Package Manager.

Clone and build:

```bash
git clone https://github.com/onedownz01/cmd.git
cd cmd
swift package resolve
swift build
```

Build a local app bundle:

```bash
ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh
open build/CMD.app
```

Build a local DMG:

```bash
ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh
./scripts/build-dmg.sh
```

Generated artifacts stay in `build/` and should not be committed.

## Run Tests

```bash
swift test
```

If this fails with `no such module 'XCTest'`, switch to a full Xcode developer directory:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Then rerun:

```bash
swift test
```

## Accessibility Permission Reset

During local development, ad-hoc rebuilt apps may need Accessibility permission again because macOS treats each rebuilt binary as a new code-signing identity.

If the HUD does not open:

1. Quit `cmd`.
2. Open **System Settings -> Privacy & Security -> Accessibility**.
3. Remove old `cmd` entries if they are stale.
4. Reopen `build/CMD.app`.
5. Grant Accessibility again.

The app also attempts to reset stale legacy entries when it detects a trusted-but-unusable event tap.

## Diagnostics

Open diagnostics from:

```text
cmd -> Open Diagnostics Log
```

The file is stored at:

```text
~/Library/Application Support/cmd/Diagnostics/cmd.log
```

Diagnostics are JSON Lines and should not contain clipboard contents. They record operational events such as launch, event tap start/stop, append sessions, slow pasteboard polls, and main-thread stalls.

## Local Data

Runtime data:

```text
~/Library/Application Support/cmd
```

Media payloads:

```text
~/Library/Application Support/cmd/Media
```

Do not commit local runtime data, media, diagnostics, `.build/`, or `build/`.

## Release Signing

Local ad-hoc builds are enough for personal testing:

```bash
ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh
```

For public distribution, use a Developer ID Application certificate:

```bash
SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build-release.sh
```

Then notarize:

```bash
TARGET_PATH="build/CMD.app" NOTARY_PROFILE=cmdNotary ./scripts/notarise.sh
```

Package a full release:

```bash
NOTARY_PROFILE=cmdNotary ./scripts/package-release.sh
```

Without Developer ID signing and notarization, other Macs may show Gatekeeper warnings.

## Troubleshooting

### HUD Does Not Open

- Confirm Accessibility permission is enabled.
- Quit and relaunch `cmd`.
- Rebuild and reopen `build/CMD.app`.
- Check diagnostics for event tap start or disabled events.

### App Feels Slow

- Open the diagnostics log and check for `main_thread_stall` or `slow_pasteboard_poll`.
- Quit old copies of `cmd` before launching a new build.
- Verify only one `CMD.app` instance is running.

### Images Do Not Paste Into A Target App

- Try a rich target first, such as Messages, Notes, or a browser editor.
- Plain text fields may accept only the text portion of a mixed append payload.
- For file-like image attachments, drag and drop may work better than paste depending on the target app.

### GitHub Rejects The Push

Do not commit generated files:

```text
.build/
build/
*.app
*.dmg
```

If they appear in GitHub Desktop, undo the commit, make sure `.gitignore` is present, and recommit only source, tests, scripts, and docs.
