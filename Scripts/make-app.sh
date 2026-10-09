#!/bin/bash
# Builds dist/Gitstick.app (menubar-only, ad-hoc signed) and dist/Gitstick.zip, which is what a
# GitHub release carries and what the app's updater and install.sh download.
#
#   ./Scripts/make-app.sh                       a local build: version 0.0.0, this Mac's chip only
#   VERSION=0.3.12 UNIVERSAL=1 ./Scripts/make-app.sh    what CI runs for a release
#
# A local build is 0.0.0 on purpose: the app then offers the latest real release as an update.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.0.0}"
COMMIT="${COMMIT:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
NAME=Gitstick
APP="dist/$NAME.app"

if [[ "${UNIVERSAL:-0}" == 1 ]]; then ARCHS=(--arch arm64 --arch x86_64); else ARCHS=(); fi
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product "$NAME"
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --product "$NAME" --show-bin-path)/$NAME"

rm -rf "$APP" "dist/$NAME.zip" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$NAME"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>dev.gitstick.app</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>GitstickCommit</key><string>$COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSUserNotificationAlertStyle</key><string>banner</string>
</dict></plist>
PLIST

# Ad-hoc signature: Apple silicon only runs signed code, and this needs no developer account.
codesign --force --sign - --timestamp=none "$APP"
ditto -c -k --keepParent "$APP" "dist/$NAME.zip"
echo "Built $APP ($VERSION, ${COMMIT:0:7}) — drag it to /Applications, or: open $APP"
