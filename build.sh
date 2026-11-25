#!/bin/zsh
# ./build.sh [Name]            Name=FloatDev → separate test app w/ own data
#   OUT=/Applications          install location (default build/)
#   VERSION=1.2.3 BUILD=42     release build version & build number
#   NOTARIZE=1                 delegate to `exact release` (sign, notarize, staple → dist/$Name-$VERSION.zip)
set -euo pipefail
cd "${0:A:h}"
NAME=${1:-Float}
ID=com.sethwebster.${NAME:l}
APP=${OUT:-build}/$NAME.app
SIGN=${SIGN:-Developer ID Application: Seth Webster (P8ZBH5878Q)}
# Resolve common-name signing identities to their 40-char SHA-1 thumbprint, which
# Exact's signingOrder requires for `codesign --verify -R '=certificate leaf = H"<sha1>"'`.
if [[ $SIGN != - && ! $SIGN =~ ^[0-9A-Fa-f]{40}$ ]]; then
  RESOLVED_SIGN=$(security find-identity -v -p codesigning 2>/dev/null | awk -v name="$SIGN" 'index($0, "\"" name "\"") { print $2; exit }')
  if [[ -n $RESOLVED_SIGN ]]; then
    SIGN="$RESOLVED_SIGN"
  fi
fi
VERSION=${VERSION:-0.1.0} BUILD=${BUILD:-1}
EXACT2=${EXACT:-${EXACT2:-}}
if [[ -z ${EXACT2:-} ]]; then
  for cand in "$HOME/Development/exact" "$HOME/Development/expo/exact" "$HOME/Development/exact2-main" "$HOME/Development/expo/exact2" "$HOME/Development/exact2"; do
    [[ -f "$cand/host/apple/build.mjs" ]] && { EXACT2="$cand"; break; }
  done
fi
EXACT2=${EXACT2:-$HOME/Development/exact}

# Prefer rustup cargo over asdf/homebrew shims, and Bun 1.4.2 when present on this machine
[[ -d "$HOME/.asdf/shims" ]] && export PATH="$HOME/.asdf/shims:$PATH"
[[ -d "$HOME/.cargo/bin" ]] && export PATH="$HOME/.cargo/bin:$PATH"
[[ -d "$HOME/.local/share/mise/installs/bun/1.4.2/bin" ]] && export PATH="$HOME/.local/share/mise/installs/bun/1.4.2/bin:$PATH"
[[ -d "$HOME/.bun/bin" ]] && export PATH="$HOME/.bun/bin:$PATH"
if [[ -z ${CARGO_HOME:-} && ! -d "$HOME/.cargo/hermes-lean-sys" && -d "$HOME/.asdf/installs/rust/stable/hermes-lean-sys" ]]; then
  export CARGO_HOME="$HOME/.asdf/installs/rust/stable"
fi
if [[ -z ${RUSTUP_HOME:-} ]] && command -v rustup >/dev/null 2>&1; then
  export RUSTUP_HOME="$(rustup show home)"
fi
BUN=${BUN:-$(command -v bun)}

# Ensure .exact/checkout resolves local @exact/* packages before building
mkdir -p .exact
ln -sfn "$EXACT2" .exact/checkout

# Clean prior bundle before Exact's source baker scans the workspace
rm -rf "$APP"

if [[ -n ${NOTARIZE:-} ]]; then
  EXACT_APP_DIR="$PWD" \
  EXACT_VERSION="$VERSION" \
  EXACT_BUILD_NUMBER="$BUILD" \
  EXACT_DEVELOPER_ID="$SIGN" \
  EXACT_RUST_SIGN_IDENTITY="$SIGN" \
  EXACT_NOTARY_PROFILE="${EXACT_NOTARY_PROFILE:-exact-notary}" \
    "$BUN" "$EXACT2/scripts/exact.mjs" release "$PWD"

  DIST_DIR=$(find "$PWD/target/dist" -maxdepth 2 -name "Float.app" -type d -exec dirname {} \; | head -n 1)
  [[ -n $DIST_DIR && -d "$DIST_DIR/Float.app" && -f "$DIST_DIR/Float.zip" ]] \
    || { echo "✗ exact release output not found under target/dist/" >&2; exit 1; }

  mkdir -p "${APP:h}" dist
  ditto "$DIST_DIR/Float.app" "$APP"
  ZIP=dist/$NAME-$VERSION.zip
  cp -f "$DIST_DIR/Float.zip" "$ZIP"
  echo "notarized $ZIP ($VERSION, build $BUILD)"
  exit 0
fi

# Local build via Exact (Sparkle.framework + Info.plist keys come from app.json)
CRATE="${PWD:t}-apple"
EXACT_APP_DIR="$PWD" \
EXACT_VERSION="$VERSION" \
EXACT_BUILD_NUMBER="$BUILD" \
EXACT_DEVELOPER_ID="$SIGN" \
EXACT_RUST_SIGN_IDENTITY="$SIGN" \
  "$BUN" "$EXACT2/host/apple/build.mjs" "$CRATE" --bundle

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
  SIGN_OPTS=(); [[ $SIGN != - ]] && SIGN_OPTS=(--options runtime)
  codesign --force $SIGN_OPTS --timestamp=none -s "$SIGN" "$APP"
fi

codesign --verify --deep --strict "$APP"
echo "built $APP ($VERSION, build $BUILD)"
