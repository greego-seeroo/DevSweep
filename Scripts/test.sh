#!/bin/bash
# Runs DevSweep's test suite. Add --live to include the slower checks that scan
# this machine's real caches and verify every offered row against the guard.
set -euo pipefail
cd "$(dirname "$0")/.."   # repository root

BIN="$(mktemp -d)/devsweep-tests"

swiftc \
  -swift-version 5 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/Core/*.swift \
  Tests/main.swift \
  -o "$BIN"

"$BIN" "$@"

# The view model is driven headlessly against this machine's real caches, so
# it belongs with the live checks. Compiled separately: it needs ScanModel and
# SwiftUI, which the core suite deliberately leaves out.
if [[ " $* " == *" --live "* ]]; then
  MODEL_BIN="$(dirname "$BIN")/devsweep-model-tests"
  swiftc \
    -swift-version 5 \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -target "$(uname -m)-apple-macos14.0" \
    -framework SwiftUI -framework AppKit \
    Sources/Core/*.swift Sources/App/ScanModel.swift \
    Tests/Model/main.swift \
    -o "$MODEL_BIN"
  echo
  echo "— Live view model (slow) —"
  "$MODEL_BIN"
fi
