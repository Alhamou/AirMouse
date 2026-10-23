#!/usr/bin/env bash
# build.sh — builds AirMouse.app (menu bar app) into macos/build/.
#
# Usage: ./build.sh [--install]
#   --install   copy to /Applications and (re)launch it
#
# Signing: uses $CODESIGN_IDENTITY, else the first valid "Apple Development" identity,
# else ad-hoc. A stable identity matters: macOS ties the Accessibility permission to it,
# so with ad-hoc signing you must re-grant Accessibility after every rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/AirMouse.app

echo "==> Compiling"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/AirMouse"

if [[ ! -f Resources/AppIcon.icns ]]; then
  echo "==> Rendering app icon"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$ICONSET/icon_512x512@2x.png" >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    [[ $s -ne 512 ]] && sips -z $d $d "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AirMouse"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp ../static/index.html "$APP/Contents/Resources/index.html"   # the trackpad page

IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | grep -v CSSMERR | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)}"
echo "==> Signing with: ${IDENTITY:-ad-hoc}"
codesign --force --sign "${IDENTITY:--}" "$APP"

if [[ "${1:-}" == "--install" ]]; then
  echo "==> Installing to /Applications"
  pkill -x AirMouse 2>/dev/null && sleep 1 || true
  rm -rf /Applications/AirMouse.app
  cp -R "$APP" /Applications/
  open /Applications/AirMouse.app
fi
echo "Done: $APP"
