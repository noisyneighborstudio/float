# Float

Chromeless, always-on-top macOS video browser (Exact + WKWebView; Sparkle for updates).

```sh
./build.sh                      # build/Float.app
OUT=/Applications ./build.sh    # install
./build.sh FloatDev             # separate test app, own data/sessions
VERSION=1.2.3 BUILD=7 NOTARIZE=1 ./build.sh   # release build: Sparkle feed baked in, notarized → dist/
```

Exact development commands:

```sh
bun exact.mjs mac --run         # build and launch on macOS
bun exact.mjs test web          # run Contract tests on web
bun exact.mjs test macos        # run Contract tests on macOS
```

Signs with `Developer ID Application: Seth Webster (P8ZBH5878Q)` (override with `SIGN=`) + hardened runtime, so keychain grants for DRM survive rebuilds. Local builds have no update feed and never self-update.

## Releases
Push to `main` → GitHub Actions runs semantic-release. Conventional commits decide the version (`fix:` patch, `feat:` minor, `feat!:` major); other commits don't release. A release builds, notarizes and staples Float, attaches `Float-<version>.zip` to the GitHub release, and publishes `appcast.xml` on the `appcasts` branch. Installed release builds update via Sparkle (Float → Check for Updates…).

Hosting/keys: `updates.env`. Sparkle EdDSA key: login keychain account `float`. Secrets: see `~/Documents/macos-sign-notarize.md`.

## Features
- Home mosaic of video sites you've played; Resume card for last video (title + position)
- Drag via top edge strip; double-click strip toggles video-aspect lock
- Video fill (default on): pins any site's main player + controls to the window, hiding page chrome; animated opacity, click-through, 6 docking positions
- Global Quick Fade (default Hold Right ⌘, configurable opacity & custom hotkey in Float › Settings…)

## Shortcuts
| Key | Action |
|---|---|
| ⌘, | Settings (Quick Fade shortcut/opacity & Show/Hide shortcut) |
| ⇧⌘H / ⇧⌘R | Home / Resume last |
| ⌘L / ⇧⌘V | Open URL (or YouTube search) / open clipboard URL |
| ⌘R, ⌘[ ⌘] | Reload, back/forward |
| ⇧⌘F / ⇧⌘A | Video fill / toggle video-aspect lock |
| ⌘T / ⇧⌘K | Always on top / click-through |
| ⌘- ⌘= | Opacity (animated fade) |
| ⌃⌘1–6 | Dock: top L/C/R, bottom L/C/R |
| ⌃Space | Play/pause |
| Right ⌘ (global, hold) | Quick Fade overlay to configured opacity (default 50%); customize in Float › Settings… |
| ⌃⌥⌘F (global) | Hide / restore Float from any app; change it in Float › Settings… or Show/Hide Hotkey… |
