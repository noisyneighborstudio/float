import type { Answer, Result, Sources, Storage } from './app.contract.d.ts';

export const appId = 'com.sethwebster.float';
export const grants = 'fs.read app:/data/float.json\nfs.write app:/data/float.json';

type FloatState = Result<'loadFloatState'>;
type Site = FloatState['sites'][number];

const STORE_FILE = 'app:/data/float.json';

interface PersistedFallback {
  mode: string;
  currentUrl: string;
  history: string[];
  historyIndex: number;
  fill: boolean;
  onTop: boolean;
  aspectLocked: boolean;
  clickThrough: boolean;
  alpha: number;
  hotkeyLabel: string;
  peekTrigger: string;
  peekAlpha: number;
  peekHotkeyLabel: string;
  peekHold: boolean;
  peeking: boolean;
  settingsOpen: boolean;
  lastDock: number;
  resume: { url: string; title: string; time: number; duration: number } | null;
  sites: { host: string; url: string; icon: string; last: number; count: number }[];
}

const DEFAULT_FALLBACK: PersistedFallback = {
  mode: 'home',
  currentUrl: '',
  history: [],
  historyIndex: -1,
  fill: true,
  onTop: true,
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
  lastDock: -1,
  resume: null,
  sites: [],
};

function siteName(host: string): string {
  const skip = new Set(['www', 'm', 'watch', 'play', 'app']);
  const parts = host.split('.').filter((p) => p && !skip.has(p));
  const core = parts.length > 1 ? parts[parts.length - 2] : (parts[0] ?? host);
  return core ? core.slice(0, 1).toUpperCase() + core.slice(1) : host;
}

function cleanTitle(title: string, host: string): string {
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

function parseWebUrl(raw: string): string | null {
  const s = raw.trim();
  if (!s) return null;
  let candidate: string;
  if (s.includes('://')) {
    candidate = s;
  } else if (s.includes('.') && !s.includes(' ')) {
    candidate = 'https://' + s;
  } else {
    candidate = 'https://www.youtube.com/results?search_query=' + encodeURIComponent(s);
  }
  try {
    const u = new URL(candidate);
    if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
    return u.toString();
  } catch {
    return null;
  }
}

function toFloatState(p: PersistedFallback): FloatState {
  const sites: Site[] = [...p.sites]
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

  if (p.resume) {
    try {
      const host = new URL(p.resume.url).host;
      if (host) {
        hasResume = true;
        resumeUrl = p.resume.url;
        resumeHost = host;
        resumeTitle = p.resume.title || siteName(host);
        const matched = sites.find((s) => s.host === host);
        resumeIcon = matched ? matched.icon : `https://${host}/favicon.ico`;
        resumeTime = p.resume.time;
        resumeDuration = p.resume.duration;
      }
    } catch {
      // ignore invalid resume URL
    }
  }

  return {
    mode: p.mode,
    currentUrl: p.currentUrl,
    fill: p.fill,
    onTop: p.onTop,
    aspectLocked: p.aspectLocked,
    clickThrough: p.clickThrough,
    alpha: p.alpha,
    hotkeyLabel: p.hotkeyLabel,
    peekTrigger: p.peekTrigger,
    peekAlpha: p.peekAlpha,
    peekHotkeyLabel: p.peekHotkeyLabel,
    peekHold: p.peekHold,
    peeking: p.peeking,
    settingsOpen: p.settingsOpen,
    peekPermissionGranted: true,
    canCheckUpdates: false,
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

async function readFallback(storage: Storage): Promise<PersistedFallback> {
  try {
    const bytes = await storage.fs.readFile(STORE_FILE);
    return { ...DEFAULT_FALLBACK, ...JSON.parse(new TextDecoder().decode(bytes)) };
  } catch (e: unknown) {
    const code = (e as { code?: string })?.code;
    if (code === 'ENOENT' || code === 'Unavailable') return { ...DEFAULT_FALLBACK, sites: [], history: [] };
    throw e;
  }
}

async function writeFallback(storage: Storage, data: PersistedFallback): Promise<void> {
  try {
    await storage.fs.atomicWriteFile(STORE_FILE, new TextEncoder().encode(JSON.stringify(data)));
  } catch (e: unknown) {
    const code = (e as { code?: string })?.code;
    if (code !== 'Unavailable') throw e;
  }
}

async function runFallbackCommand(op: string, arg: string, storage: Storage): Promise<Result<'runFloatCommand'>> {
  const data = await readFallback(storage);
  switch (op) {
    case 'load': {
      const url = parseWebUrl(arg);
      if (url) {
        data.mode = 'web';
        data.currentUrl = url;
        data.history = data.history.slice(0, data.historyIndex + 1).concat([url]);
        data.historyIndex = data.history.length - 1;
      }
      break;
    }
    case 'showHome':
      data.mode = 'home';
      break;
    case 'resumeLast':
      if (data.resume) {
        const url = parseWebUrl(data.resume.url);
        if (url) {
          data.mode = 'web';
          data.currentUrl = url;
        }
      }
      break;
    case 'removeSite':
      data.sites = data.sites.filter((s) => s.host !== arg);
      break;
    case 'toggleFill':
      data.fill = !data.fill;
      break;
    case 'toggleAspectLock':
      data.aspectLocked = !data.aspectLocked;
      break;
    case 'toggleTop':
      data.onTop = !data.onTop;
      break;
    case 'toggleClickThrough':
      data.clickThrough = !data.clickThrough;
      if (data.clickThrough && data.alpha > 0.6) data.alpha = 0.6;
      break;
    case 'fadeOut':
      data.alpha = Math.round(Math.max(0.15, data.alpha - 0.1) * 100) / 100;
      break;
    case 'fadeIn':
      data.alpha = Math.round(Math.min(1, data.alpha + 0.1) * 100) / 100;
      break;
    case 'setPeekTrigger':
      if (['rightCommand', 'rightOption', 'hotkey', 'none'].includes(arg)) {
        data.peekTrigger = arg;
        data.peeking = false;
      }
      break;
    case 'setPeekAlpha': {
      const n = Number(arg);
      if (Number.isFinite(n)) {
        data.peekAlpha = Math.round(Math.min(0.95, Math.max(0.15, n)) * 100) / 100;
      }
      break;
    }
    case 'setPeekHold':
      data.peekHold = arg === 'true';
      data.peeking = false;
      break;
    case 'setPeeking':
      data.peeking = arg === 'true';
      break;
    case 'openSettings':
      data.settingsOpen = true;
      break;
    case 'closeSettings':
      data.settingsOpen = false;
      break;
    case 'back':
      if (data.historyIndex > 0) {
        data.historyIndex -= 1;
        data.currentUrl = data.history[data.historyIndex] ?? '';
        data.mode = data.currentUrl ? 'web' : 'home';
      }
      break;
    case 'forward':
      if (data.historyIndex + 1 < data.history.length) {
        data.historyIndex += 1;
        data.currentUrl = data.history[data.historyIndex] ?? '';
        data.mode = data.currentUrl ? 'web' : 'home';
      }
      break;
    case 'dock':
      data.lastDock = Number(arg) || 0;
      break;
    case 'recordPlayback': {
      // Used by automated tests to simulate a video playback event from the browser.
      const payload = JSON.parse(arg) as { url: string; title: string; icon?: string; t: number; d: number };
      const u = new URL(payload.url);
      const host = u.host;
      const existing = data.sites.find((s) => s.host === host);
      const stamp = data.sites.reduce((m, s) => Math.max(m, s.last), 0) + 1;
      if (existing) {
        existing.last = stamp;
        existing.count += 1;
        if (payload.icon) existing.icon = payload.icon;
      } else {
        data.sites.push({
          host,
          url: `${u.protocol}//${host}`,
          icon: payload.icon ?? `${u.protocol}//${host}/favicon.ico`,
          last: stamp,
          count: 1,
        });
      }
      if (payload.d > 180 && payload.t <= payload.d) {
        let title = cleanTitle(payload.title || '', host);
        if (data.resume && data.resume.url === payload.url && (!title || title.toLowerCase() === siteName(host).toLowerCase())) {
          title = data.resume.title;
        }
        data.resume = { url: payload.url, title, time: payload.t, duration: payload.d };
      }
      break;
    }
    default:
      break;
  }
  await writeFallback(storage, data);
  return { ok: true };
}

const sources: Sources = {
  loadFloatState: async (_args, _store, storage, native) => {
    if (native?.available) {
      native.watch('float');
      try {
        return native.call({ op: 'state' }) as FloatState;
      } catch {
        // Web module has no sync call; fall back to local store on web.
      }
    }
    return toFloatState(await readFallback(storage));
  },
  runFloatCommand: async ([op, arg], _store, storage, native) => {
    if (native?.available) {
      try {
        return native.call({ op, arg }) as Result<'runFloatCommand'>;
      } catch {
        // Fall through to storage fallback when running on web without native call.
      }
    }
    return runFallbackCommand(op, arg, storage);
  },
};

export const answer: Answer = (source, args, store, storage, native) =>
  sources[source](args, store, storage, native);
