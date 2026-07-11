#!/bin/bash
# Packages DevSweep.app into a double-clickable DevSweep.dmg.
# Run ./build.sh first (or let this script do it).
set -euo pipefail
cd "$(dirname "$0")"

APP="DevSweep.app"
VOL="DevSweep"
DMG="DevSweep.dmg"
STAGE=".dmg-stage"

[ -d "$APP" ] || { echo "› $APP missing, building it first"; ./build.sh; }

echo "› staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "› creating $DMG"
hdiutil create \
  -volname "$VOL" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG" >/dev/null

rm -rf "$STAGE"

SIZE=$(du -h "$DMG" | cut -f1 | tr -d ' ')
echo
echo "Built $(pwd)/$DMG  ($SIZE)"
echo "Open it, then drag DevSweep onto the Applications shortcut."
