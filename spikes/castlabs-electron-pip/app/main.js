const { app, BrowserWindow, session, shell, ipcMain, components, webContents, screen } = require('electron');
const { spawn } = require('child_process');

const DEFAULT_URL = 'about:blank';
let currentURL = parseStartURL(process.argv);
const isWarmLaunch = process.argv.includes('--warm');

let win;
let mode = 'playback';
let shuttingDown = false;
let isMuted = false;
let dragState;
let shellReady = false;

function parseStartURL(argv) {
  const flagIndex = argv.indexOf('--url');
  const raw = flagIndex >= 0 ? argv[flagIndex + 1] : argv.find(arg => /^https?:\/\//.test(arg));
  if (!raw) return DEFAULT_URL;
  try {
    const url = new URL(raw);
    if (!['http:', 'https:', 'about:'].includes(url.protocol)) return DEFAULT_URL;
    return url.toString();
  } catch {
    return DEFAULT_URL;
  }
}

app.commandLine.appendSwitch('autoplay-policy', 'no-user-gesture-required');
app.commandLine.appendSwitch('enable-features', 'PlatformHEVCDecoderSupport');
app.commandLine.appendSwitch('password-store', 'basic');
if (isWarmLaunch) {
  app.commandLine.appendSwitch('mute-audio');
  app.commandLine.appendSwitch('disable-background-media-suspend');
}
app.setName('CMD OTTPiP');
app.setPath('userData', `${app.getPath('appData')}/CMD-OTTPiP-BasicProfile`);

const singleInstanceLock = app.requestSingleInstanceLock();
if (!singleInstanceLock) {
  app.quit();
} else {
  app.on('second-instance', (_event, argv) => {
    const nextURL = parseStartURL(argv);
    if (nextURL !== DEFAULT_URL) openTargetURL(nextURL);
  });
}

function createWindow() {
  win = new BrowserWindow({
    width: 520,
    height: 292,
    minWidth: 356,
    minHeight: 200,
    frame: false,
    transparent: true,
    roundedCorners: true,
    alwaysOnTop: !isWarmLaunch,
    hasShadow: true,
    resizable: true,
    show: !isWarmLaunch,
    title: 'CMD OTT PiP Spike',
    backgroundColor: '#00000000',
    webPreferences: {
      preload: `${__dirname}/preload.js`,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
      partition: 'persist:cmd-ott-pip',
      webviewTag: true,
      nativeWindowOpen: true
    }
  });

  if (isWarmLaunch) {
    win.setSkipTaskbar(true);
    win.webContents.audioMuted = true;
  }

  win.setAspectRatio(16 / 9);
  win.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true });
  if (!isWarmLaunch) {
    win.setAlwaysOnTop(true, 'floating');
  }

  const ses = session.fromPartition('persist:cmd-ott-pip');
  ses.setPermissionRequestHandler((webContents, permission, callback) => {
    const allowed = new Set(['media', 'fullscreen', 'pictureInPicture']);
    callback(allowed.has(permission));
  });

  win.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url);
    return { action: 'deny' };
  });

  win.webContents.on('render-process-gone', (_event, details) => {
    console.warn('CMD OTT PiP renderer gone:', details);
    win?.reload();
  });

  win.on('close', async event => {
    if (shuttingDown) return;
    event.preventDefault();
    shuttingDown = true;
    await stopPlayback();
    win.destroy();
  });

  win.on('closed', () => {
    win = null;
  });

  win.loadFile(`${__dirname}/shell.html`, { query: { url: currentURL, mode } })
    .then(() => {
      shellReady = true;
      if (!isWarmLaunch || currentURL !== DEFAULT_URL) setPlaybackMode();
    })
    .catch(error => {
      console.error('CMD OTT PiP shell failed:', error);
    });
}

ipcMain.on('cmd-close', () => win?.close());
ipcMain.on('cmd-playback', () => setPlaybackMode());
ipcMain.on('cmd-auth', () => setAuthMode());
ipcMain.on('cmd-toggle-mute', () => toggleMute());
ipcMain.on('cmd-resize', (_event, bounds) => resizeWindow(bounds));
ipcMain.on('cmd-spring-near-cursor', (_event, x, y) => springNearCursor(x, y));
ipcMain.on('cmd-drag-start', (_event, x, y) => startDrag(x, y));
ipcMain.on('cmd-drag-move', (_event, x, y) => moveDrag(x, y));
ipcMain.on('cmd-drag-end', () => { dragState = undefined; });
ipcMain.on('cmd-open-chrome', (_event, url) => openChrome(url));
ipcMain.on('cmd-reload-target', () => reloadTargetURL());
ipcMain.on('cmd-open-external', (_event, url) => {
  if (/^https?:\/\//.test(url)) shell.openExternal(url);
});

function setPlaybackMode() {
  if (!win) return;
  mode = 'playback';
  win.setSkipTaskbar(false);
  win.webContents.audioMuted = false;
  win.setAspectRatio(16 / 9);
  win.setSize(568, 336, true);
  win.center();
  win.show();
  win.setAlwaysOnTop(true, 'floating');
  win.webContents.send('cmd-mode', mode);
}

function toggleMute() {
  isMuted = !isMuted;
  for (const contents of webContents.getAllWebContents()) {
    try { contents.audioMuted = isMuted; } catch (_) {}
  }
  win?.webContents.send('cmd-muted', isMuted);
}

function resizeWindow(bounds) {
  if (!win || win.isDestroyed()) return;
  const current = win.getBounds();
  const next = clampWindowBounds({
    x: Number.isFinite(bounds?.x) ? Math.round(bounds.x) : current.x,
    y: Number.isFinite(bounds?.y) ? Math.round(bounds.y) : current.y,
    width: Math.max(356, Math.round(Number(bounds?.width) || current.width)),
    height: Math.max(200, Math.round(Number(bounds?.height) || current.height))
  });
  win.setBounds(next, false);
}

function startDrag(x, y) {
  if (!win || win.isDestroyed()) return;
  const [windowX, windowY] = win.getPosition();
  dragState = {
    pointerX: Number(x) || 0,
    pointerY: Number(y) || 0,
    windowX,
    windowY
  };
}

function moveDrag(x, y) {
  if (!win || win.isDestroyed() || !dragState) return;
  const nextX = dragState.windowX + (Number(x) || 0) - dragState.pointerX;
  const nextY = dragState.windowY + (Number(y) || 0) - dragState.pointerY;
  const current = win.getBounds();
  const next = clampWindowBounds({ ...current, x: nextX, y: nextY });
  win.setPosition(next.x, next.y, false);
}

function clampWindowBounds(bounds) {
  const center = {
    x: Math.round(bounds.x + bounds.width / 2),
    y: Math.round(bounds.y + bounds.height / 2)
  };
  const display = screen.getDisplayNearestPoint(center);
  const workArea = display.workArea;
  const padding = 8;
  const width = Math.min(Math.round(bounds.width), workArea.width - padding * 2);
  const height = Math.min(Math.round(bounds.height), workArea.height - padding * 2);
  return {
    x: Math.round(clamp(bounds.x, workArea.x + padding, workArea.x + workArea.width - width - padding)),
    y: Math.round(clamp(bounds.y, workArea.y + padding, workArea.y + workArea.height - height - padding)),
    width,
    height
  };
}

function springNearCursor(rawX, rawY) {
  if (!win || win.isDestroyed()) return;
  const point = {
    x: Number.isFinite(rawX) ? rawX : screen.getCursorScreenPoint().x,
    y: Number.isFinite(rawY) ? rawY : screen.getCursorScreenPoint().y
  };
  const display = screen.getDisplayNearestPoint(point);
  const bounds = display.workArea;
  const [width, height] = win.getSize();
  const padding = 14;
  const target = {
    x: clamp(point.x + 28, bounds.x + padding, bounds.x + bounds.width - width - padding),
    y: clamp(point.y + 28, bounds.y + padding, bounds.y + bounds.height - height - padding)
  };
  animateSpringTo(target);
}

function animateSpringTo(target) {
  if (!win || win.isDestroyed()) return;
  let [x, y] = win.getPosition();
  let velocityX = 0;
  let velocityY = 0;
  const stiffness = 0.22;
  const damping = 0.72;
  let frame = 0;
  const timer = setInterval(() => {
    if (!win || win.isDestroyed() || frame++ > 72) {
      clearInterval(timer);
      return;
    }
    velocityX = (velocityX + (target.x - x) * stiffness) * damping;
    velocityY = (velocityY + (target.y - y) * stiffness) * damping;
    x += velocityX;
    y += velocityY;
    if (Math.abs(target.x - x) < 0.5 && Math.abs(target.y - y) < 0.5 && Math.abs(velocityX) < 0.5 && Math.abs(velocityY) < 0.5) {
      win.setPosition(Math.round(target.x), Math.round(target.y), false);
      clearInterval(timer);
      return;
    }
    win.setPosition(Math.round(x), Math.round(y), false);
  }, 1000 / 60);
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(value, max));
}

function setAuthMode() {
  if (!win) return;
  mode = 'auth';
  win.setAspectRatio(0);
  win.setSize(1180, 760, true);
  win.center();
  win.setAlwaysOnTop(false);
  win.webContents.send('cmd-mode', mode);
}

function openChrome(url) {
  if (!/^https?:\/\//.test(url)) return;
  const args = [
    '-na',
    'Google Chrome',
    '--args',
    '--new-window',
    url
  ];
  try {
    const child = spawn('/usr/bin/open', args, {
      detached: true,
      stdio: 'ignore'
    });
    child.unref();
  } catch (_) {
    shell.openExternal(url);
  }
}

function reloadTargetURL() {
  if (!win || win.isDestroyed()) return;
  win.webContents.send('cmd-load-target', currentURL);
}

function openTargetURL(url) {
  currentURL = url;
  mode = 'playback';
  if (!win || win.isDestroyed()) {
    createWindow();
    return;
  }
  setPlaybackMode();
  if (!shellReady) {
    setTimeout(() => openTargetURL(url), 40);
    return;
  }
  win.webContents.send('cmd-load-target', currentURL);
}

async function stopPlayback() {
  if (!win || win.isDestroyed()) return;
  try {
    await win.webContents.executeJavaScript(`
      document.querySelectorAll('webview').forEach(webview => {
        try { webview.stop(); } catch (_) {}
        try { webview.src = 'about:blank'; } catch (_) {}
      });
    `, true);
  } catch (_) {}

  for (const contents of webContents.getAllWebContents()) {
    try { contents.audioMuted = true; } catch (_) {}
    try { contents.stop(); } catch (_) {}
    try { contents.loadURL('about:blank'); } catch (_) {}
  }
}

app.on('before-quit', async event => {
  if (shuttingDown) return;
  event.preventDefault();
  shuttingDown = true;
  await stopPlayback();
  app.exit(0);
});

app.whenReady().then(async () => {
  if (components?.whenReady) {
    try {
      await components.whenReady();
      console.log('CMD OTT PiP components ready:', components.status?.());
    } catch (error) {
      console.warn('CMD OTT PiP components unavailable:', error);
    }
  }
  createWindow();
});

app.on('activate', () => {
  if (!win) createWindow();
});

app.on('window-all-closed', () => {
  if (!isWarmLaunch) app.quit();
});
