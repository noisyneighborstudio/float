import Foundation
import WebKit
#if os(macOS)
import AppKit
import ApplicationServices
import Sparkle

private let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

struct FloatSite: Codable {
    var host: String
    var url: String
    var icon: String?
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

// Applies live CSS brightness & contrast filters to <video> elements; removes the style tag at defaults.
private func floatVideoFilterScript(brightness: Double, contrast: Double) -> String { """
(() => {
  const ID = '__fp_video_filter';
  const B = \(String(format: "%.2f", brightness)), C = \(String(format: "%.2f", contrast));
  const apply = () => {
    let s = document.getElementById(ID);
    if (Math.abs(B - 1) < 0.005 && Math.abs(C - 1) < 0.005) {
      if (s) s.remove();
      return;
    }
    if (!s) {
      s = document.createElement('style');
      s.id = ID;
      (document.head || document.documentElement).appendChild(s);
    }
    s.textContent = `video { filter: brightness(${B}) contrast(${C}) !important; }`;
  };
  if (document.documentElement) apply();
  else document.addEventListener('DOMContentLoaded', apply, { once: true });
})();
""" }

private let floatTrackScript = """
(() => {
  let last = 0;
  const send = (event, v) => webkit.messageHandlers.fpPlay.postMessage({ event, t: v.currentTime || 0, d: v.duration || 0 });
  const isVid = e => e.target instanceof HTMLVideoElement;
  document.addEventListener('play', e => isVid(e) && send('play', e.target), true);
  document.addEventListener('pause', e => isVid(e) && send('time', e.target), true);
  document.addEventListener('timeupdate', e => {
    if (isVid(e) && Date.now() - last > 5000) { last = Date.now(); send('time', e.target); }
  }, true);
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
  return { title: String(title || ''), url: String(atvUrl || '') };
})()
"""

private let floatIconScript = """
(() => {
  const size = l => parseInt(((l.sizes && l.sizes.value) || '0').split('x')[0]) || (l.rel.includes('apple') ? 180 : 16);
  const l = [...document.querySelectorAll('link[rel~="icon"],link[rel^="apple-touch-icon"]')].sort((a, b) => size(b) - size(a));
  return l[0] ? l[0].href : location.origin + '/favicon.ico';
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
    var videoContrast: Double = 1.0
    var revealStyle: String = "wave"
    var openStyle: String = "lens"
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

    var videoContrast: Double {
        get { agentFile != nil ? snapshot.videoContrast : (defaults.object(forKey: "videoContrast") as? Double ?? 1.0) }
        set {
            if agentFile != nil { snapshot.videoContrast = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "videoContrast") }
        }
    }

    var revealStyle: String {
        get { agentFile != nil ? snapshot.revealStyle : (defaults.string(forKey: "revealStyle") ?? "wave") }
        set {
            if agentFile != nil { snapshot.revealStyle = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "revealStyle") }
        }
    }

    var openStyle: String {
        get { agentFile != nil ? snapshot.openStyle : (defaults.string(forKey: "openStyle") ?? "lens") }
        set {
            if agentFile != nil { snapshot.openStyle = newValue; flushAgent() }
            else { defaults.set(newValue, forKey: "openStyle") }
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
        if let idx = list.firstIndex(where: { $0.host == host }) {
            list[idx].last = Date()
            list[idx].count += 1
            if let icon, !icon.isEmpty { list[idx].icon = icon }
        } else {
            list.append(FloatSite(host: host, url: "\(scheme)://\(host)", icon: icon, last: Date(), count: 1))
        }
        saveSites(list)
    }

    func removeSite(_ host: String) {
        saveSites(allSites().filter { $0.host != host })
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
    var onTop = true
    var expanded = false
    var aspectLocked = false
    var clickThrough = false
    var pendingSeek: Double?

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

/// Compares two http(s) URLs ignoring trailing slash differences on the root path and host casing.
private func floatSameLoadTarget(_ a: URL, _ b: URL) -> Bool {
    guard (a.scheme?.lowercased() ?? "") == (b.scheme?.lowercased() ?? ""),
          (a.host?.lowercased() ?? "") == (b.host?.lowercased() ?? ""),
          a.port == b.port,
          a.query == b.query else { return false }
    let pa = a.path.isEmpty ? "/" : a.path
    let pb = b.path.isEmpty ? "/" : b.path
    return pa == pb
}

/// WKWebView subclass that suppresses initial opaque backing-store flash before the GPU morph presents.
private final class FloatWebView: WKWebView {
    weak var module: FloatModule?
    var triggersMorphPrepare = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if triggersMorphPrepare, let win = window {
            module?.prepareWindowForMorph(win)
        }
    }
}

/// Delegate helper inheriting NSObject for WKNavigationDelegate, WKUIDelegate, and WKScriptMessageHandler.
private final class FloatBrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var module: FloatModule?
    weak var instance: FloatBrowserInstance?

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let module, let instance,
              let web = m.webView,
              web === instance.web,
              module.mode == "web",
              !web.isHidden,
              let url = web.url, url.scheme?.hasPrefix("http") == true, let host = url.host,
              let b = m.body as? [String: Any] else { return }
        let t = b["t"] as? Double ?? 0
        let d = b["d"] as? Double ?? 0
        guard t.isFinite, d.isFinite, t >= 0, d >= 0 else { return }
        if b["event"] as? String == "play" {
            web.evaluateJavaScript(floatIconScript) { [weak module] icon, _ in
                module?.recordSite(url, icon: icon as? String)
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
        web.evaluateJavaScript(floatResumeMetaScript) { [weak module] r, _ in
            let meta = r as? [String: Any]
            let rawTitle = meta?["title"] as? String ?? (r as? String ?? "")
            var resumeUrl = url
            if let candidate = meta?["url"] as? String,
               !candidate.isEmpty,
               let parsed = URL(string: candidate),
               floatIsWeb(parsed),
               parsed.host?.lowercased() == host.lowercased() {
                resumeUrl = parsed
            }
            module?.recordResume(url: resumeUrl, host: host, rawTitle: rawTitle, time: t, duration: d)
        }
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = a.request.url else { return decisionHandler(.allow) }
        if u.absoluteString == "about:blank" || floatIsWeb(u) {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
    }

    func webView(_ w: WKWebView, didCommit navigation: WKNavigation!) {
        guard let instance else { return }
        if instance.isWarmSlot(w) {
            instance.handleWarmSlotCommitted(w)
            return
        }
        instance.handleActiveCommitted(w)
        syncFromWebView(w)
    }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
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

/// Detects when a client-rendered SPA (like Apple TV+, Netflix, YouTube) has actually painted
/// real content rather than an empty black #app shell.
private let floatContentReadyScript = """
(() => {
  if (document.readyState === 'loading') return false;
  const body = document.body;
  if (!body) return false;
  const vids = document.querySelectorAll('video');
  for (const v of vids) {
    if (v.readyState >= 2 || v.offsetWidth > 80) return true;
  }
  const imgs = [...document.querySelectorAll('img')].filter(i => i.complete && i.naturalWidth > 32 && i.offsetWidth > 16);
  if (imgs.length >= 1) return true;
  const text = (body.innerText || '').trim();
  if (text.length >= 60) return true;
  const graphics = document.querySelectorAll('canvas, svg');
  if (graphics.length >= 3 && body.offsetHeight > 120) return true;
  return false;
})()
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
    private var activeNavigationToken: Int = 0
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
        installUserScripts(on: web, fill: module.fill, brightness: module.videoBrightness, contrast: module.videoContrast)
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
        w.stopLoading()
        w.setAllMediaPlaybackSuspended(true)
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
        // Re-assert media suspension across cross-origin process swaps so preloaded views never leak audio.
        w.setAllMediaPlaybackSuspended(true)
        guard let slot = warmSlot(for: w) else { return }
        slot.committed = true
    }

    func handleWarmSlotFinished(_ w: WKWebView) {
        w.setAllMediaPlaybackSuspended(true)
        guard let slot = warmSlot(for: w) else { return }
        slot.committed = true
        slot.probeToken += 1
        probeWarmSlotReadiness(slot, token: slot.probeToken, attemptsLeft: 45)
    }

    private func probeWarmSlotReadiness(_ slot: FloatWarmSlot, token: Int, attemptsLeft: Int) {
        guard slot.probeToken == token, warmPool[slot.hostKey] === slot, !slot.contentReady else { return }
        slot.web.setAllMediaPlaybackSuspended(true)
        slot.web.evaluateJavaScript(floatContentReadyScript) { [weak self, weak slot] res, _ in
            guard let self, let slot, slot.probeToken == token, self.warmPool[slot.hostKey] === slot else { return }
            let ready = (res as? Bool) ?? false
            if ready || attemptsLeft <= 1 {
                slot.contentReady = true
                // Pause any media that bootstrapped during hydration
                slot.web.evaluateJavaScript("(() => { document.querySelectorAll('video,audio').forEach(m => { try { m.pause(); } catch {} }); })()")
                slot.web.setAllMediaPlaybackSuspended(true)
                self.module?.notifyChanged()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self, weak slot] in
                    guard let self, let slot else { return }
                    self.probeWarmSlotReadiness(slot, token: token, attemptsLeft: attemptsLeft - 1)
                }
            }
        }
    }

    func handleActiveCommitted(_ w: WKWebView) {
        guard w === web, !activeContentReady else { return }
        let token = activeNavigationToken
        probeActiveContentReady(token: token, attemptsLeft: 32)
    }

    func handleActiveFinished(_ w: WKWebView) {
        guard w === web, !activeContentReady else { return }
        let token = activeNavigationToken
        probeActiveContentReady(token: token, attemptsLeft: 28)
    }

    private func probeActiveContentReady(token: Int, attemptsLeft: Int) {
        guard token == activeNavigationToken, !activeContentReady else { return }
        web.evaluateJavaScript(floatContentReadyScript) { [weak self] res, _ in
            guard let self, token == self.activeNavigationToken, !self.activeContentReady else { return }
            let ready = (res as? Bool) ?? false
            if ready || attemptsLeft <= 1 {
                self.activeContentReady = true
                self.module?.notifyChanged()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
                    self?.probeActiveContentReady(token: token, attemptsLeft: attemptsLeft - 1)
                }
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
        let key = host.lowercased()
        if pausedHomeUrl?.host?.lowercased() == key || pausedRequestedUrl?.host?.lowercased() == key {
            return true
        }
        return warmPool[key] != nil
    }

    func removeWarmSite(_ host: String) {
        let key = host.lowercased()
        if let slot = warmPool.removeValue(forKey: key) {
            slot.probeToken += 1
            teardownWebView(slot.web)
        }
    }

    func installUserScripts(fill on: Bool, brightness: Double, contrast: Double) {
        installUserScripts(on: web, fill: on, brightness: brightness, contrast: contrast)
        for slot in warmPool.values {
            installUserScripts(on: slot.web, fill: on, brightness: brightness, contrast: contrast)
        }
    }

    private func installUserScripts(on target: WKWebView, fill on: Bool, brightness: Double, contrast: Double) {
        let ucc = target.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: floatFillScript(on), injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: floatVideoFilterScript(brightness: brightness, contrast: contrast), injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: floatTrackScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: trackWorld))
    }

    func applyFill(_ on: Bool, brightness: Double, contrast: Double) {
        installUserScripts(fill: on, brightness: brightness, contrast: contrast)
        web.evaluateJavaScript(floatFillScript(on))
    }

    func applyVideoFilter(fill on: Bool, brightness: Double, contrast: Double) {
        installUserScripts(fill: on, brightness: brightness, contrast: contrast)
        web.evaluateJavaScript(floatVideoFilterScript(brightness: brightness, contrast: contrast))
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
        w.setAllMediaPlaybackSuspended(true)
        container.addSubview(w, positioned: .below, relativeTo: web)
        processWarmupWeb = w
        w.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
    }

    /// Preloads a saved site's homepage into the bounded multi-site warm pool (max 6 slots, LRU).
    func preloadStandby(_ url: URL) {
        guard let module, !module.context.agent, floatIsWeb(url), let rawHost = url.host else { return }
        let key = rawHost.lowercased()

        // Already paused on this exact target in activeWeb
        if let paused = pausedHomeUrl, floatSameLoadTarget(paused, url) { return }
        if let pausedReq = pausedRequestedUrl, floatSameLoadTarget(pausedReq, url) { return }

        // Already warm in pool for this site
        if let existing = warmPool[key] {
            existing.lastUsed = Date()
            if floatSameLoadTarget(existing.requestedUrl, url) { return }
            existing.requestedUrl = url
            existing.committed = false
            existing.contentReady = false
            existing.probeToken += 1
            existing.web.setAllMediaPlaybackSuspended(true)
            existing.web.load(URLRequest(url: url))
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
        w.isHidden = true
        installUserScripts(on: w, fill: module.fill, brightness: module.videoBrightness, contrast: module.videoContrast)
        container.addSubview(w, positioned: .below, relativeTo: web)

        let slot = FloatWarmSlot(hostKey: key, web: w, requestedUrl: url)
        warmPool[key] = slot
        w.setAllMediaPlaybackSuspended(true)
        w.load(URLRequest(url: url))
    }

    private func matchingWarmSlot(for url: URL) -> FloatWarmSlot? {
        guard let key = url.host?.lowercased(), let slot = warmPool[key] else { return nil }
        if floatSameLoadTarget(slot.requestedUrl, url) { return slot }
        if let current = slot.web.url, floatSameLoadTarget(current, url) { return slot }
        return nil
    }

    /// Prepares or promotes the target URL in the background without unhiding yet (used during glass wipe).
    func prepareRequest(_ url: URL, resumeIfPaused: Bool = false) {
        homeIdleCleanup?.cancel()
        homeIdleCleanup = nil
        preparedUrl = url

        // 1. Instant 0ms path: target is already paused in activeWeb from a recent showHome()
        let matchesPaused = (pausedHomeUrl.map { floatSameLoadTarget($0, url) } ?? false)
            || (pausedRequestedUrl.map { floatSameLoadTarget($0, url) } ?? false)
            || (resumeIfPaused && pausedHomeUrl?.host?.lowercased() == url.host?.lowercased() && pausedHomeUrl?.path == url.path)
        if matchesPaused {
            activeNavigationToken += 1
            activeContentReady = true
            module?.notifyChanged()
            return
        }

        // 2. Instant pool promotion path: site is already warm/hydrated in warmPool
        if let slot = matchingWarmSlot(for: url) {
            promoteWarmSlot(slot, reveal: false)
            return
        }

        // 3. Cold navigation directly into activeWeb behind the breathing glass veil
        parkActiveIfHomepage()
        pausedHomeUrl = nil
        pausedRequestedUrl = nil
        activeNavigationToken += 1
        activeContentReady = false
        web.setAllMediaPlaybackSuspended(true)
        web.load(URLRequest(url: url))
        module?.notifyChanged()
    }

    /// Commits a previously prepared load (or loads fresh if not yet prepared), revealing and unsuspending media.
    func commitPreparedOrLoad(_ url: URL, resumeIfPaused: Bool = false) {
        homeIdleCleanup?.cancel()
        homeIdleCleanup = nil

        let wasPrepared = preparedUrl.map { floatSameLoadTarget($0, url) } ?? false
        preparedUrl = nil

        // 1. Instant 0ms resume from paused Home state
        let matchesPaused = (pausedHomeUrl.map { floatSameLoadTarget($0, url) } ?? false)
            || (pausedRequestedUrl.map { floatSameLoadTarget($0, url) } ?? false)
            || (resumeIfPaused && pausedHomeUrl?.host?.lowercased() == url.host?.lowercased() && pausedHomeUrl?.path == url.path)
        if matchesPaused {
            pausedHomeUrl = nil
            pausedRequestedUrl = nil
            activeNavigationToken += 1
            activeContentReady = true
            web.isHidden = false
            web.setAllMediaPlaybackSuspended(false)
            if resumeIfPaused {
                web.evaluateJavaScript("(() => { const v=[...document.querySelectorAll('video')].find(v=>v.currentSrc); if(v && v.paused){ v.play().catch(()=>{}); } })()")
            }
            return
        }

        // 2. Promote matching warm slot if not already promoted in prepareRequest
        if let slot = matchingWarmSlot(for: url) {
            promoteWarmSlot(slot, reveal: true)
            return
        }

        // 3. Reveal & unsuspend activeWeb (either already prepared or fresh load)
        pausedHomeUrl = nil
        pausedRequestedUrl = nil
        web.isHidden = false
        web.setAllMediaPlaybackSuspended(false)
        if !wasPrepared {
            activeNavigationToken += 1
            activeContentReady = false
            web.load(URLRequest(url: url))
            let token = activeNavigationToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.probeActiveContentReady(token: token, attemptsLeft: 32)
            }
        } else if !activeContentReady {
            // Ensure active readiness polling continues after unhiding (for SPAs that waited on visibility)
            let token = activeNavigationToken
            probeActiveContentReady(token: token, attemptsLeft: 32)
        }
    }

    /// Parks the current activeWeb back into warmPool when switching sites if it's a clean site homepage
    /// so bouncing back to it later is 0ms.
    private func parkActiveIfHomepage() {
        guard let cur = web.url, floatIsWeb(cur), let rawHost = cur.host else { return }
        let key = rawHost.lowercased()
        let isRootOrBrowse = cur.path.isEmpty || cur.path == "/" || cur.path == "/browse" || cur.path == "/home"
        guard isRootOrBrowse, warmPool[key] == nil, warmPool.count < FloatBrowserInstance.maxWarmPoolSize else { return }
        // Caller will swap web out when promoting; only used when replacing activeWeb in promoteWarmSlot.
    }

    private func promoteWarmSlot(_ slot: FloatWarmSlot, reveal: Bool) {
        let oldWeb = web
        let oldPausedUrl = pausedHomeUrl ?? oldWeb.url
        let oldWasReady = activeContentReady
        warmPool.removeValue(forKey: slot.hostKey)
        slot.probeToken += 1

        pausedHomeUrl = nil
        pausedRequestedUrl = nil

        slot.web.frame = container.bounds
        slot.web.isHidden = !reveal
        web = slot.web
        activeNavigationToken += 1
        activeContentReady = slot.contentReady

        // Park oldWeb back into warmPool if it was sitting cleanly on a different site's browse/home page
        if let oldUrl = oldPausedUrl, floatIsWeb(oldUrl), let oldHost = oldUrl.host {
            let oldKey = oldHost.lowercased()
            let isCleanHome = oldUrl.path.isEmpty || oldUrl.path == "/" || oldUrl.path == "/browse" || oldUrl.path == "/home"
            if oldKey != slot.hostKey, isCleanHome, warmPool[oldKey] == nil, warmPool.count < FloatBrowserInstance.maxWarmPoolSize {
                oldWeb.isHidden = true
                oldWeb.setAllMediaPlaybackSuspended(true)
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
            web.setAllMediaPlaybackSuspended(false)
            if let mod = module {
                web.evaluateJavaScript(floatFillScript(mod.fill))
                web.evaluateJavaScript(floatVideoFilterScript(brightness: mod.videoBrightness, contrast: mod.videoContrast))
            }
        }
        if !activeContentReady {
            let token = activeNavigationToken
            probeActiveContentReady(token: token, attemptsLeft: 32)
        }
        module?.notifyChanged()
    }

    func loadRequest(_ url: URL) {
        commitPreparedOrLoad(url, resumeIfPaused: false)
    }

    /// Pauses & suspends media when returning Home so jumping back to the active video is 0ms.
    func suspendForHome() {
        preparedUrl = nil
        activeNavigationToken += 1
        activeContentReady = true
        homeIdleCleanup?.cancel()
        homeIdleCleanup = nil

        if let cur = web.url, floatIsWeb(cur) {
            pausedHomeUrl = cur
            pausedRequestedUrl = cur
            web.evaluateJavaScript("(() => { document.querySelectorAll('video,audio').forEach(m => { try { m.pause(); } catch {} }); })()")
            web.setAllMediaPlaybackSuspended(true)
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
        web.setAllMediaPlaybackSuspended(true)
        web.load(URLRequest(url: URL(string: "about:blank")!))
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
    private var agentOnTop = true
    private var agentExpanded = false
    private var agentAspectLocked = false
    private var agentClickThrough = false
    private var agentPendingSeek: Double?

    var mode: String {
        get { context.agent ? agentMode : FloatHub.shared.mode }
        set { if context.agent { agentMode = newValue } else { FloatHub.shared.mode = newValue } }
    }
    var currentUrl: String {
        get { context.agent ? agentCurrentUrl : FloatHub.shared.currentUrl }
        set { if context.agent { agentCurrentUrl = newValue } else { FloatHub.shared.currentUrl = newValue } }
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
    var videoContrast: Double {
        get { min(2.0, max(0.5, store.videoContrast)) }
        set { store.videoContrast = min(2.0, max(0.5, newValue)) }
    }
    var revealStyle: String {
        get { store.revealStyle == "curtain" ? "curtain" : "wave" }
        set { store.revealStyle = (newValue == "curtain" ? "curtain" : "wave") }
    }
    var openStyle: String {
        get { store.openStyle == "diagonal" ? "diagonal" : "lens" }
        set { store.openStyle = (newValue == "diagonal" ? "diagonal" : "lens") }
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
        }
    }

    override func destroy() {
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
            let targetSize = isPanel ? NSSize(width: 760, height: 320) : NSSize(width: 480, height: 520)
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
        case "removeSite":
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
        case "setVideoContrast": setVideoContrast(Double(arg) ?? videoContrast)
        case "resetVideoFilters": resetVideoFilters()
        case "setRevealStyle": setRevealStyle(arg)
        case "setOpenStyle": setOpenStyle(arg)
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

    private func snapshotState() -> [String: Any] {
        let sitesList = store.allSites().sorted { $0.last > $1.last }
        let sites: [[String: Any]] = sitesList.map { s in
            let name = floatSiteName(s.host)
            return [
                "host": s.host,
                "url": s.url,
                "icon": s.icon ?? "\(s.url)/favicon.ico",
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
            resumeIcon = sitesList.first(where: { $0.host == host }).flatMap { $0.icon ?? "\($0.url)/favicon.ico" }
                ?? "https://\(host)/favicon.ico"
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
            "videoContrast": (videoContrast * 100).rounded() / 100,
            "revealStyle": revealStyle,
            "openStyle": openStyle,
            "preloadedHost": activeBrowser?.preloadedHost ?? "",
            "webContentReady": activeBrowser?.activeContentReady ?? true,
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
        mode = "home"
        pendingSeek = nil
        if context.agent {
            activeBrowser?.web.isHidden = true
        } else {
            activeBrowser?.suspendForHome()
            scheduleWarmPoolSweep(initialDelay: 0.45)
        }
        notifyChanged()
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

    func setRevealStyle(_ style: String) {
        guard style == "wave" || style == "curtain" else { return }
        revealStyle = style
        notifyChanged()
    }

    func setOpenStyle(_ style: String) {
        guard style == "lens" || style == "diagonal" else { return }
        openStyle = style
        notifyChanged()
    }

    func reloadPage() {
        if mode == "web", let web = activeBrowser?.web, web.url?.scheme?.hasPrefix("http") == true {
            web.reload()
        } else {
            showHome()
        }
    }

    func toggleFill() {
        fill.toggle()
        activeBrowser?.applyFill(fill, brightness: videoBrightness, contrast: videoContrast)
        notifyChanged()
    }

    func setVideoBrightness(_ value: Double) {
        let clamped = (min(2.0, max(0.5, value)) * 100).rounded() / 100
        guard abs(clamped - videoBrightness) >= 0.005 else { return }
        videoBrightness = clamped
        activeBrowser?.applyVideoFilter(fill: fill, brightness: videoBrightness, contrast: videoContrast)
        notifyChanged()
    }

    func setVideoContrast(_ value: Double) {
        let clamped = (min(2.0, max(0.5, value)) * 100).rounded() / 100
        guard abs(clamped - videoContrast) >= 0.005 else { return }
        videoContrast = clamped
        activeBrowser?.applyVideoFilter(fill: fill, brightness: videoBrightness, contrast: videoContrast)
        notifyChanged()
    }

    func resetVideoFilters() {
        videoBrightness = 1.0
        videoContrast = 1.0
        activeBrowser?.applyVideoFilter(fill: fill, brightness: videoBrightness, contrast: videoContrast)
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
