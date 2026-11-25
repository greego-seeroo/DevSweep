#!/bin/bash
# Makes the App Store screenshots: three scenes in every shipped language,
# each a real capture of the app placed under a localized headline on a
# 2560×1600 canvas (a size App Store Connect accepts for Mac).
#
#   Scripts/app-store-screenshots.sh                 # all languages, all scenes
#   Scripts/app-store-screenshots.sh de ja           # some languages
#   COMPOSE_ONLY=1 Scripts/app-store-screenshots.sh  # redo the canvases from the raw captures
#   APP=path/to/DevSweep.app Scripts/app-store-screenshots.sh
#
# Output:
#   AppStore/screenshots/raw/<lang>/<scene>.png   the window as captured
#   AppStore/screenshots/<lang>/<scene>.png       the finished screenshot
# Scenes: 01-developer (Developer mode after a scan), 02-system-data (System
# Data mode after a scan), 03-welcome (the first-run sheet, which opens on the
# language choice).
#
# Every scene is set up with launch arguments. The argument domain overrides
# the app's saved defaults for that launch only, so nothing has to be clicked:
#   -AppleLanguages (xx) -devsweep.language xx   the language
#   -audience developer|everyday                  the mode
#   -devsweep.welcomeSeen.v2 NO|YES               show the first-run sheet or not
#   -"NSWindow Frame …"                            a fixed window frame
# The window is 1180×740 points so it fits the usable area of a 1440×900
# display with the Dock showing; macOS would shrink anything taller.
#
# By default it launches DevSweep.app from Scripts/build.sh (sandboxed, same
# sources and entitlements as the App Store build). The scan results come from
# this Mac: check every picture for personal folder names before uploading.
#
# Needs: the app running this script (Terminal, or the editor hosting it)
# allowed under System Settings ▸ Privacy & Security ▸ Screen Recording, and
# the display awake and unlocked.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-$(pwd)/DevSweep.app}"
OUT="AppStore/screenshots"
RAW="$OUT/raw"
LANGS=("$@"); [[ ${#LANGS[@]} -gt 0 ]] || LANGS=(en de ja fr es)
SCAN_WAIT="${SCAN_WAIT:-75}"   # seconds for a Developer scan to settle
DATA_WAIT="${DATA_WAIT:-30}"   # seconds for a System Data scan to settle
SHEET_WAIT="${SHEET_WAIT:-8}"  # seconds for the welcome sheet to appear
WIN_W=1180; WIN_H=740

# Headlines: lang <tab> scene <tab> text.
caption() {
  awk -F'\t' -v l="$1" -v s="$2" '$1==l && $2==s {print $3}' <<'TSV'
en	01-developer	Find the gigabytes your dev tools left behind
en	02-system-data	Clear macOS System Data, explained in plain words
en	03-welcome	Now in five languages. Pick yours on first launch
de	01-developer	Die Gigabytes, die Ihre Dev-Tools zurücklassen
de	02-system-data	Systemdaten aufräumen – verständlich erklärt
de	03-welcome	Jetzt in fünf Sprachen – auch auf Deutsch
ja	01-developer	開発ツールが残したギガバイトを見つける
ja	02-system-data	macOSの「システムデータ」をわかりやすく整理
ja	03-welcome	日本語を含む5つの言語に対応
fr	01-developer	Retrouvez les gigaoctets laissés par vos outils
fr	02-system-data	Videz les Données système, expliquées simplement
fr	03-welcome	Désormais en cinq langues, dont le français
es	01-developer	Encuentra los gigas que dejan tus herramientas
es	02-system-data	Limpia los Datos del sistema, explicados con claridad
es	03-welcome	Ahora en cinco idiomas, también en español
TSV
}

HELPER_DIR="$(mktemp -d)"
trap 'rm -rf "$HELPER_DIR"' EXIT
swiftc -O Scripts/compose-screenshot.swift -o "$HELPER_DIR/compose" 2>/dev/null

if [[ -z "${COMPOSE_ONLY:-}" ]]; then
  [[ -d "$APP" ]] || { echo "No DevSweep.app found. Run Scripts/build.sh first."; exit 1; }
  echo "Using $APP"

  # Centre the window in the usable area (menu bar and Dock excluded).
  # AppKit frames count y from the bottom of the screen.
  read -r SW SH VX VY VW VH < <(osascript -l JavaScript -e 'ObjC.import("AppKit"); var s=$.NSScreen.mainScreen, f=s.frame, v=s.visibleFrame; [f.size.width,f.size.height,v.origin.x,v.origin.y,v.size.width,v.size.height].map(Math.round).join(" ")')
  X=$(( VX + (VW - WIN_W) / 2 )); Y=$(( VY + (VH - WIN_H) / 2 ))
  FRAME_KEY='NSWindow Frame SwiftUI.ModifiedContent<DevSweep.ContentView, SwiftUI._EnvironmentKeyWritingModifier<Swift.Optional<DevSweep.ScanModel>>>-1-AppWindow-1'
  FRAME="$X $Y $WIN_W $WIN_H 0 0 $SW $SH "

  cat > "$HELPER_DIR/winid.swift" <<'SWIFT'
import CoreGraphics
// Largest normal-layer DevSweep window: its id and point size.
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
var best: (Int, Double, Double) = (0, 0, 0)
for w in list where (w["kCGWindowOwnerName"] as? String) == "DevSweep" && (w["kCGWindowLayer"] as? Int) == 0 {
    let b = w["kCGWindowBounds"] as? [String: Double] ?? [:]
    let (wd, ht) = (b["Width"] ?? 0, b["Height"] ?? 0)
    if wd * ht > best.1 * best.2 { best = (w["kCGWindowNumber"] as? Int ?? 0, wd, ht) }
}
print(best.0, Int(best.1), Int(best.2))
SWIFT
  swiftc -O "$HELPER_DIR/winid.swift" -o "$HELPER_DIR/winid" 2>/dev/null

  quit_app() {
    osascript -e 'quit app "DevSweep"' >/dev/null 2>&1 || true
    for _ in {1..20}; do pgrep -x DevSweep >/dev/null || return 0; sleep 0.5; done
    pkill -x DevSweep || true; sleep 1
  }

  # capture <lang> <scene> <wait> <extra args...>
  capture() {
    local lang="$1" scene="$2" wait="$3"; shift 3
    quit_app
    open -n "$APP" --args \
      -AppleLanguages "($lang)" -devsweep.language "$lang" \
      -"$FRAME_KEY" "$FRAME" -ApplePersistenceIgnoreState YES "$@"
    sleep "$wait"
    local id w h; read -r id w h < <("$HELPER_DIR/winid")
    if [[ "$id" == "0" ]]; then echo "  $lang/$scene: no DevSweep window found"; exit 2; fi
    [[ "$w" == "$WIN_W" && "$h" == "$WIN_H" ]] || echo "  $lang/$scene: window is ${w}×${h} pt, wanted ${WIN_W}×${WIN_H}"
    mkdir -p "$RAW/$lang"
    if ! screencapture -x -o -l"$id" "$RAW/$lang/$scene.png" 2>/dev/null; then
      echo "  capture refused — allow Screen Recording for the app running this script, unlock the display, retry"
      exit 2
    fi
  }

  for lang in "${LANGS[@]}"; do
    echo "› capturing $lang"
    capture "$lang" 01-developer   "$SCAN_WAIT"  -audience developer -devsweep.welcomeSeen.v2 YES
    capture "$lang" 02-system-data "$DATA_WAIT"  -audience everyday  -devsweep.welcomeSeen.v2 YES
    capture "$lang" 03-welcome     "$SHEET_WAIT" -audience developer -devsweep.welcomeSeen.v2 NO
  done
  quit_app
fi

for lang in "${LANGS[@]}"; do
  mkdir -p "$OUT/$lang"
  for scene in 01-developer 02-system-data 03-welcome; do
    [[ -f "$RAW/$lang/$scene.png" ]] || { echo "  missing $RAW/$lang/$scene.png"; continue; }
    "$HELPER_DIR/compose" "$RAW/$lang/$scene.png" "$(caption "$lang" "$scene")" "$OUT/$lang/$scene.png"
    echo "  $OUT/$lang/$scene.png  $(sips -g pixelWidth -g pixelHeight "$OUT/$lang/$scene.png" | awk '/pixel/ {printf "%s ", $2}')"
  done
done
echo "Done. Check each picture for personal folder names before uploading."
