const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('cmdPiP', {
  close: () => ipcRenderer.send('cmd-close'),
  playback: () => ipcRenderer.send('cmd-playback'),
  auth: () => ipcRenderer.send('cmd-auth'),
  toggleMute: () => ipcRenderer.send('cmd-toggle-mute'),
  resize: bounds => ipcRenderer.send('cmd-resize', bounds),
  springNearCursor: (x, y) => ipcRenderer.send('cmd-spring-near-cursor', x, y),
  dragStart: (x, y) => ipcRenderer.send('cmd-drag-start', x, y),
  dragMove: (x, y) => ipcRenderer.send('cmd-drag-move', x, y),
  dragEnd: () => ipcRenderer.send('cmd-drag-end'),
  reloadTarget: () => ipcRenderer.send('cmd-reload-target'),
  openChrome: url => ipcRenderer.send('cmd-open-chrome', url),
  openExternal: url => ipcRenderer.send('cmd-open-external', url),
  onMuted: callback => ipcRenderer.on('cmd-muted', (_event, muted) => callback(muted)),
  onLoadTarget: callback => ipcRenderer.on('cmd-load-target', (_event, targetURL) => callback(targetURL))
});

window.addEventListener('beforeunload', () => {
  document.querySelectorAll('video,audio').forEach(media => {
    try { media.pause(); } catch (_) {}
    try { media.muted = true; } catch (_) {}
    try { media.src = ''; media.load(); } catch (_) {}
  });
});
