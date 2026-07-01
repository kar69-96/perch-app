#!/usr/bin/env bash
# No-Xcode verification of the Repeat & Share follow-ups' pure core: schedule
# next-fire math, schedule-store persistence, clicky://import URL parsing,
# and imported-playbook persistence. Compiles the REAL product sources
# together with scripts/workflow-share-check/main.swift and runs the checks.
#
# The canonical tests live in leanring-buddyTests/ (run via Xcode ⌘U); this is
# the Command-Line-Tools-only mirror. Usage: ./scripts/check-workflow-share.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

CB="notch/notch/PerchBackend"
BUILD_OUT="$(mktemp -t workflow-share-check)"

swiftc -swift-version 5 -target arm64-apple-macos14.2 \
  notch/notch/Dashboard/PerchSupportPaths.swift \
  "$CB/Workflows/Capture/WorkflowDemonstrationModels.swift" \
  "$CB/Workflows/Schedule/WorkflowScheduleModels.swift" \
  "$CB/Workflows/Schedule/WorkflowScheduleStore.swift" \
  "$CB/Workflows/Share/WorkflowShareModels.swift" \
  "$CB/Workflows/Playbook/WorkflowPlaybookStore.swift" \
  "$CB/Telemetry/WorkflowDebugLog.swift" \
  scripts/workflow-share-check/main.swift \
  -o "$BUILD_OUT"

# Disable the shared debug log so fixture runs don't write noise into the real
# app's ~/Library/Application Support/Clicky log.
CLICKY_WORKFLOW_DEBUG_LOG_DISABLED=1 "$BUILD_OUT"
