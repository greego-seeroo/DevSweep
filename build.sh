#!/bin/bash
# Builds DevSweep.app from source. No Xcode project, no dependencies.
set -euo pipefail
cd "$(dirname "$0")"

APP="DevSweep.app"
BIN="$APP/Contents/MacOS/DevSweep"
RES="$APP/Contents/Resources"

echo "› cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp Info.plist "$APP/Contents/Info.plist"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

echo "› compiling ($ARCH)"
swiftc \
  -O -whole-module-optimization \
  -swift-version 5 \
  -sdk "$SDK" \
  -target "${ARCH}-apple-macos14.0" \
  -framework SwiftUI -framework AppKit \
  Sources/*.swift \
  -o "$BIN"

echo "› icon"
swift Tools/makeicon.swift "$RES/AppIcon.icns" >/dev/null 2>&1 || echo "  (skipped)"

echo "› signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP"

echo
echo "Built $(pwd)/$APP"
echo "Open with:  open '$(pwd)/$APP'"
