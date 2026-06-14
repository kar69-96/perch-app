#!/usr/bin/env bash
# No-Xcode verification of the Intent Gate (answer vs act lane classification).
# Compiles the REAL product source (leanring-buddy/IntentGate.swift) together
# with scripts/intent-gate-check/main.swift and runs the checks.
#
# The canonical tests live in leanring-buddyTests/IntentGateTests.swift (run via
# Xcode ⌘U); this is the Command-Line-Tools-only mirror.
# Usage: ./scripts/check-intent-gate.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

BUILD_OUT="$(mktemp -t intent-gate-check)"

swiftc -swift-version 5 -target arm64-apple-macos14.2 \
  leanring-buddy/IntentGate.swift \
  scripts/intent-gate-check/main.swift \
  -o "$BUILD_OUT"

"$BUILD_OUT"
