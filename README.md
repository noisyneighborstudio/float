# Float

Chromeless, always-on-top macOS video browser (Swift + WKWebView, no deps).

```sh
./build.sh                      # build/Float.app
OUT=/Applications ./build.sh    # install
./build.sh FloatDev             # separate test app, own data/sessions
```

Signs with `Developer ID Application` (override with `SIGN=`) so keychain grants for DRM survive rebuilds.

## Features
- Home mosaic of video sites you've played; Resume card for last video (title + position)
- Drag via top edge strip; double-click strip snaps to video aspect
- Video fill mode, opacity, click-through, 6 docking positions

## Shortcuts
| Key | Action |
|---|---|
| ⇧⌘H / ⇧⌘R | Home / Resume last |
| ⌘L / ⇧⌘V | Open URL (or YouTube search) / open clipboard URL |
| ⌘R, ⌘[ ⌘] | Reload, back/forward |
| ⇧⌘F / ⇧⌘A | Video fill / snap to video aspect |
| ⌘T / ⇧⌘K | Always on top / click-through |
| ⌘- ⌘= | Opacity |
| ⌃⌘1–6 | Dock: top L/C/R, bottom L/C/R |
| ⌃Space | Play/pause |
