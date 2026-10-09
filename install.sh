#!/bin/bash
# Installs (or reinstalls) Gitstick into ~/Applications and opens it. After this, updates come
# from the app itself (the gear menu, or the banner when one is ready).
#
#   curl -fsSL https://raw.githubusercontent.com/ainigh/Gitstick/main/install.sh | bash
#
# It takes the latest release that GitHub built. If there isn't one yet (or GITSTICK_FROM_SOURCE=1),
# it downloads the source of main and builds it here with Apple's command line tools.
set -euo pipefail

REPO="ainigh/Gitstick"
APPS="$HOME/Applications"
NAME="Gitstick"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\n\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# gh if it's here and signed in (works for a private fork), plain curl otherwise.
GH=""
for g in /opt/homebrew/bin/gh /usr/local/bin/gh; do [[ -x "$g" ]] && "$g" auth status >/dev/null 2>&1 && GH="$g" && break; done

app=""
if [[ "${GITSTICK_FROM_SOURCE:-0}" != 1 ]]; then
  say "Downloading the latest release"
  if [[ -n "$GH" ]] && "$GH" release download --repo "$REPO" --pattern "$NAME.zip" --dir "$tmp" 2>/dev/null; then
    :
  elif url="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" \
               | sed -nE 's/.*"browser_download_url": *"([^"]*'"$NAME"'\.zip)".*/\1/p' | head -1)" && [[ -n "$url" ]]; then
    curl -fsSL -o "$tmp/$NAME.zip" "$url"
  else
    echo "  No release yet: building it here instead."
  fi
  if [[ -f "$tmp/$NAME.zip" ]]; then
    ditto -x -k "$tmp/$NAME.zip" "$tmp/unpacked"
    app="$tmp/unpacked/$NAME.app"
  fi
fi

if [[ -z "$app" ]]; then
  xcode-select -p >/dev/null 2>&1 || die "Building needs Apple's command line tools: run xcode-select --install, then this again."
  say "Downloading the source (main)"
  mkdir -p "$tmp/src"
  curl -fsSL "https://codeload.github.com/$REPO/tar.gz/main" | tar -xz -C "$tmp/src" --strip-components 1
  say "Building (a minute or two)"
  (cd "$tmp/src" && VERSION="0.0.0" ./Scripts/make-app.sh)
  app="$tmp/src/dist/$NAME.app"
fi

# The copy that was here is kept until the new one is seen running: if the new one quits straight
# away, the old one goes back and opens again, so an install never leaves you without it.
say "Installing into $APPS"
[[ -d "$app" ]] || die "The download didn't hold $NAME.app."
pkill -x "$NAME" 2>/dev/null && sleep 1 || true
mkdir -p "$APPS"
previous="$APPS/.$NAME-previous.app"
rm -rf "$previous"
[[ -d "$APPS/$NAME.app" ]] && mv "$APPS/$NAME.app" "$previous"
ditto "$app" "$APPS/$NAME.app"
xattr -dr com.apple.quarantine "$APPS/$NAME.app" 2>/dev/null || true
version="$(defaults read "$APPS/$NAME.app/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
open "$APPS/$NAME.app"

started=0
for _ in 1 2 3 4 5 6 7 8; do
  sleep 1
  if pgrep -x "$NAME" >/dev/null; then started=1; else started=0; fi
done
if [[ "$started" == 1 ]]; then
  rm -rf "$previous"
  say "Done ($version): look for the drive icon in the menu bar."
  echo "  Not there? The menu bar may be full: quit an icon or two, or hold ⌘ and drag some away."
  exit 0
fi

if [[ -d "$previous" ]]; then
  rm -rf "$APPS/$NAME.app"; mv "$previous" "$APPS/$NAME.app"; open "$APPS/$NAME.app"
  die "$NAME $version quit as soon as it opened, so the one you had is back and open again."
fi
die "$NAME $version quit as soon as it opened. To see why: $APPS/$NAME.app/Contents/MacOS/$NAME"
