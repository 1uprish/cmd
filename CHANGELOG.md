# Changelog

## 1.1.2

- Drag: image drags rewrite their cached file when tmp cleanup removes it, instead of serving a dead URL for older clips.
- Capture: ingest warms only the fresh entry instead of decrypting the 20 most recent on every copy — the main cost behind slow capture polls.
- Telemetry: hover peek, multi-select, sensitive reveal, thumbnails, focus anchoring, embeddings, OCR, tap transitions, pause/resume, and empty captures are now traced; LoggingTests assert the load-bearing telemetry fires.
- Hover peek diagnostics now pinpoint scheduling vs presentation failures.

## 1.1.1

- HUD: holding `Cmd-V` no longer leaks the V key's auto-repeats to the app behind the panel — the repeated-paste flicker behind the HUD is gone.
- Gather: HUD navigation keys (arrows, Return, filter typing) and a stray Escape no longer end an active gather session; the session now survives until you toggle it, paste, type into a document, or it times out.
- Gather: pasting a card from the HUD ends the session cleanly instead of merging the pasted card back into the gathered payload.
- HUD: image card thumbnails no longer flash when rows rebuild (filter typing, cancelled-drag restore).
- HUD: a cancelled drag restores the pre-drag filter and selection in a single rebuild, with no second resize pass.
- Reliability: the capture-pause flag is now synchronized with the pasteboard watcher queue.

## 1.1.0

- Removed CursorPiP, the Inspiration Journal, and the Onboarding walkthrough.
- HUD: spring-based, interruptible open/dismiss; materialized rows; removed the dark scroll-edge fade.
- HUD selection: fixed the first-arrow skip and restored shift range-select; accent ring on the primary row; outside-click, Space change, and display sleep no longer paste a multi-selection.
- HUD search: visible filter bar while typing, full-history and full-text search, and a configurable cards-in-HUD setting (10–60).
- HUD images: aspect-fill thumbnails with a source-app badge and a hover peek of the full image.
- Sensitive clips: press-and-hold to reveal.
- Menu bar: Recent submenu, About, Pause Capturing with status-icon states, and a Grant Accessibility Permission item.
- Settings: sidebar layout, specific section names, Reset to Defaults, and a feedback-sound preview.
- Accessibility: reduced-motion, reduced-transparency, and increased-contrast support, plus text-size scaling.
- Feedback: optional bundled sounds harmonized with haptics.
- Drag: text drags offer both plain text and a `.txt` file so file-only drop targets work.
- Search: embeddings use the full clip text instead of the truncated preview.
- Fixed deterministic HUD text-input anchoring across multiple displays.

## 1.0.0

- Renamed the product-facing app to `cmd`.
- Added the hold `Cmd+V` clipboard HUD.
- Added opacity, sizing, and animation settings.
- Added append mode with double `Cmd`.
- Added text, image, mixed-content, file, URL, code, color, and rich clipboard support.
- Added drag-and-drop support for saved clips.
- Added sensitive-content detection, redaction, and expiry support.
- Added local diagnostics logbook for lifecycle, event tap, pasteboard, append, and performance events.
- Hardened append preview animation to avoid idle CPU loops.
- Hardened media cleanup for deleted and expired clips.
