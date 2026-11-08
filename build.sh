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

# Sparkle: pinned + checksummed; GitHub release downloads 504 for minutes at a time, so retry long
SPARKLE=vendor/Sparkle-$SPARKLE_VERSION
if [[ ! -d $SPARKLE/Sparkle.framework ]]; then
  mkdir -p $SPARKLE
  curl -fsSL --retry 30 --retry-all-errors --retry-delay 20 -o $SPARKLE.tar.xz \
    https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz
  echo "$SPARKLE_SHA256  $SPARKLE.tar.xz" | shasum -a 256 -c - >/dev/null
  tar -xJf $SPARKLE.tar.xz -C $SPARKLE Sparkle.framework bin/sign_update && rm $SPARKLE.tar.xz
fi

rm -rf $APP && mkdir -p $APP/Contents/MacOS $APP/Contents/Frameworks $APP/Contents/Resources
swiftc -O -swift-version 5 main.swift -o $APP/Contents/MacOS/$NAME -framework Cocoa -framework WebKit \
  -F $SPARKLE -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks
ditto $SPARKLE/Sparkle.framework $APP/Contents/Frameworks/Sparkle.framework
xcrun actool Float.icon --compile $APP/Contents/Resources --app-icon Float --platform macosx --target-device mac --minimum-deployment-target 13.0 --output-partial-info-plist /dev/null >/dev/null

FEED=""
[[ $BUILD != 0 ]] && FEED="<key>SUFeedURL</key><string>$FLOAT_FEED_URL</string>
<key>SUPublicEDKey</key><string>$SPARKLE_PUBLIC_KEY</string>
<key>SUEnableAutomaticChecks</key><true/>"
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>$NAME</string>
<key>CFBundleIdentifier</key><string>$ID</string>
<key>CFBundleIconFile</key><string>Float</string>
<key>CFBundleIconName</key><string>Float</string>
<key>CFBundleExecutable</key><string>$NAME</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
$FEED
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>Web</string>
  <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
</dict></array>
</dict></plist>
PLIST

# stable identity → keychain "Always Allow" (Netflix DRM keys) survives rebuilds
# inside-out: Sparkle's helpers, framework, then app; notarization needs a secure timestamp
TS=--timestamp=none; [[ -n ${NOTARIZE:-} ]] && TS=--timestamp
sign() { codesign --force --options runtime $TS -s "$SIGN" "$@" }
FW=$APP/Contents/Frameworks/Sparkle.framework/Versions/B
sign $FW/XPCServices/Installer.xpc
sign --preserve-metadata=entitlements $FW/XPCServices/Downloader.xpc
sign $FW/Autoupdate
sign $FW/Updater.app
sign $APP/Contents/Frameworks/Sparkle.framework
sign $APP
codesign --verify --deep --strict $APP
echo "built $APP ($VERSION, build $BUILD)"
[[ -z ${NOTARIZE:-} ]] && exit 0

ZIP=dist/$NAME-$VERSION.zip
mkdir -p dist && rm -f $ZIP && ditto -c -k --keepParent $APP $ZIP
xcrun notarytool submit $ZIP --wait \
  --key ${NOTARY_KEY_PATH:-~/Documents/Keys/AuthKey_NTTLXC7Y24.p8} \
  --key-id ${NOTARY_KEY_ID:-NTTLXC7Y24} --issuer ${NOTARY_KEY_ISSUER:-69a6de70-71d0-47e3-e053-5b8c7c11a4d1}
xcrun stapler staple $APP && xcrun stapler validate $APP
rm $ZIP && ditto -c -k --keepParent $APP $ZIP  # re-zip stapled app
echo "notarized $ZIP"
