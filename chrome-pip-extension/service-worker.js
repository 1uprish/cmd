async function runPiP(tab) {
  if (!tab?.id) return;

  try {
    const frameResults = await chrome.scripting.executeScript({
      target: { tabId: tab.id, allFrames: true },
      world: "MAIN",
      func: requestCMDPictureInPicture
    });
    const result = frameResults.find(frameResult => frameResult?.result?.ok)?.result
      || frameResults[0]?.result;

    console.info("CMD Browser PiP:", result);
  } catch (error) {
    console.warn("CMD Browser PiP failed:", error);
  }
}

chrome.action.onClicked.addListener(runPiP);

chrome.commands.onCommand.addListener(async command => {
  if (command !== "toggle-pip") return;
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  await runPiP(tab);
});

async function requestCMDPictureInPicture() {
  const videos = collectVideos(document)
    .filter(video => video.readyState >= 1)
    .filter(video => !video.disablePictureInPicture)
    .sort((left, right) => visibleArea(right) - visibleArea(left));

  const video = videos[0];
  if (!video) {
    return { ok: false, reason: "no_eligible_video" };
  }

  try {
    if (document.pictureInPictureElement === video) {
      await document.exitPictureInPicture();
      return { ok: true, action: "exit" };
    }

    if (document.pictureInPictureElement) {
      await document.exitPictureInPicture();
    }

    await video.requestPictureInPicture();
    return {
      ok: true,
      action: "enter",
      src: video.currentSrc || video.src || "media-stream",
      width: video.videoWidth,
      height: video.videoHeight
    };
  } catch (error) {
    return {
      ok: false,
      reason: "request_failed",
      name: error?.name || "Error",
      message: error?.message || String(error)
    };
  }

  function collectVideos(root) {
    const found = Array.from(root.querySelectorAll?.("video") || []);
    const elements = Array.from(root.querySelectorAll?.("*") || []);

    for (const element of elements) {
      if (element.shadowRoot) {
        found.push(...collectVideos(element.shadowRoot));
      }
    }

    return found;
  }

  function visibleArea(element) {
    const rect = element.getBoundingClientRect();
    const width = Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0));
    const height = Math.max(0, Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0));
    return width * height;
  }
}
