# Contributing

`cmd` is a native macOS app with global keyboard and pasteboard behavior. Changes should be small, verified, and respectful of user data.

## Development Setup

```bash
swift build
```

Run tests when your local Xcode toolchain provides `XCTest`:

```bash
swift test
```

Build the packaged app for manual verification:

```bash
ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh
open build/CMD.app
```

## Quality Bar

- Keep event tap handlers minimal and non-blocking.
- Never log clipboard contents, secrets, images, file paths from user clips, or paste payloads.
- Keep diagnostics operational: event names, durations, counts, state changes.
- Preserve backward compatibility for stored clips and media.
- Verify image, text, rich, file, and append flows after pasteboard changes.
- Verify the packaged `build/CMD.app`, not only `swift run`.

## Manual QA Checklist

- Launch app and confirm menu bar item appears.
- Grant Accessibility permission if needed.
- Copy text and hold `Cmd+V`; HUD opens near the active text field.
- Release/dismiss HUD and open it again repeatedly.
- Copy an image and confirm thumbnail, drag, copy, and paste behavior.
- Start append mode with double `Cmd`; append multiple text clips.
- Append mixed text and image content; paste into a rich target and a plain text target.
- Confirm sensitive-looking text is redacted/handled according to settings.
- Open Settings and verify opacity, sizing, and animation controls.
- Open Diagnostics Log and confirm no clipboard contents are recorded.

## Release Checklist

- `swift build` passes.
- `swift test` passes on a full Xcode toolchain.
- `ALLOW_ADHOC=1 SIGNING_IDENTITY=- ./scripts/build-release.sh` passes locally.
- `./scripts/build-dmg.sh` passes locally.
- Developer ID build is signed, notarized, stapled, and verified before public distribution.
