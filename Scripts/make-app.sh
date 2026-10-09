#!/bin/bash
# Builds Gitstick.app (menubar-only, ad-hoc signed) into ./dist
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --arch arm64 --product Gitstick
APP=dist/Gitstick.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/Gitstick "$APP/Contents/MacOS/Gitstick"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Gitstick</string>
  <key>CFBundleIdentifier</key><string>dev.gitstick.app</string>
  <key>CFBundleExecutable</key><string>Gitstick</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP — drag it to /Applications, or: open $APP"
