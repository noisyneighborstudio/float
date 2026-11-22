import Foundation
import WebKit
#if os(macOS)
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import QuartzCore

private let floatRightCommandMask: UInt = 0x0000_0010 // NX_DEVICERCMDKEYMASK
private let floatRightOptionMask: UInt = 0x0000_0040  // NX_DEVICERALTKEYMASK

private let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

// Global show/hide hotkey (Carbon: no Accessibility permission needed)
struct FloatHotKey: Codable, Equatable {
    var code: UInt32
    var mods: UInt32 // Carbon keyCode + cmdKey/shiftKey/optionKey/controlKey

    static let fallback = FloatHotKey(code: UInt32(kVK_ANSI_F), mods: UInt32(controlKey | optionKey | cmdKey))
    static let peekFallback = FloatHotKey(code: UInt32(kVK_ANSI_D), mods: UInt32(controlKey | optionKey | cmdKey))

    init(code: UInt32, mods: UInt32) {
        self.code = code
        self.mods = mods
    }

    // nil unless ⌘, ⌃ or ⌥ is held: a bare key would swallow typing everywhere
    init?(_ e: NSEvent) {
        let f = e.modifierFlags
        guard !f.intersection([.command, .control, .option]).isEmpty else { return nil }
        code = UInt32(e.keyCode)
        mods = (f.contains(.command) ? UInt32(cmdKey) : 0)
            | (f.contains(.shift) ? UInt32(shiftKey) : 0)
            | (f.contains(.option) ? UInt32(optionKey) : 0)
            | (f.contains(.control) ? UInt32(controlKey) : 0)
    }

    var label: String {
        let names: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        var key = names[Int(code)]
        if key == nil,
           let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
           let raw = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) {
            let layout = unsafeBitCast(raw, to: CFData.self)
            var dead: UInt32 = 0
            var len = 0
            var chars = [UniChar](repeating: 0, count: 4)
            CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
                _ = UCKeyTranslate(
                    $0, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars
                )
            }
            key = String(utf16CodeUnits: chars, count: len).uppercased()
        }
        return (mods & UInt32(controlKey) != 0 ? "⌃" : "")
            + (mods & UInt32(optionKey) != 0 ? "⌥" : "")
            + (mods & UInt32(shiftKey) != 0 ? "⇧" : "")
            + (mods & UInt32(cmdKey) != 0 ? "⌘" : "")
            + (key ?? "key \(code)")
    }
}

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
    [${ATTR}] { position: fixed !important; inset: 0 !important; width: 100vw !important; height: 100vh !important;
      max-width: none !important; max-height: none !important; margin: 0 !important; transform: none !important;
      z-index: 2147483647 !important; background: #000 !important; }
    [${ATTR}] [data-fp-path] { width: 100% !important; height: 100% !important; max-width: none !important; max-height: none !important; }
    [${ATTR}] video[data-fp-path] { position: absolute !important; inset: 0 !important; }
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
  const isEd = el => !!(el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)));
  document.addEventListener('focusin', e => webkit.messageHandlers.fpPlay.postMessage({ event: 'edit', on: isEd(e.target) }), true);
  document.addEventListener('focusout', () => setTimeout(() => webkit.messageHandlers.fpPlay.postMessage({ event: 'edit', on: isEd(document.activeElement) }), 0), true);
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
    var hotKey: FloatHotKey? = .fallback
    var peekTrigger: String = "rightCommand"
    var peekAlpha: Double = 0.5
    var peekHotKey: FloatHotKey? = .peekFallback
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

    var hotKey: FloatHotKey? {
        get {
            if agentFile != nil { return snapshot.hotKey }
            return defaults.data(forKey: "hotkey").map { try? JSONDecoder().decode(FloatHotKey.self, from: $0) } ?? .fallback
        }
        set {
            if agentFile != nil { snapshot.hotKey = newValue; flushAgent() }
            else { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: "hotkey") }
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

    var peekHotKey: FloatHotKey? {
        get {
            if agentFile != nil { return snapshot.peekHotKey }
            return defaults.data(forKey: "peekHotkey").map { try? JSONDecoder().decode(FloatHotKey.self, from: $0) } ?? .peekFallback
        }
        set {
            if agentFile != nil { snapshot.peekHotKey = newValue; flushAgent() }
            else { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: "peekHotkey") }
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

/// Dynamic Sparkle loader: activates only when SUFeedURL is baked into Info.plist (release builds)
/// and Sparkle.framework is present in Contents/Frameworks/. Dev builds never self-update and need
/// no compile-time Sparkle dependency.
private final class SparkleBridge {
    private var controller: NSObject?

    init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
        guard let fwURL = Bundle.main.privateFrameworksURL?.appendingPathComponent("Sparkle.framework"),
              let bundle = Bundle(url: fwURL), bundle.load() else { return }
        guard let cls = NSClassFromString("SPUStandardUpdaterController") as? NSObject.Type else { return }
        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithStartingUpdater:updaterDelegate:userDriverDelegate:")
        guard let allocImp = cls.method(for: allocSel),
              let initImp = cls.instanceMethod(for: initSel) else { return }
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> AnyObject
        typealias InitFn = @convention(c) (AnyObject, Selector, Bool, AnyObject?, AnyObject?) -> AnyObject
        let allocFn = unsafeBitCast(allocImp, to: AllocFn.self)
        let initFn = unsafeBitCast(initImp, to: InitFn.self)
        let instance = allocFn(cls, allocSel)
        controller = initFn(instance, initSel, true, nil, nil) as? NSObject
    }

    var canCheckForUpdates: Bool {
        guard let controller,
              let updater = controller.value(forKey: "updater") as? NSObject,
              let value = updater.value(forKey: "canCheckForUpdates") as? Bool else { return false }
        return value
    }

    func checkForUpdates() {
        guard let controller else { return }
        let sel = NSSelectorFromString("checkForUpdates:")
        if controller.responds(to: sel) {
            _ = controller.perform(sel, with: nil)
        }
    }
}

/// Process-wide Carbon hotkey callback owner (handles press + release for show/hide and peek).
private final class FloatHotKeyCenter {
    static let shared = FloatHotKeyCenter()
    weak var active: FloatModule?
    private var handlerInstalled = false

    func installIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                guard let event else { return noErr }
                var hkID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                guard status == noErr else { return noErr }
                let kind = GetEventKind(event)
                DispatchQueue.main.async {
                    guard let mod = FloatHotKeyCenter.shared.active else { return }
                    if hkID.id == 1, kind == UInt32(kEventHotKeyPressed) {
                        mod.toggleShown()
                    } else if hkID.id == 2 {
                        if kind == UInt32(kEventHotKeyPressed) {
                            mod.peekHotKeyPressed()
                        } else if kind == UInt32(kEventHotKeyReleased) {
                            mod.peekHotKeyReleased()
                        }
                    }
                }
                return noErr
            },
            specs.count, &specs, nil, nil
        )
    }
}

/// Top-edge hover drag strip: fades in on hover even when inactive, drags window, double-click toggles aspect lock.
private final class FloatDragStripView: NSView {
    weak var module: FloatModule?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        alphaValue = 0
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with e: NSEvent) {
        animator().alphaValue = 1
    }

    override func mouseExited(with e: NSEvent) {
        animator().alphaValue = 0
    }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 {
            module?.toggleAspectLock()
            return
        }
        window?.performDrag(with: e)
    }

    override var mouseDownCanMoveWindow: Bool { true }
}

private final class FloatDragStripInstance: ExactNativeInstance {
    private let strip = FloatDragStripView(frame: .zero)

    init(_ module: FloatModule, _ events: ExactNativeEvents) {
        super.init(events: events)
        strip.module = module
    }

    override var view: ExactNativeView { strip }
}

/// Delegate helper inheriting NSObject for WKNavigationDelegate, WKUIDelegate, and WKScriptMessageHandler.
private final class FloatBrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    weak var module: FloatModule?
    weak var web: WKWebView?

    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let module, let web,
              let url = web.url, url.scheme?.hasPrefix("http") == true, let host = url.host,
              let b = m.body as? [String: Any] else { return }
        if b["event"] as? String == "edit" {
            module.webEditingText = b["on"] as? Bool ?? false
            return
        }
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
        module?.webEditingText = false
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
    let web: WKWebView
    private let delegate = FloatBrowserDelegate()
    // Tracking script + fpPlay bridge live here; page JS can't reach them to forge messages.
    private let trackWorld = WKContentWorld.world(name: "float-track")

    init(_ module: FloatModule, _ events: ExactNativeEvents) {
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.websiteDataStore = module.context.agent ? .nonPersistent() : .default()
        web = WKWebView(frame: .zero, configuration: cfg)
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
        installFillScript(module.fill)
        module.attachBrowser(self)
    }

    override var view: ExactNativeView { web }

    override func destroy() {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "fpPlay", contentWorld: trackWorld)
        web.navigationDelegate = nil
        web.uiDelegate = nil
        web.stopLoading()
    }

    func installFillScript(_ on: Bool) {
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: floatFillScript(on), injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: floatTrackScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: trackWorld))
    }

    func applyFill(_ on: Bool) {
        installFillScript(on)
        web.evaluateJavaScript(floatFillScript(on))
    }

    func loadRequest(_ url: URL) {
        web.load(URLRequest(url: url))
    }

    func loadBlank() {
        web.load(URLRequest(url: URL(string: "about:blank")!))
    }
}

/// Dedicated native macOS Settings window (`Float › Settings…` / `⌘,`).
private final class FloatSettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}

private final class FloatSettingsWindowController: NSWindowController, NSWindowDelegate {
    private weak var module: FloatModule?
    private let rootStack = NSStackView()
    private let triggerControl = NSSegmentedControl(
        labels: ["Hold Right ⌘", "Hold Right ⌥", "Custom Hotkey", "Off"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let customRow = NSStackView()
    private let peekKeyBadge = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl(
        labels: ["Hold", "Toggle"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let permissionBox = NSView()
    private let permissionTitle = NSTextField(labelWithString: "")
    private let opacitySection = NSStackView()
    private let opacityValueLabel = NSTextField(labelWithString: "50%")
    private let opacityPresets = NSSegmentedControl(
        labels: ["15%", "25%", "50%", "75%"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let opacitySlider = NSSlider(value: 0.5, minValue: 0.15, maxValue: 0.95, target: nil, action: nil)
    private let showHideBadge = NSTextField(labelWithString: "")

    private let triggerKeys = ["rightCommand", "rightOption", "hotkey", "none"]
    private let presetValues: [Double] = [0.15, 0.25, 0.5, 0.75]

    init(module: FloatModule) {
        self.module = module
        let win = FloatSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Float Settings"
        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0)
        super.init(window: win)
        win.delegate = self
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeHeading(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: 13, weight: .semibold)
        f.textColor = .labelColor
        return f
    }

    private func makeSubtext(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        return f
    }

    private func styleBadge(_ field: NSTextField) -> NSView {
        field.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        field.textColor = .labelColor
        field.alignment = .center
        field.translatesAutoresizingMaskIntoConstraints = false
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 0.22, alpha: 1.0).cgColor
        box.layer?.cornerRadius = 6
        box.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            field.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            field.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
            box.widthAnchor.constraint(greaterThanOrEqualToConstant: 56),
        ])
        return box
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 14
        rootStack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: content.topAnchor),
            rootStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            rootStack.widthAnchor.constraint(equalToConstant: 460),
        ])

        // Section 1: Quick Fade (Global)
        let fadeHeader = NSStackView(views: [
            makeHeading("Quick Fade (Global)"),
            makeSubtext("Temporarily fade Float from any app to see what is behind it."),
        ])
        fadeHeader.orientation = .vertical
        fadeHeader.alignment = .leading
        fadeHeader.spacing = 2
        rootStack.addArrangedSubview(fadeHeader)

        triggerControl.target = self
        triggerControl.action = #selector(triggerChanged(_:))
        triggerControl.segmentStyle = .rounded
        triggerControl.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(triggerControl)
        triggerControl.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40).isActive = true

        // Custom hotkey row
        let peekBadgeWrap = styleBadge(peekKeyBadge)
        let recordPeekBtn = NSButton(title: "Record…", target: self, action: #selector(recordPeek(_:)))
        recordPeekBtn.bezelStyle = .rounded
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.segmentStyle = .rounded
        let customSpacer = NSView()
        customSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        customRow.orientation = .horizontal
        customRow.alignment = .centerY
        customRow.spacing = 8
        customRow.addArrangedSubview(peekBadgeWrap)
        customRow.addArrangedSubview(recordPeekBtn)
        customRow.addArrangedSubview(customSpacer)
        customRow.addArrangedSubview(modeControl)
        customRow.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(customRow)
        customRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40).isActive = true

        // Input Monitoring permission banner
        permissionBox.wantsLayer = true
        permissionBox.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.14).cgColor
        permissionBox.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.35).cgColor
        permissionBox.layer?.borderWidth = 1
        permissionBox.layer?.cornerRadius = 9
        permissionBox.translatesAutoresizingMaskIntoConstraints = false
        permissionTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        permissionTitle.textColor = NSColor.systemOrange
        let permBody = makeSubtext("Required by macOS to detect bare modifier keys when other apps are focused. Custom Hotkey works without permission.")
        let permTextStack = NSStackView(views: [permissionTitle, permBody])
        permTextStack.orientation = .vertical
        permTextStack.alignment = .leading
        permTextStack.spacing = 2
        let grantBtn = NSButton(title: "Grant…", target: self, action: #selector(grantPermission(_:)))
        grantBtn.bezelStyle = .rounded
        grantBtn.setContentHuggingPriority(.required, for: .horizontal)
        let permRow = NSStackView(views: [permTextStack, grantBtn])
        permRow.orientation = .horizontal
        permRow.alignment = .centerY
        permRow.spacing = 10
        permRow.translatesAutoresizingMaskIntoConstraints = false
        permissionBox.addSubview(permRow)
        NSLayoutConstraint.activate([
            permRow.topAnchor.constraint(equalTo: permissionBox.topAnchor, constant: 10),
            permRow.bottomAnchor.constraint(equalTo: permissionBox.bottomAnchor, constant: -10),
            permRow.leadingAnchor.constraint(equalTo: permissionBox.leadingAnchor, constant: 12),
            permRow.trailingAnchor.constraint(equalTo: permissionBox.trailingAnchor, constant: -12),
        ])
        rootStack.addArrangedSubview(permissionBox)
        permissionBox.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40).isActive = true

        // Fade Opacity section (presets + continuous slider)
        let opacityLabel = NSTextField(labelWithString: "Fade Opacity")
        opacityLabel.font = .systemFont(ofSize: 12, weight: .medium)
        opacityLabel.textColor = .labelColor
        opacityValueLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        opacityValueLabel.textColor = NSColor(calibratedRed: 0.50, green: 0.85, blue: 0.85, alpha: 1.0)
        let opacitySpacer = NSView()
        opacitySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let opacityTopRow = NSStackView(views: [opacityLabel, opacitySpacer, opacityValueLabel])
        opacityTopRow.orientation = .horizontal
        opacityTopRow.alignment = .centerY
        opacityTopRow.translatesAutoresizingMaskIntoConstraints = false

        opacityPresets.target = self
        opacityPresets.action = #selector(presetChanged(_:))
        opacityPresets.segmentStyle = .rounded
        opacityPresets.translatesAutoresizingMaskIntoConstraints = false

        opacitySlider.target = self
        opacitySlider.action = #selector(sliderChanged(_:))
        opacitySlider.isContinuous = true
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false

        opacitySection.orientation = .vertical
        opacitySection.alignment = .leading
        opacitySection.spacing = 8
        opacitySection.addArrangedSubview(opacityTopRow)
        opacitySection.addArrangedSubview(opacityPresets)
        opacitySection.addArrangedSubview(opacitySlider)
        opacitySection.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(opacitySection)
        NSLayoutConstraint.activate([
            opacitySection.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40),
            opacityTopRow.widthAnchor.constraint(equalTo: opacitySection.widthAnchor),
            opacityPresets.widthAnchor.constraint(equalTo: opacitySection.widthAnchor),
            opacitySlider.widthAnchor.constraint(equalTo: opacitySection.widthAnchor),
        ])

        // Divider
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40).isActive = true

        // Section 2: Show / Hide Window shortcut
        let showHeader = NSStackView(views: [
            makeHeading("Show / Hide Window"),
            makeSubtext("Global shortcut to toggle Float visibility."),
        ])
        showHeader.orientation = .vertical
        showHeader.alignment = .leading
        showHeader.spacing = 2
        let showBadgeWrap = styleBadge(showHideBadge)
        let recordShowBtn = NSButton(title: "Record…", target: self, action: #selector(recordShowHide(_:)))
        recordShowBtn.bezelStyle = .rounded
        let showSpacer = NSView()
        showSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let showRow = NSStackView(views: [showHeader, showSpacer, showBadgeWrap, recordShowBtn])
        showRow.orientation = .horizontal
        showRow.alignment = .centerY
        showRow.spacing = 8
        showRow.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(showRow)
        showRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -40).isActive = true
    }

    func show(relativeTo host: NSWindow?) {
        guard let win = window else { return }
        refresh()
        if !win.isVisible {
            if !win.setFrameUsingName("FloatSettingsWindow") {
                if let vis = (host?.screen ?? NSScreen.main)?.visibleFrame {
                    let s = win.frame.size
                    let origin = NSPoint(
                        x: (vis.midX - s.width / 2).rounded(),
                        y: (vis.midY - s.height / 2).rounded()
                    )
                    win.setFrameOrigin(origin)
                } else {
                    win.center()
                }
            }
            win.setFrameAutosaveName("FloatSettingsWindow")
        }
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refresh() {
        guard let module, let win = window else { return }
        if let idx = triggerKeys.firstIndex(of: module.peekTrigger) {
            triggerControl.selectedSegment = idx
        }
        let isHotkey = module.peekTrigger == "hotkey"
        let isModifier = module.peekTrigger == "rightCommand" || module.peekTrigger == "rightOption"
        customRow.isHidden = !isHotkey
        peekKeyBadge.stringValue = module.peekHotKeyLabel
        modeControl.selectedSegment = module.peekHold ? 0 : 1

        let needsPerm = isModifier && !module.peekPermissionGranted
        permissionBox.isHidden = !needsPerm
        if needsPerm {
            let keyName = module.peekTrigger == "rightCommand" ? "Right ⌘" : "Right ⌥"
            permissionTitle.stringValue = "Enable Input Monitoring for \(keyName)"
        }

        opacitySection.isHidden = module.peekTrigger == "none"
        let pct = Int((module.peekAlpha * 100).rounded())
        opacityValueLabel.stringValue = "\(pct)%"
        opacitySlider.doubleValue = module.peekAlpha
        if let presetIdx = presetValues.firstIndex(where: { Int(($0 * 100).rounded()) == pct }) {
            opacityPresets.selectedSegment = presetIdx
        } else {
            opacityPresets.selectedSegment = -1
        }

        showHideBadge.stringValue = module.hotKeyLabel

        // Fit height cleanly while keeping top-left anchored
        rootStack.layoutSubtreeIfNeeded()
        let fit = rootStack.fittingSize
        let targetH = max(180, fit.height)
        let current = win.contentRect(forFrameRect: win.frame)
        if abs(current.height - targetH) > 1 {
            let newFrame = win.frameRect(forContentRect: NSRect(x: 0, y: 0, width: 460, height: targetH))
            var f = win.frame
            f.origin.y += f.height - newFrame.height
            f.size = newFrame.size
            win.setFrame(f, display: true, animate: win.isVisible)
        }
    }

    func windowWillClose(_ notification: Notification) {
        module?.settingsWindowDidClose()
    }

    @objc private func triggerChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard triggerKeys.indices.contains(idx) else { return }
        module?.setPeekTrigger(triggerKeys[idx])
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        module?.setPeekHold(sender.selectedSegment == 0)
    }

    @objc private func presetChanged(_ sender: NSSegmentedControl) {
        let idx = sender.selectedSegment
        guard presetValues.indices.contains(idx) else { return }
        module?.setPeekAlpha(presetValues[idx])
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let stepped = (sender.doubleValue * 20).rounded() / 20 // 5% steps
        module?.setPeekAlpha(stepped)
    }

    @objc private func recordPeek(_ sender: Any?) {
        module?.recordPeekHotKey()
    }

    @objc private func recordShowHide(_ sender: Any?) {
        module?.recordHotKey()
    }

    @objc private func grantPermission(_ sender: Any?) {
        module?.requestPeekPermission()
    }
}

/// Separate floating Liquid Glass keyboard shortcuts HUD (`?` while Float is focused).
private final class FloatShortcutsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class FloatShortcutsWindowController: NSWindowController, NSWindowDelegate {
    private weak var module: FloatModule?
    private let panelWidth: CGFloat = 760
    private let rootStack = NSStackView()
    private let peekDescLabel = NSTextField(labelWithString: "Quick Fade (50%)")
    private let peekKeyLabel = NSTextField(labelWithString: "Right ⌘")
    private let showHideKeyLabel = NSTextField(labelWithString: "⌃⌥⌘F")

    init(module: FloatModule) {
        self.module = module
        let panel = FloatShortcutsPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 300),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        if #available(macOS 11.0, *) { panel.titlebarSeparatorStyle = .none }
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self
        buildUI()
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func makeKeycap(_ label: NSTextField) -> NSView {
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.96, alpha: 1.0)
        label.alignment = .center
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.cornerRadius = 6
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -2),
        ])
        return pill
    }

    private func makeShortcutRow(titleField: NSTextField, keyField: NSTextField) -> NSView {
        titleField.font = .systemFont(ofSize: 12)
        titleField.textColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        titleField.lineBreakMode = .byTruncatingTail
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [titleField, spacer, makeKeycap(keyField)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func makeShortcutRow(_ title: String, key: String) -> NSView {
        makeShortcutRow(
            titleField: NSTextField(labelWithString: title),
            keyField: NSTextField(labelWithString: key)
        )
    }

    private func makeGroup(_ heading: String, rows: [NSView]) -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        box.layer?.borderColor = NSColor.white.withAlphaComponent(0.11).cgColor
        box.layer?.borderWidth = 1
        box.layer?.cornerRadius = 12
        box.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: heading)
        title.font = .systemFont(ofSize: 10, weight: .semibold)
        title.textColor = NSColor(calibratedRed: 0.50, green: 0.85, blue: 0.85, alpha: 1.0)

        let stack = NSStackView(views: [title] + rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return box
    }

    private func buildUI() {
        guard let panel = window else { return }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 16, right: 16)
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: container.topAnchor),
            rootStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            rootStack.widthAnchor.constraint(equalToConstant: panelWidth),
        ])

        // Header bar
        let title = NSTextField(labelWithString: "Keyboard Shortcuts")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = NSColor(calibratedWhite: 0.96, alpha: 1.0)

        let hintText = NSTextField(labelWithString: "? or Esc")
        hintText.font = .systemFont(ofSize: 10, weight: .medium)
        hintText.textColor = NSColor(calibratedRed: 0.55, green: 0.89, blue: 0.89, alpha: 1.0)
        hintText.translatesAutoresizingMaskIntoConstraints = false
        let hintPill = NSView()
        hintPill.wantsLayer = true
        hintPill.layer?.backgroundColor = NSColor(calibratedRed: 0.25, green: 0.82, blue: 0.82, alpha: 0.16).cgColor
        hintPill.layer?.borderColor = NSColor(calibratedRed: 0.31, green: 0.86, blue: 0.86, alpha: 0.34).cgColor
        hintPill.layer?.borderWidth = 1
        hintPill.layer?.cornerRadius = 9
        hintPill.translatesAutoresizingMaskIntoConstraints = false
        hintPill.addSubview(hintText)
        NSLayoutConstraint.activate([
            hintText.leadingAnchor.constraint(equalTo: hintPill.leadingAnchor, constant: 8),
            hintText.trailingAnchor.constraint(equalTo: hintPill.trailingAnchor, constant: -8),
            hintText.topAnchor.constraint(equalTo: hintPill.topAnchor, constant: 2),
            hintText.bottomAnchor.constraint(equalTo: hintPill.bottomAnchor, constant: -2),
        ])

        let closeBtn = NSButton(title: "×", target: self, action: #selector(closeClicked(_:)))
        closeBtn.isBordered = false
        closeBtn.wantsLayer = true
        closeBtn.font = .systemFont(ofSize: 15, weight: .medium)
        closeBtn.contentTintColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        closeBtn.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        closeBtn.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        closeBtn.layer?.borderWidth = 1
        closeBtn.layer?.cornerRadius = 12
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeBtn.widthAnchor.constraint(equalToConstant: 24),
            closeBtn.heightAnchor.constraint(equalToConstant: 24),
        ])

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headerRow = NSStackView(views: [title, hintPill, headerSpacer, closeBtn])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 8
        headerRow.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -32).isActive = true

        // Subtle divider
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.14).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(divider)
        NSLayoutConstraint.activate([
            divider.heightAnchor.constraint(equalToConstant: 1),
            divider.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -32),
        ])

        // 3 balanced shortcut groups
        let navGroup = makeGroup("NAVIGATION", rows: [
            makeShortcutRow("Open URL or Search", key: "⌘L"),
            makeShortcutRow("Open Clipboard URL", key: "⇧⌘V"),
            makeShortcutRow("Home Mosaic", key: "⇧⌘H"),
            makeShortcutRow("Resume Last Video", key: "⇧⌘R"),
            makeShortcutRow("Back / Forward", key: "⌘[  ⌘]"),
            makeShortcutRow("Reload Page", key: "⌘R"),
        ])

        let videoGroup = makeGroup("VIDEO & WINDOW", rows: [
            makeShortcutRow("Play / Pause", key: "⌃Space"),
            makeShortcutRow("Toggle Video Fill", key: "⇧⌘F"),
            makeShortcutRow("Lock Video Aspect", key: "⇧⌘A"),
            makeShortcutRow("Opacity − / +", key: "⌘−  ⌘="),
            makeShortcutRow("Click-Through", key: "⇧⌘K"),
            makeShortcutRow("Always on Top", key: "⌘T"),
        ])

        let globalGroup = makeGroup("POSITION & GLOBAL", rows: [
            makeShortcutRow("Dock Top / Bottom", key: "⌃⌘1–6"),
            makeShortcutRow(titleField: peekDescLabel, keyField: peekKeyLabel),
            makeShortcutRow(titleField: NSTextField(labelWithString: "Show / Hide Float"), keyField: showHideKeyLabel),
            makeShortcutRow("Settings", key: "⌘,"),
            makeShortcutRow("Drag / Aspect Lock", key: "Top Strip"),
            makeShortcutRow("Keyboard Shortcuts", key: "?"),
        ])

        let columns = NSStackView(views: [navGroup, videoGroup, globalGroup])
        columns.orientation = .horizontal
        columns.distribution = .fillEqually
        columns.alignment = .top
        columns.spacing = 10
        columns.translatesAutoresizingMaskIntoConstraints = false
        rootStack.addArrangedSubview(columns)
        columns.widthAnchor.constraint(equalTo: rootStack.widthAnchor, constant: -32).isActive = true

        // Mount inside native macOS 26 Liquid Glass (window itself owns the native corner mask & rim)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: .zero)
            glass.style = .regular
            glass.tintColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.11, alpha: 0.44)
            glass.contentView = container
            panel.contentView = glass
        } else {
            let fx = NSVisualEffectView(frame: .zero)
            fx.material = .hudWindow
            fx.blendingMode = .behindWindow
            fx.state = .active
            fx.addSubview(container)
            NSLayoutConstraint.activate([
                container.topAnchor.constraint(equalTo: fx.topAnchor),
                container.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
                container.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
                container.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            ])
            panel.contentView = fx
        }
    }

    func show(relativeTo host: NSWindow?) {
        guard let panel = window else { return }
        refresh()
        if !panel.isVisible {
            if let vis = (host?.screen ?? NSScreen.main)?.visibleFrame {
                let s = panel.frame.size
                let origin = NSPoint(
                    x: (vis.midX - s.width / 2).rounded(),
                    y: (vis.midY - s.height / 2).rounded()
                )
                panel.setFrameOrigin(origin)
            } else {
                panel.center()
            }
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                panel.alphaValue = 1
                panel.makeKeyAndOrderFront(nil)
            } else {
                panel.alphaValue = 0
                panel.makeKeyAndOrderFront(nil)
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func hideAnimated() {
        guard let panel = window, panel.isVisible else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
            panel.alphaValue = 1
        })
    }

    func refresh() {
        guard let module, let panel = window else { return }
        let pct = Int((module.peekAlpha * 100).rounded())
        peekDescLabel.stringValue = module.peekTrigger == "none" ? "Quick Fade (Off)" : "Quick Fade (\(pct)%)"
        switch module.peekTrigger {
        case "rightCommand": peekKeyLabel.stringValue = "Right ⌘"
        case "rightOption": peekKeyLabel.stringValue = "Right ⌥"
        case "hotkey": peekKeyLabel.stringValue = module.peekHotKeyLabel
        default: peekKeyLabel.stringValue = "Off"
        }
        showHideKeyLabel.stringValue = module.hotKeyLabel

        rootStack.layoutSubtreeIfNeeded()
        let fit = rootStack.fittingSize
        let size = NSSize(width: max(panelWidth, fit.width.rounded(.up)), height: max(220, fit.height.rounded(.up)))
        if abs(panel.frame.height - size.height) > 1 || abs(panel.frame.width - size.width) > 1 {
            panel.setContentSize(size)
        }
    }

    func windowWillClose(_ notification: Notification) {
        module?.shortcutsWindowDidClose()
    }

    @objc private func closeClicked(_ sender: Any?) {
        module?.setShortcutsOpen(false)
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

/// Target for Float's dedicated Position menu (⌃⌘1–6).
private final class FloatPositionMenuTarget: NSObject {
    weak var module: FloatModule?

    @objc func dock(_ sender: NSMenuItem) {
        module?.dock(sender.tag)
    }
}

final class FloatModule: ExactModule {
    override class var views: [String: ExactNativeFactory] {
        [
            "float-browser": ExactNativeFactory(for: FloatModule.self, firstFrame: true) { mod, _, events in
                FloatBrowserInstance(mod, events)
            },
            "float-drag-strip": ExactNativeFactory(for: FloatModule.self, firstFrame: true) { mod, _, events in
                FloatDragStripInstance(mod, events)
            },
        ]
    }

    private let store: FloatStore
    private let sparkle: SparkleBridge
    private weak var hostWindow: NSWindow?
    private weak var browser: FloatBrowserInstance?
    private var homeBackdropView: NSView?
    private var lastBackdropIsHome: Bool?
    private var settingsWindow: FloatSettingsWindowController?
    private var shortcutsWindow: FloatShortcutsWindowController?
    private var hotKeyRef: EventHotKeyRef?
    private var peekHotKeyRef: EventHotKeyRef?
    private var peekGlobalFlagsMonitor: Any?
    private var peekLocalFlagsMonitor: Any?
    private var activeObserver: NSObjectProtocol?
    private var controlSpaceMonitor: Any?
    private let positionTarget = FloatPositionMenuTarget()
    private var positionMenuItem: NSMenuItem?
    private var pendingUrlLoad: String?
    private var cliHandled = false
    private var lastSelectSeq: String?

    var mode = "home"
    var currentUrl = ""
    var fill: Bool
    var onTop = true
    var aspectLocked = false
    var clickThrough = false
    var alpha: Double
    var peekTrigger: String
    var peekAlpha: Double
    var peekHold: Bool
    var peeking = false
    var settingsOpen = false
    var shortcutsOpen = false
    var webEditingText = false
    var pendingSeek: Double?

    var hotKeyLabel: String { store.hotKey?.label ?? "None" }
    var peekHotKeyLabel: String { store.peekHotKey?.label ?? "None" }
    var peekPermissionGranted: Bool { context.agent ? true : hasInputMonitoringPermission() }

    required init(context: ExactModuleContext) {
        store = FloatStore(agent: context.agent, dataDir: context.data)
        sparkle = SparkleBridge()
        fill = store.fill
        alpha = store.alpha
        peekTrigger = store.peekTrigger
        peekAlpha = min(0.95, max(0.15, store.peekAlpha))
        peekHold = store.peekHold
        super.init(context: context)
        positionTarget.module = self
        if !context.agent {
            FloatHotKeyCenter.shared.active = self
            FloatHotKeyCenter.shared.installIfNeeded()
            registerHotKey()
            installPeekTrigger()
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.installPeekTrigger()
                self.notifyChanged()
            }
        }
    }

    override func destroy() {
        homeBackdropView?.removeFromSuperview()
        homeBackdropView = nil
        lastBackdropIsHome = nil
        settingsWindow?.close()
        settingsWindow = nil
        shortcutsWindow?.close()
        shortcutsWindow = nil
        unregisterHotKey()
        teardownPeekTrigger()
        if let obs = activeObserver {
            NotificationCenter.default.removeObserver(obs)
            activeObserver = nil
        }
        if let mon = controlSpaceMonitor {
            NSEvent.removeMonitor(mon)
            controlSpaceMonitor = nil
        }
        if let item = positionMenuItem {
            item.menu?.removeItem(item)
            positionMenuItem = nil
        }
        if FloatHotKeyCenter.shared.active === self {
            FloatHotKeyCenter.shared.active = nil
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
        syncWindowBackdrop()
        settingsWindow?.refresh()
        shortcutsWindow?.refresh()
        context.changed("float")
    }

    // MARK: Window & Element Hatches

    override func window(_ exactWindow: ExactWindow) {
        guard let w = exactWindow.window else { return }
        hostWindow = w
        // Only apply initial window chrome and restore saved frame once — never on resize callbacks!
        if exactWindow.isNew {
            configureChromelessWindow(w)
            installPositionMenu()
            installControlSpaceMonitor()
            if !cliHandled, !context.agent, ProcessInfo.processInfo.environment["EXACT_SMOKE"] != "1" {
                cliHandled = true
                if let arg = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
                    load(arg)
                }
            }
        } else {
            syncWindowBackdrop()
        }
    }

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

    private func configureChromelessWindow(_ w: NSWindow) {
        if !w.styleMask.contains(.fullSizeContentView) { w.styleMask.insert(.fullSizeContentView) }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        if #available(macOS 11.0, *) { w.titlebarSeparatorStyle = .none }
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { w.standardWindowButton($0)?.isHidden = true }
        w.appearance = NSAppearance(named: .darkAqua)
        w.hasShadow = true
        w.level = onTop ? .floating : .normal
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.minSize = NSSize(width: 160, height: 90)
        w.alphaValue = CGFloat(alpha)
        w.ignoresMouseEvents = clickThrough
        syncWindowBackdrop()
        if !context.agent {
            // Preserve existing Float users' saved window position & size
            w.setFrameUsingName("FloatWindow")
            w.setFrameAutosaveName("FloatWindow")
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

    private func syncWindowBackdrop() {
        let isHome = (mode == "home")
        browser?.web.isHidden = isHome
        guard let w = hostWindow else { return }
        installHomeBackdrop(in: w)
        homeBackdropView?.isHidden = !isHome
        if let content = w.contentView {
            for sub in content.subviews {
                if let scroll = sub as? NSScrollView {
                    if scroll.drawsBackground != !isHome {
                        scroll.drawsBackground = !isHome
                    }
                    scroll.backgroundColor = isHome ? .clear : .black
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

    private func installPositionMenu() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Display ⌃Space beside View › Play / Pause (ShortcutHost only populates Command equivalents)
        if let viewMenu = mainMenu.items.first(where: { $0.submenu?.title == "View" })?.submenu,
           let playItem = viewMenu.items.first(where: { $0.title == "Play / Pause" }) {
            playItem.keyEquivalent = " "
            playItem.keyEquivalentModifierMask = .control
        }
        if let existing = positionMenuItem, existing.menu === mainMenu { return }
        let posMenu = NSMenu(title: "Position")
        let titles = ["Top Left", "Top Center", "Top Right", "Bottom Left", "Bottom Center", "Bottom Right"]
        for (i, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(FloatPositionMenuTarget.dock(_:)), keyEquivalent: "\(i + 1)")
            item.keyEquivalentModifierMask = [.control, .command]
            item.tag = i
            item.target = positionTarget
            posMenu.addItem(item)
        }
        let host = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        host.submenu = posMenu
        let viewIndex = mainMenu.items.firstIndex { $0.submenu?.title == "View" }
        let insertAt = viewIndex.map { $0 + 1 } ?? mainMenu.numberOfItems
        mainMenu.insertItem(host, at: min(insertAt, mainMenu.numberOfItems))
        positionMenuItem = host
    }

    private func installControlSpaceMonitor() {
        guard controlSpaceMonitor == nil else { return }
        controlSpaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let isHost = self.hostWindow != nil && event.window === self.hostWindow
            let isShortcuts = self.shortcutsWindow?.window != nil && event.window === self.shortcutsWindow?.window
            guard isHost || isShortcuts else { return event }
            let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if isHost, mods == .control, event.keyCode == UInt16(kVK_Space) {
                self.playPause()
                return nil
            }
            if self.shortcutsOpen, event.keyCode == UInt16(kVK_Escape), mods.isEmpty {
                self.setShortcutsOpen(false)
                return nil
            }
            if event.characters == "?", mods.intersection([.command, .control, .option]).isEmpty {
                if isHost, let win = self.hostWindow, win.firstResponder is NSText { return event }
                if isHost, self.mode == "web", self.webEditingText { return event }
                self.setShortcutsOpen(!self.shortcutsOpen)
                return nil
            }
            return event
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
        case "openClipboard": openClipboard()
        case "reloadPage": reloadPage()
        case "back": browser?.web.goBack()
        case "forward": browser?.web.goForward()
        case "toggleFill": toggleFill()
        case "toggleAspectLock": toggleAspectLock()
        case "toggleTop": toggleTop()
        case "toggleClickThrough": toggleClickThrough()
        case "fadeOut": fadeOut()
        case "fadeIn": fadeIn()
        case "playPause": playPause()
        case "dock": dock(Int(arg) ?? 0)
        case "openSettings": openSettings()
        case "closeSettings": closeSettings()
        case "toggleShortcuts": setShortcutsOpen(!shortcutsOpen)
        case "closeShortcuts": setShortcutsOpen(false)
        case "recordHotKey": recordHotKey()
        case "setPeekTrigger": setPeekTrigger(arg)
        case "setPeekAlpha": setPeekAlpha(Double(arg) ?? peekAlpha)
        case "setPeekHold": setPeekHold(arg == "true")
        case "setPeeking": setPeeking(arg == "true")
        case "recordPeekHotKey": recordPeekHotKey()
        case "requestPeekPermission": requestPeekPermission()
        case "checkForUpdates": sparkle.checkForUpdates()
        case "focusWeb": focusWeb()
        case "recordPlayback": recordPlaybackFromTest(arg)
        default: throw ExactNativeRefusal("unknown op \(op)")
        }
        return ["ok": true]
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
            "aspectLocked": aspectLocked,
            "clickThrough": clickThrough,
            "alpha": (alpha * 100).rounded() / 100,
            "hotkeyLabel": store.hotKey?.label ?? "",
            "peekTrigger": peekTrigger,
            "peekAlpha": (peekAlpha * 100).rounded() / 100,
            "peekHotkeyLabel": store.peekHotKey?.label ?? "",
            "peekHold": peekHold,
            "peeking": peeking,
            "settingsOpen": settingsOpen,
            "shortcutsOpen": shortcutsOpen,
            "peekPermissionGranted": peekPermissionGranted,
            "canCheckUpdates": sparkle.canCheckForUpdates,
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
        if let browser {
            if !context.agent {
                browser.loadRequest(url)
                hostWindow?.makeFirstResponder(browser.web)
            }
        } else {
            pendingUrlLoad = url.absoluteString
        }
        notifyChanged()
    }

    func focusWeb() {
        if let browser { hostWindow?.makeFirstResponder(browser.web) }
    }

    func showHome() {
        mode = "home"
        webEditingText = false
        pendingSeek = nil
        if !context.agent { browser?.loadBlank() }
        notifyChanged()
    }

    func resumeLast() {
        guard let r = store.loadResume() else { return }
        let target = URL(string: r.url).map { floatAppleTVResumeURL($0).absoluteString } ?? r.url
        load(target)
        pendingSeek = r.time > 0 ? r.time : nil
    }

    func openClipboard() {
        if let str = NSPasteboard.general.string(forType: .string) {
            load(str)
        }
    }

    func reloadPage() {
        if mode == "web", let web = browser?.web, web.url?.scheme?.hasPrefix("http") == true {
            web.reload()
        } else {
            showHome()
        }
    }

    func toggleFill() {
        fill.toggle()
        store.fill = fill
        browser?.applyFill(fill)
        notifyChanged()
    }

    func toggleAspectLock() {
        if aspectLocked {
            aspectLocked = false
            hostWindow?.contentResizeIncrements = NSSize(width: 1, height: 1)
            notifyChanged()
            return
        }
        if context.agent {
            aspectLocked = true
            notifyChanged()
            return
        }
        guard let web = browser?.web else { return }
        let js = "(() => { const v=[...document.querySelectorAll('video')].sort((a,b)=>b.videoWidth*b.videoHeight-a.videoWidth*a.videoHeight)[0]; return v && v.videoWidth ? [v.videoWidth, v.videoHeight] : null })()"
        web.evaluateJavaScript(js) { [weak self] r, _ in
            guard let self, let window = self.hostWindow, let d = r as? [Double], d.count == 2, d[1] > 0 else { return }
            var f = window.frame
            let h = (f.width * d[1] / d[0]).rounded()
            f.origin.y += f.height - h
            f.size.height = h
            window.setFrame(f, display: true, animate: true)
            window.contentAspectRatio = NSSize(width: d[0], height: d[1])
            self.aspectLocked = true
            self.notifyChanged()
        }
    }

    func toggleTop() {
        onTop.toggle()
        hostWindow?.level = onTop ? .floating : .normal
        notifyChanged()
    }

    func toggleClickThrough() {
        clickThrough.toggle()
        hostWindow?.ignoresMouseEvents = clickThrough
        if clickThrough && alpha > 0.6 {
            setAlpha(0.6)
        } else {
            notifyChanged()
        }
    }

    private func applyEffectiveAlpha(animated: Bool = true) {
        guard let window = hostWindow else { return }
        let target = CGFloat(peeking ? min(alpha, peekAlpha) : alpha)
        if !animated || context.agent || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.alphaValue = target
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = target
            }
        }
    }

    func setAlpha(_ value: Double) {
        alpha = min(1.0, max(0.15, value))
        store.alpha = alpha
        applyEffectiveAlpha()
        notifyChanged()
    }

    func fadeOut() { setAlpha(alpha - 0.1) }
    func fadeIn() { setAlpha(alpha + 0.1) }

    func openSettings() {
        setShortcutsOpen(false)
        settingsOpen = true
        if !context.agent {
            if settingsWindow == nil {
                settingsWindow = FloatSettingsWindowController(module: self)
            }
            settingsWindow?.show(relativeTo: hostWindow)
        }
        notifyChanged()
    }

    func setShortcutsOpen(_ open: Bool) {
        guard shortcutsOpen != open else { return }
        shortcutsOpen = open
        if !context.agent {
            if open {
                if shortcutsWindow == nil {
                    shortcutsWindow = FloatShortcutsWindowController(module: self)
                }
                shortcutsWindow?.show(relativeTo: hostWindow)
            } else {
                shortcutsWindow?.hideAnimated()
            }
        }
        notifyChanged()
    }

    func shortcutsWindowDidClose() {
        guard shortcutsOpen else { return }
        shortcutsOpen = false
        notifyChanged()
    }

    func closeSettings() {
        settingsOpen = false
        if !context.agent {
            settingsWindow?.close()
        }
        notifyChanged()
    }

    func settingsWindowDidClose() {
        guard settingsOpen else { return }
        settingsOpen = false
        notifyChanged()
    }

    func setPeeking(_ active: Bool) {
        guard peeking != active else { return }
        peeking = active
        applyEffectiveAlpha()
        notifyChanged()
    }

    func setPeekTrigger(_ trigger: String) {
        let valid = ["rightCommand", "rightOption", "hotkey", "none"]
        guard valid.contains(trigger) else { return }
        peekTrigger = trigger
        store.peekTrigger = trigger
        if peeking {
            peeking = false
            applyEffectiveAlpha()
        }
        if !context.agent {
            installPeekTrigger()
        }
        notifyChanged()
    }

    func setPeekAlpha(_ value: Double) {
        let clamped = (min(0.95, max(0.15, value)) * 100).rounded() / 100
        peekAlpha = clamped
        store.peekAlpha = clamped
        if peeking {
            applyEffectiveAlpha()
        }
        notifyChanged()
    }

    func setPeekHold(_ hold: Bool) {
        peekHold = hold
        store.peekHold = hold
        if peeking {
            peeking = false
            applyEffectiveAlpha()
        }
        notifyChanged()
    }

    func peekHotKeyPressed() {
        guard peekTrigger == "hotkey" else { return }
        if peekHold {
            setPeeking(true)
        } else {
            setPeeking(!peeking)
        }
    }

    func peekHotKeyReleased() {
        guard peekTrigger == "hotkey", peekHold else { return }
        setPeeking(false)
    }

    private func hasInputMonitoringPermission() -> Bool {
        CGPreflightListenEventAccess() || AXIsProcessTrusted()
    }

    func requestPeekPermission() {
        guard !context.agent else { return }
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        notifyChanged()
    }

    private func teardownPeekTrigger() {
        if let r = peekHotKeyRef { UnregisterEventHotKey(r) }
        peekHotKeyRef = nil
        if let m = peekGlobalFlagsMonitor {
            NSEvent.removeMonitor(m)
            peekGlobalFlagsMonitor = nil
        }
        if let m = peekLocalFlagsMonitor {
            NSEvent.removeMonitor(m)
            peekLocalFlagsMonitor = nil
        }
    }

    private func installPeekTrigger() {
        teardownPeekTrigger()
        switch peekTrigger {
        case "rightCommand", "rightOption":
            let mask: UInt = peekTrigger == "rightCommand" ? floatRightCommandMask : floatRightOptionMask
            peekGlobalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let held = (event.modifierFlags.rawValue & mask) != 0
                DispatchQueue.main.async { self?.setPeeking(held) }
            }
            peekLocalFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                let held = (event.modifierFlags.rawValue & mask) != 0
                self?.setPeeking(held)
                return event
            }
        case "hotkey":
            guard let k = store.peekHotKey else { return }
            let st = RegisterEventHotKey(
                k.code, k.mods,
                EventHotKeyID(signature: OSType(0x464C5454), id: 2),
                GetApplicationEventTarget(), 0, &peekHotKeyRef
            )
            if st != noErr, !context.agent {
                let a = NSAlert()
                a.messageText = "\(k.label) is taken by another app"
                a.informativeText = "Pick another Quick Fade shortcut in Float › Settings…"
                a.runModal()
            }
        default:
            break
        }
    }

    func recordPeekHotKey() {
        guard !context.agent else { return }
        teardownPeekTrigger()
        let a = NSAlert()
        a.messageText = "Press the new quick-fade shortcut"
        a.informativeText = "Current: \(store.peekHotKey?.label ?? "None"). Use ⌘, ⌃ or ⌥. ⌫ clears, Esc cancels."
        a.addButton(withTitle: "Cancel")
        let mon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return nil }
            switch Int(e.keyCode) {
            case kVK_Escape:
                NSApp.stopModal()
            case kVK_Delete where e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
                self.store.peekHotKey = nil
                NSApp.stopModal()
            default:
                guard let k = FloatHotKey(e) else { NSSound.beep(); return nil }
                self.store.peekHotKey = k
                NSApp.stopModal()
            }
            return nil
        }
        a.runModal()
        if let mon { NSEvent.removeMonitor(mon) }
        installPeekTrigger()
        notifyChanged()
    }

    func playPause() {
        browser?.web.evaluateJavaScript("(() => { const v=[...document.querySelectorAll('video')].find(v=>v.currentSrc); if(v){ v.paused ? v.play() : v.pause(); } })()")
    }

    // tag 0–2: top left/center/right, 3–5: bottom left/center/right
    func dock(_ tag: Int) {
        guard (0...5).contains(tag), let window = hostWindow, let vis = window.screen?.visibleFrame else { return }
        let m: CGFloat = 12
        let f = window.frame
        let x = [vis.minX + m, vis.midX - f.width / 2, vis.maxX - f.width - m][tag % 3]
        let y = tag < 3 ? vis.maxY - f.height - m : vis.minY + m
        window.setFrame(NSRect(x: x, y: y, width: f.width, height: f.height), display: true, animate: true)
    }

    func toggleShown() {
        guard let window = hostWindow else { return }
        if NSApp.isHidden || !window.isVisible {
            NSApp.unhide(nil)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            NSApp.hide(nil)
        }
    }

    // MARK: Global Hotkey

    private func unregisterHotKey() {
        if let r = hotKeyRef { UnregisterEventHotKey(r) }
        hotKeyRef = nil
    }

    private func registerHotKey() {
        unregisterHotKey()
        guard let k = store.hotKey else { return }
        let st = RegisterEventHotKey(
            k.code, k.mods,
            EventHotKeyID(signature: OSType(0x464C5454), id: 1),
            GetApplicationEventTarget(), 0, &hotKeyRef
        )
        if st != noErr, !context.agent {
            let a = NSAlert()
            a.messageText = "\(k.label) is taken by another app"
            a.informativeText = "Pick another in Float › Show/Hide Hotkey…"
            a.runModal()
        }
    }

    // Next ⌘/⌃/⌥ combo becomes the hotkey; ⌫ clears it, Esc cancels
    func recordHotKey() {
        guard !context.agent else { return }
        unregisterHotKey()
        let a = NSAlert()
        a.messageText = "Press the new show/hide shortcut"
        a.informativeText = "Current: \(store.hotKey?.label ?? "None"). Use ⌘, ⌃ or ⌥. ⌫ clears, Esc cancels."
        a.addButton(withTitle: "Cancel")
        let mon = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return nil }
            switch Int(e.keyCode) {
            case kVK_Escape:
                NSApp.stopModal()
            case kVK_Delete where e.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
                self.store.hotKey = nil
                NSApp.stopModal()
            default:
                guard let k = FloatHotKey(e) else { NSSound.beep(); return nil }
                self.store.hotKey = k
                NSApp.stopModal()
            }
            return nil
        }
        a.runModal()
        if let mon { NSEvent.removeMonitor(mon) }
        registerHotKey()
        notifyChanged()
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
