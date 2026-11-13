# Offline playback in Float: feasibility finding

**Verdict:** Partially

Only positively identified direct `.mp4`/`.webm` files, and possibly plain `.m3u8` HLS, can be saved without per-site rules. DRM streams need a persistent license that only the provider can grant, YouTube-style MSE/`blob:` streams need per-site extraction, and any source Float can't positively identify stays unsupported.

Runtime facts about WebKit, YouTube or Netflix are marked **verify on macOS**; the checks are collected in `## Verify on macOS`. This finding changes no app code.

## Context

- `cfg.websiteDataStore = .default()`: content streams from the network through the persistent default data store (main.swift:345).
- `safariUA` spoofs Safari 18 (main.swift:7). It decides whether sites serve native HLS or MSE to Float (verify on macOS).
- `isWeb` allows only http/https URLs (main.swift:207). A local file can't load today.
- `decidePolicyFor` intercepts only `float-*` schemes and allows everything else (main.swift:633). There is no navigationResponse policy and no WKDownloadDelegate, so downloads aren't supported.
- The video fill heuristic picks the main video by `currentSrc`, `currentTime > 0` and more than 15% of the viewport (main.swift:58-61). It picks the video but doesn't check its format.

## Source classes

| Class | Verdict | Reason | macOS 13+ API |
| --- | --- | --- | --- |
| DRM (EME/FairPlay, e.g. Netflix) | No without provider cooperation | Needs a persistent license only the provider's license server can grant; site ToS apply; decrypting is excluded | EME `persistent-license` session / AVContentKeySession persistable keys |
| MSE (`blob:` currentSrc, e.g. YouTube) | No | Page JS assembles the segments, so capture needs per-site extraction or yt-dlp/ffmpeg; breaks site-agnostic and minimal footprint; ToS risk | none |
| Native HLS (pathname ends in `.m3u8`, no keys) | Partially | AVAssetDownloadURLSession can store the playlist as a .movpkg, but cookies/tokens and ToS vary (verify on macOS) | AVAssetDownloadURLSession plus cookies from WKHTTPCookieStore |
| Progressive (http(s) pathname ends in `.mp4` or `.webm`) | Yes, technically | A plain file; reachable site-agnostically; ToS still apply | URLSession download task with cookies from WKHTTPCookieStore.getAllCookies, or WKDownload (macOS 11.3+) |

All APIs listed are Apple-documented and available on macOS 13.0.

A fifth outcome, **Unrecognized**, covers any http(s) currentSrc that matches none of the four classes, such as an extensionless HLS endpoint or a server-side redirector. It is never treated as savable.

## Telling classes apart at runtime

This reuses the video fill's site-agnostic pick (largest playing video, `currentSrc`). Illustrative only; it is not added to `fillScript` or main.swift. Checked in this order:

1. `v.mediaKeys || v.webkitKeys` is set: DRM, whatever the currentSrc (DRM can be `blob:` via MSE or `.m3u8` via native HLS).
2. Protocol `blob:`: MSE.
3. http(s) and the pathname matches `/\.m3u8$/i`: Native HLS.
4. http(s) and the pathname matches `/\.(mp4|webm)$/i`: Progressive.
5. Anything else: Unrecognized, not savable.

```js
function classify(v) {
  if (v.mediaKeys || v.webkitKeys) return 'DRM';
  const u = new URL(v.currentSrc);
  if (u.protocol === 'blob:') return 'MSE';
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return 'Unrecognized';
  if (/\.m3u8$/i.test(u.pathname)) return 'Native HLS';
  if (/\.(mp4|webm)$/i.test(u.pathname)) return 'Progressive';
  return 'Unrecognized';
}
```

Matching on the pathname keeps query strings and fragments from fooling the test. currentSrc alone can't reveal an extensionless HLS or MP4 URL, so such sources fail closed as Unrecognized instead of falling through to Progressive. The narrow follow-up adds a network-level Content-Type check (see the sketch). There are no per-site rules.

## DRM: encrypted offline with a persistent license

The path: media stays encrypted on disk; the license is issued by the provider's own license server and bound to this Mac/Float (Float's stable signing identity matters here); playback happens only through FairPlay/EME inside Float; the saved copy can't be played elsewhere or shared.

It depends on three things:

- (a) Whether WKWebView's FairPlay EME (`com.apple.fps`) accepts `persistent-license` sessions. Safari has historically exposed only `temporary`. Verify on macOS.
- (b) Whether the site's web player requests `persistent-license` sessions.
- (c) Whether the site's license server grants them.

Native AVContentKeySession persistable keys would also need the provider to issue offline-capable content key responses to a non-provider app.

**Without provider cooperation this does not work for Netflix-style web players.** Float can't make a player request a persistent license, and can't make a license server grant one.

## DRM: encrypted cache, online license

Encrypted segments are stored locally, but a license is still fetched online at play time. This is **not offline viewing**: a network connection is still required, so at most it saves bandwidth. It needs per-site segment capture, because MSE appends happen inside page JS; that breaks site-agnostic and carries ToS risk. It also doesn't work for Netflix-style web players without provider cooperation, and it doesn't remove the `persistent-license` dependency (WKWebView support, the site's player and its license server) for true offline play.

## Excluded

Regardless of the verdict, these are out of scope:

- Any approach that would decrypt protected content, strip DRM, or re-encode it.
- Any approach that would screen-record protected content.
- Storing decrypted output.

Site terms of service may also forbid saving content even without DRM. This is flagged for the maintainer; it isn't legal advice.

## Conflicts with current product rules

Any offline build would have to change these:

- **UserDefaults:** files, and for DRM persisted license data, would sit on disk in Application Support, beyond the UserDefaults-only persistence rule.
- **http/https:** `isWeb` and the "only http/https URLs load" constraint; playing a saved file would need a narrow file:// allowance or native AVPlayer playback.
- **site-agnostic:** MSE and DRM capture need per-site extraction.
- **minimal footprint:** robust stream capture usually means yt-dlp/ffmpeg, against Sparkle being the only third-party runtime dependency.
- **Not a general-purpose browser:** a save/download capability is a download manager, which is a non-goal.
- **Home:** a new surface for saved videos.
- **Keyboard-first:** a save action needs a menu item and a keyboard shortcut.

Size of the smallest follow-up: S–M, roughly 150–250 lines in main.swift plus README shortcut rows.

## Follow-up scope sketch

Narrowest version: **Save direct video file.**

- A menu item with a shortcut (e.g. ⇧⌘S; looks free in the current menu, verify) saves the main video, only if it passes two gates.
- Gate 1: it classifies as Progressive by the positive pathname rule (no keys, not `blob:`, pathname ends in `.mp4`/`.webm`). Unrecognized sources are refused with a short "This video can't be saved" message rather than attempted.
- Gate 2: before writing to disk, the URLSession response (a HEAD request, or the download's first response) must have a Content-Type of `video/mp4` or `video/webm`. A response that is HLS (`application/vnd.apple.mpegurl`, `application/x-mpegURL`), text/HTML or anything else aborts the save.
- If both gates pass, it downloads with URLSession using WKHTTPCookieStore cookies into Application Support.
- A "Saved" row on Home lists saved videos, and they play via a narrowly allowed file:// URL under that directory.

Conflicts it would resolve: UserDefaults-only persistence, http/https loading, a new Home surface, a keyboard shortcut, and the general-browser scope. Conflicts it avoids: site-agnostic and minimal footprint.

DRM, MSE, HLS and Unrecognized sources stay out.

## Recommendation

**Don't build.** The narrow "Save direct video file" version only reaches sites that serve positively identifiable progressive files. The main targets (Netflix DRM, YouTube MSE) stay unreachable, so the value is low against five rule changes. Revisit only if WKWebView supports FairPlay `persistent-license` and a provider grants it.

## Verify on macOS

Claims the factory couldn't check on Linux, each with a one-line Web Inspector check:

- currentSrc classes on YouTube/Netflix in Float: `document.querySelector('video').currentSrc`
- Attached keys on DRM video: `!!(document.querySelector('video').mediaKeys || document.querySelector('video').webkitKeys)`
- WKWebView FairPlay accepts persistent sessions: `navigator.requestMediaKeySystemAccess('com.apple.fps', [{initDataTypes:['skd'], videoCapabilities:[{contentType:'video/mp4'}], sessionTypes:['persistent-license']}]).then(()=>'ok', e=>e.name)`
- Whether the site requests persistent sessions: wrap `MediaKeys.prototype.createSession` and log its arguments.
- Whether plain-HLS URLs download with cookies only: fetch the `.m3u8` with `credentials:'include'` and check the status.
- Whether sites serve HLS or MP4 from extensionless URLs (they would land in Unrecognized): `fetch(document.querySelector('video').currentSrc,{method:'HEAD',credentials:'include'}).then(r=>r.headers.get('content-type'))`
- That ⇧⌘S is unused: check the app's menus for the shortcut.
