import Foundation
import WebKit
#if os(macOS)
import AppKit
import ApplicationServices
import Darwin
import Metal
import QuartzCore
import Sparkle

private let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

struct FloatSite: Codable {
    var host: String
    var url: String
    var icon: String?
    var name: String?
    var last: Date
    var count: Int
}

struct FloatResume: Codable {
    var url: String
    var title: String
    var time: Double
    var duration: Double
}

private func floatFormatChordLabel(_ keys: String) -> String {
    guard !keys.isEmpty else { return "None" }
    if keys == "MetaRight" { return "Right ⌘" }
    if keys == "AltRight" { return "Right ⌥" }
    var parts = keys.split(separator: "+").map(String.init)
    let key = parts.popLast() ?? ""
    let mods = Set(parts)
    let named: [String: String] = [
        "Space": "Space", "Enter": "↩", "Tab": "⇥",
        "ArrowLeft": "←", "ArrowRight": "→", "ArrowUp": "↑", "ArrowDown": "↓",
    ]
    let keyLabel = named[key] ?? (key.count == 1 ? key.uppercased() : key)
    return (mods.contains("Control") ? "⌃" : "")
        + (mods.contains("Alt") ? "⌥" : "")
        + (mods.contains("Shift") ? "⇧" : "")
        + (mods.contains("Meta") ? "⌘" : "")
        + keyLabel
}

private func floatIsWeb(_ u: URL) -> Bool {
    ["http", "https"].contains(u.scheme?.lowercased() ?? "")
}

private func floatNormalizedHost(_ host: String) -> String {
    let lower = host.lowercased()
    return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
}

private func floatSiteName(_ host: String) -> String {
    let parts = host.split(separator: ".").filter { !["www", "m", "watch", "play", "app"].contains($0) }
    let core = parts.count > 1 ? parts[parts.count - 2] : (parts.first ?? Substring(host))
    return core.prefix(1).uppercased() + core.dropFirst()
}

// "Unabomber | Netflix" → "Unabomber"
private func floatCleanTitle(_ title: String, host: String) -> String {
    for sep in [" | ", " - ", " – "] {
        if let r = title.range(of: sep, options: .backwards),
           title[r.upperBound...].lowercased().contains(floatSiteName(host).lowercased()) {
            return String(title[..<r.lowerBound]).replacingOccurrences(of: "Watch ", with: "", options: .anchored)
        }
    }
    return title
}

private let floatAppleTVAutoPlayKinds: Set<String> = ["episode", "movie", "show", "season", "sporting-event"]
private let floatAppleTVContentKinds: Set<String> = ["episode", "movie", "show", "season", "sporting-event", "clip"]

/// Returns the Apple TV content kind (`episode`, `movie`, `show`, `season`, `sporting-event`, `clip`)
/// when `url` points to a specific tv.apple.com content page, or `nil` for home/browse pages.
private func floatAppleTVContentKind(_ url: URL) -> String? {
    guard url.host?.lowercased() == "tv.apple.com" else { return nil }
    let segs = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
    guard !segs.isEmpty else { return nil }
    let start: Int
    if segs[0].count == 2 && segs[0].allSatisfy({ $0.isASCII && $0.isLetter }) {
        start = 1
    } else {
        start = 0
    }
    guard segs.count >= start + 2 else { return nil }
    let kind = segs[start].lowercased()
    return floatAppleTVContentKinds.contains(kind) ? kind : nil
}

/// Ensures tv.apple.com content resume links include `action=play` so Apple TV's router
/// auto-launches playback instead of landing on a browse or detail page.
private func floatAppleTVResumeURL(_ url: URL) -> URL {
    guard let kind = floatAppleTVContentKind(url),
          floatAppleTVAutoPlayKinds.contains(kind),
          var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return url
    }
    if #available(macOS 13.0, *) {
        var items = comps.percentEncodedQueryItems ?? []
        if let idx = items.firstIndex(where: { $0.name == "action" }) {
            items[idx] = URLQueryItem(name: "action", value: "play")
        } else {
            items.append(URLQueryItem(name: "action", value: "play"))
        }
        comps.percentEncodedQueryItems = items
    } else {
        var items = comps.queryItems ?? []
        if let idx = items.firstIndex(where: { $0.name == "action" }) {
            items[idx] = URLQueryItem(name: "action", value: "play")
        } else {
            items.append(URLQueryItem(name: "action", value: "play"))
        }
        comps.queryItems = items
    }
    return comps.url ?? url
}

private func floatIsGenericTitle(_ title: String, host: String) -> Bool {
    if title.isEmpty || title.caseInsensitiveCompare(floatSiteName(host)) == .orderedSame {
        return true
    }
    if host.lowercased() == "tv.apple.com" {
        let lower = title.lowercased()
        if lower == "apple tv" || lower == "apple tv+" || lower.hasPrefix("browse apple tv") {
            return true
        }
    }
    return false
}

// Pins the main video's player (video + site controls) to the window; works on any site.
private func floatFillScript(_ on: Bool) -> String { """
(() => {
  const ON = \(on), ATTR = 'data-fp-pin', ID = '__fp_pin_style';
  const CSS = `
    html:has([${ATTR}]), html:has([${ATTR}]) body { overflow: hidden !important; }
    [data-fp-anc] { transform: none !important; filter: none !important; perspective: none !important; contain: none !important; will-change: auto !important; }
    [${ATTR}] { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important;
      max-width: none !important; max-height: none !important; margin: 0 !important; padding: 0 !important; transform: none !important;
      z-index: 2147483647 !important; background: #000 !important; }
    [${ATTR}] [data-fp-path] { width: 100% !important; height: 100% !important; max-width: none !important; max-height: none !important;
      margin: 0 !important; padding: 0 !important; transform: none !important; top: 0 !important; left: 0 !important; right: 0 !important; bottom: 0 !important; }
    [${ATTR}] video[data-fp-path] { position: absolute !important; inset: 0 !important; width: 100% !important; height: 100% !important;
      margin: 0 !important; padding: 0 !important; transform: none !important; }
    [${ATTR}] video, video[${ATTR}] { object-fit: contain !important; }`;
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
    const cur = document.querySelector(`[${ATTR}]`);
    const curVid = cur && (cur.matches('video') ? cur : cur.querySelector('video'));
    if (ON && curVid && curVid.currentSrc) return;
    cur && cur.removeAttribute(ATTR);
    document.querySelectorAll('[data-fp-path]').forEach(e => e.removeAttribute('data-fp-path'));
    document.querySelectorAll('[data-fp-anc]').forEach(e => e.removeAttribute('data-fp-anc'));
    let s = document.getElementById(ID);
    if (!ON) { s && s.remove(); cur && dispatchEvent(new Event('resize')); return; }
    if (!s) { s = document.createElement('style'); s.id = ID; s.textContent = CSS; (document.head || document.documentElement).appendChild(s); }
    const v = main();
    if (!v) return;
    const p = player(v);
    p.setAttribute(ATTR, '');
    for (let e = v; e && e !== p; e = e.parentElement) e.setAttribute('data-fp-path', '');
    for (let e = p.parentElement; e && e !== document.documentElement; e = e.parentElement) e.setAttribute('data-fp-anc', '');
    dispatchEvent(new Event('resize'));
  }
  apply();
  clearInterval(window.__fpTimer);
  if (ON) window.__fpTimer = setInterval(apply, 1000);
})();
""" }

// Document-start hook: enforces Prefer SDR capability overrides and detects live HDR vs SDR video streams
// (via MSE codec strings, unencrypted fMP4 init segment boxes, WebCodecs VideoFrame, and HLS playlists).
private func floatMediaHookScript(preferSdr: Bool) -> String { """
(() => {
  window.__fpPreferSdr = \(preferSdr ? "true" : "false");
  if (window.__fpMediaHooked) {
    if (typeof window.__fpSyncStreams === 'function') window.__fpSyncStreams();
    return;
  }
  window.__fpMediaHooked = true;

  const isHdrMime = (mime) => {
    if (typeof mime !== 'string' || /^audio\\//i.test(mime)) return false;
    return /\\b(dvh1|dvhe|dav1)\\b/i.test(mime)
      || /\\bvp09\\.0[23]\\b/i.test(mime)
      || /\\bav01\\.\\d+\\.\\d+[MH]\\.(?:10|12)\\.\\d+\\.\\d+\\.\\d+\\.(?:16|18)\\b/i.test(mime);
  };

  const classifyMime = (mime) => {
    if (typeof mime !== 'string' || /^audio\\//i.test(mime)) return null;
    if (isHdrMime(mime)) return 'hdr';
    if (/\\b(hev1|hvc1)\\.2\\./i.test(mime)) return 'hdr';
    if (/\\b(avc1|avc3|hev1\\.1|hvc1\\.1|vp09\\.00|vp8)\\b/i.test(mime)) return 'sdr';
    return null;
  };

  // --- Prefer SDR capability overrides ---
  try {
    const mc = navigator.mediaCapabilities;
    if (mc && typeof mc.decodingInfo === 'function') {
      const origDecode = mc.decodingInfo.bind(mc);
      mc.decodingInfo = function(cfg) {
        if (window.__fpPreferSdr && cfg && cfg.video) {
          const v = cfg.video;
          const tf = typeof v.transferFunction === 'string' ? v.transferFunction.toLowerCase() : '';
          const gamut = typeof v.colorGamut === 'string' ? v.colorGamut.toLowerCase() : '';
          if (tf === 'pq' || tf === 'hlg' || v.hdrMetadataType || gamut === 'rec2020' || isHdrMime(v.contentType || '')) {
            return Promise.resolve({ supported: false, smooth: false, powerEfficient: false, configuration: cfg });
          }
        }
        return origDecode(cfg);
      };
    }
  } catch {}

  for (const Ctor of [window.MediaSource, window.ManagedMediaSource]) {
    if (!Ctor || typeof Ctor.isTypeSupported !== 'function') continue;
    try {
      const origSupported = Ctor.isTypeSupported.bind(Ctor);
      Ctor.isTypeSupported = function(type) {
        if (window.__fpPreferSdr && isHdrMime(type)) return false;
        return origSupported(type);
      };
    } catch {}
  }

  try {
    const origCanPlay = HTMLMediaElement.prototype.canPlayType;
    if (typeof origCanPlay === 'function') {
      HTMLMediaElement.prototype.canPlayType = function(type) {
        if (window.__fpPreferSdr && isHdrMime(type)) return '';
        return origCanPlay.call(this, type);
      };
    }
  } catch {}

  try {
    if (navigator && typeof navigator.requestMediaKeySystemAccess === 'function') {
      const origEme = navigator.requestMediaKeySystemAccess.bind(navigator);
      navigator.requestMediaKeySystemAccess = function(keySystem, configs) {
        if (window.__fpPreferSdr && Array.isArray(configs)) {
          const filtered = [];
          for (const cfg of configs) {
            if (!cfg || !Array.isArray(cfg.videoCapabilities)) {
              filtered.push(cfg);
              continue;
            }
            const kept = cfg.videoCapabilities.filter(vc => !isHdrMime((vc && vc.contentType) || ''));
            if (kept.length > 0 || cfg.videoCapabilities.length === 0) {
              filtered.push(Object.assign({}, cfg, { videoCapabilities: kept }));
            }
          }
          if (filtered.length > 0) return origEme(keySystem, filtered);
        }
        return origEme(keySystem, configs);
      };
    }
  } catch {}

  try {
    const origMM = window.matchMedia && window.matchMedia.bind(window);
    if (origMM) {
      window.matchMedia = function(query) {
        const res = origMM(query);
        if (!window.__fpPreferSdr || typeof query !== 'string') return res;
        let forced = null;
        if (/\\(\\s*(?:video-)?dynamic-range\\s*:\\s*high\\s*\\)/i.test(query)
            || /\\(\\s*color-gamut\\s*:\\s*rec2020\\s*\\)/i.test(query)) {
          forced = false;
        } else if (/\\(\\s*(?:video-)?dynamic-range\\s*:\\s*standard\\s*\\)/i.test(query)) {
          forced = true;
        }
        if (forced === null) return res;
        return new Proxy(res, {
          get(target, prop) {
            if (prop === 'matches') return forced;
            const v = Reflect.get(target, prop, target);
            return typeof v === 'function' ? v.bind(target) : v;
          }
        });
      };
    }
  } catch {}

  // --- Stream kind detection (HDR vs SDR) ---
  const msKind = new WeakMap();
  const sbOwner = new WeakMap();
  const blobMs = new Map();
  let lastMsKind = '';
  let hlsHasHdr = null;

  const u32 = (b, i) => ((b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]) >>> 0;
  const tag4 = (b, i) => String.fromCharCode(b[i], b[i + 1], b[i + 2], b[i + 3]);

  // Parses unencrypted fMP4 init segments (moov) for Dolby Vision / HDR10 / HLG boxes.
  const detectInitKind = (data) => {
    let bytes;
    if (data instanceof ArrayBuffer) bytes = new Uint8Array(data);
    else if (ArrayBuffer.isView(data)) bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
    else return null;
    if (bytes.length < 32) return null;
    // Walk top-level boxes to find moov (media chunks start with moof/mdat and return immediately).
    let off = 0, moovStart = -1, moovEnd = -1;
    while (off + 8 <= bytes.length && off < 65536) {
      let sz = u32(bytes, off);
      const t = tag4(bytes, off + 4);
      if (sz === 0) sz = bytes.length - off;
      else if (sz < 8) break;
      if (t === 'moov') {
        moovStart = off + 8;
        moovEnd = Math.min(bytes.length, off + sz, off + 65536);
        break;
      }
      if (t === 'moof' || t === 'mdat') return null;
      off += sz;
    }
    if (moovStart < 0) return null;
    let isVideo = false;
    let sdrFound = false;
    for (let i = moovStart; i + 8 <= moovEnd; i++) {
      const c0 = bytes[i];
      if (c0 === 118 && bytes[i + 1] === 105 && bytes[i + 2] === 100 && bytes[i + 3] === 101) { // vide
        isVideo = true;
      } else if (c0 === 100 && bytes[i + 1] === 118 && (
        (bytes[i + 2] === 99 && bytes[i + 3] === 67) || // dvcC
        (bytes[i + 2] === 118 && bytes[i + 3] === 67) || // dvvC
        (bytes[i + 2] === 104 && bytes[i + 3] === 49) || // dvh1
        (bytes[i + 2] === 104 && bytes[i + 3] === 101)   // dvhe
      )) {
        return 'hdr';
      } else if ((c0 === 109 && bytes[i + 1] === 100 && bytes[i + 2] === 99 && bytes[i + 3] === 118) || // mdcv
                 (c0 === 99 && bytes[i + 1] === 108 && bytes[i + 2] === 108 && bytes[i + 3] === 105)) {   // clli
        return 'hdr';
      } else if (c0 === 99 && bytes[i + 1] === 111 && bytes[i + 2] === 108 && bytes[i + 3] === 114 && i + 12 <= moovEnd) { // colr
        if (bytes[i + 4] === 110 && bytes[i + 5] === 99 && bytes[i + 6] === 108 && bytes[i + 7] === 120) { // nclx
          const tf = (bytes[i + 10] << 8) | bytes[i + 11];
          if (tf === 16 || tf === 18) return 'hdr';
          if (tf === 1 || tf === 6 || tf === 13 || tf === 14 || tf === 15) sdrFound = true;
        }
      }
    }
    if (!isVideo) return null;
    return sdrFound ? 'sdr' : null;
  };

  const setMsKind = (ms, kind) => {
    if (!ms || !kind) return;
    msKind.set(ms, kind);
    lastMsKind = kind;
    syncAllVideos();
  };

  const hookMediaSource = (Ctor) => {
    if (!Ctor || !Ctor.prototype || typeof Ctor.prototype.addSourceBuffer !== 'function') return;
    const origAdd = Ctor.prototype.addSourceBuffer;
    Ctor.prototype.addSourceBuffer = function(mime) {
      const sb = origAdd.call(this, mime);
      try {
        sbOwner.set(sb, this);
        const k = classifyMime(mime);
        if (k) setMsKind(this, k);
      } catch {}
      return sb;
    };
  };
  hookMediaSource(window.MediaSource);
  hookMediaSource(window.ManagedMediaSource);

  try {
    if (window.SourceBuffer && SourceBuffer.prototype) {
      if (typeof SourceBuffer.prototype.changeType === 'function') {
        const origChange = SourceBuffer.prototype.changeType;
        SourceBuffer.prototype.changeType = function(mime) {
          const r = origChange.call(this, mime);
          try {
            const k = classifyMime(mime);
            const ms = sbOwner.get(this);
            if (k && ms) setMsKind(ms, k);
          } catch {}
          return r;
        };
      }
      if (typeof SourceBuffer.prototype.appendBuffer === 'function') {
        const origAppend = SourceBuffer.prototype.appendBuffer;
        SourceBuffer.prototype.appendBuffer = function(data) {
          try {
            const k = detectInitKind(data);
            const ms = sbOwner.get(this);
            if (k && ms) setMsKind(ms, k);
          } catch {}
          return origAppend.call(this, data);
        };
      }
    }
  } catch {}

  try {
    if (window.URL && typeof URL.createObjectURL === 'function') {
      const origCreate = URL.createObjectURL.bind(URL);
      URL.createObjectURL = function(obj) {
        const u = origCreate(obj);
        try {
          if (obj && ((window.MediaSource && obj instanceof MediaSource) || (window.ManagedMediaSource && obj instanceof ManagedMediaSource))) {
            if (blobMs.size > 64) blobMs.delete(blobMs.keys().next().value);
            blobMs.set(u, obj);
          }
        } catch {}
        return u;
      };
    }
  } catch {}

  // Read-only HLS playlist peek for native HLS players (e.g. Apple TV+)
  try {
    if (typeof window.fetch === 'function') {
      const origFetch = window.fetch.bind(window);
      window.fetch = function(input, init) {
        const p = origFetch(input, init);
        try {
          const url = typeof input === 'string' ? input : (input && input.url) || '';
          if (/\\.m3u8(\\?|$|#)/i.test(url)) {
            p.then(res => {
              if (!res || !res.ok) return;
              res.clone().text().then(txt => {
                if (!txt || !txt.includes('#EXT-X-STREAM-INF')) return;
                if (/VIDEO-RANGE=(?:PQ|HLG)/i.test(txt) || /CODECS="[^"]*\\b(?:dvh1|dvhe)\\b/i.test(txt)) {
                  hlsHasHdr = true;
                  syncAllVideos();
                } else if (/VIDEO-RANGE=SDR/i.test(txt) && hlsHasHdr === null) {
                  hlsHasHdr = false;
                  syncAllVideos();
                }
              }).catch(() => {});
            }).catch(() => {});
          }
        } catch {}
        return p;
      };
    }
  } catch {}

  const classifyVideo = (v) => {
    if (!v || !v.currentSrc) return '';
    if (v.srcObject && msKind.has(v.srcObject)) return msKind.get(v.srcObject);
    const bms = blobMs.get(v.currentSrc);
    if (bms && msKind.has(bms)) return msKind.get(bms);
    if (typeof window.VideoFrame === 'function' && v.readyState >= 2 && v.videoWidth > 0) {
      try {
        const vf = new VideoFrame(v);
        const tf = vf.colorSpace && vf.colorSpace.transfer;
        vf.close();
        if (tf === 'pq' || tf === 'hlg') return 'hdr';
        if (tf) return 'sdr';
      } catch {}
    }
    if (window.__fpPreferSdr) return 'sdr';
    if (lastMsKind) return lastMsKind;
    if (hlsHasHdr === true) return 'hdr';
    return 'sdr';
  };

  let syncTimer = 0;
  const syncAllVideos = () => {
    if (syncTimer) return;
    syncTimer = setTimeout(() => {
      syncTimer = 0;
      const videos = [...document.querySelectorAll('video')];
      let mainVid = null, mainArea = 0;
      for (const v of videos) {
        if (!v.currentSrc) {
          if (v.hasAttribute('data-fp-stream')) v.removeAttribute('data-fp-stream');
          continue;
        }
        const k = classifyVideo(v);
        if (k && v.getAttribute('data-fp-stream') !== k) {
          v.setAttribute('data-fp-stream', k);
        }
        const area = (v.offsetWidth * v.offsetHeight) || (v.videoWidth * v.videoHeight) || 1;
        if (area >= mainArea && (!v.paused || !mainVid || mainVid.paused)) {
          mainVid = v;
          mainArea = area;
        }
      }
      const active = mainVid ? (mainVid.getAttribute('data-fp-stream') || '') : '';
      const root = document.documentElement;
      if (root && root.getAttribute('data-fp-active-stream') !== active) {
        if (active) root.setAttribute('data-fp-active-stream', active);
        else root.removeAttribute('data-fp-active-stream');
      }
    }, 50);
  };
  window.__fpSyncStreams = syncAllVideos;

  for (const ev of ['loadeddata', 'playing', 'resize', 'emptied']) {
    document.addEventListener(ev, (e) => {
      if (e.target instanceof HTMLVideoElement) {
        if (ev === 'emptied') e.target.removeAttribute('data-fp-stream');
        syncAllVideos();
      }
    }, true);
  }
})();
""" }

// Applies live CSS brightness & contrast filters (single or per-stream HDR/SDR) and optional dynamic-range-limit.
private func floatVideoFilterScript(brightness: Double, hdrBrightness: Double, contrast: Double, streamBrightness: Bool, preferSdr: Bool) -> String { """
(() => {
  const ID = '__fp_video_filter';
  const B = \(String(format: "%.2f", brightness)), HB = \(String(format: "%.2f", hdrBrightness)), C = \(String(format: "%.2f", contrast));
  const SPLIT = \(streamBrightness ? "true" : "false"), PREFER_SDR = \(preferSdr ? "true" : "false");
  const isOne = x => Math.abs(x - 1) < 0.005;
  const apply = () => {
    const rules = [];
    if (PREFER_SDR) {
      rules.push('video { dynamic-range-limit: standard !important; }');
    }
    if (!SPLIT) {
      if (!isOne(B) || !isOne(C)) {
        rules.push(`video { filter: brightness(${B}) contrast(${C}) !important; }`);
      }
    } else {
      if (!isOne(B) || !isOne(C)) {
        rules.push(`video:not([data-fp-stream="hdr"]) { filter: brightness(${B}) contrast(${C}) !important; }`);
      }
      if (!isOne(HB) || !isOne(C)) {
        rules.push(`video[data-fp-stream="hdr"] { filter: brightness(${HB}) contrast(${C}) !important; }`);
      }
    }
    let s = document.getElementById(ID);
    if (rules.length === 0) {
      if (s) s.remove();
      return;
    }
    if (!s) {
      s = document.createElement('style');
      s.id = ID;
      (document.head || document.documentElement).appendChild(s);
    }
    s.textContent = rules.join(' ');
  };
  if (document.documentElement) apply();
  else document.addEventListener('DOMContentLoaded', apply, { once: true });
})();
""" }

private let floatTrackScript = """
(() => {
  let last = 0, lastStream = null;
  const readStream = (v) => {
    const s = (v && v.getAttribute('data-fp-stream'))
      || (document.documentElement && document.documentElement.getAttribute('data-fp-active-stream'))
      || '';
    return (s === 'hdr' || s === 'sdr') ? s : '';
  };
  const sendStream = (s) => {
    const norm = (s === 'hdr' || s === 'sdr') ? s : '';
    if (norm === lastStream) return;
    lastStream = norm;
    webkit.messageHandlers.fpPlay.postMessage({ event: 'stream', stream: norm });
  };
  const send = (event, v) => {
    const stream = readStream(v);
    if (stream) lastStream = stream;
    webkit.messageHandlers.fpPlay.postMessage({ event, t: v.currentTime || 0, d: v.duration || 0, stream });
  };
  const isVid = e => e.target instanceof HTMLVideoElement;
  document.addEventListener('play', e => isVid(e) && send('play', e.target), true);
  document.addEventListener('pause', e => isVid(e) && send('time', e.target), true);
  document.addEventListener('timeupdate', e => {
    if (isVid(e) && Date.now() - last > 5000) { last = Date.now(); send('time', e.target); }
  }, true);
  const watchRoot = () => {
    if (!document.documentElement) return;
    sendStream(document.documentElement.getAttribute('data-fp-active-stream') || '');
    new MutationObserver(() => {
      sendStream(document.documentElement.getAttribute('data-fp-active-stream') || '');
    }).observe(document.documentElement, { attributes: true, attributeFilter: ['data-fp-active-stream'] });
  };
  if (document.documentElement) watchRoot();
  else document.addEventListener('DOMContentLoaded', watchRoot, { once: true });
})();
"""

// Best title + canonical playback URL for what's playing.
// On tv.apple.com, playback runs in an overlay on top of the current browse page (e.g. Home),
// so web.url never changes; MusicKit.getInstance().nowPlayingItem exposes the active playable's URL & metadata.
private let floatResumeMetaScript = """
(() => {
  let atvUrl = '';
  let atvTitle = '';
  let atvFallbackTitle = '';
  if (location.hostname === 'tv.apple.com') {
    try {
      const mk = window.MusicKit && typeof window.MusicKit.getInstance === 'function'
        ? window.MusicKit.getInstance()
        : null;
      const item = mk && (mk.nowPlayingItem || (mk.queue && mk.queue.currentItem));
      const p = item && (item.defaultPlayable || (Array.isArray(item.playables) && item.playables[0]) || item.attributes);
      if (p) {
        if (typeof p.url === 'string' && p.url) {
          atvUrl = p.url;
        } else if (typeof p.canonicalId === 'string' && p.canonicalId) {
          const kinds = {
            Episode: 'episode',
            Movie: 'movie',
            Show: 'show',
            Season: 'season',
            SportingEvent: 'sporting-event',
            Extra: 'clip',
          };
          const seg = kinds[p.contentType || item.contentType];
          if (seg) {
            const pathSf = (location.pathname.match(/^\\/([a-z]{2})(?:\\/|$)/i) || [])[1] || '';
            const mkSf = typeof mk.storefrontId === 'string' && /^[a-z]{2}$/i.test(mk.storefrontId) ? mk.storefrontId : '';
            const sf = (pathSf || mkSf).toLowerCase();
            atvUrl = sf
              ? `https://tv.apple.com/${sf}/${seg}/${encodeURIComponent(p.canonicalId)}`
              : `https://tv.apple.com/${seg}/${encodeURIComponent(p.canonicalId)}`;
          }
        }
        const cm = p.canonicalMetadata || {};
        const ep = typeof cm.episodeTitle === 'string' ? cm.episodeTitle.trim() : '';
        const show = typeof cm.showTitle === 'string' ? cm.showTitle.trim() : '';
        const movie = typeof cm.movieTitle === 'string' ? cm.movieTitle.trim() : '';
        const shortTitle = typeof cm.shortTitle === 'string' ? cm.shortTitle.trim() : '';
        atvTitle = ep && show && ep !== show ? `${ep} · ${show}` : (ep || movie || shortTitle);
        atvFallbackTitle = typeof p.title === 'string' ? p.title.trim() : (typeof item.title === 'string' ? item.title.trim() : '');
      }
      if (!atvUrl) {
        const canon = document.querySelector('link[rel="canonical"]');
        const ogUrl = document.querySelector('meta[property="og:url"]');
        const cand = (canon && canon.href) || (ogUrl && ogUrl.content) || '';
        if (/^https?:\\/\\/tv\\.apple\\.com\\/(?:[a-z]{2}\\/)?(?:episode|movie|show|season|sporting-event|clip)\\//i.test(cand)) {
          atvUrl = cand;
        }
      }
    } catch {}
  }

  let title = atvTitle;
  if (!title) {
    const nf = document.querySelector('[data-uia="video-title"]');
    if (nf) {
      title = [...nf.children].map(e => e.textContent.trim()).filter(Boolean).join(' · ') || nf.textContent.trim();
    } else {
      const ms = navigator.mediaSession && navigator.mediaSession.metadata;
      if (ms && ms.title) {
        title = ms.artist ? `${ms.title} · ${ms.artist}` : ms.title;
      } else if (atvFallbackTitle) {
        title = atvFallbackTitle;
      } else {
        const og = document.querySelector('meta[property="og:title"]');
        title = (og && og.content) || document.title || '';
      }
    }
  }
  return { title: String(title || ''), url: String(atvUrl || ''), pageUrl: String(location.href || '') };
})()
"""

private let floatIconScript = """
(() => {
  const size = l => parseInt(((l.sizes && l.sizes.value) || '0').split('x')[0]) || (l.rel.includes('apple') ? 180 : 16);
  const l = [...document.querySelectorAll('link[rel~="icon"],link[rel^="apple-touch-icon"]')].sort((a, b) => size(b) - size(a));
  const fallback = (location.origin && /^https?:/i.test(location.origin)) ? location.origin + '/favicon.ico' : '';
  const raw = l[0] ? String(l[0].href || '') : fallback;
  const icon = /^(?:https?:|data:image\\/)/i.test(raw) ? raw : '';
  return { url: String(location.href || ''), icon };
})()
"""

/// Persistence store: uses UserDefaults.standard (exact same keys as original Float) in live
/// sessions, and an isolated scratch JSON file in `context.data` during agent/test sessions so
/// tests survive `reload` without ever touching the user's real UserDefaults.
private struct AgentSnapshot: Codable {
    var sites: [FloatSite] = []
    var resume: FloatResume?
    var fill: Bool = true
    var alpha: Double = 1.0
    var videoBrightness: Double = 1.0
    var hdrVideoBrightness: Double = 1.0
    var videoContrast: Double = 1.0
    var revealStyle: String = "ripple"
    var openStyle: String = "ripple"
    var preferSdr: Bool = false
    var streamBrightness: Bool = false
    var hotkeyKeys: String = "Control+Alt+Meta+F"
    var peekTrigger: String = "rightCommand"
    var peekAlpha: Double = 0.5
    var peekHotkeyKeys: String = "Control+Alt+Meta+D"
    var peekHold: Bool = true
}

private final class FloatStore {
    private let agentFile: URL?
    private let defaults = UserDefaults.standard
    private var snapshot = AgentSnapshot()

    init(agent: Bool, dataDir: URL) {
        if agent {
            let file = dataDir.appendingPathComponent("float-agent-defaults.json")
            agentFile = file
            if let data = try? Data(contentsOf: file),
               let loaded = try? JSONDecoder().decode(AgentSnapshot.self, from: data) {
                snapshot = loaded
            }
        } else {
            agentFile = nil
            // One-time migration from pre-mosaic builds
            if let last = defaults.string(forKey: "lastURL"), let u = URL(string: last) {
                recordSite(u, icon: nil)
                saveResume(FloatResume(url: last, title: "", time: 0, duration: 0))
                defaults.removeObject(forKey: "lastURL")
            }
        }
    }

    private func flushAgent() {
        guard let agentFile else { return }
        try? FileManager.default.createDirectory(at: agentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: agentFile, options: .atomic)
        }
    }

    var fill: Bool {
        get { agentFile != nil ? snapshot.fill : (defaults.object(forKey: "fill") as? Bool ?? true) }
        set {
            if agentFile != nil { snapshot.fill = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "fill") }
        }
    }

    var alpha: Double {
        get { agentFile != nil ? snapshot.alpha : (defaults.object(forKey: "alpha") as? Double ?? 1.0) }
        set {
            if agentFile != nil { snapshot.alpha = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "alpha") }
        }
    }

    var videoBrightness: Double {
        get { agentFile != nil ? snapshot.videoBrightness : (defaults.object(forKey: "videoBrightness") as? Double ?? 1.0) }
        set {
            if agentFile != nil { snapshot.videoBrightness = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "videoBrightness") }
        }
    }

    var hdrVideoBrightness: Double {
        get { agentFile != nil ? snapshot.hdrVideoBrightness : (defaults.object(forKey: "hdrVideoBrightness") as? Double ?? 1.0) }
        set {
            if agentFile != nil { snapshot.hdrVideoBrightness = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "hdrVideoBrightness") }
        }
    }

    var videoContrast: Double {
        get { agentFile != nil ? snapshot.videoContrast : (defaults.object(forKey: "videoContrast") as? Double ?? 1.0) }
        set {
            if agentFile != nil { snapshot.videoContrast = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "videoContrast") }
        }
    }

    var revealStyle: String {
        get { agentFile != nil ? snapshot.revealStyle : (defaults.string(forKey: "revealStyle") ?? "ripple") }
        set {
            if agentFile != nil { snapshot.revealStyle = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "revealStyle") }
        }
    }

    var openStyle: String {
        get { agentFile != nil ? snapshot.openStyle : (defaults.string(forKey: "openStyle") ?? "ripple") }
        set {
            if agentFile != nil { snapshot.openStyle = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "openStyle") }
        }
    }

    var preferSdr: Bool {
        get { agentFile != nil ? snapshot.preferSdr : (defaults.object(forKey: "preferSdr") as? Bool ?? false) }
        set {
            if agentFile != nil { snapshot.preferSdr = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "preferSdr") }
        }
    }

    var streamBrightness: Bool {
        get { agentFile != nil ? snapshot.streamBrightness : (defaults.object(forKey: "streamBrightness") as? Bool ?? false) }
        set {
            if agentFile != nil { snapshot.streamBrightness = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "streamBrightness") }
        }
    }

    var hotkeyKeys: String {
        get {
            if agentFile != nil { return snapshot.hotkeyKeys }
            return defaults.object(forKey: "hotkeyKeys") as? String ?? "Control+Alt+Meta+F"
        }
        set {
            if agentFile != nil { snapshot.hotkeyKeys = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "hotkeyKeys") }
        }
    }

    var peekTrigger: String {
        get { agentFile != nil ? snapshot.peekTrigger : (defaults.string(forKey: "peekTrigger") ?? "rightCommand") }
        set {
            if agentFile != nil { snapshot.peekTrigger = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "peekTrigger") }
        }
    }

    var peekAlpha: Double {
        get { agentFile != nil ? snapshot.peekAlpha : (defaults.object(forKey: "peekAlpha") as? Double ?? 0.5) }
        set {
            if agentFile != nil { snapshot.peekAlpha = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "peekAlpha") }
        }
    }

    var peekHotkeyKeys: String {
        get {
            if agentFile != nil { return snapshot.peekHotkeyKeys }
            return defaults.object(forKey: "peekHotkeyKeys") as? String ?? "Control+Alt+Meta+D"
        }
        set {
            if agentFile != nil { snapshot.peekHotkeyKeys = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "peekHotkeyKeys") }
        }
    }

    var peekHold: Bool {
        get { agentFile != nil ? snapshot.peekHold : (defaults.object(forKey: "peekHold") as? Bool ?? true) }
        set {
            if agentFile != nil { snapshot.peekHold = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "peekHold") }
        }
    }

    func allSites() -> [FloatSite] {
        if agentFile != nil { return snapshot.sites }
        guard let d = defaults.data(forKey: "sites") else { return [] }
        return (try? JSONDecoder().decode([FloatSite].self, from: d)) ?? []
    }

    func saveSites(_ sites: [FloatSite]) {
        if agentFile != nil { snapshot.sites = sites; flushAgent() }
        else if let data = try? JSONEncoder().encode(sites) { defaults.set(data, forKey: "sites") }
    }

    func recordSite(_ url: URL, icon: String?) {
        guard let host = url.host, let scheme = url.scheme, scheme.hasPrefix("http") else { return }
        var list = allSites()
        let norm = floatNormalizedHost(host)
        if let idx = list.firstIndex(where: { floatNormalizedHost($0.host) == norm }) {
            list[idx].last = Date()
            list[idx].count += 1
            let keepBundled = list[idx].icon?.hasPrefix("assets/providers/") == true
            if let icon, !icon.isEmpty, !keepBundled { list[idx].icon = icon }
        } else {
            list.append(FloatSite(host: host, url: "\(scheme)://\(host)", icon: icon, name: nil, last: Date(), count: 1))
        }
        saveSites(list)
    }

    func addSite(url: URL, name: String?, icon: String?) {
        guard let host = url.host, let scheme = url.scheme, scheme.hasPrefix("http") else { return }
        var list = allSites()
        let norm = floatNormalizedHost(host)
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanIcon = icon?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = list.firstIndex(where: { floatNormalizedHost($0.host) == norm }) {
            list[idx].url = url.absoluteString
            list[idx].last = Date()
            if let cleanName, !cleanName.isEmpty { list[idx].name = cleanName }
            if let cleanIcon, !cleanIcon.isEmpty { list[idx].icon = cleanIcon }
        } else {
            list.append(FloatSite(
                host: host,
                url: url.absoluteString,
                icon: (cleanIcon?.isEmpty == false ? cleanIcon : nil),
                name: (cleanName?.isEmpty == false ? cleanName : nil),
                last: Date(),
                count: 1
            ))
        }
        saveSites(list)
    }

    func removeSite(_ host: String) {
        let norm = floatNormalizedHost(host)
        saveSites(allSites().filter { floatNormalizedHost($0.host) != norm })
    }

    func loadResume() -> FloatResume? {
        if agentFile != nil { return snapshot.resume }
        return defaults.data(forKey: "resume").flatMap { try? JSONDecoder().decode(FloatResume.self, from: $0) }
    }

    func saveResume(_ resume: FloatResume) {
        if agentFile != nil { snapshot.resume = resume; flushAgent() }
        else if let data = try? JSONEncoder().encode(resume) { defaults.set(data, forKey: "resume") }
    }
}

/// Process-wide Sparkle 2 updater controller (linked via host.macos.swiftPackages).
private final class FloatUpdater {
    static let shared = FloatUpdater()
    private var started = false
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    func start() {
        guard !started else { return }
        started = true
        _ = controller
    }

    var canCheckForUpdates: Bool {
        started ? controller.updater.canCheckForUpdates : false
    }

    func checkForUpdates() {
        // Open Sparkle's window on the next main-queue turn, not inside native.call.
        DispatchQueue.main.async { [self] in
            start()
            controller.checkForUpdates(nil)
        }
    }
}

/// Process-wide live session hub so secondary windows (Settings, Shortcuts HUD) share state
/// and live video-filter updates with the main window's WKWebView.
private final class FloatHub {
    static let shared = FloatHub()

    private struct WeakMod { weak var value: FloatModule? }
    private var sessions: [WeakMod] = []
    private var liveStore: FloatStore?

    var mode = "home"
    var currentUrl = ""
    var activeVideoStream = ""
    var onTop = true
    var expanded = false
    var aspectLocked = false
    var clickThrough = false
    var pendingSeek: Double?
    var fxDemoSeq = 0
    var fxDemoKind = 0

    func store(for context: ExactModuleContext) -> FloatStore {
        if context.agent {
            return FloatStore(agent: true, dataDir: context.data)
        }
        if let liveStore { return liveStore }
        let s = FloatStore(agent: false, dataDir: context.data)
        liveStore = s
        return s
    }

    func register(_ mod: FloatModule) {
        sessions.removeAll { $0.value == nil || $0.value === mod }
        sessions.append(WeakMod(value: mod))
    }

    func unregister(_ mod: FloatModule) {
        sessions.removeAll { $0.value == nil || $0.value === mod }
    }

    var primaryBrowser: FloatBrowserInstance? {
        sessions.compactMap { $0.value?.browser }.first
    }

    var primaryWindow: NSWindow? {
        sessions.compactMap { $0.value?.mainWindow }.first
    }

    var primaryModule: FloatModule? {
        sessions.compactMap { $0.value }.first { $0.mainWindow != nil }
    }

    func broadcastChange(from origin: FloatModule) {
        if origin.context.agent {
            origin.syncWindowBackdrop()
            origin.context.changed("float")
            return
        }
        sessions.removeAll { $0.value == nil }
        for entry in sessions {
            guard let mod = entry.value else { continue }
            mod.syncWindowBackdrop()
            mod.context.changed("float")
        }
    }
}

/// Canonical host key ignoring case and optional `www.` prefix so `primevideo.com` and `www.primevideo.com`
/// share the same live tab slot.
private func floatCanonicalHost(_ host: String) -> String {
    let lower = host.lowercased()
    return lower.hasPrefix("www.") ? String(lower.dropFirst(4)) : lower
}

/// Compares two http(s) URLs ignoring trailing slash differences on the root path and host casing.
private func floatSameLoadTarget(_ a: URL, _ b: URL) -> Bool {
    guard (a.scheme?.lowercased() ?? "") == (b.scheme?.lowercased() ?? ""),
          let ha = a.host, let hb = b.host,
          floatCanonicalHost(ha) == floatCanonicalHost(hb),
          a.port == b.port,
          a.query == b.query else { return false }
    let pa = a.path.isEmpty ? "/" : a.path
    let pb = b.path.isEmpty ? "/" : b.path
    return pa == pb
}

/// WKWebView subclass that suppresses initial opaque backing-store flash before the GPU morph presents
/// and balances WebKit's reference-counted media suspension API across cross-origin process swaps.
private final class FloatWebView: WKWebView {
    weak var module: FloatModule?
    var triggersMorphPrepare = false
    private(set) var wantsMediaSuspended = false
    private(set) var webkitMediaSuspended = false
    private var provisionalNavigations: Set<ObjectIdentifier> = []
    private var pendingResumeCompletions: [() -> Void] = []

    var hasProvisionalNavigation: Bool {
        !provisionalNavigations.isEmpty
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if triggersMorphPrepare, let win = window {
            module?.prepareWindowForMorph(win)
        }
    }

    @discardableResult
    func loadTracked(_ request: URLRequest) -> WKNavigation? {
        let nav = load(request)
        noteProvisionalNavigationStarted(nav)
        return nav
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if alphaValue < 0.05 { return nil }
        return super.hitTest(point)
    }

    func noteProvisionalNavigationStarted(_ navigation: WKNavigation?) {
        guard let navigation else { return }
        provisionalNavigations.insert(ObjectIdentifier(navigation))
    }

    func noteProvisionalNavigationSettled(_ navigation: WKNavigation?) {
        if let navigation {
            provisionalNavigations.remove(ObjectIdentifier(navigation))
        }
        guard provisionalNavigations.isEmpty, !wantsMediaSuspended, webkitMediaSuspended else { return }
        webkitMediaSuspended = false
        let completions = pendingResumeCompletions
        pendingResumeCompletions.removeAll()
        setAllMediaPlaybackSuspended(false) {
            completions.forEach { $0() }
        }
    }

    func resetNavigationTracking() {
        provisionalNavigations.removeAll()
        pendingResumeCompletions.removeAll()
    }

    /// Balances WebKit's reference-counted `setAllMediaPlaybackSuspended(_:)` calls and defers
    /// unsuspending while a provisional cross-origin navigation is in flight (WebKit does not
    /// forward `ResumeAllMediaPlayback` to `ProvisionalPageProxy`, which would otherwise commit
    /// permanently suspended).
    func setMediaSuspended(_ suspended: Bool, completion: (() -> Void)? = nil) {
        wantsMediaSuspended = suspended
        if suspended {
            pendingResumeCompletions.removeAll()
            guard !webkitMediaSuspended else {
                completion?()
                return
            }
            webkitMediaSuspended = true
            setAllMediaPlaybackSuspended(true) {
                completion?()
            }
            return
        }

        if webkitMediaSuspended && !provisionalNavigations.isEmpty {
            if let completion {
                pendingResumeCompletions.append(completion)
            }
            return
        }

        guard webkitMediaSuspended else {
            completion?()
            return
        }
        webkitMediaSuspended = false
        let completions = pendingResumeCompletions
        pendingResumeCompletions.removeAll()
        setAllMediaPlaybackSuspended(false) {
            completions.forEach { $0() }
            completion?()
        }
    }
}

/// Delegate helper inheriting NSObject for WKNavigationDelegate, WKUIDelegate, and WKScriptMessageHandler.
private final class FloatBrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var module: FloatModule?
    weak var instance: FloatBrowserInstance?

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let module, let instance,
              let web = m.webView as? FloatWebView,
              web === instance.web,
              module.mode == "web",
              !web.isHidden,
              instance.activeNavigationCommitted,
              !web.hasProvisionalNavigation,
              let url = web.url, url.scheme?.hasPrefix("http") == true, let host = url.host,
              let b = m.body as? [String: Any] else { return }
        if m.frameInfo.isMainFrame {
            let originHost = m.frameInfo.securityOrigin.host
            if !originHost.isEmpty, originHost.lowercased() != host.lowercased() { return }
        }
        if let stream = b["stream"] as? String, ["", "sdr", "hdr"].contains(stream), module.activeVideoStream != stream {
            module.activeVideoStream = stream
            module.notifyChanged()
        }
        if b["event"] as? String == "stream" { return }
        let t = b["t"] as? Double ?? 0
        let d = b["d"] as? Double ?? 0
        guard t.isFinite, d.isFinite, t >= 0, d >= 0 else { return }
        let navToken = instance.activeNavigationToken
        if b["event"] as? String == "play" {
            web.evaluateJavaScript(floatIconScript) { [weak module, weak instance, weak web] result, _ in
                guard let module, let instance, let web,
                      web === instance.web,
                      module.mode == "web",
                      !web.isHidden,
                      instance.activeNavigationToken == navToken,
                      instance.activeNavigationCommitted,
                      !web.hasProvisionalNavigation,
                      let dict = result as? [String: Any],
                      let pageUrlStr = dict["url"] as? String,
                      let pageUrl = URL(string: pageUrlStr),
                      floatIsWeb(pageUrl),
                      let pageHost = pageUrl.host,
                      let currentHost = web.url?.host,
                      pageHost.lowercased() == currentHost.lowercased(),
                      pageHost.lowercased() == host.lowercased() else { return }
                let icon = (dict["icon"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                module.recordSite(pageUrl, icon: icon)
            }
        }
        // Skip trailers/previews/ads
        guard d > 180, t <= d else { return }
        if let seek = module.pendingSeek {
            if t < seek - 10, seek < d {
                web.evaluateJavaScript("[...document.querySelectorAll('video')].filter(v => !v.paused && v.duration > 180).forEach(v => v.currentTime = \(seek))")
            }
            module.pendingSeek = nil
        }
        web.evaluateJavaScript(floatResumeMetaScript) { [weak module, weak instance, weak web] r, _ in
            guard let module, let instance, let web,
                  web === instance.web,
                  module.mode == "web",
                  !web.isHidden,
                  instance.activeNavigationToken == navToken,
                  instance.activeNavigationCommitted,
                  !web.hasProvisionalNavigation,
                  let meta = r as? [String: Any],
                  let pageUrlStr = meta["pageUrl"] as? String,
                  let pageUrl = URL(string: pageUrlStr),
                  floatIsWeb(pageUrl),
                  let pageHost = pageUrl.host,
                  let currentHost = web.url?.host,
                  pageHost.lowercased() == currentHost.lowercased(),
                  pageHost.lowercased() == host.lowercased() else { return }
            let rawTitle = meta["title"] as? String ?? ""
            var resumeUrl = pageUrl
            if let candidate = meta["url"] as? String,
               !candidate.isEmpty,
               let parsed = URL(string: candidate),
               floatIsWeb(parsed),
               parsed.host?.lowercased() == pageHost.lowercased() {
                resumeUrl = parsed
            }
            module.recordResume(url: resumeUrl, host: pageHost, rawTitle: rawTitle, time: t, duration: d)
        }
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = a.request.url else { return decisionHandler(.allow) }
        if u.absoluteString == "about:blank" || floatIsWeb(u) {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
    }

    func webView(_ w: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        (w as? FloatWebView)?.noteProvisionalNavigationStarted(navigation)
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        (w as? FloatWebView)?.noteProvisionalNavigationSettled(navigation)
        let nsErr = error as NSError
        guard nsErr.domain != NSURLErrorDomain || nsErr.code != NSURLErrorCancelled else { return }
        instance?.handleActiveFailed(w)
    }

    func webView(_ w: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        (w as? FloatWebView)?.noteProvisionalNavigationSettled(navigation)
        let nsErr = error as NSError
        guard nsErr.domain != NSURLErrorDomain || nsErr.code != NSURLErrorCancelled else { return }
        instance?.handleActiveFailed(w)
    }

    func webView(_ w: WKWebView, didCommit navigation: WKNavigation!) {
        (w as? FloatWebView)?.noteProvisionalNavigationSettled(navigation)
        guard let instance else { return }
        if instance.isWarmSlot(w) {
            instance.handleWarmSlotCommitted(w)
            return
        }
        if let module, !module.activeVideoStream.isEmpty {
            module.activeVideoStream = ""
        }
        instance.handleActiveCommitted(w)
        syncFromWebView(w)
    }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        (w as? FloatWebView)?.noteProvisionalNavigationSettled(navigation)
        guard let instance else { return }
        if instance.isWarmSlot(w) {
            instance.handleWarmSlotFinished(w)
            return
        }
        instance.handleActiveFinished(w)
        syncFromWebView(w)
    }

    private func syncFromWebView(_ web: WKWebView) {
        guard let module, let instance,
              web === instance.web,
              module.mode == "web",
              !web.isHidden,
              let url = web.url else { return }
        if url.absoluteString == "about:blank" {
            if module.mode != "home" {
                module.mode = "home"
                module.notifyChanged()
            }
        } else if floatIsWeb(url) {
            let changed = module.mode != "web" || module.currentUrl != url.absoluteString
            module.mode = "web"
            module.currentUrl = url.absoluteString
            if changed { module.notifyChanged() }
        }
    }

    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        // Top-level page popups only: iframe popups would escape their sandbox
        if a.targetFrame == nil, a.sourceFrame.isMainFrame, let u = a.request.url, floatIsWeb(u) {
            w.load(URLRequest(url: u))
        }
        return nil
    }
}

/// Synchronous readiness probe for hidden background warm-pool slots (where rAF may be throttled).
/// Checks the middle band of the viewport (skipping top nav bars) so half-hydrated SPAs like Apple TV+
/// aren't falsely marked ready before hero/shelf content mounts.
private let floatContentReadyScript = """
(() => {
  if (!document.body || document.readyState !== 'complete') return false;
  const vw = window.innerWidth || 1, vh = window.innerHeight || 1;
  const inCenterBand = (el) => {
    const r = el.getBoundingClientRect();
    if (r.width < 24 || r.height < 24) return false;
    if (r.bottom <= vh * 0.18 || r.top >= vh * 0.88 || r.right <= 0 || r.left >= vw) return false;
    if (el.closest('header, nav, [role="banner"], [role="navigation"]')) return false;
    const cs = getComputedStyle(el);
    return cs.visibility !== 'hidden' && cs.display !== 'none' && parseFloat(cs.opacity || '1') > 0.1;
  };
  const vids = document.querySelectorAll('video');
  for (const v of vids) {
    if (v.readyState >= 2 && v.videoWidth > 0 && inCenterBand(v)) return true;
  }
  const imgs = [...document.querySelectorAll('img')].filter(i =>
    i.complete && i.naturalWidth > 64 && i.offsetWidth >= 64 && i.offsetHeight >= 44 && inCenterBand(i)
  );
  if (imgs.length >= 1) return true;
  const interactive = document.querySelectorAll('main a[href], main button:not([disabled]), [role="main"] a[href], [role="main"] button:not([disabled])');
  let centerInteractive = 0;
  for (const el of interactive) {
    if (inCenterBand(el)) { centerInteractive++; if (centerInteractive >= 2) break; }
  }
  return centerInteractive >= 2 && (document.body.innerText || '').trim().length >= 120;
})()
"""

/// Async TTI + center-viewport paint readiness probe for the visible active WebView behind the cover:
/// Returns:
/// - "video": a visible center <video> has decoded a real frame (bypasses pixel snapshot check for DRM video)
/// - "dom-ready": real non-nav visual + interactive content is painted in the middle band and rAF is quiet
///                (Swift then confirms with a fast 32x18 center-rect pixel variance check)
/// - "not-ready": still loading, empty middle, or main thread busy
private let floatInteractiveReadyScript = """
if (!document.body || document.readyState === 'loading') return 'not-ready';
const docComplete = document.readyState === 'complete';
const navElapsed = (typeof performance !== 'undefined' && performance.now) ? performance.now() : 0;

const rootEl = document.getElementById('root') || document.getElementById('app') || document.getElementById('__next') || document.body;
if (rootEl && rootEl.getAttribute('aria-busy') === 'true' && navElapsed < 5000) return 'not-ready';

const vw = window.innerWidth || 1, vh = window.innerHeight || 1;
const isVisibleRect = (el, minW, minH) => {
  const r = el.getBoundingClientRect();
  if (r.width < minW || r.height < minH) return false;
  if (r.bottom <= 0 || r.top >= vh || r.right <= 0 || r.left >= vw) return false;
  const cs = getComputedStyle(el);
  return cs.visibility !== 'hidden' && cs.display !== 'none' && parseFloat(cs.opacity || '1') > 0.1;
};
const inCenterBand = (el, minW, minH) => {
  const r = el.getBoundingClientRect();
  if (r.width < minW || r.height < minH) return false;
  if (r.bottom <= vh * 0.18 || r.top >= vh * 0.86 || r.right <= vw * 0.04 || r.left >= vw * 0.96) return false;
  if (el.closest('header, nav, [role="banner"], [role="navigation"]')) return false;
  const cs = getComputedStyle(el);
  return cs.visibility !== 'hidden' && cs.display !== 'none' && parseFloat(cs.opacity || '1') > 0.1;
};

// 1. Decoded video frame in viewport (handles FairPlay/DRM video whose pixels may read black in snapshots)
const hasDecodedVideo = [...document.querySelectorAll('video')].some(v =>
  v.readyState >= 2 && v.videoWidth > 0 && isVisibleRect(v, 100, 60)
);

// 2. Real painted imagery or canvas inside the middle band (ignoring top nav bar logos/icons!)
const hasCenterImg = [...document.querySelectorAll('img')].some(img =>
  img.complete && img.naturalWidth >= 48 && inCenterBand(img, 64, 44)
);
const hasCenterCanvas = [...document.querySelectorAll('canvas')].some(c =>
  inCenterBand(c, 120, 80)
);

// 3. CSS background-image artwork or substantial non-nav content sampled across a center 3x3 grid
let centerMediaHits = 0;
let centerTextChars = 0;
if (!hasDecodedVideo && !hasCenterImg && !hasCenterCanvas) {
  const seen = new Set();
  for (const fx of [0.25, 0.5, 0.75]) {
    for (const fy of [0.32, 0.52, 0.70]) {
      let el = document.elementFromPoint(vw * fx, vh * fy);
      let hops = 0;
      while (el && el !== document.body && el !== document.documentElement && hops < 5) {
        if (!seen.has(el) && !el.closest('header, nav, [role="banner"], [role="navigation"]')) {
          seen.add(el);
          const cs = getComputedStyle(el);
          if (cs.backgroundImage && cs.backgroundImage !== 'none' && cs.backgroundImage.includes('url(')) {
            const r = el.getBoundingClientRect();
            if (r.width >= 80 && r.height >= 50) centerMediaHits++;
          }
          const t = (el.innerText || '').trim();
          if (t.length > centerTextChars) centerTextChars = t.length;
        }
        el = el.parentElement;
        hops++;
      }
    }
  }
}

const hasCenterVisual = hasDecodedVideo || hasCenterImg || hasCenterCanvas || centerMediaHits >= 1 || centerTextChars >= 45;
const interactiveCount = [...document.querySelectorAll('a[href], button:not([disabled]), input:not([type="hidden"]), [role="button"], [tabindex]:not([tabindex="-1"]), video')]
  .filter(el => isVisibleRect(el, 16, 16)).length;
const hasInteractive = hasDecodedVideo || interactiveCount >= 1;

if (!hasCenterVisual || !hasInteractive) return 'not-ready';
if (!docComplete && !hasDecodedVideo && navElapsed < 2200) return 'not-ready';

const settled = await new Promise((resolve) => {
  const t0 = performance.now();
  requestAnimationFrame(() => {
    const t1 = performance.now();
    requestAnimationFrame(() => {
      const t2 = performance.now();
      setTimeout(() => {
        const t3 = performance.now();
        const frameOk = (t1 - t0) < 120 && (t2 - t1) < 90;
        const taskOk = (t3 - t2) < 120;
        resolve(frameOk && taskOk);
      }, 45);
    });
  });
});
if (!settled) return 'not-ready';
return hasDecodedVideo ? 'video' : 'dom-ready';
"""

private final class FloatWarmSlot {
    let hostKey: String
    let web: FloatWebView
    var requestedUrl: URL
    var committed = false
    var contentReady = false
    var lastUsed = Date()
    var probeToken: Int = 0

    init(hostKey: String, web: FloatWebView, requestedUrl: URL) {
        self.hostKey = hostKey
        self.web = web
        self.requestedUrl = requestedUrl
    }
}

/// Native WKWebView host owning video playback, fill script, isolated fpPlay tracking,
/// a bounded multi-site warm preload pool (up to 6 saved sites), true SPA readiness probing,
/// and instant resume-from-pause.
fileprivate final class FloatBrowserInstance: ExactNativeInstance {
    private static let maxWarmPoolSize = 6

    let container: NSView
    private(set) var web: FloatWebView
    private var warmPool: [String: FloatWarmSlot] = [:]
    private var processWarmupWeb: FloatWebView?
    private var pausedHomeUrl: URL?
    private var pausedRequestedUrl: URL?
    private var homeIdleCleanup: DispatchWorkItem?
    private var preparedUrl: URL?
    private(set) var activeNavigationToken: Int = 0
    private(set) var activeNavigationCommitted: Bool = true
    private var activeProbeToken: Int = 0
    private var activeReadyViaVideo: Bool = false
    private(set) var activeContentReady: Bool = true

    private weak var module: FloatModule?
    private let delegate = FloatBrowserDelegate()
    // Tracking script + fpPlay bridge live here; page JS can't reach them to forge messages.
    private let trackWorld = WKContentWorld.world(name: "float-track")

    init(_ module: FloatModule, _ events: ExactNativeEvents) {
        self.module = module
        self.container = NSView(frame: .zero)
        self.web = FloatBrowserInstance.makeWebView(
            module: module,
            delegate: delegate,
            trackWorld: trackWorld,
            triggersMorphPrepare: true
        )
        super.init(events: events)
        delegate.module = module
        delegate.instance = self
        web.frame = container.bounds
        web.autoresizingMask = [.width, .height]
        web.isHidden = (module.mode == "home")
        container.addSubview(web)
        installUserScripts(
            on: web,
            fill: module.fill,
            brightness: module.videoBrightness,
            hdrBrightness: module.hdrVideoBrightness,
            contrast: module.videoContrast,
            streamBrightness: module.streamBrightness,
            preferSdr: module.preferSdr
        )
        module.attachBrowser(self)
    }

    private static func makeWebView(
        module: FloatModule,
        delegate: FloatBrowserDelegate,
        trackWorld: WKContentWorld,
        triggersMorphPrepare: Bool
    ) -> FloatWebView {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.websiteDataStore = module.context.agent ? .nonPersistent() : .default()
        cfg.userContentController.add(delegate, contentWorld: trackWorld, name: "fpPlay")
        let w = FloatWebView(frame: .zero, configuration: cfg)
        w.module = module
        w.triggersMorphPrepare = triggersMorphPrepare
        w.customUserAgent = safariUA
        w.navigationDelegate = delegate
        w.uiDelegate = delegate
        w.allowsBackForwardNavigationGestures = true
        w.allowsMagnification = true
        w.underPageBackgroundColor = .black
        return w
    }

    override var view: ExactNativeView { container }

    override func destroy() {
        homeIdleCleanup?.cancel()
        homeIdleCleanup = nil
        activeNavigationToken += 1
        teardownWebView(web)
        for slot in warmPool.values {
            slot.probeToken += 1
            teardownWebView(slot.web)
        }
        warmPool.removeAll()
        if let pw = processWarmupWeb {
            teardownWebView(pw)
            processWarmupWeb = nil
        }
    }

    private func teardownWebView(_ w: FloatWebView) {
        w.configuration.userContentController.removeScriptMessageHandler(forName: "fpPlay", contentWorld: trackWorld)
        w.navigationDelegate = nil
        w.uiDelegate = nil
        w.resetNavigationTracking()
        w.stopLoading()
        w.setMediaSuspended(true)
        w.removeFromSuperview()
    }

    func isWarmSlot(_ w: WKWebView) -> Bool {
        if processWarmupWeb === w { return true }
        return warmPool.values.contains { $0.web === w }
    }

    private func warmSlot(for w: WKWebView) -> FloatWarmSlot? {
        warmPool.values.first { $0.web === w }
    }

    func handleWarmSlotCommitted(_ w: WKWebView) {
        (w as? FloatWebView)?.setMediaSuspended(true)
        guard let slot = warmSlot(for: w) else { return }
        slot.committed = true
    }

    func handleWarmSlotFinished(_ w: WKWebView) {
        (w as? FloatWebView)?.setMediaSuspended(true)
        guard let slot = warmSlot(for: w) else { return }
        slot.committed = true
        slot.probeToken += 1
        probeWarmSlotReadiness(slot, token: slot.probeToken, attemptsLeft: 60)
    }

    private func probeWarmSlotReadiness(_ slot: FloatWarmSlot, token: Int, attemptsLeft: Int) {
        guard slot.probeToken == token, warmPool[slot.hostKey] === slot, !slot.contentReady else { return }
        slot.web.setMediaSuspended(true)
        slot.web.evaluateJavaScript(floatContentReadyScript) { [weak self, weak slot] res, _ in
            guard let self, let slot, slot.probeToken == token, self.warmPool[slot.hostKey] === slot else { return }
            let domReady = (res as? Bool) ?? false
            let finishSlot = { (isPainted: Bool) in
                guard slot.probeToken == token, self.warmPool[slot.hostKey] === slot else { return }
                slot.contentReady = isPainted
                // Pause any media that bootstrapped during hydration and park hidden to save idle GPU.
                slot.web.evaluateJavaScript("(() => { document.querySelectorAll('video,audio').forEach(m => { try { m.pause(); } catch {} }); })()")
                slot.web.isHidden = true
                slot.web.alphaValue = 1.0
                self.module?.notifyChanged()
            }
            let retrySlot = { [weak self, weak slot] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                    guard let self, let slot else { return }
                    self.probeWarmSlotReadiness(slot, token: token, attemptsLeft: attemptsLeft - 1)
                }
            }
            if domReady {
                self.verifyCenterPixelsPainted(slot.web) { [weak self, weak slot] painted in
                    guard let self, let slot, slot.probeToken == token, self.warmPool[slot.hostKey] === slot else { return }
                    if painted {
                        finishSlot(true)
                    } else if attemptsLeft <= 1 {
                        // Never poison contentReady = true if the center is still blank!
                        finishSlot(false)
                    } else {
                        retrySlot()
                    }
                }
            } else if attemptsLeft <= 1 {
                finishSlot(false)
            } else {
                retrySlot()
            }
        }
    }

    func handleActiveCommitted(_ w: WKWebView) {
        guard w === web else { return }
        activeNavigationCommitted = true
        guard !activeContentReady, !web.isHidden else { return }
        startActiveInteractiveProbe(attemptsLeft: 60)
    }

    func handleActiveFinished(_ w: WKWebView) {
        guard w === web else { return }
        activeNavigationCommitted = true
        guard !activeContentReady, !web.isHidden else { return }
        startActiveInteractiveProbe(attemptsLeft: 50)
    }

    func handleActiveFailed(_ w: WKWebView) {
        guard w === web, !activeContentReady else { return }
        activeNavigationCommitted = true
        activeContentReady = true
        module?.notifyChanged()
    }

    private func startActiveInteractiveProbe(attemptsLeft: Int) {
        guard activeNavigationCommitted, !activeContentReady, !web.isHidden else { return }
        let token = activeNavigationToken
        guard activeProbeToken != token else { return }
        activeProbeToken = token
        probeActiveContentReady(token: token, attemptsLeft: attemptsLeft)
    }

    /// Takes a tiny 32x18 snapshot of the center 76% x 66% of the WKWebView (~2-4ms) and verifies
    /// that the middle actually has painted content rather than a uniform blank/black/dark-gray shell
    /// (even if a top nav bar or tiny centered loading spinner is visible).
    private func verifyCenterPixelsPainted(_ targetWeb: WKWebView, completion: @escaping (Bool) -> Void) {
        let b = targetWeb.bounds
        guard b.width >= 80, b.height >= 80 else {
            completion(true)
            return
        }
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = true
        cfg.rect = CGRect(
            x: b.origin.x + b.width * 0.12,
            y: b.origin.y + b.height * 0.18,
            width: b.width * 0.76,
            height: b.height * 0.66
        )
        cfg.snapshotWidth = 32
        targetWeb.takeSnapshot(with: cfg) { image, _ in
            guard let image else { completion(false); return }
            var proposed = CGRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
                completion(false)
                return
            }
            let gw = 32, gh = 18
            var pixels = [UInt8](repeating: 0, count: gw * gh * 4)
            let ok = pixels.withUnsafeMutableBytes { buf -> Bool in
                guard let base = buf.baseAddress,
                      let ctx = CGContext(
                          data: base,
                          width: gw,
                          height: gh,
                          bitsPerComponent: 8,
                          bytesPerRow: gw * 4,
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      ) else { return false }
                ctx.interpolationQuality = .low
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: gw, height: gh))
                return true
            }
            guard ok else { completion(false); return }

            // Quantize into 4-bit-per-channel RGB buckets (4096 bins) to find the dominant background color.
            var counts: [Int: Int] = [:]
            var bucketR: [Int: Int] = [:]
            var bucketG: [Int: Int] = [:]
            var bucketB: [Int: Int] = [:]
            let total = gw * gh
            for i in 0..<total {
                let off = i * 4
                let r = Int(pixels[off]), g = Int(pixels[off + 1]), b = Int(pixels[off + 2])
                let key = ((r >> 4) << 8) | ((g >> 4) << 4) | (b >> 4)
                counts[key, default: 0] += 1
                bucketR[key, default: 0] += r
                bucketG[key, default: 0] += g
                bucketB[key, default: 0] += b
            }
            guard let domEntry = counts.max(by: { $0.value < $1.value }) else {
                completion(false)
                return
            }
            let domCount = max(1, domEntry.value)
            let bgR = (bucketR[domEntry.key] ?? 0) / domCount
            let bgG = (bucketG[domEntry.key] ?? 0) / domCount
            let bgB = (bucketB[domEntry.key] ?? 0) / domCount

            var nonBg = 0
            for i in 0..<total {
                let off = i * 4
                let diff = abs(Int(pixels[off]) - bgR)
                    + abs(Int(pixels[off + 1]) - bgG)
                    + abs(Int(pixels[off + 2]) - bgB)
                if diff >= 36 { nonBg += 1 }
            }
            let nonBgFraction = Double(nonBg) / Double(total)
            let distinctBuckets = counts.count
            // Reject empty/black/spinner-only center; pass once real artwork, shelves, or a card paints!
            let painted = (nonBgFraction >= 0.12 && distinctBuckets >= 6) || nonBgFraction >= 0.24
            completion(painted)
        }
    }

    private func probeActiveContentReady(token: Int, attemptsLeft: Int) {
        guard token == activeNavigationToken, activeNavigationCommitted, !activeContentReady, !web.isHidden else { return }
        web.callAsyncJavaScript(floatInteractiveReadyScript, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self, token == self.activeNavigationToken, self.activeNavigationCommitted, !self.activeContentReady else { return }
            let status: String
            if case .success(let val) = result {
                status = (val as? String) ?? "not-ready"
            } else {
                status = "not-ready"
            }
            let scheduleRetry = { [weak self] in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.probeActiveContentReady(token: token, attemptsLeft: attemptsLeft - 1)
                }
            }
            if status == "video" || attemptsLeft <= 1 {
                self.activeReadyViaVideo = (status == "video")
                self.activeContentReady = true
                self.module?.notifyChanged()
                return
            }
            if status == "dom-ready" {
                let targetWeb = self.web
                self.verifyCenterPixelsPainted(targetWeb) { [weak self] painted in
                    guard let self, token == self.activeNavigationToken, self.activeNavigationCommitted, !self.activeContentReady else { return }
                    if painted {
                        self.activeContentReady = true
                        self.module?.notifyChanged()
                    } else {
                        scheduleRetry()
                    }
                }
            } else {
                scheduleRetry()
            }
        }
    }

    func confirmActiveVisuallyPainted(_ completion: @escaping (Bool) -> Void) {
        guard activeContentReady else {
            completion(false)
            return
        }
        if activeReadyViaVideo {
            completion(true)
            return
        }
        let targetWeb = web
        let token = activeNavigationToken
        verifyCenterPixelsPainted(targetWeb) { [weak self] painted in
            guard let self, token == self.activeNavigationToken else {
                completion(false)
                return
            }
            if painted {
                completion(true)
            } else {
                // Re-arm the active interactive probe if a promoted slot hadn't finished painting yet
                self.activeContentReady = false
                self.activeProbeToken = 0
                self.startActiveInteractiveProbe(attemptsLeft: 55)
                completion(false)
            }
        }
    }

    var preloadedHost: String {
        if let paused = pausedHomeUrl?.host ?? pausedRequestedUrl?.host {
            return paused
        }
        if let readySlot = warmPool.values
            .filter({ $0.contentReady })
            .sorted(by: { $0.lastUsed > $1.lastUsed })
            .first {
            return readySlot.requestedUrl.host ?? ""
        }
        return ""
    }

    func hasWarmHost(_ host: String) -> Bool {
        let key = floatCanonicalHost(host)
        if let ph = pausedHomeUrl?.host, floatCanonicalHost(ph) == key { return true }
        if let pr = pausedRequestedUrl?.host, floatCanonicalHost(pr) == key { return true }
        return warmPool[key] != nil
    }

    func removeWarmSite(_ host: String) {
        let key = floatCanonicalHost(host)
        if let slot = warmPool.removeValue(forKey: key) {
            slot.probeToken += 1
            teardownWebView(slot.web)
        }
    }

    func clearWarmPool() {
        for slot in warmPool.values {
            slot.probeToken += 1
            teardownWebView(slot.web)
        }
        warmPool.removeAll()
    }

    func installUserScripts(fill on: Bool, brightness: Double, hdrBrightness: Double, contrast: Double, streamBrightness: Bool, preferSdr: Bool) {
        installUserScripts(on: web, fill: on, brightness: brightness, hdrBrightness: hdrBrightness, contrast: contrast, streamBrightness: streamBrightness, preferSdr: preferSdr)
        for slot in warmPool.values {
            installUserScripts(on: slot.web, fill: on, brightness: brightness, hdrBrightness: hdrBrightness, contrast: contrast, streamBrightness: streamBrightness, preferSdr: preferSdr)
        }
    }

    private func installUserScripts(on target: WKWebView, fill on: Bool, brightness: Double, hdrBrightness: Double, contrast: Double, streamBrightness: Bool, preferSdr: Bool) {
        let ucc = target.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: floatMediaHookScript(preferSdr: preferSdr), injectionTime: .atDocumentStart, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: floatFillScript(on), injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: floatVideoFilterScript(brightness: brightness, hdrBrightness: hdrBrightness, contrast: contrast, streamBrightness: streamBrightness, preferSdr: preferSdr), injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: floatTrackScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: trackWorld))
    }

    func applyFill(_ on: Bool, brightness: Double, hdrBrightness: Double, contrast: Double, streamBrightness: Bool, preferSdr: Bool) {
        installUserScripts(fill: on, brightness: brightness, hdrBrightness: hdrBrightness, contrast: contrast, streamBrightness: streamBrightness, preferSdr: preferSdr)
        web.evaluateJavaScript(floatFillScript(on))
    }

    func applyVideoFilter(fill on: Bool, brightness: Double, hdrBrightness: Double, contrast: Double, streamBrightness: Bool, preferSdr: Bool) {
        installUserScripts(fill: on, brightness: brightness, hdrBrightness: hdrBrightness, contrast: contrast, streamBrightness: streamBrightness, preferSdr: preferSdr)
        let hookJs = floatMediaHookScript(preferSdr: preferSdr)
        let filterJs = floatVideoFilterScript(brightness: brightness, hdrBrightness: hdrBrightness, contrast: contrast, streamBrightness: streamBrightness, preferSdr: preferSdr)
        web.evaluateJavaScript(hookJs)
        web.evaluateJavaScript(filterJs)
        for slot in warmPool.values {
            slot.web.evaluateJavaScript(hookJs)
            slot.web.evaluateJavaScript(filterJs)
        }
    }

    /// Wakes WebKit's WebContent + Networking XPC processes on cold start when there are no saved sites yet.
    func warmWebKitProcesses() {
        guard let module, !module.context.agent else { return }
        guard processWarmupWeb == nil, warmPool.isEmpty else { return }
        let w = FloatBrowserInstance.makeWebView(
            module: module,
            delegate: delegate,
            trackWorld: trackWorld,
            triggersMorphPrepare: false
        )
        w.frame = container.bounds
        w.autoresizingMask = [.width, .height]
        w.isHidden = true
        w.setMediaSuspended(true)
        container.addSubview(w, positioned: .below, relativeTo: web)
        processWarmupWeb = w
        w.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
    }

    /// Preloads a saved site's homepage into the bounded multi-site warm pool (max 6 slots, LRU).
    func preloadStandby(_ url: URL) {
        guard let module, !module.context.agent, floatIsWeb(url), let rawHost = url.host else { return }
        let key = floatCanonicalHost(rawHost)

        // Already paused in activeWeb on this host (never spawn a duplicate slot or clobber live tab!)
        if let paused = pausedHomeUrl, let ph = paused.host, floatCanonicalHost(ph) == key {
            if floatSameLoadTarget(paused, url) || Self.isHomepageTileTarget(url) { return }
        }
        if let pausedReq = pausedRequestedUrl, let prh = pausedReq.host, floatCanonicalHost(prh) == key {
            if floatSameLoadTarget(pausedReq, url) || Self.isHomepageTileTarget(url) { return }
        }

        // Already warm/parked in pool for this site: never wipe a live parked tab when hovering a tile!
        if let existing = warmPool[key] {
            existing.lastUsed = Date()
            if floatSameLoadTarget(existing.requestedUrl, url) || Self.isHomepageTileTarget(url) { return }
            if let current = existing.web.url, floatSameLoadTarget(current, url) { return }
            existing.requestedUrl = url
            existing.committed = false
            existing.contentReady = false
            existing.probeToken += 1
            existing.web.alphaValue = 0.001
            existing.web.isHidden = false
            existing.web.setMediaSuspended(true)
            existing.web.loadTracked(URLRequest(url: url))
            return
        }

        // Clean up process-only warmup view once real sites enter the pool
        if let pw = processWarmupWeb {
            teardownWebView(pw)
            processWarmupWeb = nil
        }

        // LRU eviction when pool is at capacity
        while warmPool.count >= FloatBrowserInstance.maxWarmPoolSize {
            if let oldest = warmPool.values.min(by: { $0.lastUsed < $1.lastUsed }) {
                oldest.probeToken += 1
                teardownWebView(oldest.web)
                warmPool.removeValue(forKey: oldest.hostKey)
            } else {
                break
            }
        }

        let w = FloatBrowserInstance.makeWebView(
            module: module,
            delegate: delegate,
            trackWorld: trackWorld,
            triggersMorphPrepare: false
        )
        w.frame = container.bounds
        w.autoresizingMask = [.width, .height]
        // Mount unhidden at imperceptible 0.001 alpha (rounds to 0/255 on screen, hitTest -> nil)
        // so WebKit treats the view as visible and actually hydrates SPAs, triggers IntersectionObserver,
        // decodes hero artwork, and paints pixels BEFORE the user clicks the tile!
        w.alphaValue = 0.001
        w.isHidden = false
        installUserScripts(
            on: w,
            fill: module.fill,
            brightness: module.videoBrightness,
            hdrBrightness: module.hdrVideoBrightness,
            contrast: module.videoContrast,
            streamBrightness: module.streamBrightness,
            preferSdr: module.preferSdr
        )
        container.addSubview(w, positioned: .below, relativeTo: web)

        let slot = FloatWarmSlot(hostKey: key, web: w, requestedUrl: url)
        warmPool[key] = slot
        w.setMediaSuspended(true)
        w.loadTracked(URLRequest(url: url))
    }

    private static func isHomepageTileTarget(_ url: URL) -> Bool {
        (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
    }

    private static func sameHostAndPathOrAppleTV(_ a: URL, _ b: URL) -> Bool {
        guard let ha = a.host, let hb = b.host else { return false }
        let ca = floatCanonicalHost(ha)
        let cb = floatCanonicalHost(hb)
        guard ca == cb else { return false }
        if a.path == b.path { return true }
        // Apple TV+ plays video in an overlay on top of /us without changing web.url
        if ca == "tv.apple.com" { return true }
        return false
    }

    private func matchesPausedTarget(_ url: URL, resumeIfPaused: Bool) -> Bool {
        if pausedHomeUrl.map({ floatSameLoadTarget($0, url) }) ?? false { return true }
        if pausedRequestedUrl.map({ floatSameLoadTarget($0, url) }) ?? false { return true }
        if resumeIfPaused, let paused = pausedHomeUrl, Self.sameHostAndPathOrAppleTV(paused, url) {
            return true
        }
        // Clicking a site tile (e.g. https://tv.apple.com) matches a paused session on the same host
        // even after the SPA redirected to /us, /browse, /storefront, or a show/watch page!
        if !resumeIfPaused, Self.isHomepageTileTarget(url),
           let pausedHost = (pausedHomeUrl ?? pausedRequestedUrl)?.host,
           let targetHost = url.host,
           floatCanonicalHost(pausedHost) == floatCanonicalHost(targetHost) {
            return true
        }
        return false
    }

    private func matchingWarmSlot(for url: URL, resumeIfPaused: Bool = false) -> FloatWarmSlot? {
        guard let rawHost = url.host, let slot = warmPool[floatCanonicalHost(rawHost)] else { return nil }
        if floatSameLoadTarget(slot.requestedUrl, url) { return slot }
        if let current = slot.web.url, floatSameLoadTarget(current, url) { return slot }
        if Self.isHomepageTileTarget(url) { return slot }
        if resumeIfPaused, let current = slot.web.url, Self.sameHostAndPathOrAppleTV(current, url) { return slot }
        return nil
    }

    /// True when the requested target is already loaded & painted in memory (either paused in activeWeb
    /// or verified painted in warmPool), so opening it can skip all loading states completely.
    func isTargetAlreadyReady(_ url: URL, resumeIfPaused: Bool) -> Bool {
        if matchesPausedTarget(url, resumeIfPaused: resumeIfPaused) {
            return activeContentReady
        }
        if let slot = matchingWarmSlot(for: url, resumeIfPaused: resumeIfPaused) {
            return slot.contentReady
        }
        return false
    }

    /// Parks the current activeWeb into `warmPool` when switching to a different host so returning to it
    /// later is instant with zero reload.
    private func parkCurrentWebIfDifferentHost(from targetUrl: URL) {
        let oldWeb = web
        guard let oldUrl = pausedHomeUrl ?? oldWeb.url,
              floatIsWeb(oldUrl),
              let oldHost = oldUrl.host,
              let newHost = targetUrl.host else { return }
        let oldKey = floatCanonicalHost(oldHost)
        let newKey = floatCanonicalHost(newHost)
        guard oldKey != newKey else { return }

        // Evict oldest slot if pool is at capacity before parking
        while warmPool.count >= FloatBrowserInstance.maxWarmPoolSize && warmPool[oldKey] == nil {
            if let oldest = warmPool.values.min(by: { $0.lastUsed < $1.lastUsed }) {
                oldest.probeToken += 1
                teardownWebView(oldest.web)
                warmPool.removeValue(forKey: oldest.hostKey)
            } else {
                break
            }
        }
        // Replace any stale preloaded slot for oldKey with the user's actual visited tab
        if let existing = warmPool.removeValue(forKey: oldKey) {
            existing.probeToken += 1
            teardownWebView(existing.web)
        }
        guard let module else { return }

        oldWeb.triggersMorphPrepare = false
        oldWeb.isHidden = true
        oldWeb.alphaValue = 1.0
        oldWeb.evaluateJavaScript("(() => { document.querySelectorAll('video,audio').forEach(m => { try { m.pause(); } catch {} }); })()")
        oldWeb.setMediaSuspended(true)
        let parked = FloatWarmSlot(hostKey: oldKey, web: oldWeb, requestedUrl: URL(string: "\(oldUrl.scheme ?? "https")://\(oldHost)") ?? oldUrl)
        parked.committed = true
        parked.contentReady = activeContentReady
        parked.lastUsed = Date()
        warmPool[oldKey] = parked

        // Spin up a fresh activeWeb for the new cold target
        let fresh = FloatBrowserInstance.makeWebView(
            module: module,
            delegate: delegate,
            trackWorld: trackWorld,
            triggersMorphPrepare: false
        )
        fresh.frame = container.bounds
        fresh.autoresizingMask = [.width, .height]
        fresh.isHidden = true
        installUserScripts(
            on: fresh,
            fill: module.fill,
            brightness: module.videoBrightness,
            hdrBrightness: module.hdrVideoBrightness,
            contrast: module.videoContrast,
            streamBrightness: module.streamBrightness,
            preferSdr: module.preferSdr
        )
        container.addSubview(fresh)
        web = fresh
    }

    /// Prepares or promotes the target URL in the background without unhiding yet (used during glass wipe).
    func prepareRequest(_ url: URL, resumeIfPaused: Bool = false) {
        homeIdleCleanup?.cancel()
        homeIdleCleanup = nil
        preparedUrl = url

        // 1. Instant 0ms path: target is already paused in activeWeb from a recent showHome()
        if matchesPausedTarget(url, resumeIfPaused: resumeIfPaused) {
            activeNavigationToken += 1
            activeNavigationCommitted = true
            activeContentReady = true
            module?.notifyChanged()
            return
        }

        // 2. Instant pool promotion path: site is already warm/hydrated in warmPool
        if let slot = matchingWarmSlot(for: url, resumeIfPaused: resumeIfPaused) {
            promoteWarmSlot(slot, reveal: false)
            return
        }

        // 3. Cold navigation directly into activeWeb behind the cover (parking previous site in warmPool!).
        parkCurrentWebIfDifferentHost(from: url)
        pausedHomeUrl = nil
        pausedRequestedUrl = nil
        activeNavigationToken += 1
        activeNavigationCommitted = false
        activeReadyViaVideo = false
        activeContentReady = false
        let token = activeNavigationToken
        let targetWeb = web
        targetWeb.setMediaSuspended(false) { [weak self] in
            guard let self, self.web === targetWeb, self.activeNavigationToken == token else { return }
            targetWeb.loadTracked(URLRequest(url: url))
        }
        module?.notifyChanged()
    }

    /// Commits a previously prepared load (or loads fresh if not yet prepared), revealing and unsuspending media.
    func commitPreparedOrLoad(_ url: URL, resumeIfPaused: Bool = false) {
        homeIdleCleanup?.cancel()
        homeIdleCleanup = nil

        let wasPrepared = preparedUrl.map { floatSameLoadTarget($0, url) } ?? false
        preparedUrl = nil

        // 1. Instant 0ms resume from paused Home state
        if matchesPausedTarget(url, resumeIfPaused: resumeIfPaused) {
            pausedHomeUrl = nil
            pausedRequestedUrl = nil
            activeNavigationToken += 1
            activeNavigationCommitted = true
            activeContentReady = true
            web.alphaValue = 1.0
            web.isHidden = false
            let activeWeb = web
            activeWeb.setMediaSuspended(false) { [weak self] in
                guard let self, self.web === activeWeb, resumeIfPaused else { return }
                activeWeb.evaluateJavaScript("(() => { const v=[...document.querySelectorAll('video')].find(v=>v.currentSrc); if(v && v.paused){ v.play().catch(()=>{}); } })()")
            }
            return
        }

        // 2. Promote matching warm slot if not already promoted in prepareRequest
        if let slot = matchingWarmSlot(for: url, resumeIfPaused: resumeIfPaused) {
            promoteWarmSlot(slot, reveal: true)
            return
        }

        // 3. Reveal & unsuspend activeWeb (either already prepared or fresh load)
        pausedHomeUrl = nil
        pausedRequestedUrl = nil
        web.alphaValue = 1.0
        web.isHidden = false
        let activeWeb = web
        if !wasPrepared {
            activeNavigationToken += 1
            activeNavigationCommitted = false
            activeReadyViaVideo = false
            activeContentReady = false
            let token = activeNavigationToken
            activeWeb.setMediaSuspended(false) { [weak self] in
                guard let self, self.web === activeWeb, self.activeNavigationToken == token else { return }
                activeWeb.loadTracked(URLRequest(url: url))
            }
        } else {
            let canTouchActiveDoc = activeNavigationCommitted && !activeWeb.hasProvisionalNavigation
            activeWeb.setMediaSuspended(false) { [weak self] in
                guard let self, self.web === activeWeb, resumeIfPaused,
                      self.activeNavigationCommitted, !activeWeb.hasProvisionalNavigation,
                      activeWeb.url?.host?.lowercased() == url.host?.lowercased() else { return }
                activeWeb.evaluateJavaScript("(() => { const v=[...document.querySelectorAll('video')].find(v=>v.currentSrc); if(v && v.paused){ v.play().catch(()=>{}); } })()")
            }
            if canTouchActiveDoc, let mod = module {
                web.evaluateJavaScript(floatMediaHookScript(preferSdr: mod.preferSdr))
                web.evaluateJavaScript(floatFillScript(mod.fill))
                web.evaluateJavaScript(floatVideoFilterScript(
                    brightness: mod.videoBrightness,
                    hdrBrightness: mod.hdrVideoBrightness,
                    contrast: mod.videoContrast,
                    streamBrightness: mod.streamBrightness,
                    preferSdr: mod.preferSdr
                ))
            }
            if !activeContentReady, activeNavigationCommitted {
                // Start TTI + paint probing now that WebView is unhidden behind the opaque glass veil
                startActiveInteractiveProbe(attemptsLeft: 60)
            }
        }
    }

    private func promoteWarmSlot(_ slot: FloatWarmSlot, reveal: Bool) {
        let oldWeb = web
        let oldWasCommitted = activeNavigationCommitted && !oldWeb.hasProvisionalNavigation
        let oldPausedUrl = pausedHomeUrl ?? oldWeb.url
        let oldWasReady = activeContentReady
        warmPool.removeValue(forKey: slot.hostKey)
        slot.probeToken += 1

        pausedHomeUrl = nil
        pausedRequestedUrl = nil

        slot.web.frame = container.bounds
        slot.web.alphaValue = 1.0
        slot.web.isHidden = !reveal
        web = slot.web
        activeNavigationToken += 1
        activeNavigationCommitted = slot.committed
        activeReadyViaVideo = false
        activeContentReady = slot.contentReady

        // Park oldWeb back into warmPool for ANY committed visited site (including redirected paths like /us or /storefront)
        // so bouncing between streaming apps literally switches straight back to "that tab" with zero reload!
        if oldWasCommitted, let oldUrl = oldPausedUrl, floatIsWeb(oldUrl), let oldHost = oldUrl.host {
            let oldKey = floatCanonicalHost(oldHost)
            if oldKey != slot.hostKey {
                // Replace any stale preloaded slot for oldKey with the user's live visited tab
                if let existing = warmPool.removeValue(forKey: oldKey) {
                    existing.probeToken += 1
                    teardownWebView(existing.web)
                }
                while warmPool.count >= FloatBrowserInstance.maxWarmPoolSize {
                    if let oldest = warmPool.values.min(by: { $0.lastUsed < $1.lastUsed }) {
                        oldest.probeToken += 1
                        teardownWebView(oldest.web)
                        warmPool.removeValue(forKey: oldest.hostKey)
                    } else {
                        break
                    }
                }
                oldWeb.triggersMorphPrepare = false
                oldWeb.isHidden = true
                oldWeb.alphaValue = 1.0
                oldWeb.evaluateJavaScript("(() => { document.querySelectorAll('video,audio').forEach(m => { try { m.pause(); } catch {} }); })()")
                oldWeb.setMediaSuspended(true)
                let parked = FloatWarmSlot(hostKey: oldKey, web: oldWeb, requestedUrl: URL(string: "\(oldUrl.scheme ?? "https")://\(oldHost)") ?? oldUrl)
                parked.committed = true
                parked.contentReady = oldWasReady
                parked.lastUsed = Date()
                warmPool[oldKey] = parked
            } else {
                teardownWebView(oldWeb)
            }
        } else {
            teardownWebView(oldWeb)
        }

        if reveal {
            web.setMediaSuspended(false)
            if let mod = module {
                web.evaluateJavaScript(floatMediaHookScript(preferSdr: mod.preferSdr))
                web.evaluateJavaScript(floatFillScript(mod.fill))
                web.evaluateJavaScript(floatVideoFilterScript(
                    brightness: mod.videoBrightness,
                    hdrBrightness: mod.hdrVideoBrightness,
                    contrast: mod.videoContrast,
                    streamBrightness: mod.streamBrightness,
                    preferSdr: mod.preferSdr
                ))
            }
        }
        if !activeContentReady, reveal, activeNavigationCommitted {
            startActiveInteractiveProbe(attemptsLeft: 60)
        }
        module?.notifyChanged()
    }

    func loadRequest(_ url: URL) {
        commitPreparedOrLoad(url, resumeIfPaused: false)
    }

    /// Pauses & suspends media when returning Home so jumping back to the active video is 0ms.
    func suspendForHome() {
        let wasCommitted = activeNavigationCommitted && !web.hasProvisionalNavigation
        preparedUrl = nil
        activeNavigationToken += 1
        activeNavigationCommitted = true
        activeContentReady = true
        homeIdleCleanup?.cancel()
        homeIdleCleanup = nil

        if wasCommitted, let cur = web.url, floatIsWeb(cur) {
            pausedHomeUrl = cur
            pausedRequestedUrl = cur
            web.evaluateJavaScript("(() => { document.querySelectorAll('video,audio').forEach(m => { try { m.pause(); } catch {} }); })()")
            web.setMediaSuspended(true)
            web.isHidden = true

            // Release memory if user stays on Home idle for 3 minutes
            let cleanup = DispatchWorkItem { [weak self] in
                guard let self, self.module?.mode == "home" else { return }
                self.loadBlank()
            }
            homeIdleCleanup = cleanup
            DispatchQueue.main.asyncAfter(deadline: .now() + 180.0, execute: cleanup)
        } else {
            loadBlank()
        }
    }

    func loadBlank() {
        homeIdleCleanup?.cancel()
        homeIdleCleanup = nil
        pausedHomeUrl = nil
        pausedRequestedUrl = nil
        preparedUrl = nil
        activeNavigationToken += 1
        activeContentReady = true
        web.isHidden = true
        web.setMediaSuspended(true)
        web.loadTracked(URLRequest(url: URL(string: "about:blank")!))
    }
}

/// Non-interactive Liquid Glass window backdrop for the Home screen (macOS 26+ native glass, older HUD material fallback).
@available(macOS 26.0, *)
private final class FloatHomeGlassView: NSGlassEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class FloatHomeVisualEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct FloatSurfaceUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var duration: Float
    var effectKind: Int32
    var releaseAt: Float
    var isDemo: Int32
    var hasWindowMask: Int32
    var origin: SIMD4<Float> // cx, cy, w, h in normalized [0..1] top-left UV
}

private let floatSurfaceTransitionMSL = """
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution;
    float time;
    float duration;
    int effectKind;
    float releaseAt;
    int isDemo;
    int hasWindowMask;
    float4 origin;
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut surfaceVS(uint vid [[vertex_id]]) {
    constexpr float2 pos[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    VSOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = float2(pos[vid].x * 0.5 + 0.5, 0.5 - pos[vid].y * 0.5);
    return out;
}

static inline float clamp01(float x) { return clamp(x, 0.0f, 1.0f); }
static inline float easeOutCubic(float t) { float i = 1.0f - clamp01(t); return 1.0f - i * i * i; }
static inline float easeInOutCubic(float t) {
    t = clamp01(t);
    return t < 0.5f ? 4.0f * t * t * t : 1.0f - pow(-2.0f * t + 2.0f, 3.0f) * 0.5f;
}
static inline float hash2(float2 p) {
    return fract(sin(dot(p, float2(127.1f, 311.7f))) * 43758.5453123f);
}
static inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0f - 2.0f * f);
    return mix(mix(hash2(i), hash2(i + float2(1.0f, 0.0f)), u.x),
               mix(hash2(i + float2(0.0f, 1.0f)), hash2(i + float2(1.0f, 1.0f)), u.x), u.y);
}
static inline float fbm(float2 p) {
    float v = 0.0f, a = 0.52f;
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        p *= 2.03f;
        a *= 0.5f;
    }
    return v;
}
static inline float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + float2(r);
    return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - r;
}

static inline float4 sampleTex(texture2d<float> tex, sampler s, float2 uv) {
    if (uv.x < 0.0f || uv.x > 1.0f || uv.y < 0.0f || uv.y > 1.0f) return float4(0.0f);
    return tex.sample(s, uv);
}

static inline float4 sampleBlur(texture2d<float> tex, sampler s, float2 uv, float2 res, float radiusPx) {
    if (radiusPx < 0.35f) return sampleTex(tex, s, uv);
    float2 px = radiusPx / max(res, float2(1.0f));
    float4 acc = sampleTex(tex, s, uv) * 0.24f;
    acc += sampleTex(tex, s, uv + float2( px.x,  0.0f)) * 0.11f;
    acc += sampleTex(tex, s, uv + float2(-px.x,  0.0f)) * 0.11f;
    acc += sampleTex(tex, s, uv + float2( 0.0f,  px.y)) * 0.11f;
    acc += sampleTex(tex, s, uv + float2( 0.0f, -px.y)) * 0.11f;
    acc += sampleTex(tex, s, uv + float2( px.x,  px.y) * 0.72f) * 0.08f;
    acc += sampleTex(tex, s, uv + float2(-px.x,  px.y) * 0.72f) * 0.08f;
    acc += sampleTex(tex, s, uv + float2( px.x, -px.y) * 0.72f) * 0.08f;
    acc += sampleTex(tex, s, uv + float2(-px.x, -px.y) * 0.72f) * 0.08f;
    return acc;
}

static inline float4 sampleChromatic(texture2d<float> tex, sampler s, float2 uv, float2 res, float2 dir, float amt, float blurPx) {
    if (amt < 0.0002f) return sampleBlur(tex, s, uv, res, blurPx);
    float4 cr = sampleBlur(tex, s, uv + dir * amt, res, blurPx);
    float4 cg = sampleBlur(tex, s, uv, res, blurPx);
    float4 cb = sampleBlur(tex, s, uv - dir * amt, res, blurPx);
    float a = clamp01(max(cg.a, max(cr.a, cb.a)));
    return float4(min(float3(cr.r, cg.g, cb.b), float3(a)), a);
}

static inline float4 overPremul(float4 top, float4 bot) {
    return top + bot * (1.0f - top.a);
}

static inline float4 evaluateSurfaceEffect(
    float2 uv,
    float2 res,
    constant Uniforms& u,
    texture2d<float> fromTex,
    texture2d<float> toTex,
    sampler s
) {
    float aspect = res.x / res.y;
    float2 p = float2((uv.x - 0.5f) * aspect, uv.y - 0.5f);
    float t = clamp01(u.time / max(u.duration, 0.001f));
    int kind = u.effectKind;
    bool demo = (u.isDemo != 0);

    // 0: Pixel-identical hold of outgoing surface while incoming Home layout renders behind overlay
    if (kind == 0) {
        return sampleTex(fromTex, s, uv);
    }

    // 1: Wave + Bevel (diagonal refractive glass wave sweeping across live UI)
    if (kind == 1) {
        float diag = uv.x * 0.64f + uv.y * 0.36f;
        float front = mix(-0.24f, 1.30f, easeInOutCubic(t));
        float delta = diag - front;
        float env = exp(-pow(delta * 8.5f, 2.0f)) * smoothstep(0.0f, 0.08f, t) * (1.0f - smoothstep(0.84f, 1.0f, t));
        float lift = sin(delta * 16.0f) * env;
        float2 wuv = uv + float2(0.016f / aspect, 0.014f) * lift;
        float4 surf = sampleChromatic(fromTex, s, wuv, res, float2(0.64f / aspect, 0.36f), env * 0.008f, env * 2.5f);
        float sheenA = clamp01(exp(-pow(delta * 14.0f, 2.0f)) * env * 0.62f);
        float4 sheen = float4(float3(0.45f, 0.98f, 0.99f) * sheenA, sheenA);
        return overPremul(sheen, surf);
    }

    // 2: Glass Curtain (prismatic frosted-glass curtain gliding across live UI)
    if (kind == 2) {
        float diag = uv.x * 0.72f + uv.y * 0.28f;
        float front = mix(-0.22f, 1.32f, easeInOutCubic(t));
        float distEdge = diag - front;
        float fade = smoothstep(0.0f, 0.08f, t) * (1.0f - smoothstep(0.84f, 1.0f, t));
        float band = exp(-pow(distEdge * 6.0f, 2.0f)) * fade;
        float2 wuv = uv + float2(0.022f / aspect, 0.010f) * band;
        float4 surf = sampleChromatic(fromTex, s, wuv, res, float2(0.72f / aspect, 0.28f), band * 0.014f, band * 8.5f);
        float veilA = band * 0.34f;
        float4 veil = float4(float3(0.07f, 0.28f, 0.32f) * veilA, veilA);
        float4 outC = overPremul(veil, surf);
        float core = exp(-pow(distEdge * 20.0f, 2.0f)) * fade;
        float prismA = clamp01(core * 0.82f);
        return overPremul(float4(float3(0.62f, 0.99f, 1.0f) * prismA, prismA), outC);
    }

    // 11: Liquid Refractive Ripple — center shockwave expands outward, revealing the underlying
    // page behind the wave front while refracting & bending freshly revealed cards across 3 trailing crests.
    if (kind == 11) {
        float2 center = float2(0.0f, -0.02f);
        float2 d = p - center;
        float dist = length(d);
        float2 dir = dist > 0.0001f ? d / dist : float2(1.0f, 0.0f);

        // In Settings demo (already looking at Home), smoothly dissolve the existing UI into bare
        // Liquid Glass over the first 95ms so the center ripple genuinely reveals it from nothing.
        // On real Web -> Home return (demo == false), start immediately from bare Liquid Glass!
        float preFade = demo ? (1.0f - easeOutCubic(clamp01(t / 0.095f))) : 0.0f;
        float rt = demo ? clamp01((t - 0.075f) / 0.925f) : t;

        float front = mix(-0.05f, 1.44f, easeOutCubic(rt));
        float delta = dist - front;
        float intro = smoothstep(0.0f, 0.07f, rt);
        float outro = 1.0f - smoothstep(0.76f, 1.0f, rt);
        float fade = intro * outro;

        // Sharp leading shock front + wide trailing wake carrying 3 bold concentric ripples
        float leadEnv = exp(-pow(max(delta, 0.0f) * 14.0f, 2.0f));
        float wakeEnv = exp(-pow(max(-delta, 0.0f) * 3.0f, 2.0f));
        float env = leadEnv * wakeEnv * fade;

        float phase = delta * 24.0f;
        float waveHeight = sin(phase) * env;
        float waveSlope = cos(phase) * env;

        // True radial reveal mask: 0.0 (hidden over live Liquid Glass) ahead of front, 1.0 behind front!
        float revealed = (rt <= 0.0001f) ? 0.0f : (1.0f - smoothstep(-0.055f, 0.035f, delta));
        float2 radialUv = float2(dir.x / aspect, dir.y);
        float sc = mix(0.92f, 1.0f, revealed) + waveHeight * 0.085f;
        float2 wuv = (uv - 0.5f) / sc + 0.5f;
        wuv += radialUv * (waveSlope * 0.130f + waveHeight * 0.045f);

        float blurPx = (1.0f - revealed) * 5.0f + abs(waveSlope) * 4.5f;
        float chromAmt = abs(waveSlope) * 0.028f;
        float4 surf = sampleChromatic(toTex, s, wuv, res, radialUv, chromAmt, blurPx);

        float shade = 1.0f + waveSlope * 0.18f;
        surf.rgb = min(surf.rgb * max(0.0f, shade), float3(surf.a));

        // Mask the revealed Home surface by the expanding ripple front
        float4 revealedSurf = surf * revealed;
        if (demo) {
            if (preFade > 0.001f) {
                float4 oldSurf = sampleBlur(fromTex, s, uv, res, (1.0f - preFade) * 5.0f) * preFade;
                revealedSurf = overPremul(revealedSurf, oldSurf);
            }
        } else {
            // Composited right on top of the outgoing Web view (fromTex): the live Web page stays intact
            // ahead of the expanding center ripple, bends as the shockwave hits it, and parts cleanly
            // into live Liquid Glass + Home behind the wave front!
            float webRemain = 1.0f - revealed;
            if (webRemain > 0.001f) {
                float2 webUv = uv + radialUv * (waveSlope * 0.095f);
                float4 webSurf = sampleChromatic(fromTex, s, webUv, res, radialUv, abs(waveSlope) * 0.024f, abs(waveSlope) * 3.5f);
                float webShade = 1.0f + waveSlope * 0.14f;
                webSurf.rgb = min(webSurf.rgb * max(0.0f, webShade), float3(webSurf.a));
                webSurf *= webRemain;
                revealedSurf = overPremul(revealedSurf, webSurf);
            }
        }

        // Crisp glassy specular caustic glint along the expanding reveal front & trailing crests
        float spec = pow(clamp01(waveSlope), 2.5f) * 0.36f * revealed + pow(clamp01(-waveSlope), 3.0f) * 0.12f * revealed;
        float rimGlow = exp(-pow(delta * 16.0f, 2.0f)) * 0.42f * fade;
        float crestA = clamp01(spec + rimGlow);
        float4 crest = float4(float3(0.45f, 0.98f, 1.0f) * crestA, crestA);
        return overPremul(crest, revealedSurf);
    }

    // 12: Frost Refraction Thaw (ice-crystal micro-refraction that freezes/thaws across real UI)
    if (kind == 12) {
        float dist = length(p * float2(0.82f, 1.0f));
        float n = fbm(uv * float2(14.0f, 8.0f));
        float fine = fbm(uv * float2(42.0f, 24.0f));
        float field = dist * 0.72f + n * 0.42f;

        float frozen = 0.0f;
        float meltEdge = 0.0f;
        if (demo) {
            float freezeAmt = easeOutCubic(clamp01(t / 0.24f));
            float thawU = clamp01((t - 0.20f) / 0.80f);
            float thawFront = mix(-0.14f, 1.28f, easeInOutCubic(thawU));
            float stillFrozen = smoothstep(thawFront - 0.09f, thawFront + 0.07f, field);
            frozen = freezeAmt * stillFrozen;
            meltEdge = exp(-pow((field - thawFront) * 16.0f, 2.0f)) * smoothstep(0.16f, 0.28f, t) * (1.0f - smoothstep(0.84f, 1.0f, t));
        } else {
            float front = mix(-0.14f, 1.26f, easeInOutCubic(t));
            frozen = smoothstep(front - 0.09f, front + 0.07f, field);
            meltEdge = exp(-pow((field - front) * 16.0f, 2.0f)) * (1.0f - smoothstep(0.80f, 1.0f, t));
        }

        float2 refractOff = (float2(fine, fbm(uv * float2(42.0f, 24.0f) + 7.3f)) - 0.5f) * 0.048f * frozen;
        float2 scaleUv = mix(uv, (uv - 0.5f) * 0.96f + 0.5f, frozen) + refractOff;
        float blurPx = frozen * 9.5f + meltEdge * 2.5f;

        float4 surf = sampleChromatic(toTex, s, scaleUv, res, normalize(refractOff + float2(0.0001f)), frozen * 0.009f, blurPx);
        if (!demo && frozen > 0.001f) {
            float4 webFrozen = sampleChromatic(fromTex, s, scaleUv, res, normalize(refractOff + float2(0.0001f)), frozen * 0.012f, blurPx);
            surf = mix(surf, webFrozen, frozen);
        }
        float frostA = frozen * 0.54f;
        float4 frostCol = float4(float3(0.12f, 0.36f, 0.44f) * (0.75f + fine * 0.5f) * frostA, frostA);
        float4 outC = overPremul(frostCol, float4(surf.rgb * mix(1.0f, 0.78f, frozen), surf.a));
        float rimA = clamp01(meltEdge * 0.82f);
        return overPremul(float4(float3(0.50f, 0.99f, 0.99f) * rimA, rimA), outC);
    }

    // 13: 3D Glass Louvers (8 rotating 3D perspective glass slats)
    if (kind == 13) {
        float N = 8.0f;
        float idx = floor(uv.x * N);
        float localX = fract(uv.x * N) - 0.5f;
        float delay = idx * 0.042f;
        float pStrip = clamp01((t - delay) / 0.64f);

        float angle;
        float turnAmt;
        if (demo) {
            // Smooth 0 deg -> 76 deg -> 0 deg so frame 0 and final frame are exact 1:1 with zero start jank!
            float swing = sin(pStrip * 3.14159265f);
            turnAmt = pow(swing, 0.85f);
            angle = turnAmt * 1.34f;
        } else {
            float e = easeOutCubic(pStrip);
            turnAmt = 1.0f - e;
            angle = mix(1.42f, 0.0f, e);
        }

        float ca = max(cos(angle), 0.001f);
        float sa = sin(angle);
        float persp = 1.0f + localX * sa * 0.44f;
        float projX = (localX * persp) / ca;
        float projY = (uv.y - 0.5f) * (1.0f + abs(localX) * sa * 0.24f) + 0.5f;

        if (abs(projX) > 0.5f || projY < 0.0f || projY > 1.0f) {
            // Transparent gap between rotating 3D slats lets live Liquid Glass shine straight through
            return float4(0.0f);
        }
        float2 sampleUv = float2((idx + projX + 0.5f) / N, projY);
        float blurPx = turnAmt * 4.5f;
        float4 surf = sampleChromatic(toTex, s, sampleUv, res, float2(22.0f / res.x, 0.0f), turnAmt * 0.016f, blurPx);
        float shade = mix(0.46f, 1.0f, ca);
        // Subtle tinted glass pane backing on each slat so slats read clearly in 3D over live Liquid Glass
        float paneA = turnAmt * 0.24f;
        float4 pane = float4(float3(0.06f, 0.20f, 0.24f) * shade * paneA, paneA);
        float4 slat = overPremul(float4(surf.rgb * shade, surf.a), pane);
        float spec = pow(clamp01(1.0f - abs(angle - 0.46f) * 2.0f), 2.5f) * (1.0f - abs(projX) * 1.35f) * turnAmt;
        float edgeHi = smoothstep(0.41f, 0.50f, abs(projX)) * turnAmt * 0.78f;
        float gA = clamp01(spec * 0.42f + edgeHi);
        float4 glow = float4(float3(0.38f, 0.97f, 0.98f) * gA, gA);
        return overPremul(glow, slat);
    }

    // 14: Anamorphic Focus Pull (horizontal cinema stretch + 9-tap directional bokeh + RGB split)
    if (kind == 14) {
        float defocus;
        if (demo) {
            // Smoothly racks out of focus (0 -> 0.22) then cleanly pulls back to crisp 1:1 (0.22 -> 1.0)
            float rackOut = easeOutCubic(clamp01(t / 0.22f));
            float rackIn = 1.0f - easeInOutCubic(clamp01((t - 0.20f) / 0.80f));
            defocus = rackOut * rackIn;
        } else {
            defocus = 1.0f - easeOutCubic(clamp01(t / 0.86f));
        }

        float sx = mix(1.0f, 1.20f, defocus);
        float sy = mix(1.0f, 0.94f, defocus);
        float2 su = float2((uv.x - 0.5f) / sx + 0.5f, (uv.y - 0.5f) / sy + 0.5f);

        float4 acc = float4(0.0f);
        float spread = defocus * 30.0f / res.x;
        if (defocus < 0.002f) {
            acc = sampleTex(toTex, s, uv);
        } else {
            for (int i = -4; i <= 4; i++) {
                float fi = float(i) / 4.0f;
                float w = 1.0f - abs(fi) * 0.55f;
                float2 off = float2(fi * spread, 0.0f);
                float4 sr = sampleTex(toTex, s, su + off + float2(defocus * 0.016f, 0.0f));
                float4 sg = sampleTex(toTex, s, su + off);
                float4 sb = sampleTex(toTex, s, su + off - float2(defocus * 0.016f, 0.0f));
                acc += float4(sr.r, sg.g, sb.b, max(sg.a, max(sr.a, sb.a))) * w;
            }
            acc /= 6.5f;
            acc.rgb *= mix(1.0f, 0.76f, defocus);
        }

        float flareA = exp(-pow((uv.y - 0.48f) * 22.0f, 2.0f)) * defocus * 0.42f;
        return overPremul(float4(float3(0.36f, 0.96f, 0.99f) * flareA, flareA), acc);
    }

    // Open-site phase split (handles both smooth demo timing and live WKWebView releaseAt)
    // When releaseAt == 0 on kind 16 (already-ready instant ripple), skip coverDur completely!
    float coverDur = (kind == 15) ? 0.42f : ((kind == 16) ? ((u.releaseAt >= 0.0f && u.releaseAt < 0.05f) ? 0.0f : 0.14f) : 0.34f);
    float releaseDur = (kind == 15) ? 0.52f : ((kind == 16) ? 1.02f : 0.48f);
    bool releasing = (u.releaseAt >= 0.0f);
    float relStart = releasing ? max(coverDur, u.releaseAt) : 100.0f;
    bool inPhase2 = releasing && (u.time >= relStart);
    float inU = clamp01(u.time / max(coverDur, 0.0001f));
    float outU = inPhase2 ? clamp01((u.time - relStart) / releaseDur) : 0.0f;

    // 3: Tile Lens (expanding refractive liquid-glass lens from clicked tile -> alive breathing glass veil -> caustic reveal of finished page)
    if (kind == 3) {
        float uExp = easeInOutCubic(inU);
        float2 curC = mix(u.origin.xy, float2(0.5f), uExp);
        float2 curS = mix(u.origin.zw, float2(1.06f), uExp);
        float2 boxP = float2((uv.x - curC.x) * aspect, uv.y - curC.y);
        float2 boxB = float2(curS.x * 0.5f * aspect, curS.y * 0.5f);
        float sd = sdRoundBox(boxP, boxB, mix(0.03f, 0.0f, uExp));

        float lensMask = (1.0f - smoothstep(-0.008f, 0.008f, sd)) * smoothstep(0.0f, 0.06f, inU);
        float revealMask = 1.0f;
        float edgeGlow = 0.0f;
        float diag = uv.x * 0.65f + uv.y * 0.35f;
        if (inPhase2) {
            float wipe = mix(-0.18f, 1.28f, easeInOutCubic(outU));
            revealMask = smoothstep(wipe - 0.06f, wipe + 0.06f, diag);
            edgeGlow = exp(-pow((diag - wipe) * 18.0f, 2.0f)) * (1.0f - smoothstep(0.84f, 1.0f, outU));
        }

        float cover = lensMask * revealMask;
        float2 magUv = curC + (uv - curC) * mix(1.0f, 0.88f, cover * (1.0f - outU));
        float4 homeSurf = sampleBlur(fromTex, s, magUv, res, cover * 9.0f);
        float4 destSurf = inPhase2 ? sampleBlur(toTex, s, uv, res, revealMask * 4.0f) : homeSurf;
        float4 baseSurf = inPhase2 ? mix(destSurf, homeSurf, revealMask) : homeSurf;

        // Alive breathing glass shimmer while waiting for the site to paint behind the cover
        float breathe = 0.5f + 0.5f * sin(u.time * 4.2f);
        float sheenPos = mix(-0.35f, 1.35f, fract(u.time * 0.62f));
        float sheen = exp(-pow((diag - sheenPos) * 5.2f, 2.0f)) * 0.22f * smoothstep(0.35f, 1.0f, uExp);
        float3 veilRgb = mix(float3(0.03f, 0.15f, 0.18f), float3(0.06f, 0.28f, 0.32f), diag * 0.65f + 0.12f * breathe);
        veilRgb = mix(veilRgb, float3(0.75f, 0.99f, 0.99f), sheen);

        // Fully opaque on real opens once expanded so WKWebView renders cleanly behind the glass veil
        float veilA = demo ? (cover * 0.72f) : clamp01(cover * mix(0.72f, 1.0f, easeOutCubic(inU)));
        float4 outC = overPremul(float4(veilRgb * veilA, veilA), baseSurf);
        float rimA = clamp01((smoothstep(-0.016f, 0.0f, sd) * lensMask * (1.0f - uExp) + edgeGlow) * 0.90f);
        return overPremul(float4(float3(0.54f, 0.99f, 1.0f) * rimA, rimA), outC);
    }

    // 4: Diagonal Wipe (prismatic diagonal frosted-glass sweep -> alive breathing veil -> crisp reveal of finished page)
    if (kind == 4) {
        float diag = uv.x * 0.72f + uv.y * 0.28f;
        float coverFront = mix(-0.18f, 1.28f, easeInOutCubic(inU));
        float covered = 1.0f - smoothstep(coverFront - 0.06f, coverFront + 0.06f, diag);
        float coverEdge = exp(-pow((diag - coverFront) * 18.0f, 2.0f)) * smoothstep(0.0f, 0.06f, inU) * (1.0f - smoothstep(0.84f, 1.0f, inU));

        float cleared = 0.0f;
        float clearEdge = 0.0f;
        if (inPhase2) {
            float clearFront = mix(-0.18f, 1.28f, easeInOutCubic(outU));
            cleared = 1.0f - smoothstep(clearFront - 0.06f, clearFront + 0.06f, diag);
            clearEdge = exp(-pow((diag - clearFront) * 18.0f, 2.0f)) * (1.0f - smoothstep(0.84f, 1.0f, outU));
        }

        float veilMask = clamp01(covered - cleared);
        float4 bg = (inPhase2 && cleared > 0.01f) ? mix(sampleTex(fromTex, s, uv), sampleTex(toTex, s, uv), cleared) : sampleTex(fromTex, s, uv);
        float4 refr = sampleBlur(inPhase2 ? toTex : fromTex, s, uv + float2(0.018f / aspect, 0.008f) * veilMask, res, veilMask * 10.0f);
        float4 base = mix(bg, refr, veilMask);

        float breathe = 0.5f + 0.5f * sin(u.time * 4.2f);
        float sheenPos = mix(-0.35f, 1.35f, fract(u.time * 0.62f));
        float sheen = exp(-pow((diag - sheenPos) * 5.2f, 2.0f)) * 0.22f * smoothstep(0.35f, 1.0f, inU);
        float3 veilRgb = mix(float3(0.03f, 0.15f, 0.18f), float3(0.06f, 0.28f, 0.32f), diag * 0.65f + 0.12f * breathe);
        veilRgb = mix(veilRgb, float3(0.75f, 0.99f, 0.99f), sheen);

        float veilA = demo ? (veilMask * 0.70f) : clamp01(veilMask * 0.99f);
        float4 outC = overPremul(float4(veilRgb * veilA, veilA), base);
        float rimA = clamp01(max(coverEdge, clearEdge) * 0.90f);
        return overPremul(float4(float3(0.55f, 0.99f, 1.0f) * rimA, rimA), outC);
    }

    // 15: Optical Portal Warp — dramatic barrel suction + vortex swirl into portal, then reverse-fisheye un-warp!
    if (kind == 15) {
        float2 orig = u.origin.xy;
        if (!inPhase2) {
            float uIn = easeInOutCubic(inU);
            float breathe = (u.time > coverDur) ? (0.5f + 0.5f * sin((u.time - coverDur) * 5.0f)) : 0.0f;
            float2 d = uv - orig;
            float2 dp = float2(d.x * aspect, d.y);
            float r = length(dp);

            // Subtle rotational vortex swirl near the portal mouth (strictly 0 at uIn=0)
            float swirl = uIn * uIn * 0.48f * exp(-r * 2.2f);
            float cs = cos(swirl), sn = sin(swirl);
            float2 dRot = float2((dp.x * cs - dp.y * sn) / aspect, dp.x * sn + dp.y * cs);

            // Strong barrel distortion pulling the entire window surface into the portal
            float warp = 1.0f + uIn * 2.75f * r * r;
            float2 wuv = orig + dRot * mix(1.0f, 0.36f, uIn) * warp;
            float2 dir = r > 0.001f ? normalize(d) : float2(1.0f, 0.0f);

            float4 surf = sampleChromatic(fromTex, s, wuv, res, dir, uIn * 0.028f * (0.35f + r), uIn * 9.5f);
            // Deep portal void (100% opaque dark-teal cover on real Web opens once peaked so WKWebView
            // can render at opacity 1.0 behind it at 120Hz without leaking any blank loading frame;
            // translucent in Settings demos so live Liquid Glass stays alive behind the portal).
            float voidA = demo
                ? clamp01(uIn * (0.24f + 0.34f * smoothstep(0.15f, 0.95f, r)))
                : clamp01(smoothstep(0.08f, 0.78f, uIn));
            float4 voidCol = float4(float3(0.03f, 0.12f, 0.16f) * voidA, voidA);
            float4 base = overPremul(voidCol, float4(surf.rgb * (1.0f - uIn * 0.38f), surf.a));

            // Luminous cyan outer shockwave ring + breathing inner portal horizon while waiting on TTI
            float holdT = max(0.0f, u.time - coverDur);
            float pulseR = fract(holdT * 0.65f);
            float pulseRing = (holdT > 0.01f)
                ? exp(-pow((r - mix(0.12f, 0.85f, pulseR)) * 14.0f, 2.0f)) * sin(pulseR * 3.14159265f) * 0.45f
                : 0.0f;
            float outerRing = exp(-pow((r - mix(0.04f, 1.18f, uIn)) * 12.0f, 2.0f)) * sin(inU * 3.14159265f) * 0.90f;
            float coreRing = exp(-pow((r - mix(0.03f, 0.16f + breathe * 0.03f, uIn)) * 20.0f, 2.0f)) * smoothstep(0.06f, 0.55f, uIn) * 0.82f;
            float ringA = clamp01(outerRing + coreRing + pulseRing);
            return overPremul(float4(float3(0.34f, 0.97f, 0.99f) * ringA, ringA), base);
        } else {
            float uOut = easeOutCubic(outU);
            float inv = 1.0f - uOut;
            float2 d = uv - 0.5f;
            float2 dp = float2(d.x * aspect, d.y);
            float r = length(dp);

            // Reverse fisheye un-warp + counter-swirl settling smoothly into crisp 1:1 focus
            float swirl = -inv * inv * 0.34f * exp(-r * 2.0f);
            float cs = cos(swirl), sn = sin(swirl);
            float2 dRot = float2((dp.x * cs - dp.y * sn) / aspect, dp.x * sn + dp.y * cs);

            float k = 1.0f - inv * 0.60f * r * r;
            float2 wuv = 0.5f + dRot * mix(1.30f, 1.0f, uOut) * k;
            float2 dir = r > 0.001f ? normalize(d) : float2(1.0f, 0.0f);

            float4 surf = sampleChromatic(toTex, s, wuv, res, dir, inv * 0.024f * (0.25f + r), inv * 9.0f);
            float veilA = inv * inv * 0.36f;
            float4 base = overPremul(float4(float3(0.04f, 0.16f, 0.20f) * veilA, veilA), float4(surf.rgb * mix(0.68f, 1.0f, uOut), surf.a));

            float ringA = clamp01(exp(-pow((r - mix(0.05f, 1.32f, uOut)) * 11.0f, 2.0f)) * inv * 0.88f);
            return overPremul(float4(float3(0.38f, 0.98f, 1.0f) * ringA, ringA), base);
        }
    }

    // 16: Liquid Ripple Open — pulses softly at the clicked tile while the site finishes painting
    // behind the opaque Home surface, then bursts a multi-crest liquid shockwave outward from the
    // clicked tile to reveal the finished destination page!
    if (kind == 16) {
        float2 orig = u.origin.xy;
        float2 d = uv - orig;
        float2 dp = float2(d.x * aspect, d.y);
        float dist = length(dp);
        float2 dir = dist > 0.0001f ? dp / dist : float2(1.0f, 0.0f);
        float2 radialUv = float2(dir.x / aspect, dir.y);

        if (!inPhase2) {
            // Tactile pulsing liquid ripple right around the clicked tile while waiting for painted content
            float intro = smoothstep(0.0f, 0.08f, u.time);
            float pulse = fract(u.time * 1.10f);
            float ringR = mix(0.03f, 0.42f, easeOutCubic(pulse));
            float ringDelta = dist - ringR;
            float ringEnv = exp(-pow(ringDelta * 16.0f, 2.0f)) * sin(pulse * 3.14159265f) * intro;
            float localWave = cos(ringDelta * 26.0f) * ringEnv;
            float2 wuv = uv + radialUv * localWave * 0.040f;
            float4 surf = sampleChromatic(fromTex, s, wuv, res, radialUv, abs(localWave) * 0.014f, abs(localWave) * 2.5f);
            // Gentle focus glow around clicked tile origin
            float coreGlow = exp(-pow(dist * 7.5f, 2.0f)) * (0.18f + 0.14f * sin(u.time * 5.0f)) * intro;
            float ringA = clamp01(ringEnv * 0.65f + coreGlow);
            return overPremul(float4(float3(0.36f, 0.97f, 0.99f) * ringA, ringA), surf);
        } else {
            // Full multi-crest liquid shockwave erupting from the clicked tile across the entire window!
            float maxDist = length(float2(aspect, 1.0f)) * 1.18f;
            float front = mix(-0.04f, maxDist, easeOutCubic(outU));
            float delta = dist - front;
            float intro = smoothstep(0.0f, 0.06f, outU);
            float outro = 1.0f - smoothstep(0.78f, 1.0f, outU);
            float fade = intro * outro;

            float leadEnv = exp(-pow(max(delta, 0.0f) * 14.0f, 2.0f));
            float wakeEnv = exp(-pow(max(-delta, 0.0f) * 2.9f, 2.0f));
            float env = leadEnv * wakeEnv * fade;

            float phase = delta * 24.0f;
            float waveHeight = sin(phase) * env;
            float waveSlope = cos(phase) * env;

            float revealed = (outU <= 0.0001f) ? 0.0f : (1.0f - smoothstep(-0.055f, 0.035f, delta));
            float sc = mix(0.93f, 1.0f, revealed) + waveHeight * 0.085f;
            float2 wuv = (uv - orig) / sc + orig;
            wuv += radialUv * (waveSlope * 0.130f + waveHeight * 0.045f);

            float blurPx = (1.0f - revealed) * 4.5f + abs(waveSlope) * 4.5f;
            float4 destSurf = sampleChromatic(toTex, s, wuv, res, radialUv, abs(waveSlope) * 0.028f, blurPx);
            float shade = 1.0f + waveSlope * 0.18f;
            destSurf.rgb = min(destSurf.rgb * max(0.0f, shade), float3(destSurf.a));

            float4 outSurf = destSurf * revealed;
            float homeRemain = 1.0f - revealed;
            if (homeRemain > 0.001f) {
                float2 homeUv = uv + radialUv * (waveSlope * 0.095f);
                float4 homeSurf = sampleChromatic(fromTex, s, homeUv, res, radialUv, abs(waveSlope) * 0.024f, abs(waveSlope) * 3.5f);
                float hShade = 1.0f + waveSlope * 0.14f;
                homeSurf.rgb = min(homeSurf.rgb * max(0.0f, hShade), float3(homeSurf.a));
                homeSurf *= homeRemain;
                outSurf = overPremul(outSurf, homeSurf);
            }

            float spec = pow(clamp01(waveSlope), 2.5f) * 0.36f * revealed + pow(clamp01(-waveSlope), 3.0f) * 0.12f * revealed;
            float rimGlow = exp(-pow(delta * 16.0f, 2.0f)) * 0.44f * fade;
            float crestA = clamp01(spec + rimGlow);
            float4 crest = float4(float3(0.45f, 0.98f, 1.0f) * crestA, crestA);
            return overPremul(crest, outSurf);
        }
    }

    return sampleTex(toTex, s, uv);
}

fragment float4 surfaceFS(
    VSOut in [[stage_in]],
    constant Uniforms& u [[buffer(0)]],
    texture2d<float> fromTex [[texture(0)]],
    texture2d<float> toTex [[texture(1)]]
) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;
    float2 res = max(u.resolution, float2(1.0f));
    float4 outCol = evaluateSurfaceEffect(uv, res, u, fromTex, toTex, s);

    if (u.hasWindowMask != 0) {
        float2 edgePx = min(uv, 1.0f - uv) * res;
        if (edgePx.x < 68.0f && edgePx.y < 68.0f) {
            float cornerA = clamp01(fromTex.sample(s, uv).a * 1.18f);
            outCol *= cornerA;
        }
    }
    return outCol;
}
"""

private final class FloatMetalResources: @unchecked Sendable {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState

    init(device: MTLDevice, queue: MTLCommandQueue, pipeline: MTLRenderPipelineState) {
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }
}

/// Native macOS Metal surface-displacement transition overlay that captures the real live
/// WindowServer backing surface (Liquid Glass + cards + icons + video) into MTLTextures
/// and warps/refracts them at display refresh rate with zero startup jank.
private final class FloatSurfaceTransitionHost: NSObject {
    private final class MetalOverlayView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func makeBackingLayer() -> CALayer {
            let l = CAMetalLayer()
            l.isOpaque = false
            l.pixelFormat = .bgra8Unorm
            l.framebufferOnly = true
            l.backgroundColor = NSColor.clear.cgColor
            return l
        }
    }

    private static var prewarmStarted = false
    private static var cachedResources: FloatMetalResources?
    private static var pendingWaiters: [(FloatMetalResources?) -> Void] = []

    /// Pre-compiles the Metal shader library & pipeline state on a background queue at app startup
    /// and runs a 2x2 warmup render pass so GPU shader binaries are hot before the first click.
    static func prewarm() {
        guard !prewarmStarted else { return }
        prewarmStarted = true
        DispatchQueue.global(qos: .userInitiated).async {
            let built = buildResources()
            DispatchQueue.main.async {
                cachedResources = built
                let waiters = pendingWaiters
                pendingWaiters.removeAll()
                for cb in waiters { cb(built) }
            }
        }
    }

    private static func buildResources() -> FloatMetalResources? {
        guard let dev = MTLCreateSystemDefaultDevice(),
              let q = dev.makeCommandQueue() else { return nil }
        do {
            let lib = try dev.makeLibrary(source: floatSurfaceTransitionMSL, options: nil)
            guard let vs = lib.makeFunction(name: "surfaceVS"),
                  let fs = lib.makeFunction(name: "surfaceFS") else { return nil }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled = false
            let pipe = try dev.makeRenderPipelineState(descriptor: desc)

            // Warm GPU pipeline caches with a tiny 2x2 offscreen render pass off the main thread.
            let tDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 2, height: 2, mipmapped: false)
            tDesc.usage = [.renderTarget, .shaderRead]
            if let dummy = dev.makeTexture(descriptor: tDesc),
               let cmd = q.makeCommandBuffer() {
                let rpd = MTLRenderPassDescriptor()
                rpd.colorAttachments[0].texture = dummy
                rpd.colorAttachments[0].loadAction = .clear
                rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
                rpd.colorAttachments[0].storeAction = .store
                if let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) {
                    enc.setRenderPipelineState(pipe)
                    var u = FloatSurfaceUniforms(
                        resolution: SIMD2<Float>(2, 2),
                        time: 0, duration: 1, effectKind: 15,
                        releaseAt: -1, isDemo: 1, hasWindowMask: 0,
                        origin: SIMD4<Float>(0.5, 0.5, 0.2, 0.2)
                    )
                    enc.setFragmentBytes(&u, length: MemoryLayout<FloatSurfaceUniforms>.stride, index: 0)
                    enc.setFragmentTexture(dummy, index: 0)
                    enc.setFragmentTexture(dummy, index: 1)
                    enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                    enc.endEncoding()
                }
                cmd.commit()
                cmd.waitUntilCompleted()
            }
            return FloatMetalResources(device: dev, queue: q, pipeline: pipe)
        } catch {
            return nil
        }
    }

    static func obtain(_ ready: @escaping (FloatSurfaceTransitionHost?) -> Void) {
        if let res = cachedResources {
            ready(FloatSurfaceTransitionHost(resources: res))
            return
        }
        prewarm()
        pendingWaiters.append { res in
            ready(res.map { FloatSurfaceTransitionHost(resources: $0) })
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState

    private weak var hostWindow: NSWindow?
    private var overlayView: MetalOverlayView?
    private var hiddenContentViews: [NSView] = []
    private var fromTex: MTLTexture?
    private var toTex: MTLTexture?
    private var reusableFromTex: MTLTexture?
    private var reusableToTex: MTLTexture?
    private var scratchPixels: [UInt8] = []
    private var hasWindowMask: Bool = true
    private var keepBackdropLive: Bool = false
    private var displayLink: CADisplayLink?
    private var fallbackTimer: Timer?

    private var effectKind: Int32 = 0
    private var isDemo: Bool = true
    private var origin: SIMD4<Float> = SIMD4<Float>(0.5, 0.48, 0.24, 0.24)
    private var startTime: CFTimeInterval = 0
    private var duration: Double = 0.95
    private var releaseAt: Double = -1
    private var onComplete: (() -> Void)?

    private init(resources: FloatMetalResources) {
        self.device = resources.device
        self.queue = resources.queue
        self.pipeline = resources.pipeline
        super.init()
    }

    var isActive: Bool { overlayView != nil }

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for v in hiddenContentViews {
            v.layer?.opacity = 1.0
        }
        hiddenContentViews.removeAll()
        overlayView?.removeFromSuperview()
        overlayView = nil
        CATransaction.commit()
        fromTex = nil
        toTex = nil
        let cb = onComplete
        onComplete = nil
        cb?()
    }

    private static func isEmptyCGImage(_ image: CGImage) -> Bool {
        let side = 4
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let ctx = CGContext(
                data: bytes.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return !drawn || stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 0 }
    }

    /// Captures this process's own NSWindow directly from macOS WindowServer (Liquid Glass +
    /// layer-backed Exact cards + icons + text + WKWebView video), matching ExactKit's
    /// `WindowServerPicture.ownWindow` with zero Screen Recording permission prompt.
    private static func ownWindowCGImage(_ windowNumber: Int) -> CGImage? {
        typealias Create = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: Create.self)
        // kCGWindowListOptionIncludingWindow (1<<3); kCGWindowImageBoundsIgnoreFraming (1<<0) | kCGWindowImageBestResolution (1<<3)
        guard let image = create(.null, 1 << 3, UInt32(windowNumber), (1 << 0) | (1 << 3))?.takeRetainedValue(),
              !isEmptyCGImage(image) else { return nil }
        return image
    }

    private func textureForSlot(isFrom: Bool, width: Int, height: Int) -> MTLTexture? {
        let existing = isFrom ? reusableFromTex : reusableToTex
        if let tex = existing, tex.width == width, tex.height == height {
            return tex
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        if isFrom { reusableFromTex = tex } else { reusableToTex = tex }
        return tex
    }

    private func uploadTexture(from cgImage: CGImage, isFrom: Bool) -> MTLTexture? {
        let w = max(1, cgImage.width)
        let h = max(1, cgImage.height)
        guard let tex = textureForSlot(isFrom: isFrom, width: w, height: h) else { return nil }

        // Fast zero-draw path: macOS WindowServer images are already 32-bit BGRA premultiplied.
        let alpha = cgImage.alphaInfo
        let order = cgImage.bitmapInfo.intersection(.byteOrderMask)
        if cgImage.bitsPerPixel == 32,
           cgImage.bitsPerComponent == 8,
           order == .byteOrder32Little,
           (alpha == .premultipliedFirst || alpha == .noneSkipFirst),
           let cfData = cgImage.dataProvider?.data,
           let ptr = CFDataGetBytePtr(cfData) {
            let bpr = cgImage.bytesPerRow
            if CFDataGetLength(cfData) >= bpr * h {
                tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: ptr, bytesPerRow: bpr)
                return tex
            }
        }

        // Reusable buffer fallback for non-BGRA images.
        let bytesPerRow = w * 4
        let needed = bytesPerRow * h
        if scratchPixels.count < needed {
            scratchPixels = [UInt8](repeating: 0, count: needed)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        let ok = scratchPixels.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: w,
                      height: h,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: colorSpace,
                      bitmapInfo: bitmapInfo
                  ) else { return false }
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
            return true
        }
        return ok ? tex : nil
    }

    /// Renders ONLY the transparent UI subviews (cards, icons, text, borders — excluding `backdrop`)
    /// via Core Animation's layer tree so macOS 26 Liquid Glass (`NSGlassEffectView`) can remain
    /// 100% live and untouched underneath the Metal distortion overlay with zero pop or freeze.
    private func captureUILayerTree(in window: NSWindow, excluding backdrop: NSView?, isFrom: Bool) -> MTLTexture? {
        guard let content = window.contentView else { return nil }
        let uiViews = content.subviews.filter { $0 !== backdrop && $0 !== overlayView && !$0.isHidden }
        guard !uiViews.isEmpty else { return nil }
        let scale = window.backingScaleFactor
        let w = max(1, Int((content.bounds.width * scale).rounded()))
        let h = max(1, Int((content.bounds.height * scale).rounded()))
        let bytesPerRow = w * 4
        let needed = bytesPerRow * h
        if scratchPixels.count < needed {
            scratchPixels = [UInt8](repeating: 0, count: needed)
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let tex = textureForSlot(isFrom: isFrom, width: w, height: h) else { return nil }

        for v in uiViews {
            v.layoutSubtreeIfNeeded()
            if v.layer == nil { v.wantsLayer = true }
            v.displayIfNeeded()
        }

        let drawnNonEmpty = scratchPixels.withUnsafeMutableBytes { buf -> Bool in
            guard let base = buf.baseAddress,
                  let ctx = CGContext(
                      data: base,
                      width: w,
                      height: h,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: bitmapInfo
                  ) else { return false }
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            for sub in uiViews {
                guard let subLayer = sub.layer else { continue }
                let wasOpacity = subLayer.opacity
                if wasOpacity == 0 {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    subLayer.opacity = 1.0
                    CATransaction.commit()
                }
                ctx.saveGState()
                let f = sub.frame
                let bottomY = content.isFlipped ? (content.bounds.height - f.maxY) : f.minY
                if sub.isFlipped || subLayer.isGeometryFlipped {
                    ctx.translateBy(x: f.minX * scale, y: (bottomY + f.height) * scale)
                    ctx.scaleBy(x: scale, y: -scale)
                } else {
                    ctx.translateBy(x: f.minX * scale, y: bottomY * scale)
                    ctx.scaleBy(x: scale, y: scale)
                }
                subLayer.render(in: ctx)
                ctx.restoreGState()
                if wasOpacity == 0 {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    subLayer.opacity = wasOpacity
                    CATransaction.commit()
                }
            }
            // Quick stride check to verify real UI pixels were captured
            let bytes = buf.bindMemory(to: UInt8.self)
            var hasInk = false
            var i = 3
            while i < needed {
                if bytes[i] > 4 { hasInk = true; break }
                i += 256
            }
            guard hasInk else { return false }
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
            return true
        }
        return drawnNonEmpty ? tex : nil
    }

    /// Captures the live window surface. When a live Liquid Glass `backdrop` is present on Home,
    /// captures ONLY the transparent UI layer so the Metal shader distorts the UI directly on top
    /// of the live `NSGlassEffectView` without ever hiding or popping the glass!
    func captureWindowSurface(in window: NSWindow, backdrop: NSView?, isFrom: Bool = true) -> (texture: MTLTexture, fromWindowServer: Bool, keepBackdropLive: Bool)? {
        if isFrom, overlayView != nil, hostWindow === window, let clean = fromTex {
            return (clean, hasWindowMask, keepBackdropLive)
        }
        if let backdrop, backdrop.superview === window.contentView, !backdrop.isHidden,
           let uiTex = captureUILayerTree(in: window, excluding: backdrop, isFrom: isFrom) {
            return (uiTex, false, true)
        }
        if let cg = Self.ownWindowCGImage(window.windowNumber),
           let tex = uploadTexture(from: cg, isFrom: isFrom) {
            return (tex, true, false)
        }
        if let fb = captureUILayerTree(in: window, excluding: nil, isFrom: isFrom) {
            return (fb, false, false)
        }
        return nil
    }

    func captureWebSurface(_ web: WKWebView, afterScreenUpdates: Bool = true, completion: @escaping (MTLTexture?) -> Void) {
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = afterScreenUpdates
        web.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self, let image else { completion(nil); return }
            var rect = CGRect(origin: .zero, size: image.size)
            guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
                completion(nil)
                return
            }
            completion(self.uploadTexture(from: cg, isFrom: false))
        }
    }

    /// Immediately holds the outgoing surface 1:1 on the Metal overlay BEFORE switching views,
    /// so the underlying view swap or snapshot capture never flashes or pulses.
    func holdOutgoingSurface(in window: NSWindow, texture: MTLTexture, keepBackdropLive: Bool = true, fromWindowServer: Bool = false) {
        guard let content = window.contentView else { return }
        cancel()
        self.hostWindow = window
        self.effectKind = 0
        self.isDemo = false
        self.fromTex = texture
        self.toTex = texture
        self.hasWindowMask = fromWindowServer
        self.keepBackdropLive = keepBackdropLive
        self.startTime = 0
        self.duration = 2.0
        self.releaseAt = -1

        let overlay = MetalOverlayView(frame: content.bounds)
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
        guard let metalLayer = overlay.layer as? CAMetalLayer else { return }
        metalLayer.device = device
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, content.bounds.width * scale),
            height: max(1, content.bounds.height * scale)
        )
        if keepBackdropLive {
            if #available(macOS 26.0, *) {
                metalLayer.cornerRadius = 24.0
            } else {
                metalLayer.cornerRadius = 16.0
            }
            metalLayer.masksToBounds = true
        }

        let targets = content.subviews.filter { $0 !== overlay }
        for v in targets where v.layer == nil { v.wantsLayer = true }
        hiddenContentViews = targets

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.presentsWithTransaction = true
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlayView = overlay
        renderFrame(elapsed: 0.0, syncWithTransaction: true, metalLayer: metalLayer)
        for v in hiddenContentViews {
            v.layer?.opacity = 0.0
        }
        CATransaction.commit()
        metalLayer.presentsWithTransaction = false
    }

    /// Transitions an active held Web overlay seamlessly into a Home reveal effect (`kind` 11..14)
    /// once Exact has painted the incoming Home UI behind the overlay.
    func beginHeldReveal(in window: NSWindow, backdrop: NSView?, kind: Int, toTexture: MTLTexture) {
        guard let content = window.contentView,
              let overlay = overlayView,
              let metalLayer = overlay.layer as? CAMetalLayer,
              hostWindow === window else {
            cancel()
            return
        }
        // Keep the newly installed live Liquid Glass backdrop visible (`opacity = 1`) beneath the overlay
        // while keeping all UI subviews hidden until the reveal finishes.
        let uiTargets = content.subviews.filter { $0 !== overlay && $0 !== backdrop }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let backdrop {
            if backdrop.layer == nil { backdrop.wantsLayer = true }
            backdrop.layer?.opacity = 1.0
        }
        for v in uiTargets {
            if v.layer == nil { v.wantsLayer = true }
            v.layer?.opacity = 0.0
        }
        CATransaction.commit()
        hiddenContentViews = uiTargets

        self.effectKind = Int32(kind)
        self.isDemo = false
        self.toTex = toTexture
        self.hasWindowMask = false
        self.keepBackdropLive = true
        self.startTime = 0
        self.releaseAt = -1
        self.duration = (kind == 11) ? 1.08 : ((kind == 12) ? 0.98 : 0.92)

        renderFrame(elapsed: 0.0, syncWithTransaction: false, metalLayer: metalLayer)

        displayLink?.invalidate()
        displayLink = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        if #available(macOS 14.0, *) {
            let link = overlay.displayLink(target: self, selector: #selector(stepDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        } else {
            self.fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.stepFallback()
            }
        }
    }

    func start(
        in window: NSWindow,
        backdrop: NSView?,
        kind: Int,
        fromTexture: MTLTexture,
        toTexture: MTLTexture?,
        fromWindowServer: Bool,
        keepBackdropLive: Bool,
        origin: SIMD4<Float>,
        isDemo: Bool,
        autoReleaseAt: Double? = nil,
        onComplete: (() -> Void)? = nil
    ) {
        guard let content = window.contentView else { onComplete?(); return }

        let reusingOverlay = (overlayView != nil && hostWindow === window && self.keepBackdropLive == keepBackdropLive)
        if !reusingOverlay {
            cancel()
        } else {
            // Stop previous completion callback cleanly without unmounting overlay
            self.onComplete = nil
        }

        self.hostWindow = window
        self.effectKind = Int32(kind)
        self.isDemo = isDemo
        self.origin = origin
        self.fromTex = fromTexture
        self.toTex = toTexture ?? fromTexture
        self.hasWindowMask = fromWindowServer
        self.keepBackdropLive = keepBackdropLive
        self.onComplete = onComplete
        self.startTime = 0

        if kind == 1 || kind == 2 {
            self.duration = (kind == 1) ? 0.86 : 0.78
            self.releaseAt = -1
        } else if kind >= 11 && kind <= 14 {
            self.duration = (kind == 11) ? 1.08 : ((kind == 12) ? 0.98 : 0.92)
            self.releaseAt = -1
        } else if kind == 15 {
            self.releaseAt = autoReleaseAt ?? -1
            let rel = max(0.42, autoReleaseAt ?? 0.44)
            self.duration = rel + 0.54
        } else if kind == 16 {
            self.releaseAt = autoReleaseAt ?? -1
            let rel = (autoReleaseAt != nil && autoReleaseAt! < 0.05) ? 0.0 : (autoReleaseAt ?? 0.16)
            self.duration = rel + 1.04
        } else {
            self.releaseAt = autoReleaseAt ?? -1
            let rel = max(0.34, autoReleaseAt ?? 0.38)
            self.duration = rel + 0.50
        }

        if reusingOverlay, let overlay = overlayView, let metalLayer = overlay.layer as? CAMetalLayer {
            // Seamless in-place switch to new effect on the existing Metal overlay (0ms blink!)
            renderFrame(elapsed: 0.0, syncWithTransaction: false, metalLayer: metalLayer)
            if displayLink == nil && fallbackTimer == nil {
                if #available(macOS 14.0, *) {
                    let link = overlay.displayLink(target: self, selector: #selector(stepDisplayLink(_:)))
                    link.add(to: .main, forMode: .common)
                    self.displayLink = link
                } else {
                    self.fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                        self?.stepFallback()
                    }
                }
            }
            return
        }

        let overlay = MetalOverlayView(frame: content.bounds)
        overlay.wantsLayer = true
        overlay.autoresizingMask = [.width, .height]
        guard let metalLayer = overlay.layer as? CAMetalLayer else { onComplete?(); return }
        metalLayer.device = device
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, content.bounds.width * scale),
            height: max(1, content.bounds.height * scale)
        )
        if keepBackdropLive {
            // Clip distorted UI pixels cleanly inside the Liquid Glass rounded window corners.
            if #available(macOS 26.0, *) {
                metalLayer.cornerRadius = 24.0
            } else {
                metalLayer.cornerRadius = 16.0
            }
            metalLayer.masksToBounds = true
        }

        // When keepBackdropLive is true, leave NSGlassEffectView 100% visible & live underneath
        // and hide ONLY the UI layer so the Metal shader distorts the UI directly over live Liquid Glass!
        let targets = content.subviews.filter { $0 !== overlay && (!keepBackdropLive || $0 !== backdrop) }
        for v in targets where v.layer == nil {
            v.wantsLayer = true
        }
        hiddenContentViews = targets

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.presentsWithTransaction = true
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlayView = overlay
        // Present pixel-identical frame 0 (t = 0.0) synchronously inside the same transaction
        // that hides the live subviews -> zero blink, zero brightness jump, zero startup jank!
        renderFrame(elapsed: 0.0, syncWithTransaction: true, metalLayer: metalLayer)
        for v in hiddenContentViews {
            v.layer?.opacity = 0.0
        }
        CATransaction.commit()
        metalLayer.presentsWithTransaction = false

        if #available(macOS 14.0, *) {
            let link = overlay.displayLink(target: self, selector: #selector(stepDisplayLink(_:)))
            link.add(to: .main, forMode: .common)
            self.displayLink = link
        } else {
            self.fallbackTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.stepFallback()
            }
        }
    }

    /// Restores full opacity on the underlying view hierarchy once the Metal cover is opaque
    /// so `WKWebView` renders at full 120Hz behind the cover (WebKit throttles rAF & image decode
    /// when any ancestor layer has opacity 0).
    func revealUnderlyingViewsBehindCover() {
        guard overlayView != nil, !hiddenContentViews.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for v in hiddenContentViews {
            v.layer?.opacity = 1.0
        }
        CATransaction.commit()
    }

    func releaseOpen(with toTexture: MTLTexture?, immediate: Bool = false) {
        guard overlayView != nil, (effectKind == 3 || effectKind == 4 || effectKind >= 15), releaseAt < 0 else { return }
        if let tex = toTexture {
            self.toTex = tex
        }
        let now = CACurrentMediaTime()
        let elapsed = startTime > 0 ? max(0, now - startTime) : 0
        let minCover: Double
        if immediate && effectKind == 16 {
            minCover = 0.0
        } else {
            minCover = (effectKind == 15) ? 0.42 : ((effectKind == 16) ? 0.14 : 0.34)
        }
        let relDur = (effectKind == 15) ? 0.54 : ((effectKind == 16) ? 1.02 : 0.50)
        let rel = max(minCover, elapsed)
        self.releaseAt = rel
        self.duration = rel + relDur
    }

    @available(macOS 14.0, *)
    @objc private func stepDisplayLink(_ link: CADisplayLink) {
        let now = link.timestamp
        if startTime == 0 {
            let dt = max(0.004, min(0.016, link.targetTimestamp - link.timestamp))
            startTime = now - dt
        }
        advanceFrame(now: now)
    }

    private func stepFallback() {
        let now = CACurrentMediaTime()
        if startTime == 0 {
            startTime = now - (1.0 / 60.0)
        }
        advanceFrame(now: now)
    }

    private func advanceFrame(now: CFTimeInterval) {
        let elapsed = max(0, now - startTime)
        let isOpenKind = (effectKind == 3 || effectKind == 4 || effectKind >= 15)
        if isOpenKind && releaseAt < 0 && elapsed > 7.8 {
            releaseOpen(with: nil)
        }
        if (!isOpenKind || releaseAt >= 0) && elapsed >= duration {
            cancel()
            return
        }
        guard let metalLayer = overlayView?.layer as? CAMetalLayer else { return }
        renderFrame(elapsed: elapsed, syncWithTransaction: false, metalLayer: metalLayer)
    }

    private func renderFrame(elapsed: Double, syncWithTransaction: Bool, metalLayer: CAMetalLayer) {
        guard let overlay = overlayView,
              let fromTex, let toTex else { return }
        let scale = hostWindow?.backingScaleFactor ?? 2.0
        let targetSize = CGSize(
            width: max(1, overlay.bounds.width * scale),
            height: max(1, overlay.bounds.height * scale)
        )
        if metalLayer.drawableSize != targetSize {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = targetSize
        }
        guard let drawable = metalLayer.nextDrawable(),
              let cmdBuf = queue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        var uniforms = FloatSurfaceUniforms(
            resolution: SIMD2<Float>(Float(targetSize.width), Float(targetSize.height)),
            time: Float(elapsed),
            duration: Float(duration),
            effectKind: effectKind,
            releaseAt: Float(releaseAt),
            isDemo: isDemo ? 1 : 0,
            hasWindowMask: hasWindowMask ? 1 : 0,
            origin: origin
        )
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<FloatSurfaceUniforms>.stride, index: 0)
        enc.setFragmentTexture(fromTex, index: 0)
        enc.setFragmentTexture(toTex, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        if syncWithTransaction {
            cmdBuf.commit()
            cmdBuf.waitUntilScheduled()
            drawable.present()
        } else {
            cmdBuf.present(drawable)
            cmdBuf.commit()
        }
    }
}

final class FloatModule: ExactModule {
    override class var views: [String: ExactNativeFactory] {
        [
            "float-browser": ExactNativeFactory(for: FloatModule.self, firstFrame: true) { mod, _, events in
                FloatBrowserInstance(mod, events)
            },
        ]
    }

    private let store: FloatStore
    private weak var hostWindow: NSWindow?
    fileprivate weak var mainWindow: NSWindow?
    fileprivate weak var browser: FloatBrowserInstance?
    private var homeBackdropView: NSView?
    private var lastBackdropIsHome: Bool?
    private var surfaceFx: FloatSurfaceTransitionHost?
    private var pendingSurfaceOpenToken = 0
    private var morphPrepared = false
    private var morphWindowShown = false
    private var glassReady = false
    private var coldWarmupScheduled = false
    private var pendingUrlLoad: String?
    private var cliHandled = false
    private var lastSelectSeq: String?

    // Agent sessions keep per-session transient state; live sessions share FloatHub.shared across windows.
    private var agentMode = "home"
    private var agentCurrentUrl = ""
    private var agentActiveVideoStream = ""
    private var agentOnTop = true
    private var agentExpanded = false
    private var agentAspectLocked = false
    private var agentClickThrough = false
    private var agentPendingSeek: Double?
    private var agentFxDemoSeq = 0
    private var agentFxDemoKind = 0

    var mode: String {
        get { context.agent ? agentMode : FloatHub.shared.mode }
        set { if context.agent { agentMode = newValue } else { FloatHub.shared.mode = newValue } }
    }
    var currentUrl: String {
        get { context.agent ? agentCurrentUrl : FloatHub.shared.currentUrl }
        set { if context.agent { agentCurrentUrl = newValue } else { FloatHub.shared.currentUrl = newValue } }
    }
    var activeVideoStream: String {
        get { context.agent ? agentActiveVideoStream : FloatHub.shared.activeVideoStream }
        set { if context.agent { agentActiveVideoStream = newValue } else { FloatHub.shared.activeVideoStream = newValue } }
    }
    var onTop: Bool {
        get { context.agent ? agentOnTop : FloatHub.shared.onTop }
        set { if context.agent { agentOnTop = newValue } else { FloatHub.shared.onTop = newValue } }
    }
    var expanded: Bool {
        get { context.agent ? agentExpanded : FloatHub.shared.expanded }
        set { if context.agent { agentExpanded = newValue } else { FloatHub.shared.expanded = newValue } }
    }
    var aspectLocked: Bool {
        get { context.agent ? agentAspectLocked : FloatHub.shared.aspectLocked }
        set { if context.agent { agentAspectLocked = newValue } else { FloatHub.shared.aspectLocked = newValue } }
    }
    var clickThrough: Bool {
        get { context.agent ? agentClickThrough : FloatHub.shared.clickThrough }
        set { if context.agent { agentClickThrough = newValue } else { FloatHub.shared.clickThrough = newValue } }
    }
    var pendingSeek: Double? {
        get { context.agent ? agentPendingSeek : FloatHub.shared.pendingSeek }
        set { if context.agent { agentPendingSeek = newValue } else { FloatHub.shared.pendingSeek = newValue } }
    }
    var fxDemoSeq: Int {
        get { context.agent ? agentFxDemoSeq : FloatHub.shared.fxDemoSeq }
        set { if context.agent { agentFxDemoSeq = newValue } else { FloatHub.shared.fxDemoSeq = newValue } }
    }
    var fxDemoKind: Int {
        get { context.agent ? agentFxDemoKind : FloatHub.shared.fxDemoKind }
        set { if context.agent { agentFxDemoKind = newValue } else { FloatHub.shared.fxDemoKind = newValue } }
    }

    var fill: Bool {
        get { store.fill }
        set { store.fill = newValue }
    }
    var alpha: Double {
        get { store.alpha }
        set { store.alpha = newValue }
    }
    var videoBrightness: Double {
        get { min(2.0, max(0.5, store.videoBrightness)) }
        set { store.videoBrightness = min(2.0, max(0.5, newValue)) }
    }
    var hdrVideoBrightness: Double {
        get { min(2.0, max(0.5, store.hdrVideoBrightness)) }
        set { store.hdrVideoBrightness = min(2.0, max(0.5, newValue)) }
    }
    var videoContrast: Double {
        get { min(2.0, max(0.5, store.videoContrast)) }
        set { store.videoContrast = min(2.0, max(0.5, newValue)) }
    }
    private static let validRevealStyles: Set<String> = ["wave", "curtain", "ripple", "frost", "louvers", "anamorphic"]
    private static let validOpenStyles: Set<String> = ["lens", "diagonal", "portal", "ripple"]

    private static func revealKindCode(_ style: String) -> Int {
        switch style {
        case "curtain": return 2
        case "ripple": return 11
        case "frost": return 12
        case "louvers": return 13
        case "anamorphic": return 14
        default: return 1
        }
    }

    private static func openKindCode(_ style: String) -> Int {
        switch style {
        case "diagonal": return 4
        case "portal": return 15
        case "ripple": return 16
        default: return 3
        }
    }

    var revealStyle: String {
        get { Self.validRevealStyles.contains(store.revealStyle) ? store.revealStyle : "ripple" }
        set { store.revealStyle = Self.validRevealStyles.contains(newValue) ? newValue : "ripple" }
    }
    var openStyle: String {
        get { Self.validOpenStyles.contains(store.openStyle) ? store.openStyle : "ripple" }
        set { store.openStyle = Self.validOpenStyles.contains(newValue) ? newValue : "ripple" }
    }
    var preferSdr: Bool {
        get { store.preferSdr }
        set { store.preferSdr = newValue }
    }
    var streamBrightness: Bool {
        get { store.streamBrightness }
        set { store.streamBrightness = newValue }
    }
    var hotkeyKeys: String {
        get { store.hotkeyKeys }
        set { store.hotkeyKeys = newValue }
    }
    var peekTrigger: String {
        get { store.peekTrigger }
        set { store.peekTrigger = newValue }
    }
    var peekAlpha: Double {
        get { min(0.95, max(0.15, store.peekAlpha)) }
        set { store.peekAlpha = min(0.95, max(0.15, newValue)) }
    }
    var peekHotkeyKeys: String {
        get { store.peekHotkeyKeys }
        set { store.peekHotkeyKeys = newValue }
    }
    var peekHold: Bool {
        get { store.peekHold }
        set { store.peekHold = newValue }
    }

    private var activeBrowser: FloatBrowserInstance? {
        browser ?? (context.agent ? nil : FloatHub.shared.primaryBrowser)
    }

    required init(context: ExactModuleContext) {
        store = FloatHub.shared.store(for: context)
        super.init(context: context)
        if !context.agent {
            FloatHub.shared.register(self)
            // Pre-compile Metal surface shaders on a background queue and attach `surfaceFx`
            // eagerly so the very first Web -> Home reveal can synchronously hold the Web frame.
            FloatSurfaceTransitionHost.obtain { [weak self] host in
                guard let self, let host, self.surfaceFx == nil else { return }
                self.surfaceFx = host
            }
        }
    }

    override func destroy() {
        surfaceFx?.cancel()
        homeBackdropView?.removeFromSuperview()
        homeBackdropView = nil
        lastBackdropIsHome = nil
        if !context.agent {
            FloatHub.shared.unregister(self)
        }
    }

    fileprivate func attachBrowser(_ instance: FloatBrowserInstance) {
        browser = instance
        syncWindowBackdrop()
        if let pending = pendingUrlLoad {
            pendingUrlLoad = nil
            load(pending)
        }
    }

    func notifyChanged() {
        FloatHub.shared.broadcastChange(from: self)
    }

    // MARK: Window & Element Hatches

    private var shouldDeferGlassForMorph: Bool {
        !context.agent
            && ProcessInfo.processInfo.environment["EXACT_SMOKE"] != "1"
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Runs before the main window's first paint so macOS never flashes an opaque backing rectangle
    /// or default window shadow before the GPU WGSL morph draws its first frame.
    fileprivate func prepareWindowForMorph(_ w: NSWindow) {
        guard w.identifier?.rawValue == "Exact.MainWindow" else { return }
        guard !morphPrepared, shouldDeferGlassForMorph else { return }
        morphPrepared = true
        mainWindow = w
        w.animationBehavior = .none
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.alphaValue = 0.001
        if !context.agent {
            w.setFrameUsingName("FloatWindow")
        }
        // Failsafe in case GPU presentation never fires
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.showMorphWindow()
        }
    }

    private func showMorphWindow() {
        guard !morphWindowShown else { return }
        morphWindowShown = true
        guard let w = mainWindow else { return }
        w.alphaValue = CGFloat(alpha)
    }

    override func window(_ exactWindow: ExactWindow) {
        guard let w = exactWindow.window else { return }
        hostWindow = w
        let isMain = w.identifier?.rawValue == "Exact.MainWindow"
        if isMain {
            mainWindow = w
            // Only apply initial window chrome and restore saved frame once — never on resize callbacks!
            if exactWindow.isNew {
                let deferGlass = shouldDeferGlassForMorph
                glassReady = !deferGlass
                configureChromelessWindow(w, deferGlass: deferGlass)
                if !cliHandled, !context.agent, ProcessInfo.processInfo.environment["EXACT_SMOKE"] != "1" {
                    cliHandled = true
                    if let arg = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                        load(arg)
                    }
                }
                if deferGlass {
                    // Failsafe in case shader never presents on an unsupported GPU; normally triggered by revealGlass at t=380ms.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.showMorphWindow()
                        self?.revealHomeGlass()
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                        guard let self, !self.context.agent else { return }
                        FloatUpdater.shared.start()
                        self.notifyChanged()
                    }
                } else if !context.agent {
                    FloatUpdater.shared.start()
                    scheduleColdStartPreload(delay: 0.25)
                }
            } else {
                syncWindowBackdrop()
            }
        } else if exactWindow.isNew {
            configureSecondaryWindow(w)
        }
    }

    override func windowEnded(_ exactWindow: ExactWindow) {}

    override func element(_ element: ExactElement) {
        guard element.hatch == .urlInput else { return }
        if let field = element.textField {
            field.bezelStyle = .roundedBezel
            field.focusRingType = .none
        }
        let seq = element.data[.selectSeq]
        guard seq != lastSelectSeq else { return }
        lastSelectSeq = seq
        DispatchQueue.main.async { [weak element] in
            guard let field = element?.textField else { return }
            field.bezelStyle = .roundedBezel
            field.focusRingType = .none
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    private func configureChromelessWindow(_ w: NSWindow, deferGlass: Bool = false) {
        if !w.styleMask.contains(.fullSizeContentView) { w.styleMask.insert(.fullSizeContentView) }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        if #available(macOS 11.0, *) { w.titlebarSeparatorStyle = .none }
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { w.standardWindowButton($0)?.isHidden = true }
        w.appearance = NSAppearance(named: .darkAqua)
        w.animationBehavior = deferGlass ? .none : .default
        w.hasShadow = !deferGlass
        w.level = onTop ? .floating : .normal
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.minSize = NSSize(width: 160, height: 90)
        w.alphaValue = (deferGlass && !morphWindowShown) ? 0.001 : CGFloat(alpha)
        w.ignoresMouseEvents = clickThrough
        syncWindowBackdrop()
        if !context.agent {
            // Preserve existing Float users' saved window position & size
            w.setFrameUsingName("FloatWindow")
            w.setFrameAutosaveName("FloatWindow")
        }
    }

    /// Secondary windows (Settings window and Shortcuts HUD RoutePanel) stay dark-aqua and float
    /// cleanly above Float's always-on-top main window with a balanced first-open size.
    private func configureSecondaryWindow(_ w: NSWindow) {
        w.appearance = NSAppearance(named: .darkAqua)
        let isPanel = w is NSPanel
        if !isPanel {
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
        guard !context.agent else { return }
        let savedKey = w.frameAutosaveName.isEmpty ? nil : "NSWindow Frame \(w.frameAutosaveName)"
        let hasSavedFrame = savedKey.map { UserDefaults.standard.object(forKey: $0) != nil } ?? false
        if !hasSavedFrame {
            let targetSize = isPanel ? NSSize(width: 760, height: 340) : NSSize(width: 500, height: 700)
            w.setContentSize(targetSize)
            if let vis = (FloatHub.shared.primaryWindow?.screen ?? NSScreen.main)?.visibleFrame {
                let s = w.frame.size
                w.setFrameOrigin(NSPoint(
                    x: (vis.midX - s.width / 2).rounded(),
                    y: (vis.midY - s.height / 2).rounded()
                ))
            }
        }
    }

    private func installHomeBackdrop(in w: NSWindow) {
        guard let content = w.contentView else { return }
        if let existing = homeBackdropView, existing.superview === content { return }
        homeBackdropView?.removeFromSuperview()
        let backdrop: NSView
        if #available(macOS 26.0, *) {
            let glass = FloatHomeGlassView(frame: content.bounds)
            glass.style = .regular
            backdrop = glass
        } else {
            let fx = FloatHomeVisualEffectView(frame: content.bounds)
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            backdrop = fx
        }
        backdrop.autoresizingMask = [.width, .height]
        backdrop.setAccessibilityElement(false)
        content.addSubview(backdrop, positioned: .below, relativeTo: content.subviews.first)
        homeBackdropView = backdrop
    }

    private func removeHomeBackdrop() {
        guard let existing = homeBackdropView else { return }
        existing.removeFromSuperview()
        homeBackdropView = nil
    }

    fileprivate func syncWindowBackdrop() {
        let isHome = (mode == "home")
        if let web = browser?.web, web.isHidden != isHome {
            web.isHidden = isHome
        }
        guard let w = mainWindow else { return }
        let wantsHomeBackdrop = isHome && glassReady
        if wantsHomeBackdrop {
            installHomeBackdrop(in: w)
            if homeBackdropView?.isHidden == true {
                homeBackdropView?.isHidden = false
            }
        } else {
            // Detach NSGlassEffectView/NSVisualEffectView completely in web mode (and before morph reveal):
            // keeping a hidden glass backdrop mounted in an opaque floating window interferes with
            // WindowServer shadow and behind-window vibrancy compositing.
            removeHomeBackdrop()
        }
        if let content = w.contentView {
            for sub in content.subviews {
                if let scroll = sub as? NSScrollView {
                    if scroll.drawsBackground != !isHome {
                        scroll.drawsBackground = !isHome
                    }
                    if isHome, scroll.backgroundColor != .clear {
                        scroll.backgroundColor = .clear
                    }
                    if scroll.hasVerticalScroller { scroll.hasVerticalScroller = false }
                    if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
                }
            }
        }
        if isHome {
            if w.isOpaque { w.isOpaque = false }
            if w.backgroundColor != .clear { w.backgroundColor = .clear }
        } else {
            if !w.isOpaque { w.isOpaque = true }
            if w.backgroundColor != .black { w.backgroundColor = .black }
        }
        if lastBackdropIsHome != isHome {
            lastBackdropIsHome = isHome
            if w.hasShadow {
                w.invalidateShadow()
            }
        }
    }

    private func revealHomeGlass() {
        showMorphWindow()
        guard !glassReady else { return }
        glassReady = true
        guard let w = mainWindow else { return }
        syncWindowBackdrop()
        homeBackdropView?.alphaValue = 0
        w.hasShadow = true
        w.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            self.homeBackdropView?.animator().alphaValue = 1
        }
        scheduleColdStartPreload(delay: 0.28)
    }

    /// Runs after the opening morph settles so WebKit warms without stealing launch morph frames:
    /// stagger-preloads up to 6 saved site homepages into the media-suspended warm pool (prioritizing
    /// the Resume host + most recent sites so heavy SPAs like Apple TV+ hydrate before you click).
    private func scheduleColdStartPreload(delay: TimeInterval) {
        guard !coldWarmupScheduled, !context.agent, ProcessInfo.processInfo.environment["EXACT_SMOKE"] != "1" else { return }
        coldWarmupScheduled = true
        scheduleWarmPoolSweep(initialDelay: delay)
    }

    private func scheduleWarmPoolSweep(initialDelay: TimeInterval) {
        guard !context.agent, ProcessInfo.processInfo.environment["EXACT_SMOKE"] != "1" else { return }
        var ordered = store.allSites().sorted { $0.last > $1.last }
        if let resumeHost = store.loadResume().flatMap({ URL(string: $0.url)?.host?.lowercased() }),
           let idx = ordered.firstIndex(where: { $0.host.lowercased() == resumeHost }),
           idx > 0 {
            let resumed = ordered.remove(at: idx)
            ordered.insert(resumed, at: 0)
        }
        let targets = Array(ordered.prefix(6))
        if targets.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) { [weak self] in
                guard let self, self.mode == "home" else { return }
                self.activeBrowser?.warmWebKitProcesses()
            }
            return
        }
        for (i, site) in targets.enumerated() {
            let fireAt = initialDelay + Double(i) * 0.26
            DispatchQueue.main.asyncAfter(deadline: .now() + fireAt) { [weak self] in
                guard let self, self.mode == "home",
                      let targetBrowser = self.activeBrowser,
                      !targetBrowser.hasWarmHost(site.host),
                      let url = URL(string: site.url),
                      floatIsWeb(url) else { return }
                targetBrowser.preloadStandby(url)
            }
        }
    }

    // MARK: Contract Data Seam (native.call)

    override func call(_ request: [String: Any]) throws -> [String: Any] {
        guard let op = request["op"] as? String else {
            throw ExactNativeRefusal("missing op")
        }
        if op == "state" {
            return snapshotState()
        }
        let arg = request["arg"] as? String ?? ""
        switch op {
        case "load": load(arg)
        case "showHome": showHome()
        case "resumeLast": resumeLast()
        case "addSite": addSite(arg)
        case "removeSite":
            let norm = floatNormalizedHost(arg)
            for existing in store.allSites() where floatNormalizedHost(existing.host) == norm {
                activeBrowser?.removeWarmSite(existing.host)
            }
            store.removeSite(arg)
            activeBrowser?.removeWarmSite(arg)
            notifyChanged()
        case "reloadPage": reloadPage()
        case "back": activeBrowser?.web.goBack()
        case "forward": activeBrowser?.web.goForward()
        case "toggleFill": toggleFill()
        case "toggleExpand": toggleExpand()
        case "toggleAspectLock": setAspectLocked(!aspectLocked)
        case "setAspectLocked": setAspectLocked(arg == "true")
        case "toggleTop": toggleTop()
        case "toggleClickThrough": toggleClickThrough()
        case "fadeOut": fadeOut()
        case "fadeIn": fadeIn()
        case "playPause": playPause()
        case "dock": dock(Int(arg) ?? 0)
        case "setHotkeyKeys":
            hotkeyKeys = arg
            notifyChanged()
        case "setPeekTrigger": setPeekTrigger(arg)
        case "setPeekAlpha": setPeekAlpha(Double(arg) ?? peekAlpha)
        case "setPeekHotkeyKeys":
            peekHotkeyKeys = arg
            notifyChanged()
        case "setPeekHold":
            peekHold = (arg == "true")
            notifyChanged()
        case "setVideoBrightness": setVideoBrightness(Double(arg) ?? videoBrightness)
        case "setHdrVideoBrightness": setHdrVideoBrightness(Double(arg) ?? hdrVideoBrightness)
        case "brightenVideo": brightenVideo()
        case "dimVideo": dimVideo()
        case "setVideoContrast": setVideoContrast(Double(arg) ?? videoContrast)
        case "setPreferSdr": setPreferSdr(arg == "true")
        case "setStreamBrightness": setStreamBrightness(arg == "true")
        case "setActiveVideoStream": setActiveVideoStream(arg)
        case "resetVideoFilters": resetVideoFilters()
        case "setRevealStyle": setRevealStyle(arg)
        case "setOpenStyle": setOpenStyle(arg)
        case "surfaceOpen": surfaceOpen(arg)
        case "preloadSite", "prewarmUrl": preloadSite(arg)
        case "prepareLoad": prepareLoad(arg)
        case "commitLoad": commitLoad(arg)
        case "prepareResume": prepareResume()
        case "commitResume": commitResume()
        case "requestPeekPermission": requestPeekPermission()
        case "showMorphWindow": showMorphWindow()
        case "revealGlass": revealHomeGlass()
        case "checkForUpdates":
            if !context.agent { FloatUpdater.shared.checkForUpdates() }
        case "focusWeb": focusWeb()
        case "recordPlayback": recordPlaybackFromTest(arg)
        default: throw ExactNativeRefusal("unknown op \(op)")
        }
        return ["ok": true]
    }

    override func later(_ request: [String: Any], reply: ExactReply) {
        guard (request["op"] as? String) == "videoAspect" else {
            reply.fail("unknown op")
            return
        }
        if context.agent {
            reply.send(["ok": true, "ratio": 16.0 / 9.0])
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let web = self.activeBrowser?.web else {
                reply.send(["ok": false, "ratio": 0.0])
                return
            }
            let js = "(() => { const v=[...document.querySelectorAll('video')].sort((a,b)=>b.videoWidth*b.videoHeight-a.videoWidth*a.videoHeight)[0]; return v && v.videoWidth && v.videoHeight ? [v.videoWidth, v.videoHeight] : null })()"
            web.evaluateJavaScript(js) { r, _ in
                if let d = r as? [Double], d.count == 2, d[0] > 0, d[1] > 0 {
                    reply.send(["ok": true, "ratio": d[0] / d[1]])
                } else {
                    reply.send(["ok": false, "ratio": 0.0])
                }
            }
        }
    }

    private static func fallbackHighResIcon(for host: String, fallbackUrl: String) -> String {
        let clean = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "\(fallbackUrl)/favicon.ico" }
        let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clean
        return "https://www.google.com/s2/favicons?sz=128&domain=\(encoded)"
    }

    private static func resolveIconUrl(_ stored: String?, host: String, fallbackUrl: String) -> String {
        guard let stored, !stored.isEmpty else { return fallbackHighResIcon(for: host, fallbackUrl: fallbackUrl) }
        if stored.hasPrefix("http://") || stored.hasPrefix("https://") || stored.hasPrefix("data:") {
            if stored.hasSuffix("/favicon.ico") {
                return fallbackHighResIcon(for: host, fallbackUrl: fallbackUrl)
            }
            return stored
        }
        // Keep bundled Exact asset paths (e.g. assets/providers/*.png) intact
        if stored.hasPrefix("assets/") {
            return stored
        }
        return fallbackHighResIcon(for: host, fallbackUrl: fallbackUrl)
    }

    private func snapshotState() -> [String: Any] {
        let sitesList = store.allSites().sorted { $0.last > $1.last }
        let sites: [[String: Any]] = sitesList.map { s in
            let customName = s.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (customName?.isEmpty == false ? customName! : floatSiteName(s.host))
            return [
                "host": s.host,
                "url": s.url,
                "icon": Self.resolveIconUrl(s.icon, host: s.host, fallbackUrl: s.url),
                "name": name,
                "initial": String(name.prefix(1)),
                "last": s.last.timeIntervalSince1970 * 1000,
                "count": s.count,
            ]
        }
        var hasResume = false
        var resumeUrl = ""
        var resumeTitle = ""
        var resumeHost = ""
        var resumeIcon = ""
        var resumeTime = 0.0
        var resumeDuration = 0.0
        if let r = store.loadResume(), let host = URL(string: r.url)?.host {
            hasResume = true
            resumeUrl = r.url
            resumeHost = host
            resumeTitle = r.title.isEmpty ? floatSiteName(host) : r.title
            let normResume = floatNormalizedHost(host)
            resumeIcon = sitesList.first(where: { floatNormalizedHost($0.host) == normResume }).map { Self.resolveIconUrl($0.icon, host: $0.host, fallbackUrl: $0.url) }
                ?? Self.fallbackHighResIcon(for: host, fallbackUrl: "https://\(host)")
            resumeTime = r.time
            resumeDuration = r.duration
        }
        return [
            "mode": mode,
            "currentUrl": currentUrl,
            "fill": fill,
            "onTop": onTop,
            "expanded": expanded,
            "aspectLocked": aspectLocked,
            "clickThrough": clickThrough,
            "alpha": (alpha * 100).rounded() / 100,
            "videoBrightness": (videoBrightness * 100).rounded() / 100,
            "hdrVideoBrightness": (hdrVideoBrightness * 100).rounded() / 100,
            "videoContrast": (videoContrast * 100).rounded() / 100,
            "revealStyle": revealStyle,
            "openStyle": openStyle,
            "fxDemoSeq": fxDemoSeq,
            "fxDemoKind": fxDemoKind,
            "preloadedHost": activeBrowser?.preloadedHost ?? "",
            "webContentReady": activeBrowser?.activeContentReady ?? true,
            "preferSdr": preferSdr,
            "streamBrightness": streamBrightness,
            "activeVideoStream": activeVideoStream,
            "hotkeyKeys": hotkeyKeys,
            "hotkeyLabel": floatFormatChordLabel(hotkeyKeys),
            "peekTrigger": peekTrigger,
            "peekAlpha": (peekAlpha * 100).rounded() / 100,
            "peekHotkeyKeys": peekHotkeyKeys,
            "peekHotkeyLabel": floatFormatChordLabel(peekHotkeyKeys),
            "peekHold": peekHold,
            "canCheckUpdates": context.agent ? false : FloatUpdater.shared.canCheckForUpdates,
            "nativeBackdrop": true,
            "browserFrame": "",
            "hasResume": hasResume,
            "resumeUrl": resumeUrl,
            "resumeTitle": resumeTitle,
            "resumeHost": resumeHost,
            "resumeIcon": resumeIcon,
            "resumeTime": resumeTime,
            "resumeDuration": resumeDuration,
            "sites": sites,
        ]
    }

    // MARK: Actions

    private func resolveWebURL(_ raw: String) -> URL? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        let url: URL?
        if s.contains("://") {
            url = URL(string: s)
        } else if s.contains(".") && !s.contains(" ") {
            url = URL(string: "https://" + s)
        } else {
            var c = URLComponents(string: "https://www.youtube.com/results")!
            c.queryItems = [URLQueryItem(name: "search_query", value: s)]
            url = c.url
        }
        guard let url, floatIsWeb(url) else { return nil }
        return url
    }

    private func normalizedUrlString(_ url: URL) -> String {
        url.path.isEmpty && url.query == nil && url.fragment == nil
            ? url.absoluteString + "/"
            : url.absoluteString
    }

    func preloadSite(_ raw: String) {
        guard !context.agent, mode == "home", let url = resolveWebURL(raw) else { return }
        activeBrowser?.preloadStandby(url)
    }

    /// Starts loading or promoting the URL in WKWebView while keeping Home glass backdrop visible
    /// behind the expanding liquid-glass transition veil.
    func prepareLoad(_ raw: String) {
        guard let url = resolveWebURL(raw) else { return }
        pendingSeek = nil
        if !context.agent, let targetBrowser = activeBrowser {
            targetBrowser.prepareRequest(url, resumeIfPaused: false)
        }
    }

    /// Completes a deferred click transition once the shader veil covers the window.
    func commitLoad(_ raw: String) {
        guard let url = resolveWebURL(raw) else { return }
        pendingSeek = nil
        mode = "web"
        currentUrl = normalizedUrlString(url)
        activeVideoStream = ""
        if let targetBrowser = activeBrowser {
            if !context.agent {
                targetBrowser.commitPreparedOrLoad(url, resumeIfPaused: false)
                (mainWindow ?? FloatHub.shared.primaryWindow)?.makeFirstResponder(targetBrowser.web)
            }
        } else {
            pendingUrlLoad = url.absoluteString
        }
        notifyChanged()
    }

    func prepareResume() {
        guard let r = store.loadResume() else { return }
        let target = URL(string: r.url).map { floatAppleTVResumeURL($0).absoluteString } ?? r.url
        guard let url = resolveWebURL(target) else { return }
        pendingSeek = r.time > 0 ? r.time : nil
        if !context.agent, let targetBrowser = activeBrowser {
            targetBrowser.prepareRequest(url, resumeIfPaused: true)
        }
    }

    func commitResume() {
        guard let r = store.loadResume() else { return }
        let target = URL(string: r.url).map { floatAppleTVResumeURL($0).absoluteString } ?? r.url
        guard let url = resolveWebURL(target) else { return }
        pendingSeek = r.time > 0 ? r.time : nil
        mode = "web"
        currentUrl = normalizedUrlString(url)
        activeVideoStream = ""
        if let targetBrowser = activeBrowser {
            if !context.agent {
                targetBrowser.commitPreparedOrLoad(url, resumeIfPaused: true)
                (mainWindow ?? FloatHub.shared.primaryWindow)?.makeFirstResponder(targetBrowser.web)
            }
        } else {
            pendingUrlLoad = url.absoluteString
        }
        notifyChanged()
    }

    func load(_ raw: String) {
        guard let url = resolveWebURL(raw) else { return }
        pendingSeek = nil
        mode = "web"
        currentUrl = normalizedUrlString(url)
        activeVideoStream = ""
        if let targetBrowser = activeBrowser {
            if !context.agent {
                targetBrowser.loadRequest(url)
                (mainWindow ?? FloatHub.shared.primaryWindow)?.makeFirstResponder(targetBrowser.web)
            }
        } else {
            pendingUrlLoad = url.absoluteString
        }
        notifyChanged()
    }

    func focusWeb() {
        if let targetBrowser = activeBrowser {
            (mainWindow ?? FloatHub.shared.primaryWindow)?.makeFirstResponder(targetBrowser.web)
        }
    }

    func showHome() {
        let wasWeb = (mode == "web")
        pendingSurfaceOpenToken += 1
        let revealToken = pendingSurfaceOpenToken
        let kind = Self.revealKindCode(revealStyle)
        let primary = (mainWindow != nil ? self : FloatHub.shared.primaryModule)
        let shouldCompositeWebReveal = !context.agent
            && wasWeb
            && kind >= 11
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // Capture & hold the live Web view BEFORE suspending WKWebView / switching to Home
        // so the Web view never disappears before the ripple reveals Home over live Liquid Glass!
        var heldWebSurface = false
        if shouldCompositeWebReveal,
           let primary,
           let win = primary.mainWindow ?? FloatHub.shared.primaryWindow {
            if let fx = primary.surfaceFx,
               let webCap = fx.captureWindowSurface(in: win, backdrop: nil, isFrom: true) {
                fx.holdOutgoingSurface(in: win, texture: webCap.texture)
                heldWebSurface = true
            } else {
                // Ensure surfaceFx is initialized for next time
                primary.withSurfaceFx { _ in }
            }
        } else {
            surfaceFx?.cancel()
        }

        mode = "home"
        activeVideoStream = ""
        pendingSeek = nil
        if context.agent {
            activeBrowser?.web.isHidden = true
        } else {
            activeBrowser?.suspendForHome()
            scheduleWarmPoolSweep(initialDelay: 0.45)
        }
        notifyChanged()

        if heldWebSurface, let primary, let win = primary.mainWindow ?? FloatHub.shared.primaryWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.036) { [weak self, weak primary, weak win] in
                guard let self, let primary, let win,
                      self.mode == "home",
                      self.pendingSurfaceOpenToken == revealToken,
                      let fx = primary.surfaceFx else {
                    primary?.surfaceFx?.cancel()
                    return
                }
                let backdrop = primary.homeBackdropView
                guard let homeCap = fx.captureWindowSurface(in: win, backdrop: backdrop, isFrom: false) else {
                    fx.cancel()
                    return
                }
                fx.beginHeldReveal(in: win, backdrop: backdrop, kind: kind, toTexture: homeCap.texture)
            }
        }
    }

    func resumeLast() {
        guard let r = store.loadResume() else { return }
        let target = URL(string: r.url).map { floatAppleTVResumeURL($0).absoluteString } ?? r.url
        guard let url = resolveWebURL(target) else { return }
        pendingSeek = r.time > 0 ? r.time : nil
        mode = "web"
        currentUrl = normalizedUrlString(url)
        if let targetBrowser = activeBrowser {
            if !context.agent {
                targetBrowser.commitPreparedOrLoad(url, resumeIfPaused: true)
                (mainWindow ?? FloatHub.shared.primaryWindow)?.makeFirstResponder(targetBrowser.web)
            }
        } else {
            pendingUrlLoad = url.absoluteString
        }
        notifyChanged()
    }

    private func withSurfaceFx(_ block: @escaping (FloatSurfaceTransitionHost) -> Void) {
        if let existing = surfaceFx {
            block(existing)
            return
        }
        FloatSurfaceTransitionHost.obtain { [weak self] host in
            guard let self, let host else { return }
            if self.surfaceFx == nil {
                self.surfaceFx = host
            }
            if let ready = self.surfaceFx {
                block(ready)
            }
        }
    }

    func setRevealStyle(_ style: String) {
        guard Self.validRevealStyles.contains(style) else { return }
        revealStyle = style
        let kind = Self.revealKindCode(style)
        // On live macOS, play ALL reveal styles (1..2 and 11..14) via the pre-warmed native Metal host
        // with zero WGSL mount compile hitch; keep kind 1..2 for agent tests / web fallback.
        fxDemoKind = context.agent ? kind : (kind + 100)
        fxDemoSeq += 1
        notifyChanged()
        if !context.agent {
            DispatchQueue.main.async {
                FloatHub.shared.primaryModule?.playNativeSurfaceDemo(kind: kind)
            }
        }
    }

    func setOpenStyle(_ style: String) {
        guard Self.validOpenStyles.contains(style) else { return }
        openStyle = style
        let kind = Self.openKindCode(style)
        fxDemoKind = context.agent ? kind : (kind + 100)
        fxDemoSeq += 1
        notifyChanged()
        if !context.agent {
            DispatchQueue.main.async {
                FloatHub.shared.primaryModule?.playNativeSurfaceDemo(kind: kind)
            }
        }
    }

    fileprivate func playNativeSurfaceDemo(kind: Int, isDemo: Bool = true, onFail: (() -> Void)? = nil) {
        guard !context.agent,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let win = mainWindow ?? FloatHub.shared.primaryWindow else {
            onFail?()
            return
        }
        pendingSurfaceOpenToken += 1
        let isOpenKind = (kind == 3 || kind == 4 || kind >= 15)
        let origin: SIMD4<Float> = (kind == 15)
            ? SIMD4<Float>(0.50, 0.48, 0.28, 0.24)
            : SIMD4<Float>(0.24, 0.54, 0.24, 0.25)
        let release: Double? = isOpenKind ? ((kind == 15) ? 0.44 : ((kind == 16) ? 0.16 : 0.38)) : nil
        withSurfaceFx { [weak self, weak win] fx in
            guard let self, let win else { onFail?(); return }
            let backdrop = (self.mode == "home") ? self.homeBackdropView : nil
            guard let cap = fx.captureWindowSurface(in: win, backdrop: backdrop, isFrom: true) else {
                onFail?()
                return
            }
            fx.start(
                in: win,
                backdrop: backdrop,
                kind: kind,
                fromTexture: cap.texture,
                toTexture: cap.texture,
                fromWindowServer: cap.fromWindowServer,
                keepBackdropLive: cap.keepBackdropLive,
                origin: origin,
                isDemo: isDemo,
                autoReleaseAt: release
            )
        }
    }

    /// Runs a real Home -> WKWebView native Metal surface transition from the clicked tile's UV rect.
    /// arg format: "<kind>,<cx>,<cy>,<w>,<h>,<resume|site>,<url>"
    func surfaceOpen(_ arg: String) {
        let parts = arg.split(separator: ",", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 7,
              let kind = Int(parts[0]),
              let cx = Float(parts[1]),
              let cy = Float(parts[2]),
              let w = Float(parts[3]),
              let h = Float(parts[4]) else { return }
        let isResume = (parts[5] == "resume")
        let rawUrl = parts[6]

        if context.agent || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            if isResume { resumeLast() } else { load(rawUrl) }
            return
        }

        guard let win = mainWindow ?? FloatHub.shared.primaryWindow else {
            if isResume { resumeLast() } else { load(rawUrl) }
            return
        }

        pendingSurfaceOpenToken += 1
        let token = pendingSurfaceOpenToken
        let origin = SIMD4<Float>(
            max(0.05, min(0.95, cx)),
            max(0.05, min(0.95, cy)),
            max(0.08, min(0.95, w)),
            max(0.08, min(0.95, h))
        )

        let resolvedTargetUrl: URL? = {
            if isResume, let r = store.loadResume() {
                let t = URL(string: r.url).map { floatAppleTVResumeURL($0).absoluteString } ?? r.url
                return resolveWebURL(t)
            }
            return resolveWebURL(rawUrl)
        }()
        let alreadyReady = resolvedTargetUrl.map {
            activeBrowser?.isTargetAlreadyReady($0, resumeIfPaused: isResume) ?? false
        } ?? false

        if isResume { prepareResume() } else { prepareLoad(rawUrl) }

        withSurfaceFx { [weak self, weak win] fx in
            guard let self, let win, self.pendingSurfaceOpenToken == token else { return }
            // Capture the full opaque Home window (Liquid Glass + cards baked in via backdrop: nil)
            // for ALL 4 open-site transitions (Tile Lens, Diagonal Wipe, Portal Warp, Liquid Ripple)
            // so WKWebView can mount at opacity 1.0 underneath at full 120Hz with zero backdrop flash.
            guard let cap = fx.captureWindowSurface(in: win, backdrop: nil, isFrom: true) else {
                if isResume { self.resumeLast() } else { self.load(rawUrl) }
                return
            }
            if alreadyReady {
                // Subsequent / pre-warmed load: that tab is ALREADY loaded & painted in memory!
                // Hold the exact Home frame 1:1 while unhiding the live tab behind it and grabbing
                // its current frame (~16ms), then run ONE uninterrupted transition straight into
                // that live tab with ZERO reload and ZERO loading pulse!
                fx.holdOutgoingSurface(in: win, texture: cap.texture, keepBackdropLive: false, fromWindowServer: cap.fromWindowServer)
                if isResume { self.commitResume() } else { self.commitLoad(rawUrl) }
                fx.revealUnderlyingViewsBehindCover()
                let launchDirect: (MTLTexture?) -> Void = { [weak self, weak win] toTex in
                    guard let self, let win, self.pendingSurfaceOpenToken == token else { return }
                    fx.start(
                        in: win,
                        backdrop: nil,
                        kind: kind,
                        fromTexture: cap.texture,
                        toTexture: toTex,
                        fromWindowServer: cap.fromWindowServer,
                        keepBackdropLive: false,
                        origin: origin,
                        isDemo: false,
                        autoReleaseAt: 0.0
                    )
                }
                if let web = self.activeBrowser?.web {
                    fx.captureWebSurface(web, afterScreenUpdates: true) { toTex in
                        launchDirect(toTex)
                    }
                } else {
                    launchDirect(nil)
                }
                return
            }

            fx.start(
                in: win,
                backdrop: nil,
                kind: kind,
                fromTexture: cap.texture,
                toTexture: nil,
                fromWindowServer: cap.fromWindowServer,
                keepBackdropLive: false,
                origin: origin,
                isDemo: false,
                autoReleaseAt: nil
            )

            // Cold first load: commit & unhide WKWebView behind the opaque Metal cover once cover peaks,
            // restoring underlying view opacity so WebKit paints at full 120Hz underneath the cover,
            // then wait for center-viewport visual readiness before snapshotting & releasing Phase 2.
            let commitDelay: Double = (kind == 15) ? 0.34 : ((kind == 16) ? 0.06 : 0.28)
            DispatchQueue.main.asyncAfter(deadline: .now() + commitDelay) { [weak self] in
                guard let self, self.pendingSurfaceOpenToken == token else { return }
                if isResume { self.commitResume() } else { self.commitLoad(rawUrl) }
                self.surfaceFx?.revealUnderlyingViewsBehindCover()
                self.waitForWebAndReleaseSurface(token: token, attemptsLeft: 75)
            }
        }
    }

    private func waitForWebAndReleaseSurface(token: Int, attemptsLeft: Int) {
        guard pendingSurfaceOpenToken == token else { return }
        guard let browser = activeBrowser, let fx = surfaceFx else {
            surfaceFx?.releaseOpen(with: nil)
            return
        }
        let web = browser.web
        let retry = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
                self?.waitForWebAndReleaseSurface(token: token, attemptsLeft: attemptsLeft - 1)
            }
        }
        if attemptsLeft <= 1 {
            fx.captureWebSurface(web) { [weak self] toTex in
                guard let self, self.pendingSurfaceOpenToken == token else { return }
                self.surfaceFx?.releaseOpen(with: toTex)
            }
            return
        }
        guard browser.activeContentReady else {
            retry()
            return
        }
        browser.confirmActiveVisuallyPainted { [weak self] painted in
            guard let self, self.pendingSurfaceOpenToken == token else { return }
            if painted {
                fx.captureWebSurface(web) { [weak self] toTex in
                    guard let self, self.pendingSurfaceOpenToken == token else { return }
                    self.surfaceFx?.releaseOpen(with: toTex)
                }
            } else {
                retry()
            }
        }
    }

    func reloadPage() {
        if mode == "web", let web = activeBrowser?.web, web.url?.scheme?.hasPrefix("http") == true {
            web.reload()
        } else {
            showHome()
        }
    }

    private func syncVideoFilterScripts() {
        activeBrowser?.applyVideoFilter(
            fill: fill,
            brightness: videoBrightness,
            hdrBrightness: hdrVideoBrightness,
            contrast: videoContrast,
            streamBrightness: streamBrightness,
            preferSdr: preferSdr
        )
    }

    func toggleFill() {
        fill.toggle()
        activeBrowser?.applyFill(
            fill,
            brightness: videoBrightness,
            hdrBrightness: hdrVideoBrightness,
            contrast: videoContrast,
            streamBrightness: streamBrightness,
            preferSdr: preferSdr
        )
        notifyChanged()
    }

    func setVideoBrightness(_ value: Double) {
        let clamped = (min(2.0, max(0.5, value)) * 100).rounded() / 100
        guard abs(clamped - videoBrightness) >= 0.005 else { return }
        videoBrightness = clamped
        syncVideoFilterScripts()
        notifyChanged()
    }

    func setHdrVideoBrightness(_ value: Double) {
        let clamped = (min(2.0, max(0.5, value)) * 100).rounded() / 100
        guard abs(clamped - hdrVideoBrightness) >= 0.005 else { return }
        hdrVideoBrightness = clamped
        syncVideoFilterScripts()
        notifyChanged()
    }

    func brightenVideo() {
        if streamBrightness && activeVideoStream == "hdr" {
            setHdrVideoBrightness(hdrVideoBrightness + 0.1)
        } else {
            setVideoBrightness(videoBrightness + 0.1)
        }
    }

    func dimVideo() {
        if streamBrightness && activeVideoStream == "hdr" {
            setHdrVideoBrightness(hdrVideoBrightness - 0.1)
        } else {
            setVideoBrightness(videoBrightness - 0.1)
        }
    }

    func setVideoContrast(_ value: Double) {
        let clamped = (min(2.0, max(0.5, value)) * 100).rounded() / 100
        guard abs(clamped - videoContrast) >= 0.005 else { return }
        videoContrast = clamped
        syncVideoFilterScripts()
        notifyChanged()
    }

    func setPreferSdr(_ value: Bool) {
        guard preferSdr != value else { return }
        preferSdr = value
        activeBrowser?.clearWarmPool()
        syncVideoFilterScripts()
        if !context.agent, mode == "web", let web = activeBrowser?.web, web.url?.scheme?.hasPrefix("http") == true {
            web.reload()
        }
        notifyChanged()
    }

    func setStreamBrightness(_ value: Bool) {
        guard streamBrightness != value else { return }
        streamBrightness = value
        syncVideoFilterScripts()
        notifyChanged()
    }

    func setActiveVideoStream(_ value: String) {
        guard ["", "sdr", "hdr"].contains(value), activeVideoStream != value else { return }
        activeVideoStream = value
        notifyChanged()
    }

    func resetVideoFilters() {
        videoBrightness = 1.0
        hdrVideoBrightness = 1.0
        videoContrast = 1.0
        syncVideoFilterScripts()
        notifyChanged()
    }

    func toggleExpand() {
        expanded.toggle()
        notifyChanged()
    }

    func setAspectLocked(_ locked: Bool) {
        guard aspectLocked != locked else { return }
        aspectLocked = locked
        notifyChanged()
    }

    func toggleTop() {
        onTop.toggle()
        notifyChanged()
    }

    func toggleClickThrough() {
        clickThrough.toggle()
        if clickThrough && alpha > 0.6 {
            setAlpha(0.6)
        } else {
            notifyChanged()
        }
    }

    func setAlpha(_ value: Double) {
        alpha = min(1.0, max(0.15, value))
        notifyChanged()
    }

    func fadeOut() { setAlpha(alpha - 0.1) }
    func fadeIn() { setAlpha(alpha + 0.1) }

    func setPeekTrigger(_ trigger: String) {
        let valid = ["rightCommand", "rightOption", "hotkey", "none"]
        guard valid.contains(trigger) else { return }
        peekTrigger = trigger
        notifyChanged()
    }

    func setPeekAlpha(_ value: Double) {
        peekAlpha = (min(0.95, max(0.15, value)) * 100).rounded() / 100
        notifyChanged()
    }

    func requestPeekPermission() {
        guard !context.agent else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        notifyChanged()
    }

    func playPause() {
        activeBrowser?.web.evaluateJavaScript("(() => { const v=[...document.querySelectorAll('video')].find(v=>v.currentSrc); if(v){ v.paused ? v.play() : v.pause(); } })()")
    }

    // tag 0–2: top left/center/right, 3–5: bottom left/center/right
    func dock(_ tag: Int) {
        guard (0...5).contains(tag) else { return }
        if expanded {
            expanded = false
            notifyChanged()
        }
    }

    // MARK: Playback Recording

    func recordSite(_ url: URL, icon: String?) {
        store.recordSite(url, icon: icon)
        notifyChanged()
    }

    func addSite(_ raw: String) {
        var urlStr = raw
        var name: String?
        var icon: String?
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let parsedUrl = obj["url"] as? String {
            urlStr = parsedUrl
            name = obj["name"] as? String
            icon = obj["icon"] as? String
        }
        guard let url = resolveWebURL(urlStr) else { return }
        store.addSite(url: url, name: name, icon: icon)
        notifyChanged()
    }

    func recordResume(url: URL, host: String, rawTitle: String, time: Double, duration: Double) {
        var targetUrl = floatAppleTVResumeURL(url)
        var title = floatCleanTitle(rawTitle, host: host)
        if let prev = store.loadResume() {
            let prevUrl = URL(string: prev.url)
            // On tv.apple.com, closing the player clears MusicKit.nowPlayingItem before the video's
            // final pause event arrives while web.url is still Home; keep the episode/movie URL.
            if host.lowercased() == "tv.apple.com",
               floatAppleTVContentKind(targetUrl) == nil,
               let prevUrl,
               floatAppleTVContentKind(prevUrl) != nil,
               abs(prev.duration - duration) < 5 {
                targetUrl = floatAppleTVResumeURL(prevUrl)
            }
            // Player titles are often hidden with the controls; keep the last good one for this page
            let prevNormalized = prevUrl.map { floatAppleTVResumeURL($0).absoluteString } ?? prev.url
            if prevNormalized == targetUrl.absoluteString, floatIsGenericTitle(title, host: host) {
                title = prev.title
            }
        }
        store.saveResume(FloatResume(url: targetUrl.absoluteString, title: title, time: time, duration: duration))
        notifyChanged()
    }

    private func recordPlaybackFromTest(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let urlStr = obj["url"] as? String,
              let url = URL(string: urlStr),
              let host = url.host else { return }
        let icon = obj["icon"] as? String
        let title = obj["title"] as? String ?? ""
        let t = (obj["t"] as? NSNumber)?.doubleValue ?? 0
        let d = (obj["d"] as? NSNumber)?.doubleValue ?? 0
        store.recordSite(url, icon: icon)
        if d > 180, t <= d {
            recordResume(url: url, host: host, rawTitle: title, time: t, duration: d)
        } else {
            notifyChanged()
        }
    }
}

let exactModule: ExactModule.Type = FloatModule.self
#else
final class FloatModule: ExactModule {}
let exactModule: ExactModule.Type = FloatModule.self
#endif
