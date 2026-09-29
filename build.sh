#!/usr/bin/env bash
#
# build.sh — compile PodsMute with the Swift Command Line Tools (no full Xcode)
# and package it into a signed, double-clickable PodsMute.app.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PodsMute"
CONFIG="release"

echo "==> Building ($CONFIG)…"
# Universal (Apple Silicon + Intel) を試し、ツールチェーンが対応していなければ実行中のCPUだけでビルドする
ARCH_FLAGS=(--arch arm64 --arch x86_64)
if ! swift build -c "$CONFIG" "${ARCH_FLAGS[@]}"; then
  echo "==> Universal build failed; falling back to the host architecture" >&2
  ARCH_FLAGS=()
  swift build -c "$CONFIG"
fi
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

DIST="dist"
APP="$DIST/$APP_NAME.app"
echo "==> Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp "Packaging/Info.plist" "$APP/Contents/Info.plist"
[ -f "AppIcon.icns" ] && cp "AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
[ -f "LICENSE" ] && cp "LICENSE" "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Code signing (ad-hoc)…"
codesign --force --sign - \
  --entitlements "PodsMute/PodsMute.entitlements" \
  "$APP"
codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /' || true

echo
echo "==> Done: $APP"
echo "    Launch:       open \"$APP\""
echo "    Install:      cp -R \"$APP\" /Applications/"
echo "    Diagnostics:  PODSMUTE_DEBUG=1 \"$PWD/$APP/Contents/MacOS/$APP_NAME\""
