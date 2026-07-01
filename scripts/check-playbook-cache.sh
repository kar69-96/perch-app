#!/usr/bin/env bash
# No-Xcode verification of the playbook caching core: MATCH-directive parsing
# (update-vs-create decision) and the playbook store's list + update-in-place
# behavior. Compiles the REAL product sources together with
# scripts/playbook-cache-check/main.swift and runs the checks.
#
# The canonical tests live in leanring-buddyTests/ (run via Xcode ⌘U); this is
# the Command-Line-Tools-only mirror. Usage: ./scripts/check-playbook-cache.sh
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

CB="notch/notch/PerchBackend"
BUILD_OUT="$(mktemp -t playbook-cache-check)"

swiftc -swift-version 5 -target arm64-apple-macos14.2 \
  notch/notch/Dashboard/PerchSupportPaths.swift \
  "$CB/Workflows/Capture/WorkflowDemonstrationModels.swift" \
  "$CB/Workflows/Playbook/WorkflowPlaybookStore.swift" \
  "$CB/Workflows/Playbook/WorkflowPlaybookSynthesizer.swift" \
  "$CB/Workflows/Capture/WorkflowVideoKeyframeExtractor.swift" \
  "$CB/Overlay/WindowPositionManager.swift" \
  "$CB/Capture/CompanionScreenCaptureUtility.swift" \
  "$CB/Capture/AccessibilityTreeSnapshotter.swift" \
  "$CB/Workflows/Agent/WorkflowAgentModels.swift" \
  "$CB/Telemetry/PerchRunLog.swift" \
  "$CB/Telemetry/PerchDebugLog.swift" \
  "$CB/Telemetry/TurnTraceAccumulator.swift" \
  "$CB/Telemetry/TelemetryConsent.swift" \
  "$CB/Telemetry/TurnTraceUploader.swift" \
  "$CB/Identity/PerchEntitlement.swift" \
  "$CB/Identity/PerchInstallIdentity.swift" \
  "$CB/LLM/ClaudeAPI.swift" \
  "$CB/AppBundleConfiguration.swift" \
  "$CB/Telemetry/WorkflowDebugLog.swift" \
  scripts/playbook-cache-check/main.swift \
  -o "$BUILD_OUT"

# Disable the shared debug log so fixture runs don't write noise into the real
# app's ~/Library/Application Support/Clicky log.
CLICKY_WORKFLOW_DEBUG_LOG_DISABLED=1 "$BUILD_OUT"
