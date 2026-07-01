#!/usr/bin/env bash
# No-Xcode verification of the vision gate's deterministic deictic guard.
# Compiles the REAL product source (ClickyBackend/LLM/VisionGateDeicticGuard.swift)
# together with scripts/vision-gate-check/main.swift and runs the checks.
#
# The guard forces a screen capture for messages that point at on-screen content
# ("which of these movies are on netflix?"), which the tiny LLM classifier has
# misrouted to the blind text-only path. Reliability over the saved round-trip.
# Usage: ./scripts/check-vision-gate.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

CB="notch/notch/PerchBackend"
BUILD_OUT="$(mktemp -t vision-gate-check)"

swiftc -swift-version 5 -target arm64-apple-macos14.2 \
  "$CB/LLM/VisionGateDeicticGuard.swift" \
  scripts/vision-gate-check/main.swift \
  -o "$BUILD_OUT"

"$BUILD_OUT"
