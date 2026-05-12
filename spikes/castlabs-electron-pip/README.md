# CMD OTT Mini-Browser Spike

Reversible experiment for a custom floating Chromium-class window.

This is not wired into CMD. It is a standalone spike under `spikes/`.

## Run

```sh
cd /Users/arv/Desktop/cmd/spikes/castlabs-electron-pip
npm install
npm run start:youtube
```

Custom URL:

```sh
npm run start:url -- https://www.netflix.com/
```

## What To Test

- YouTube loads.
- Window floats above other apps.
- Window has rounded corners.
- Dragging top area moves it.
- Close button works.
- Logged-in OTT pages load.
- DRM playback succeeds or fails cleanly.

## Notes

This currently uses stock Electron so we can validate shell/window UX quickly.
For DRM tests, swap dependency to Castlabs downstream Electron once the exact
release artifact is selected.

No screen capture, frame extraction, or DRM bypass is used.
