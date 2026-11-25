#!/bin/bash
# Pulls every localizable string out of the sources and merges it into
# Resources/Localizable.xcstrings — the same two steps Xcode runs on every build
# (SWIFT_EMIT_LOC_STRINGS + "sync string catalog"), here as a script so a
# Scripts/build.sh workflow stays in step with the catalog.
#
# New keys land with their translator comment and no translations; keys that
# vanished from the code are marked stale. Translate in Xcode's catalog editor
# or by editing the JSON, then rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."   # repository root

CATALOG="Resources/Localizable.xcstrings"
[[ -f "$CATALOG" ]] || printf '{\n  "sourceLanguage" : "en",\n  "strings" : {\n  },\n  "version" : "1.0"\n}\n' > "$CATALOG"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "› extracting (swiftc -emit-localized-strings)"
swiftc \
  -c -whole-module-optimization \
  -swift-version 5 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macos14.0" \
  -framework SwiftUI -framework AppKit \
  -emit-localized-strings -emit-localized-strings-path "$TMP" \
  Sources/Core/*.swift Sources/App/*.swift \
  -o "$TMP/DevSweep.o"

echo "› syncing $CATALOG"
xcrun xcstringstool sync "$CATALOG" --stringsdata "$TMP"/*.stringsdata

python3 - "$CATALOG" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
strings = d["strings"]
stale = [k for k, v in strings.items() if v.get("extractionState") == "stale"]
missing = {}
for k, v in strings.items():
    if v.get("shouldTranslate") is False or v.get("extractionState") == "stale":
        continue
    for lang in ("de", "ja", "fr", "es"):
        loc = v.get("localizations", {}).get(lang)
        if not loc:
            missing[lang] = missing.get(lang, 0) + 1
print(f"  {len(strings)} keys, {len(stale)} stale")
for lang, n in sorted(missing.items()):
    print(f"  {lang}: {n} untranslated")
PY
