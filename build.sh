#!/bin/zsh
set -e
cd "${0:A:h}"
NAME=${1:-Float}  # ./build.sh FloatDev → separate test app w/ own data
ID=com.sethwebster.${NAME:l}
APP=${OUT:-build}/$NAME.app  # OUT=/Applications ./build.sh to install
rm -rf $APP && mkdir -p $APP/Contents/MacOS
swiftc -O -swift-version 5 main.swift -o $APP/Contents/MacOS/$NAME -framework Cocoa -framework WebKit
mkdir -p $APP/Contents/Resources && xcrun actool Float.icon --compile $APP/Contents/Resources --app-icon Float --platform macosx --target-device mac --minimum-deployment-target 13.0 --output-partial-info-plist /dev/null >/dev/null
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
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>Web</string>
  <key>CFBundleURLSchemes</key><array><string>http</string><string>https</string></array>
</dict></array>
</dict></plist>
PLIST
# stable identity → keychain "Always Allow" (Netflix DRM keys) survives rebuilds
codesign --force --timestamp=none -s "${SIGN:-Developer ID Application}" $APP
echo "built $APP"
