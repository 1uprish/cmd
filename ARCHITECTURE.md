# CGEventTap — architecture notes

## The suppression race — why we suppress immediately

The naive approach is:
  keyDown → start timer → if timer fires, suppress → show HUD

This is WRONG. CGEvent delivery is not reversible. The moment you return
`Unmanaged.passRetained(event)` from the callback, the event is delivered
downstream. You cannot recall it.

The correct approach (implemented here):
  keyDown → suppress immediately (return nil) → start timer
  If keyUp before 180ms: synthesise a NEW ⌘V via CGEventPost → passthrough
  If timer fires first: trigger HUD

This means the user always gets their paste — either via the original event
(suppressed + re-synthesised) or via HUD selection. The 180ms gap is
imperceptible for normal paste speed.

## Why .cghidEventTap + .cgSessionEventTap for re-injection

Tap level: kCGHIDEventTap
  - Intercepts before the OS event dispatcher
  - Requires Accessibility permission
  - Runs on a dedicated CFRunLoop thread

Re-injection level: .cgSessionEventTap
  - Posts below our own tap in the chain
  - Prevents the re-synthesised event from re-entering our callback
  - This is the correct level for "pass this event along as if we never saw it"

If we post at .cghidEventTap, our callback sees the event again → infinite loop.

## Threading model

tapRunLoop thread (CFRunLoop)
  └── eventTapCallback (C function, no Swift captures)
        └── tapQueue.sync { tap.handle(event:type:) }
              ├── state machine transitions
              ├── timer.cancel() / timer.resume()
              └── DispatchQueue.main.async { onHUDTrigger / onPassthrough }

Rules:
- tapQueue is the single writer of `state`
- Timer eventHandler also runs on tapQueue (scheduled on tapQueue)
- No main thread work inside tapQueue.sync (deadlock risk)
- All UI callbacks dispatched async to main

## Tap health monitoring

CGEventTaps can be disabled by the OS if the callback takes too long
(default timeout: ~1 second). If this happens, the tap silently stops
working — no error, keyboard just behaves normally (no HUD).

Mitigation: poll CGEvent.tapIsEnabled() every 5 seconds on a background
timer and re-enable if needed. Add a menu bar status indicator.

## Password manager sensitivity detection — layered defence

Layer 1: NSPasteboardTypeConcealed ("org.nspasteboard.ConcealedType")
  Set by 1Password, Bitwarden, etc. before writing the real data.
  Check presence of this type BEFORE reading any content.
  Cost: zero — just a type presence check.

Layer 2: Source app bundle ID exclusion
  We capture the frontmost app at copy time via NSWorkspace.
  Known password manager bundles hardcoded + user-configurable.
  Cost: one NSWorkspace lookup per copy event.

Layer 3: Content heuristic (NOT implemented — too fragile)
  Regex for password patterns is unreliable and privacy-invasive.
  We deliberately do NOT inspect content for sensitivity.
  The above two layers are sufficient and more privacy-respecting.
