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

/// WKWebView subclass that suppresses initial opaque backing-store flash before the GPU morph presents.
private final class FloatWebView: WKWebView {
    weak var module: FloatModule?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let win = window {
            module?.prepareWindowForMorph(win)
        }
    }
}

/// Delegate helper inheriting NSObject for WKNavigationDelegate, WKUIDelegate, and WKScriptMessageHandler.
private final class FloatBrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var module: FloatModule?
    weak var web: WKWebView?

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let module, let web,
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
        syncFromWebView()
    }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        syncFromWebView()
    }

    private func syncFromWebView() {
        guard let module, let web, let url = web.url else { return }
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

/// Native WKWebView instance owning video playback, fill script, isolated fpPlay tracking, and navigation.
fileprivate final class FloatBrowserInstance: ExactNativeInstance {
    let web: FloatWebView
    private let delegate = FloatBrowserDelegate()
    // Tracking script + fpPlay bridge live here; page JS can't reach them to forge messages.
    private let trackWorld = WKContentWorld.world(name: "float-track")

    init(_ module: FloatModule, _ events: ExactNativeEvents) {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.websiteDataStore = module.context.agent ? .nonPersistent() : .default()
        web = FloatWebView(frame: .zero, configuration: cfg)
        web.module = module
        super.init(events: events)
        delegate.module = module
        delegate.web = web
        web.customUserAgent = safariUA
        web.navigationDelegate = delegate
        web.uiDelegate = delegate
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.setValue(false, forKey: "drawsBackground")
        cfg.userContentController.add(delegate, contentWorld: trackWorld, name: "fpPlay")
        installUserScripts(fill: module.fill, brightness: module.videoBrightness, contrast: module.videoContrast)
        module.attachBrowser(self)
    }

    override var view: ExactNativeView { web }

    override func destroy() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "fpPlay", contentWorld: trackWorld)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.stopLoading()
    }

    func installUserScripts(fill on: Bool, brightness: Double, contrast: Double) {
        let ucc = web.configuration.userContentController
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

    func loadRequest(_ url: URL) {
        web.load(URLRequest(url: url))
    }

    func loadBlank() {
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

    fileprivate func syncWindowBackdrop() {
        let isHome = (mode == "home")
        browser?.web.isHidden = isHome
        guard let w = mainWindow else { return }
        installHomeBackdrop(in: w)
        homeBackdropView?.isHidden = !isHome || !glassReady
        if let content = w.contentView {
            for sub in content.subviews {
                if let scroll = sub as? NSScrollView {
                    if scroll.drawsBackground != !isHome {
                        scroll.drawsBackground = !isHome
                    }
                    scroll.backgroundColor = isHome ? .clear : .black
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
            w.invalidateShadow()
        }
    }

    private func revealHomeGlass() {
        showMorphWindow()
        guard !glassReady else { return }
        glassReady = true
        guard let w = mainWindow else { return }
        homeBackdropView?.alphaValue = 0
        syncWindowBackdrop()
        w.hasShadow = true
        w.invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            self.homeBackdropView?.animator().alphaValue = 1
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

    func load(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
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
        guard let url, floatIsWeb(url) else { return }
        pendingSeek = nil
        // Match URL.toString() normalization for bare host URLs like https://netflix.com/
        let normalized = url.path.isEmpty && url.query == nil && url.fragment == nil
            ? url.absoluteString + "/"
            : url.absoluteString
        mode = "web"
        currentUrl = normalized
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
        if !context.agent { activeBrowser?.loadBlank() }
        notifyChanged()
    }

    func resumeLast() {
        guard let r = store.loadResume() else { return }
        let target = URL(string: r.url).map { floatAppleTVResumeURL($0).absoluteString } ?? r.url
        load(target)
        pendingSeek = r.time > 0 ? r.time : nil
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
