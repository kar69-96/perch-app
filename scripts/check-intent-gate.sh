#!/usr/bin/env bash
# No-Xcode verification of the Intent Gate (answer vs act lane classification).
# Compiles the REAL product source (ClickyBackend/Input/IntentGate.swift) together
# with scripts/intent-gate-check/main.swift and runs the checks.
#
# The product source now lives in boring.notch's ClickyBackend (leanring-buddy was
# retired); the canonical test cases are leanring-buddyTests/IntentGateTests.swift.
# Usage: ./scripts/check-intent-gate.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

CB="notch/notch/PerchBackend"
BUILD_OUT="$(mktemp -t intent-gate-check)"

swiftc -swift-version 5 -target arm64-apple-macos14.2 \
  "$CB/Input/IntentGate.swift" \
  scripts/intent-gate-check/main.swift \
  -o "$BUILD_OUT"

"$BUILD_OUT"
