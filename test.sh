#!/bin/bash
# Runs DevSweep's test suite. Add --live to include the slower checks that scan
# this machine's real caches and verify every offered row against the guard.
set -euo pipefail
cd "$(dirname "$0")"

BIN="$(mktemp -d)/devsweep-tests"

swiftc \
  -swift-version 5 \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "$(uname -m)-apple-macos14.0" \
  Sources/Models.swift Sources/Catalog.swift Sources/Scanner.swift \
  Tests/main.swift \
  -o "$BIN"

"$BIN" "$@"
