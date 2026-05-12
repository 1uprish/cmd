# CMD Browser PiP Spike

Reversible Chrome companion experiment for OTT services.

This uses Chrome's official `video.requestPictureInPicture()` API. It does not capture pixels, inspect DRM keys, extract streams, or bypass service controls.

## Install

1. Open `chrome://extensions`.
2. Enable Developer Mode.
3. Click Load Unpacked.
4. Choose this folder:

```text
/Users/arv/Desktop/cmd/.codex-spikes/chrome-pip-extension
```

## Test Matrix

| Service | Expected | Notes |
|---|---|---|
| YouTube | likely works | open video, click extension |
| JioCinema | unknown | test logged-in playback |
| Prime Video | unknown | DRM may allow Chrome PiP |
| Netflix | unknown | may disable PiP |
| Hotstar | unknown | test logged-in playback |

## Use

Open a video in Chrome, then click the extension icon or press `Option+P`.

## Remove

Delete the unpacked extension in `chrome://extensions`, then remove this folder.
