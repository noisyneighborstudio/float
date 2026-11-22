#!/bin/zsh
# ./build.sh [Name]            Name=FloatDev → separate test app w/ own data
#   OUT=/Applications          install location (default build/)
#   VERSION=1.2.3 BUILD=42     release build: bakes in the Sparkle feed (dev builds never self-update)
#   NOTARIZE=1                 secure timestamp, notarize, staple, zip to dist/$Name-$VERSION.zip
set -euo pipefail
cd "${0:A:h}"
source ./updates.env
NAME=${1:-Float}
ID=com.sethwebster.${NAME:l}
APP=${OUT:-build}/$NAME.app
SIGN=${SIGN:-Developer ID Application: Seth Webster (P8ZBH5878Q)}
VERSION=${VERSION:-0.0.0} BUILD=${BUILD:-0}
EXACT2=${EXACT:-${EXACT2:-}}
if [[ -z ${EXACT2:-} ]]; then
  for cand in "$HOME/Development/exact" "$HOME/Development/expo/exact" "$HOME/Development/exact2-main" "$HOME/Development/expo/exact2" "$HOME/Development/exact2"; do
    [[ -f "$cand/host/apple/build.mjs" ]] && { EXACT2="$cand"; break; }
  done
fi
EXACT2=${EXACT2:-$HOME/Development/exact}

# Prefer rustup/asdf cargo and Bun 1.4.2 when present on this machine
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"
[[ -d "$HOME/.asdf/shims" ]] && export PATH="$HOME/.asdf/shims:$PATH"
[[ -d "$HOME/.local/share/mise/installs/bun/1.4.2/bin" ]] && export PATH="$HOME/.local/share/mise/installs/bun/1.4.2/bin:$PATH"
[[ -d "$HOME/.bun/bin" ]] && export PATH="$HOME/.bun/bin:$PATH"
if [[ -z ${CARGO_HOME:-} && ! -d "$HOME/.cargo/hermes-lean-sys" && -d "$HOME/.asdf/installs/rust/stable/hermes-lean-sys" ]]; then
  export CARGO_HOME="$HOME/.asdf/installs/rust/stable"
fi
BUN=${BUN:-$(command -v bun)}

# Sparkle: pinned + checksummed; stored in .vendor/ so Exact's source baker skips its framework symlinks
SPARKLE=.vendor/Sparkle-$SPARKLE_VERSION
if [[ $BUILD != 0 && ! -d $SPARKLE/Sparkle.framework ]]; then
  mkdir -p $SPARKLE
  curl -fsSL --retry 30 --retry-all-errors --retry-delay 20 -o $SPARKLE.tar.xz \
    https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz
  echo "$SPARKLE_SHA256  $SPARKLE.tar.xz" | shasum -a 256 -c - >/dev/null
  tar -xJf $SPARKLE.tar.xz -C $SPARKLE Sparkle.framework bin/sign_update && rm $SPARKLE.tar.xz
fi

# Clean prior bundle before Exact's source baker scans the workspace
rm -rf "$APP"

# Build Float with Exact (macOS bundle)
BUILD_ARGS=(--bundle)
if [[ $BUILD != 0 || -n ${NOTARIZE:-} ]]; then
  BUILD_ARGS+=(--distribution)
fi
CRATE="${PWD:t}-apple"
EXACT_APP_DIR="$PWD" EXACT_DEVELOPER_ID="$SIGN" EXACT_RUST_SIGN_IDENTITY="$SIGN" \
  "$BUN" "$EXACT2/host/apple/build.mjs" "$CRATE" "${BUILD_ARGS[@]}"

# Locate Exact's built macOS bundle (newest match if both dev and distribution bundles exist)
BUILT_APP=$(find "$PWD/.exact" "$PWD/target" -maxdepth 8 -path "*/macos/Float.app" -type d -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | head -n 1 | cut -d' ' -f2-)
[[ -n $BUILT_APP && -d $BUILT_APP ]] || { echo "✗ Exact macOS bundle not found after build" >&2; exit 1; }

mkdir -p "${APP:h}"
ditto "$BUILT_APP" "$APP"

# Separate dev app support (./build.sh FloatDev → own bundle id, executable name, and data)
if [[ $NAME != Float ]]; then
  mv "$APP/Contents/MacOS/Float" "$APP/Contents/MacOS/$NAME"
  /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $NAME" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $NAME" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $NAME" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $ID" "$APP/Contents/Info.plist"
fi

# Stamp version/build and embed Sparkle.framework + feed into release builds only
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
if [[ $BUILD != 0 ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
  /usr/libexec/PlistBuddy -c "Delete :SUFeedURL" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Delete :SUEnableAutomaticChecks" "$APP/Contents/Info.plist" 2>/dev/null || true
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $FLOAT_FEED_URL" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$APP/Contents/Info.plist"
fi

# Stable identity → keychain "Always Allow" (Netflix DRM keys) survives rebuilds
# Inside-out: Sparkle's helpers/framework (release builds), Exact dylibs, then app; notarization needs a secure timestamp
TS=--timestamp=none; [[ -n ${NOTARIZE:-} ]] && TS=--timestamp
SIGN_OPTS=(); [[ $SIGN != - ]] && SIGN_OPTS=(--options runtime)
sign() { codesign --force $SIGN_OPTS $TS -s "$SIGN" "$@"; }
if [[ $BUILD != 0 ]]; then
  FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign "$FW/XPCServices/Installer.xpc"
  sign --preserve-metadata=entitlements "$FW/XPCServices/Downloader.xpc"
  sign "$FW/Autoupdate"
  sign "$FW/Updater.app"
  sign "$APP/Contents/Frameworks/Sparkle.framework"
fi
for dylib in "$APP/Contents/MacOS/"*.dylib(N); do
  sign "$dylib"
done
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "built $APP ($VERSION, build $BUILD)"
[[ -z ${NOTARIZE:-} ]] && exit 0

ZIP=dist/$NAME-$VERSION.zip
mkdir -p dist && rm -f "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --wait \
  --key ${NOTARY_KEY_PATH:-~/Documents/Keys/AuthKey_NTTLXC7Y24.p8} \
  --key-id ${NOTARY_KEY_ID:-NTTLXC7Y24} --issuer ${NOTARY_KEY_ISSUER:-69a6de70-71d0-47e3-e053-5b8c7c11a4d1}
xcrun stapler staple "$APP" && xcrun stapler validate "$APP"
rm "$ZIP" && ditto -c -k --keepParent "$APP" "$ZIP"  # re-zip stapled app
echo "notarized $ZIP"
