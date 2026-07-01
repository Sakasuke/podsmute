#!/usr/bin/env bash
#
# make-dmg.sh — build PodsMute and wrap it in a drag-to-install .dmg.
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PodsMute"
APP="dist/$APP_NAME.app"
DMG="dist/$APP_NAME.dmg"

# Always produce a fresh app bundle.
./build.sh

STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"   # drag target

echo "==> Creating $DMG …"
rm -f "$DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null

rm -rf "$STAGING"
echo "==> Done."
ls -lh "$DMG"
