import Cocoa
import WebKit

let defaults = UserDefaults.standard
let safariUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

// pins the main video's player (video + site controls) to the window; works on any site
func fillScript(_ on: Bool) -> String { """
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
  // main video: largest one actually playing (layout has settled by then), ignoring small previews
  const main = () => [...document.querySelectorAll('video')]
    .filter(v => v.currentSrc && v.currentTime > 0 && v.offsetWidth * v.offsetHeight > innerWidth * innerHeight * 0.15)
    .sort((a, b) => b.offsetWidth * b.offsetHeight - a.offsetWidth * a.offsetHeight)[0];
  // outermost ancestor still hugging the video: matches one axis, fits the viewport on the other (letterboxing)
  function player(v) {
    const r = v.getBoundingClientRect();
    let p = v;
    for (let e = v.parentElement; e && e !== document.body; e = e.parentElement) {
      const b = e.getBoundingClientRect();
      if (!b.width || !b.height) continue; // collapsed wrappers
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
    // stretch wrappers between player and video; resize lets site players re-layout controls
    for (let e = v; e && e !== p; e = e.parentElement) e.setAttribute('data-fp-path', '');
    dispatchEvent(new Event('resize'));
  }
  apply();
  clearInterval(window.__fpTimer);
  if (ON) window.__fpTimer = setInterval(apply, 1000);
})();
""" }

final class PlayerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class DragStrip: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        alphaValue = 0
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseEntered(with e: NSEvent) { animator().alphaValue = 1 }
    override func mouseExited(with e: NSEvent) { animator().alphaValue = 0 }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { (NSApp.delegate as? AppDelegate)?.toggleAspectLock(); return }
        window?.performDrag(with: e)
    }
    override var mouseDownCanMoveWindow: Bool { true }
}

struct Site: Codable {
    var host: String
    var url: String
    var icon: String?
    var last: Date
    var count: Int
}

enum SiteStore {
    static func all() -> [Site] {
        guard let d = defaults.data(forKey: "sites") else { return [] }
        return (try? JSONDecoder().decode([Site].self, from: d)) ?? []
    }
    static func save(_ s: [Site]) { defaults.set(try! JSONEncoder().encode(s), forKey: "sites") }
    static func record(_ url: URL, icon: String?) {
        guard let host = url.host, let scheme = url.scheme, scheme.hasPrefix("http") else { return }
        var s = all()
        if let i = s.firstIndex(where: { $0.host == host }) {
            s[i].last = Date(); s[i].count += 1
            if icon != nil { s[i].icon = icon }
        } else {
            s.append(Site(host: host, url: "\(scheme)://\(host)", icon: icon, last: Date(), count: 1))
        }
        save(s)
    }
    static func remove(_ host: String) { save(all().filter { $0.host != host }) }
}

struct Resume: Codable {
    var url: String
    var title: String
    var time: Double
    var duration: Double
}

enum ResumeStore {
    static func load() -> Resume? {
        defaults.data(forKey: "resume").flatMap { try? JSONDecoder().decode(Resume.self, from: $0) }
    }
    static func save(_ r: Resume) { defaults.set(try! JSONEncoder().encode(r), forKey: "resume") }
}

// "Unabomber | Netflix" → "Unabomber"
func cleanTitle(_ title: String, host: String) -> String {
    for sep in [" | ", " - ", " – "] {
        if let r = title.range(of: sep, options: .backwards),
           title[r.upperBound...].lowercased().contains(siteName(host).lowercased()) {
            return String(title[..<r.lowerBound]).replacingOccurrences(of: "Watch ", with: "", options: .anchored)
        }
    }
    return title
}

let trackScript = """
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

// best title for what's playing: Netflix player overlay → Media Session → og:title → document title
let titleScript = """
(() => {
  const nf = document.querySelector('[data-uia="video-title"]');
  if (nf) return [...nf.children].map(e => e.textContent.trim()).filter(Boolean).join(' · ') || nf.textContent.trim();
  const ms = navigator.mediaSession && navigator.mediaSession.metadata;
  if (ms && ms.title) return ms.artist ? `${ms.title} · ${ms.artist}` : ms.title;
  const og = document.querySelector('meta[property="og:title"]');
  return (og && og.content) || document.title;
})()
"""

let iconScript = """
(() => {
  const size = l => parseInt(((l.sizes && l.sizes.value) || '0').split('x')[0]) || (l.rel.includes('apple') ? 180 : 16);
  const l = [...document.querySelectorAll('link[rel~="icon"],link[rel^="apple-touch-icon"]')].sort((a, b) => size(b) - size(a));
  return l[0] ? l[0].href : location.origin + '/favicon.ico';
})()
"""

func isWeb(_ u: URL) -> Bool { ["http", "https"].contains(u.scheme?.lowercased() ?? "") }

func siteName(_ host: String) -> String {
    let parts = host.split(separator: ".").filter { !["www", "m", "watch", "play", "app"].contains($0) }
    let core = parts.count > 1 ? parts[parts.count - 2] : (parts.first ?? Substring(host))
    return core.prefix(1).uppercased() + core.dropFirst()
}

// JSON safe to inline in <script>: escape '<' so titles can't alter HTML tokenizing ('/' already escaped)
func scriptJSON(_ o: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: o), encoding: .utf8)!.replacingOccurrences(of: "<", with: "\\u003C")
}

// token: per-load secret so only this page can issue float-* commands
func homeHTML(_ sites: [Site], resume: Resume?, token: String) -> String {
    let icon = { (s: Site) in s.icon ?? "\(s.url)/favicon.ico" }
    let tiles = sites.sorted { $0.last > $1.last }.map {
        ["host": $0.host, "url": $0.url, "icon": icon($0), "name": siteName($0.host)]
    }
    let json = scriptJSON(tiles)
    var resumeObj: [String: Any] = [:]
    if let r = resume, let host = URL(string: r.url)?.host {
        resumeObj = ["title": r.title.isEmpty ? siteName(host) : r.title, "host": host, "t": r.time, "d": r.duration,
                     "icon": sites.first { $0.host == host }.map(icon) ?? "https://\(host)/favicon.ico"]
    }
    let resumeJSON = scriptJSON(resumeObj)
    return """
<!doctype html><html><head><meta charset="utf-8"><style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body { margin: 0; min-height: 100vh; background: radial-gradient(120% 90% at 50% 0%, #1c1d22 0%, #0b0b0d 70%);
         font: 13px -apple-system, system-ui, sans-serif; color: #e8e8ea; padding: 30px 16px 16px; -webkit-user-select: none; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(112px, 1fr)); gap: 12px; }
  a.tile { position: relative; aspect-ratio: 16/10; border-radius: 12px; background: rgba(255,255,255,.06);
           border: 1px solid rgba(255,255,255,.08); display: flex; flex-direction: column; align-items: center;
           justify-content: center; gap: 8px; color: inherit; text-decoration: none; transition: transform .15s, background .15s; }
  a.tile:hover { background: rgba(255,255,255,.12); transform: scale(1.03); }
  .icon { width: 40px; height: 40px; border-radius: 9px; object-fit: contain; }
  .letter { width: 40px; height: 40px; border-radius: 9px; display: grid; place-items: center;
            font-size: 20px; font-weight: 600; background: #2c2d33; }
  .name { font-weight: 500; max-width: 90%; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .x { position: absolute; top: 5px; right: 5px; width: 20px; height: 20px; border-radius: 10px; display: none;
       place-items: center; background: rgba(0,0,0,.6); color: #bbb; font-size: 13px; text-decoration: none; }
  a.tile:hover .x { display: grid; }
  .x:hover { color: #fff; background: rgba(0,0,0,.9); }
  .empty { position: fixed; inset: 0; display: grid; place-items: center; text-align: center; color: #8a8a90; line-height: 1.6; }
  kbd { font: inherit; padding: 1px 6px; border-radius: 5px; background: #2c2d33; color: #ddd; }
  a.resume { display: flex; align-items: center; gap: 14px; margin-bottom: 14px; padding: 14px 16px; border-radius: 14px;
             color: inherit; text-decoration: none; background: linear-gradient(135deg, rgba(20,160,160,.28), rgba(255,255,255,.05));
             border: 1px solid rgba(80,220,220,.25); transition: background .15s; }
  a.resume:hover { background: linear-gradient(135deg, rgba(20,160,160,.42), rgba(255,255,255,.08)); }
  .resume .icon { flex: none; }
  .resume .meta { min-width: 0; flex: 1; }
  .resume .label { font-size: 11px; text-transform: uppercase; letter-spacing: .08em; color: #7fd8d8; }
  .resume .title { font-size: 15px; font-weight: 600; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; margin: 2px 0; }
  .resume .sub { color: #9a9aa0; font-size: 12px; }
  .bar { height: 3px; border-radius: 2px; background: rgba(255,255,255,.12); margin-top: 8px; overflow: hidden; }
  .bar > i { display: block; height: 100%; background: #3fd0d0; }
  .play { flex: none; width: 34px; height: 34px; border-radius: 17px; background: #3fd0d0; color: #062424;
          display: grid; place-items: center; font-size: 14px; padding-left: 3px; }
</style></head><body><div id="r"></div><div class="grid" id="g"></div><script>
  const sites = \(json);
  const resume = \(resumeJSON);
  const g = document.getElementById('g');
  const fmt = s => { s = Math.floor(s); const h = Math.floor(s / 3600), m = Math.floor(s % 3600 / 60), x = String(s % 60).padStart(2, '0');
    return h ? `${h}:${String(m).padStart(2, '0')}:${x}` : `${m}:${x}`; };
  if (resume.host) {
    const a = document.createElement('a'); a.className = 'resume'; a.href = 'float-resume:\(token)';
    const img = document.createElement('img'); img.className = 'icon'; img.src = resume.icon;
    img.onerror = () => img.remove();
    const meta = document.createElement('div'); meta.className = 'meta';
    const label = document.createElement('div'); label.className = 'label'; label.textContent = 'Resume';
    const title = document.createElement('div'); title.className = 'title'; title.textContent = resume.title;
    const sub = document.createElement('div'); sub.className = 'sub';
    sub.textContent = resume.d ? `${fmt(resume.t)} of ${fmt(resume.d)} · ${resume.host}` : resume.host;
    meta.append(label, title, sub);
    if (resume.d) { const bar = document.createElement('div'); bar.className = 'bar'; const i = document.createElement('i');
      i.style.width = Math.min(100, resume.t / resume.d * 100) + '%'; bar.append(i); meta.append(bar); }
    const play = document.createElement('div'); play.className = 'play'; play.textContent = '▶';
    a.append(img, meta, play); document.getElementById('r').append(a);
  }
  if (!sites.length && !resume.host) {
    document.body.innerHTML = '<div class="empty"><div>Video sites you watch will show up here.<br>Press <kbd>⌘L</kbd> to open a URL.</div></div>';
  }
  for (const s of sites) {
    const a = document.createElement('a'); a.className = 'tile'; a.href = s.url; a.title = s.host;
    const img = document.createElement('img'); img.className = 'icon'; img.src = s.icon;
    img.onerror = () => { const d = document.createElement('div'); d.className = 'letter'; d.textContent = s.name[0]; img.replaceWith(d); };
    const n = document.createElement('div'); n.className = 'name'; n.textContent = s.name;
    const x = document.createElement('a'); x.className = 'x'; x.textContent = '×'; x.title = 'Remove';
    x.href = 'float-remove:\(token)/' + encodeURIComponent(s.host);
    a.append(img, n, x); g.append(a);
  }
</script></body></html>
"""
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSMenuItemValidation {
    var window: PlayerWindow!
    var web: WKWebView!
    var urlField: NSTextField!
    var fill = defaults.object(forKey: "fill") as? Bool ?? true
    var onTop = true
    var aspectLocked = false
    var pendingSeek: Double?
    var homeToken = ""
    // tracking script + fpPlay bridge live here; page JS can't reach them to forge messages
    let trackWorld = WKContentWorld.world(name: "float-track")

    func applicationDidFinishLaunching(_ n: Notification) {
        buildMenu()

        window = PlayerWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                              styleMask: [.titled, .resizable, .closable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        window.backgroundColor = .black
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.minSize = NSSize(width: 160, height: 90)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("FloatWindow")
        window.alphaValue = CGFloat(defaults.object(forKey: "alpha") as? Double ?? 1)

        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.preferences.isElementFullscreenEnabled = true
        cfg.websiteDataStore = .default()
        web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = safariUA
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.allowsMagnification = true
        web.setValue(false, forKey: "drawsBackground")
        installFillScript()
        cfg.userContentController.add(self, contentWorld: trackWorld, name: "fpPlay")

        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = root
        web.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(web)

        let strip = DragStrip(frame: .zero)
        strip.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(strip)

        urlField = NSTextField()
        urlField.translatesAutoresizingMaskIntoConstraints = false
        urlField.placeholderString = "URL or search — Enter to go, Esc to cancel"
        urlField.font = .systemFont(ofSize: 13)
        urlField.bezelStyle = .roundedBezel
        urlField.focusRingType = .none
        urlField.delegate = self
        urlField.isHidden = true
        root.addSubview(urlField)

        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            web.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            web.topAnchor.constraint(equalTo: root.topAnchor),
            web.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.topAnchor.constraint(equalTo: root.topAnchor),
            strip.heightAnchor.constraint(equalToConstant: 18),
            urlField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            urlField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            urlField.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
        ])

        // one-time migration from pre-mosaic builds
        if let last = defaults.string(forKey: "lastURL"), let u = URL(string: last) {
            SiteStore.record(u, icon: nil)
            ResumeStore.save(Resume(url: last, title: "", time: 0, duration: 0))
            defaults.removeObject(forKey: "lastURL")
        }

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if let arg = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) { load(arg) } else { showHome() }
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        urls.first.map { load($0.absoluteString) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    // MARK: menu
    func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [(String, String, NSEvent.ModifierFlags, Selector?)]) {
            let m = NSMenu(title: title)
            for (t, k, mods, sel) in items {
                if t == "-" { m.addItem(.separator()); continue }
                let i = NSMenuItem(title: t, action: sel, keyEquivalent: k)
                i.keyEquivalentModifierMask = mods
                m.addItem(i)
            }
            let host = NSMenuItem(); host.submenu = m; main.addItem(host)
        }
        sub("Float", [
            ("Hide Float", "h", .command, #selector(NSApplication.hide(_:))),
            ("Quit Float", "q", .command, #selector(NSApplication.terminate(_:))),
        ])
        sub("Edit", [
            ("Undo", "z", .command, Selector(("undo:"))),
            ("Cut", "x", .command, #selector(NSText.cut(_:))),
            ("Copy", "c", .command, #selector(NSText.copy(_:))),
            ("Paste", "v", .command, #selector(NSText.paste(_:))),
            ("Select All", "a", .command, #selector(NSText.selectAll(_:))),
        ])
        sub("View", [
            ("Home", "h", [.command, .shift], #selector(showHome)),
            ("Resume Last", "r", [.command, .shift], #selector(resumeLast)),
            ("Open Location…", "l", .command, #selector(showURL)),
            ("Open URL from Clipboard", "v", [.command, .shift], #selector(openClipboard)),
            ("Reload", "r", .command, #selector(reloadPage)),
            ("Back", "[", .command, #selector(back)),
            ("Forward", "]", .command, #selector(forward)),
            ("-", "", [], nil),
            ("Toggle Video Fill", "f", [.command, .shift], #selector(toggleFill)),
            ("Lock to Video Aspect", "a", [.command, .shift], #selector(toggleAspectLock)),
            ("Toggle Always on Top", "t", .command, #selector(toggleTop)),
            ("Toggle Click-Through", "k", [.command, .shift], #selector(toggleClickThrough)),
            ("More Transparent", "-", .command, #selector(fadeOut)),
            ("Less Transparent", "=", .command, #selector(fadeIn)),
            ("-", "", [], nil),
            ("Play / Pause", " ", .control, #selector(playPause)),
            ("Close", "w", .command, #selector(NSWindow.performClose(_:))),
        ])
        let pos = NSMenu(title: "Position")
        for (i, t) in ["Top Left", "Top Center", "Top Right", "Bottom Left", "Bottom Center", "Bottom Right"].enumerated() {
            let item = NSMenuItem(title: t, action: #selector(dock(_:)), keyEquivalent: "\(i + 1)")
            item.keyEquivalentModifierMask = [.control, .command]
            item.tag = i
            pos.addItem(item)
        }
        let posHost = NSMenuItem(); posHost.submenu = pos; main.addItem(posHost)
        NSApp.mainMenu = main
    }

    // MARK: actions
    func load(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        let url: URL?
        if s.contains("://") { url = URL(string: s) }
        else if s.contains(".") && !s.contains(" ") { url = URL(string: "https://" + s) }
        else {
            var c = URLComponents(string: "https://www.youtube.com/results")!
            c.queryItems = [URLQueryItem(name: "search_query", value: s)]
            url = c.url
        }
        if let url, isWeb(url) { web.load(URLRequest(url: url)) }
    }

    @objc func showURL() {
        urlField.stringValue = web.url?.absoluteString ?? ""
        urlField.isHidden = false
        window.makeFirstResponder(urlField)
        urlField.currentEditor()?.selectAll(nil)
    }
    func hideURL() { urlField.isHidden = true; window.makeFirstResponder(web) }

    func control(_ c: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { load(urlField.stringValue); hideURL(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { hideURL(); return true }
        return false
    }

    @objc func openClipboard() { NSPasteboard.general.string(forType: .string).map(load) }
    // home is loadHTMLString (about:blank); reloading it natively yields an empty page
    @objc func reloadPage() {
        if web.url?.scheme?.hasPrefix("http") == true { web.reload() } else { showHome() }
    }
    @objc func back() { web.goBack() }
    @objc func forward() { web.goForward() }

    func installFillScript() {
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(WKUserScript(source: fillScript(fill), injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        ucc.addUserScript(WKUserScript(source: trackScript, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: trackWorld))
    }
    @objc func toggleFill() {
        fill.toggle()
        defaults.set(fill, forKey: "fill")
        installFillScript()
        web.evaluateJavaScript(fillScript(fill))
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleAspectLock) { item.state = aspectLocked ? .on : .off }
        return true
    }

    // locked: snap + hold video aspect; unlocked: free resize (setting increments clears aspect)
    @objc func toggleAspectLock() {
        if aspectLocked {
            aspectLocked = false
            window.contentResizeIncrements = NSSize(width: 1, height: 1)
            return
        }
        let js = "(() => { const v=[...document.querySelectorAll('video')].sort((a,b)=>b.videoWidth*b.videoHeight-a.videoWidth*a.videoHeight)[0]; return v && v.videoWidth ? [v.videoWidth, v.videoHeight] : null })()"
        web.evaluateJavaScript(js) { [weak self] r, _ in
            guard let self, let d = r as? [Double], d.count == 2, d[1] > 0 else { return }
            var f = self.window.frame
            let h = (f.width * d[1] / d[0]).rounded()
            f.origin.y += f.height - h
            f.size.height = h
            self.window.setFrame(f, display: true, animate: true)
            self.window.contentAspectRatio = NSSize(width: d[0], height: d[1])
            self.aspectLocked = true
        }
    }

    // tag 0–2: top left/center/right, 3–5: bottom left/center/right
    @objc func dock(_ sender: NSMenuItem) {
        guard let vis = window.screen?.visibleFrame else { return }
        let m: CGFloat = 12, f = window.frame
        let x = [vis.minX + m, vis.midX - f.width / 2, vis.maxX - f.width - m][sender.tag % 3]
        let y = sender.tag < 3 ? vis.maxY - f.height - m : vis.minY + m
        window.setFrame(NSRect(x: x, y: y, width: f.width, height: f.height), display: true, animate: true)
    }

    @objc func toggleTop() { onTop.toggle(); window.level = onTop ? .floating : .normal }
    @objc func toggleClickThrough() {
        window.ignoresMouseEvents.toggle()
        if window.ignoresMouseEvents && window.alphaValue > 0.6 { setAlpha(0.6) }
    }
    func setAlpha(_ a: CGFloat) {
        window.alphaValue = min(1, max(0.15, a))
        defaults.set(Double(window.alphaValue), forKey: "alpha")
    }
    @objc func fadeOut() { setAlpha(window.alphaValue - 0.1) }
    @objc func fadeIn() { setAlpha(window.alphaValue + 0.1) }
    @objc func playPause() {
        web.evaluateJavaScript("(() => { const v=[...document.querySelectorAll('video')].find(v=>v.currentSrc); if(v){ v.paused ? v.play() : v.pause(); } })()")
    }

    @objc func showHome() {
        homeToken = UUID().uuidString
        web.loadHTMLString(homeHTML(SiteStore.all(), resume: ResumeStore.load(), token: homeToken), baseURL: nil)
    }

    // MARK: web delegates
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let url = web.url, url.scheme?.hasPrefix("http") == true, let host = url.host,
              let b = m.body as? [String: Any] else { return }
        let t = b["t"] as? Double ?? 0, d = b["d"] as? Double ?? 0
        guard t.isFinite, d.isFinite, t >= 0, d >= 0 else { return }
        if b["event"] as? String == "play" {
            web.evaluateJavaScript(iconScript) { icon, _ in SiteStore.record(url, icon: icon as? String) }
            if let seek = pendingSeek, t < seek - 10 {
                web.evaluateJavaScript("[...document.querySelectorAll('video')].filter(v => !v.paused).forEach(v => v.currentTime = \(seek))")
            }
            pendingSeek = nil
        }
        // skip trailers/previews/ads
        guard d > 180, t <= d else { return }
        web.evaluateJavaScript(titleScript) { r, _ in
            var title = cleanTitle(r as? String ?? "", host: host)
            // player titles are often hidden with the controls; keep the last good one for this page
            if let prev = ResumeStore.load(), prev.url == url.absoluteString,
               title.isEmpty || title.caseInsensitiveCompare(siteName(host)) == .orderedSame {
                title = prev.title
            }
            ResumeStore.save(Resume(url: url.absoluteString, title: title, time: t, duration: d))
        }
    }
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = a.request.url, u.scheme?.hasPrefix("float-") == true else { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        // only the current home page knows the token; anything else is a forged command
        let arg = u.absoluteString.drop { $0 != ":" }.dropFirst()
        guard a.sourceFrame.isMainFrame, !homeToken.isEmpty, arg.hasPrefix(homeToken) else { return }
        let rest = arg.dropFirst(homeToken.count)
        switch u.scheme {
        case "float-resume" where rest.isEmpty: resumeLast()
        case "float-remove" where rest.hasPrefix("/"):
            SiteStore.remove(rest.dropFirst().removingPercentEncoding ?? "")
            showHome()
        default: break
        }
    }


    @objc func resumeLast() {
        guard let r = ResumeStore.load() else { return }
        pendingSeek = r.time > 0 ? r.time : nil
        load(r.url)
    }
    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        // top-level page popups only: iframe popups would escape their sandbox
        if a.targetFrame == nil, a.sourceFrame.isMainFrame, let u = a.request.url, isWeb(u) { w.load(URLRequest(url: u)) }
        return nil
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
