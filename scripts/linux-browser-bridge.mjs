#!/usr/bin/env bun
// Local Chromium + Xvfb bridge for Float on exact-linux.
// Runs real Chromium on a dedicated Xvfb framebuffer (with audio via PipeWire/ALSA),
// serves fast PNG frames over http://127.0.0.1:17420, and handles Float commands,
// pointer clicks, scrolling, keyboard input, Video Fill, and playback tracking.

import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { deflateSync } from 'node:zlib';

const PORT = Number(process.env.FLOAT_BRIDGE_PORT || 17420);
const WIDTH = Number(process.env.FLOAT_BRIDGE_WIDTH || 1280);
const HEIGHT = Number(process.env.FLOAT_BRIDGE_HEIGHT || 800);
const DISPLAY_NUM = process.env.FLOAT_BRIDGE_DISPLAY || ':99';
const FB_DIR = '/dev/shm/float-xvfb';
const FB_FILE = `${FB_DIR}/Xvfb_screen0`;
const STATE_DIR = resolve(process.env.XDG_DATA_HOME || resolve(homedir(), '.local/share'), 'exact/com.sethwebster.float/data');
const STATE_FILE = resolve(STATE_DIR, 'float.json');
const PROFILE_DIR = resolve(process.env.XDG_DATA_HOME || resolve(homedir(), '.local/share'), 'float-chromium');
const EXACT_DIR = process.env.EXACT || process.env.EXACT2 || (existsSync(resolve(homedir(), 'exact/node_modules/playwright-core')) ? resolve(homedir(), 'exact') : resolve(homedir(), 'exact2'));

const { chromium } = await import(resolve(EXACT_DIR, 'node_modules/playwright-core/index.mjs'));

function findChromiumExecutable() {
  try {
    const def = chromium.executablePath();
    if (def && existsSync(def)) return def;
  } catch {}
  const base = resolve(homedir(), '.cache/ms-playwright');
  if (existsSync(base)) {
    for (const entry of readdirSync(base).sort().reverse()) {
      if (!entry.startsWith('chromium-')) continue;
      for (const rel of ['chrome-linux/chrome', 'chrome-linux64/chrome', 'chrome-linux-arm64/chrome']) {
        const p = resolve(base, entry, rel);
        if (existsSync(p)) return p;
      }
    }
  }
  return undefined;
}

// Precompute CRC32 table for fast PNG encoding
const CRC_TABLE = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let c = i;
  for (let k = 0; k < 8; k++) c = (c & 1) ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
  CRC_TABLE[i] = c >>> 0;
}

function crc32(buf) {
  let c = 0xffffffff;
  for (let i = 0; i < buf.length; i++) c = CRC_TABLE[(c ^ buf[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const out = new Uint8Array(12 + data.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, data.length, false);
  out[4] = type.charCodeAt(0);
  out[5] = type.charCodeAt(1);
  out[6] = type.charCodeAt(2);
  out[7] = type.charCodeAt(3);
  out.set(data, 8);
  const crc = crc32(out.subarray(4, 8 + data.length));
  view.setUint32(8 + data.length, crc, false);
  return out;
}

const PNG_SIG = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);
const IEND_CHUNK = pngChunk('IEND', new Uint8Array(0));
let rawRgbScratch = null;
let cachedIhdr = null;
let cachedDims = { w: 0, h: 0 };

function encodeXwdToPng(xwdBuf) {
  if (xwdBuf.byteLength < 100) return null;
  const view = new DataView(xwdBuf.buffer, xwdBuf.byteOffset, xwdBuf.byteLength);
  const headerSize = view.getUint32(0, false);
  const width = view.getUint32(16, false);
  const height = view.getUint32(20, false);
  const bpp = view.getUint32(44, false);
  const bpl = view.getUint32(48, false);
  const ncolors = view.getUint32(76, false);
  const pixelOffset = headerSize + ncolors * 12;
  if (!width || !height || (bpp !== 32 && bpp !== 24)) return null;
  if (pixelOffset + height * bpl > xwdBuf.byteLength) return null;

  const stride = width * 3 + 1;
  if (!rawRgbScratch || cachedDims.w !== width || cachedDims.h !== height) {
    rawRgbScratch = new Uint8Array(height * stride);
    const ihdr = new Uint8Array(13);
    const iv = new DataView(ihdr.buffer);
    iv.setUint32(0, width, false);
    iv.setUint32(4, height, false);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // RGB color type
    cachedIhdr = pngChunk('IHDR', ihdr);
    cachedDims = { w: width, h: height };
  }

  const raw = rawRgbScratch;
  const step = bpp === 32 ? 4 : 3;
  for (let y = 0; y < height; y++) {
    let src = pixelOffset + y * bpl;
    let dst = y * stride;
    raw[dst++] = 0; // filter None
    for (let x = 0; x < width; x++) {
      // Xvfb 24-bit depth in 32-bit pixels is little-endian BGRX
      raw[dst++] = xwdBuf[src + 2];
      raw[dst++] = xwdBuf[src + 1];
      raw[dst++] = xwdBuf[src];
      src += step;
    }
  }

  const idatData = deflateSync(raw, { level: 1 });
  const idat = pngChunk('IDAT', idatData);
  const out = new Uint8Array(PNG_SIG.length + cachedIhdr.length + idat.length + IEND_CHUNK.length);
  let pos = 0;
  out.set(PNG_SIG, pos); pos += PNG_SIG.length;
  out.set(cachedIhdr, pos); pos += cachedIhdr.length;
  out.set(idat, pos); pos += idat.length;
  out.set(IEND_CHUNK, pos);
  return out;
}

function quickHash(buf) {
  let h = 2166136261;
  const step = Math.max(1, Math.floor(buf.length / 2048));
  for (let i = 128; i < buf.length; i += step) {
    h ^= buf[i];
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h;
}

// Float URL, site name, title, and Video Fill helpers (mirrors app.ts & FloatModule.swift)
function siteName(host) {
  const skip = new Set(['www', 'm', 'watch', 'play', 'app']);
  const parts = host.split('.').filter((p) => p && !skip.has(p));
  const core = parts.length > 1 ? parts[parts.length - 2] : (parts[0] ?? host);
  return core ? core.slice(0, 1).toUpperCase() + core.slice(1) : host;
}

function cleanTitle(title, host) {
  const name = siteName(host).toLowerCase();
  for (const sep of [' | ', ' - ', ' – ']) {
    const idx = title.lastIndexOf(sep);
    if (idx !== -1 && title.slice(idx + sep.length).toLowerCase().includes(name)) {
      const head = title.slice(0, idx);
      return head.startsWith('Watch ') ? head.slice(6) : head;
    }
  }
  return title;
}

function parseWebUrl(raw) {
  const s = String(raw || '').trim();
  if (!s) return null;
  let candidate;
  if (s.includes('://')) candidate = s;
  else if (s.includes('.') && !s.includes(' ')) candidate = 'https://' + s;
  else candidate = 'https://www.youtube.com/results?search_query=' + encodeURIComponent(s);
  try {
    const u = new URL(candidate);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    return u.toString();
  } catch {
    return null;
  }
}

function fillScript(on) {
  return `(() => {
    const ON = ${Boolean(on)}, ATTR = 'data-fp-pin', ID = '__fp_pin_style';
    const CSS = \`
      html:has([\${ATTR}]), html:has([\${ATTR}]) body { overflow: hidden !important; }
      [\${ATTR}] { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important;
        max-width: none !important; max-height: none !important; margin: 0 !important; transform: none !important;
        z-index: 2147483647 !important; background: #000 !important; }
      [\${ATTR}] [data-fp-path] { width: 100% !important; height: 100% !important; max-width: none !important; max-height: none !important; }
      [\${ATTR}] video[data-fp-path] { position: absolute !important; inset: 0 !important; }
      [\${ATTR}] video, video[\${ATTR}] { object-fit: contain !important; }\`;
    const main = () => [...document.querySelectorAll('video')]
      .filter(v => v.currentSrc && v.currentTime > 0 && v.offsetWidth * v.offsetHeight > innerWidth * innerHeight * 0.15)
      .sort((a, b) => b.offsetWidth * b.offsetHeight - a.offsetWidth * a.offsetHeight)[0];
    function player(v) {
      const r = v.getBoundingClientRect();
      let p = v;
      for (let e = v.parentElement; e && e !== document.body; e = e.parentElement) {
        const b = e.getBoundingClientRect();
        if (!b.width || !b.height) continue;
        const w = Math.abs(b.width - r.width) < 4, h = Math.abs(b.height - r.height) < 4;
        if (!(w || h) || b.width > innerWidth + 4 || b.height > innerHeight + 4) break;
        p = e;
      }
      return p;
    }
    function apply() {
      const cur = document.querySelector(\`[\${ATTR}]\`);
      const curVid = cur && (cur.matches('video') ? cur : cur.querySelector('video'));
      if (ON && curVid && curVid.currentSrc) return;
      cur && cur.removeAttribute(ATTR);
      document.querySelectorAll('[data-fp-path]').forEach(e => e.removeAttribute('data-fp-path'));
      let s = document.getElementById(ID);
      if (!ON) { s && s.remove(); cur && dispatchEvent(new Event('resize')); return; }
      if (!s) { s = document.createElement('style'); s.id = ID; s.textContent = CSS; (document.head || document.documentElement).appendChild(s); }
      const v = main();
      if (!v) return;
      const p = player(v);
      p.setAttribute(ATTR, '');
      for (let e = v; e && e !== p; e = e.parentElement) e.setAttribute('data-fp-path', '');
      dispatchEvent(new Event('resize'));
    }
    apply();
    clearInterval(window.__fpTimer);
    if (ON) window.__fpTimer = setInterval(apply, 1000);
  })();`;
}

const DEFAULT_STATE = {
  mode: 'home',
  currentUrl: '',
  history: [],
  historyIndex: -1,
  fill: true,
  onTop: true,
  expanded: false,
  aspectLocked: false,
  clickThrough: false,
  alpha: 1,
  hotkeyLabel: '⌃⌥⌘F',
  peekTrigger: 'rightCommand',
  peekAlpha: 0.5,
  peekHotkeyLabel: '⌃⌥⌘D',
  peekHold: true,
  peeking: false,
  settingsOpen: false,
  shortcutsOpen: false,
  lastDock: -1,
  resume: null,
  sites: [],
};

function loadState() {
  try {
    if (existsSync(STATE_FILE)) {
      return { ...DEFAULT_STATE, ...JSON.parse(readFileSync(STATE_FILE, 'utf8')) };
    }
  } catch {}
  return { ...DEFAULT_STATE, sites: [], history: [] };
}

function saveState(st) {
  try {
    mkdirSync(STATE_DIR, { recursive: true });
    writeFileSync(STATE_FILE, JSON.stringify(st));
  } catch (e) {
    console.error('saveState failed:', e);
  }
}

const data = loadState();
let frameSeq = 1;
let lastHash = 0;
let latestPng = null;

function buildFloatState() {
  const sites = [...data.sites]
    .sort((a, b) => b.last - a.last)
    .map((s) => {
      const name = siteName(s.host);
      return {
        host: s.host,
        url: s.url,
        icon: s.icon || `${s.url}/favicon.ico`,
        name,
        initial: name.slice(0, 1) || '?',
        last: s.last,
        count: s.count,
      };
    });

  let hasResume = false;
  let resumeUrl = '';
  let resumeTitle = '';
  let resumeHost = '';
  let resumeIcon = '';
  let resumeTime = 0;
  let resumeDuration = 0;

  if (data.resume) {
    try {
      const host = new URL(data.resume.url).host;
      if (host) {
        hasResume = true;
        resumeUrl = data.resume.url;
        resumeHost = host;
        resumeTitle = data.resume.title || siteName(host);
        const matched = sites.find((s) => s.host === host);
        resumeIcon = matched ? matched.icon : `https://${host}/favicon.ico`;
        resumeTime = data.resume.time;
        resumeDuration = data.resume.duration;
      }
    } catch {}
  }

  return {
    mode: data.mode,
    currentUrl: data.currentUrl,
    fill: data.fill,
    onTop: data.onTop,
    expanded: data.expanded,
    aspectLocked: data.aspectLocked,
    clickThrough: data.clickThrough,
    alpha: data.alpha,
    hotkeyLabel: data.hotkeyLabel,
    peekTrigger: data.peekTrigger,
    peekAlpha: data.peekAlpha,
    peekHotkeyLabel: data.peekHotkeyLabel,
    peekHold: data.peekHold,
    peeking: data.peeking,
    settingsOpen: data.settingsOpen,
    shortcutsOpen: data.shortcutsOpen,
    peekPermissionGranted: true,
    canCheckUpdates: false,
    nativeBackdrop: false,
    browserFrame: data.mode === 'web' && latestPng ? `http://127.0.0.1:${PORT}/frame/${frameSeq}.png` : '',
    hasResume,
    resumeUrl,
    resumeTitle,
    resumeHost,
    resumeIcon,
    resumeTime,
    resumeDuration,
    sites,
  };
}

// 1. Start Xvfb with raw framebuffer file in /dev/shm
mkdirSync(FB_DIR, { recursive: true });
rmSync(`/tmp/.X${DISPLAY_NUM.replace(':', '')}-lock`, { force: true });
const xvfb = spawn('Xvfb', [DISPLAY_NUM, '-screen', '0', `${WIDTH}x${HEIGHT}x24`, '-fbdir', FB_DIR, '-nolisten', 'tcp', '-ac'], {
  stdio: 'ignore',
});
xvfb.on('exit', (code) => {
  console.error('Xvfb exited with code', code);
  process.exit(1);
});

for (let i = 0; i < 50 && !existsSync(FB_FILE); i++) {
  await Bun.sleep(100);
}
if (!existsSync(FB_FILE)) {
  console.error('Xvfb framebuffer did not appear at', FB_FILE);
  process.exit(1);
}

// 2. Launch persistent Chromium inside Xvfb (fullscreen = exact 1280x800, zero browser chrome)
mkdirSync(PROFILE_DIR, { recursive: true });
const context = await chromium.launchPersistentContext(PROFILE_DIR, {
  headless: false,
  executablePath: findChromiumExecutable(),
  viewport: { width: WIDTH, height: HEIGHT },
  colorScheme: 'dark',
  env: { ...process.env, DISPLAY: DISPLAY_NUM },
  args: [
    '--start-fullscreen',
    '--kiosk',
    '--window-position=0,0',
    `--window-size=${WIDTH},${HEIGHT}`,
    '--autoplay-policy=no-user-gesture-required',
    '--no-sandbox',
    '--disable-dev-shm-usage',
    '--disable-infobars',
    '--disable-session-crashed-bubble',
    '--hide-crash-restore-bubble',
    '--disable-features=TranslateUI',
    '--force-dark-mode',
    '--no-first-run',
    '--no-default-browser-check',
  ],
  ignoreDefaultArgs: ['--enable-automation'],
});

const page = context.pages()[0] || await context.newPage();
await page.setViewportSize({ width: WIDTH, height: HEIGHT });
try {
  const cdp = await context.newCDPSession(page);
  const { windowId } = await cdp.send('Browser.getWindowForTarget');
  await cdp.send('Browser.setWindowBounds', {
    windowId,
    bounds: { windowState: 'fullscreen' },
  });
} catch {}

function recordSite(urlStr, icon) {
  try {
    const u = new URL(urlStr);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return;
    const host = u.host;
    const existing = data.sites.find((s) => s.host === host);
    const stamp = Math.floor(Date.now() / 1000);
    if (existing) {
      existing.last = stamp;
      existing.count += 1;
      if (icon) existing.icon = icon;
    } else {
      data.sites.push({
        host,
        url: `${u.protocol}//${host}`,
        icon: icon || `${u.protocol}//${host}/favicon.ico`,
        last: stamp,
        count: 1,
      });
    }
    saveState(data);
  } catch {}
}

page.on('framenavigated', async (frame) => {
  if (frame !== page.mainFrame()) return;
  const u = page.url();
  if (u && (u.startsWith('http://') || u.startsWith('https://'))) {
    data.currentUrl = u;
    saveState(data);
    try {
      await page.evaluate(fillScript(data.fill));
    } catch {}
  }
});

// Poll playback progress every 3s for Home mosaic & Resume card
setInterval(async () => {
  if (data.mode !== 'web') return;
  try {
    const info = await page.evaluate(() => {
      const v = [...document.querySelectorAll('video')]
        .filter((el) => el.currentSrc && el.duration > 0)
        .sort((a, b) => b.offsetWidth * b.offsetHeight - a.offsetWidth * a.offsetHeight)[0];
      if (!v) return null;
      const ms = navigator.mediaSession && navigator.mediaSession.metadata;
      const og = document.querySelector('meta[property="og:title"]');
      const title = (ms && ms.title) ? (ms.artist ? `${ms.title} · ${ms.artist}` : ms.title) : ((og && og.content) || document.title);
      const links = [...document.querySelectorAll('link[rel~="icon"],link[rel^="apple-touch-icon"]')];
      const icon = links[0]?.href || (location.origin + '/favicon.ico');
      return { url: location.href, title, icon, t: v.currentTime || 0, d: v.duration || 0, paused: v.paused };
    });
    if (info && info.url) {
      recordSite(info.url, info.icon);
      if (info.d > 180 && info.t <= info.d) {
        const host = new URL(info.url).host;
        data.resume = { url: info.url, title: cleanTitle(info.title || '', host), time: info.t, duration: info.d };
        saveState(data);
      }
    }
  } catch {}
}, 3000);

// Capture Xvfb framebuffer into PNG at ~12fps when changed
function captureNow(force = false) {
  try {
    const buf = readFileSync(FB_FILE);
    const h = quickHash(buf);
    if (!force && h === lastHash && latestPng) return;
    const png = encodeXwdToPng(buf);
    if (png) {
      latestPng = png;
      lastHash = h;
      frameSeq += 1;
    }
  } catch {}
}

captureNow(true);
setInterval(() => {
  if (data.mode === 'web') captureNow(false);
}, 80);

// If Float restarted while already in web mode, restore the page!
if (data.mode === 'web' && data.currentUrl) {
  page.goto(data.currentUrl, { waitUntil: 'domcontentloaded' }).then(async () => {
    try { await page.evaluate(fillScript(data.fill)); } catch {}
    captureNow(true);
  }).catch(() => {});
}

function mapPointer(arg) {
  const [xs, ys] = String(arg || '').split(',');
  let x = Number(xs), y = Number(ys);
  if (!Number.isFinite(x) || !Number.isFinite(y)) return null;
  // Normalized [0..1] coordinates scale cleanly across any Wayland window size
  if (x >= 0 && x <= 1 && y >= 0 && y <= 1) {
    x = x * WIDTH;
    y = y * HEIGHT;
  }
  return [Math.max(0, Math.min(WIDTH - 1, Math.round(x))), Math.max(0, Math.min(HEIGHT - 1, Math.round(y)))];
}

async function handleCommand(op, arg) {
  switch (op) {
    case 'openClipboard': {
      const clip = spawnSync('wl-paste', ['--no-newline'], {
        encoding: 'utf8',
        env: { ...process.env, WAYLAND_DISPLAY: process.env.WAYLAND_DISPLAY || 'wayland-0' },
      });
      const text = (clip.stdout || '').trim();
      if (text) await handleCommand('load', text);
      break;
    }
    case 'load': {
      const url = parseWebUrl(arg);
      if (url) {
        data.mode = 'web';
        data.currentUrl = url;
        data.history = data.history.slice(0, data.historyIndex + 1).concat([url]);
        data.historyIndex = data.history.length - 1;
        saveState(data);
        page.goto(url, { waitUntil: 'domcontentloaded' })
          .then(async () => {
            try { await page.evaluate(fillScript(data.fill)); } catch {}
            captureNow(true);
          })
          .catch((e) => console.error('goto failed:', e?.message || e));
        captureNow(true);
      }
      break;
    }
    case 'showHome':
      data.mode = 'home';
      saveState(data);
      page.evaluate(() => document.querySelectorAll('video').forEach((v) => v.pause())).catch(() => {});
      break;
    case 'resumeLast':
      if (data.resume) {
        const url = parseWebUrl(data.resume.url);
        const seekTo = data.resume.time || 0;
        if (url) {
          data.mode = 'web';
          data.currentUrl = url;
          saveState(data);
          page.goto(url, { waitUntil: 'domcontentloaded' })
            .then(async () => {
              try { await page.evaluate(fillScript(data.fill)); } catch {}
              if (seekTo > 5) {
                setTimeout(() => {
                  page.evaluate((t) => {
                    const v = document.querySelector('video');
                    if (v && Number.isFinite(v.duration) && t < v.duration) v.currentTime = t;
                  }, seekTo).catch(() => {});
                }, 1500);
              }
              captureNow(true);
            })
            .catch(() => {});
        }
      }
      break;
    case 'back':
      page.goBack({ waitUntil: 'domcontentloaded' }).then(() => captureNow(true)).catch(() => {});
      break;
    case 'forward':
      page.goForward({ waitUntil: 'domcontentloaded' }).then(() => captureNow(true)).catch(() => {});
      break;
    case 'reloadPage':
      page.reload({ waitUntil: 'domcontentloaded' }).then(() => captureNow(true)).catch(() => {});
      break;
    case 'toggleFill':
      data.fill = !data.fill;
      saveState(data);
      page.evaluate(fillScript(data.fill)).then(() => captureNow(true)).catch(() => {});
      break;
    case 'playPause':
      page.evaluate(() => {
        const v = [...document.querySelectorAll('video')].sort((a, b) => b.offsetWidth * b.offsetHeight - a.offsetWidth * a.offsetHeight)[0];
        if (v) v.paused ? v.play() : v.pause();
      }).then(() => captureNow(true)).catch(() => {});
      break;
    case 'pointerDown': {
      const pt = mapPointer(arg);
      if (pt) {
        await page.mouse.move(pt[0], pt[1]).catch(() => {});
        await page.mouse.down().catch(() => {});
        setTimeout(() => captureNow(true), 40);
      }
      break;
    }
    case 'pointerMove': {
      const pt = mapPointer(arg);
      if (pt) {
        await page.mouse.move(pt[0], pt[1]).catch(() => {});
      }
      break;
    }
    case 'pointerUp': {
      const pt = mapPointer(arg);
      if (pt) {
        await page.mouse.move(pt[0], pt[1]).catch(() => {});
      }
      await page.mouse.up().catch(() => {});
      setTimeout(() => captureNow(true), 50);
      break;
    }
    case 'pointerClick': {
      const pt = mapPointer(arg);
      if (pt) {
        await page.mouse.click(pt[0], pt[1]).catch(() => {});
        setTimeout(() => captureNow(true), 60);
      }
      break;
    }
    case 'scroll': {
      const [dxs, dys] = String(arg || '').split(',');
      const dx = Number(dxs) || 0, dy = Number(dys) || 0;
      await page.mouse.wheel(dx, dy).catch(() => {});
      setTimeout(() => captureNow(true), 60);
      break;
    }
    case 'key': {
      const raw = String(arg || '');
      const sep = raw.indexOf(':');
      const mods = sep >= 0 ? raw.slice(0, sep) : '';
      const k = sep >= 0 ? raw.slice(sep + 1) : raw;
      if (!k) break;
      const ctrl = mods.includes('C');
      const meta = mods.includes('M');
      const alt = mods.includes('A');
      const shift = mods.includes('S');
      const low = k.toLowerCase();

      // Translate macOS Meta/Alt editing chords to Linux Chromium equivalents
      if (meta && !ctrl && !alt) {
        if (low === 'a' || low === 'c' || low === 'v' || low === 'x' || low === 'z' || low === 'y') {
          const chord = shift ? `Control+Shift+${low}` : `Control+${low}`;
          await page.keyboard.press(chord).catch(() => {});
        } else if (k === 'ArrowLeft') {
          await page.keyboard.press(shift ? 'Shift+Home' : 'Home').catch(() => {});
        } else if (k === 'ArrowRight') {
          await page.keyboard.press(shift ? 'Shift+End' : 'End').catch(() => {});
        } else if (k === 'Backspace') {
          await page.keyboard.press('Shift+Home').catch(() => {});
          await page.keyboard.press('Backspace').catch(() => {});
        } else {
          const chord = `${shift ? 'Shift+' : ''}Meta+${k === ' ' ? 'Space' : k}`;
          await page.keyboard.press(chord).catch(() => {});
        }
      } else if (alt && !ctrl && !meta && (k === 'Backspace' || k === 'Delete' || k === 'ArrowLeft' || k === 'ArrowRight')) {
        const chord = `${shift ? 'Shift+' : ''}Control+${k}`;
        await page.keyboard.press(chord).catch(() => {});
      } else if (ctrl || alt) {
        const parts = [];
        if (ctrl) parts.push('Control');
        if (alt) parts.push('Alt');
        if (shift) parts.push('Shift');
        parts.push(k === ' ' ? 'Space' : (k.length === 1 ? low : k));
        await page.keyboard.press(parts.join('+')).catch(() => {});
      } else if (k === ' ') {
        await page.keyboard.press('Space').catch(() => {});
      } else if (k.length === 1) {
        await page.keyboard.insertText(k).catch(() => {});
      } else {
        const chord = shift ? `Shift+${k}` : k;
        await page.keyboard.press(chord).catch(() => {});
      }
      setTimeout(() => captureNow(true), 50);
      break;
    }
    case 'removeSite':
      data.sites = data.sites.filter((s) => s.host !== arg);
      saveState(data);
      break;
    case 'toggleExpand':
      data.expanded = !data.expanded;
      saveState(data);
      break;
    case 'toggleAspectLock':
      data.aspectLocked = !data.aspectLocked;
      saveState(data);
      break;
    case 'toggleTop':
      data.onTop = !data.onTop;
      saveState(data);
      break;
    case 'toggleClickThrough':
      data.clickThrough = !data.clickThrough;
      if (data.clickThrough && data.alpha > 0.6) data.alpha = 0.6;
      saveState(data);
      break;
    case 'fadeOut':
      data.alpha = Math.round(Math.max(0.15, data.alpha - 0.1) * 100) / 100;
      saveState(data);
      break;
    case 'fadeIn':
      data.alpha = Math.round(Math.min(1, data.alpha + 0.1) * 100) / 100;
      saveState(data);
      break;
    case 'setPeekTrigger':
      if (['rightCommand', 'rightOption', 'hotkey', 'none'].includes(arg)) {
        data.peekTrigger = arg;
        data.peeking = false;
        saveState(data);
      }
      break;
    case 'setPeekAlpha': {
      const n = Number(arg);
      if (Number.isFinite(n)) {
        data.peekAlpha = Math.round(Math.min(0.95, Math.max(0.15, n)) * 100) / 100;
        saveState(data);
      }
      break;
    }
    case 'setPeekHold':
      data.peekHold = arg === 'true';
      data.peeking = false;
      saveState(data);
      break;
    case 'openSettings':
      data.settingsOpen = true;
      saveState(data);
      break;
    case 'closeSettings':
      data.settingsOpen = false;
      saveState(data);
      break;
    case 'toggleShortcuts':
      data.shortcutsOpen = !data.shortcutsOpen;
      saveState(data);
      break;
    case 'closeShortcuts':
      data.shortcutsOpen = false;
      saveState(data);
      break;
    case 'dock':
      data.lastDock = Number(arg) || 0;
      data.expanded = false;
      saveState(data);
      break;
    default:
      break;
  }
}

Bun.serve({
  hostname: '127.0.0.1',
  port: PORT,
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === '/health') {
      return Response.json({ ok: true, seq: frameSeq, mode: data.mode, url: data.currentUrl });
    }
    if (url.pathname === '/state') {
      return Response.json(buildFloatState());
    }
    if (url.pathname === '/cmd' && req.method === 'POST') {
      const body = await req.json();
      await handleCommand(body.op, body.arg);
      return Response.json({ ok: true });
    }
    if (url.pathname.startsWith('/frame/') && url.pathname.endsWith('.png')) {
      if (!latestPng) captureNow(true);
      if (!latestPng) return new Response('no frame', { status: 503 });
      return new Response(latestPng, {
        headers: {
          'Content-Type': 'image/png',
          'Cache-Control': 'no-store',
        },
      });
    }
    return new Response('not found', { status: 404 });
  },
});

console.log(`float-browser-bridge listening on http://127.0.0.1:${PORT} (${WIDTH}x${HEIGHT} on ${DISPLAY_NUM})`);

process.on('SIGTERM', async () => {
  try { await context.close(); } catch {}
  try { xvfb.kill('SIGTERM'); } catch {}
  process.exit(0);
});
