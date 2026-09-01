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

# Info.plist references $(MARKETING_VERSION)/$(CURRENT_PROJECT_VERSION) so the
# version typed into Xcode is the single source of truth. Xcode substitutes
# them during its build; this script has to do the same by hand.
MV="$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' DevSweep.xcodeproj/project.pbxproj | head -1)"
BV="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \(.*\);/\1/p' DevSweep.xcodeproj/project.pbxproj | head -1)"
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString ${MV:-0.0}" \
  -c "Set :CFBundleVersion ${BV:-1}" \
  "$APP/Contents/Info.plist"
echo "› version ${MV:-?} (build ${BV:-?})"

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

# macOS keys a privacy grant to the app's code signature. An ad-hoc signature gets
# a fresh hash on every compile, so the system sees a brand new app each build and
# asks for Desktop/Documents/Downloads again. Signing with a real identity keeps the
# grant across rebuilds — approve the folders once and you are done.
#
# Override with:  SIGN_ID="Apple Development: you (TEAMID)" ./build.sh
if [[ -z "${SIGN_ID:-}" ]]; then
  SIGN_ID="$(security find-identity -v -p codesigning \
    | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)"
fi

# The App Store build runs sandboxed. Embedding the entitlements here means a
# local ./build.sh produces the same sandboxed app the archive will, so folder
# grants and their limits can be tested without going through Xcode.
ENT_ARGS=()
if [[ -f DevSweep.entitlements ]]; then
  echo "› entitlements (DevSweep.entitlements — App Sandbox)"
  ENT_ARGS=(--entitlements DevSweep.entitlements)
fi

if [[ -n "$SIGN_ID" ]]; then
  echo "› signing ($SIGN_ID)"
  codesign --force --options runtime --timestamp=none "${ENT_ARGS[@]}" --sign "$SIGN_ID" "$APP"
else
  echo "› signing (ad-hoc — no Apple Development identity found)"
  echo "  macOS will re-ask for folder access after every rebuild."
  codesign --force --timestamp=none "${ENT_ARGS[@]}" --sign - "$APP"
fi

echo
echo "Built $(pwd)/$APP"
echo "Open with:  open '$(pwd)/$APP'"
