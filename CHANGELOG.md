# Changelog

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
