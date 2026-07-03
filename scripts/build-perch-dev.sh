#!/bin/bash
set -euo pipefail

# =============================================================================
# build-perch-dev.sh (app worktree) — Build a LOCAL "Perch Dev" install that
# behaves like the beta (so TCC grants actually stick) but runs against THIS
# repo's on-disk state, wiring the browser sidecar to the SIBLING BACKEND
# WORKTREE.
#
# This is the post-Big-Split variant for the app checkouts (which contain no
# browser-subagent/). It resolves the sidecar from the sibling backend checkout:
# `../backend` when run from dev/app, `../beta-backend-perch` when run from
# beta/beta-app-perch (see Perch_Project/.claude/perch-paths.sh for the map).
#
# WHY RELEASE (not Debug): a Debug build splits into a launcher stub that
# dlopen()s the real code, so macOS TCC attributes Accessibility / Screen
# Recording to the bare stub and the push-to-talk hotkeys silently die. Release
# is one self-contained executable, so TCC resolves to the bundle correctly.
# Distinct identity ("Perch Dev" / app.perch.notch.dev) + stable "Perch Self
# Signed" cert make the grants bind and persist across rebuilds.
#
# Grant Accessibility / Microphone / Screen Recording to "Perch Dev" ONCE after
# the first run; they then survive every rebuild.
#
# Usage:  ./scripts/build-perch-dev.sh
# =============================================================================

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_IDENTITY="Perch Self Signed"
KEYCHAIN="$HOME/Library/Keychains/perchdev.keychain-db"
# Password for the dedicated signing keychain (set by setup-signing-identity.sh).
# Override with PERCH_SIGN_KEYCHAIN_PASSWORD to match a non-default setup.
KEYCHAIN_PW="${PERCH_SIGN_KEYCHAIN_PASSWORD:-perch}"
PROJECT="$REPO_DIR/perch/notch.xcodeproj"
SCHEME="notch"
ENTITLEMENTS="$REPO_DIR/perch/notch/notch.entitlements"
DERIVED_DATA="$REPO_DIR/perch/build/DerivedData"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Perch.app"
# The renamed dev bundle lives beside the build product, in-repo, at a stable path.
APP="$DERIVED_DATA/Build/Products/Release/Perch Dev.app"
DEV_BUNDLE_ID="app.perch.notch.dev"

# ── Sanity: stable signing identity present ─────────────────────────────────
if ! security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
    echo "❌ Signing identity '${SIGN_IDENTITY}' not found."
    echo "   Run scripts/setup-signing-identity.sh first, or TCC grants will reset."
    exit 1
fi
security unlock-keychain -p "${KEYCHAIN_PW}" "${KEYCHAIN}" 2>/dev/null || true

echo "▶︎ Building Perch Dev (xcodebuild, RELEASE — no debug stub)…"
xcodebuild build -project "${PROJECT}" -scheme "${SCHEME}" -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -10

echo "▶︎ Quitting any running Perch Dev / stale dev instance…"
osascript -e 'quit app "Perch Dev"' 2>/dev/null || true
osascript -e 'quit app "Perch"' 2>/dev/null || true
sleep 1

# ── Rename the product to "Perch Dev.app" ────────────────────────────────────
rm -rf "${APP}"
mv "${BUILT_APP}" "${APP}"

# ── Give it the standalone "Perch Dev" identity ──────────────────────────────
PLIST="${APP}/Contents/Info.plist"
plutil -replace CFBundleIdentifier  -string "${DEV_BUNDLE_ID}" "${PLIST}"
plutil -replace CFBundleName        -string "Perch Dev" "${PLIST}"
plutil -replace CFBundleDisplayName -string "Perch Dev" "${PLIST}" 2>/dev/null || \
    plutil -insert CFBundleDisplayName -string "Perch Dev" "${PLIST}" 2>/dev/null || true
XPC_PLIST="${APP}/Contents/XPCServices/NotchXPCHelper.xpc/Contents/Info.plist"
if [ -f "${XPC_PLIST}" ]; then
    plutil -replace CFBundleIdentifier -string "${DEV_BUNDLE_ID}.NotchXPCHelper" "${XPC_PLIST}"
fi

# ── Keep the repo paths (dev state lives in <repo>/support + <repo>/logs) ─────
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "${PLIST}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "${PLIST}"; }
plist_set PerchRepoRoot              "${REPO_DIR}"

# Resolve the sidecar dir. The app checkout has no browser-subagent/ — it lives
# in the sibling backend checkout: `../backend` from dev/app (dev worktree pair),
# `../beta-backend-perch` from beta/beta-app-perch (beta pair). Prefer the
# sibling from the SAME pair so a dev build runs the dev sidecar.
if [ -d "${REPO_DIR}/../backend/browser-subagent" ]; then
    SIDECAR_DIR="$(cd "${REPO_DIR}/../backend/browser-subagent" && pwd)"
elif [ -d "${REPO_DIR}/../beta-backend-perch/browser-subagent" ]; then
    SIDECAR_DIR="$(cd "${REPO_DIR}/../beta-backend-perch/browser-subagent" && pwd)"
elif [ -d "${REPO_DIR}/browser-subagent" ]; then
    SIDECAR_DIR="${REPO_DIR}/browser-subagent"
else
    echo "⚠️  browser-subagent/ not found in a sibling backend checkout;"
    echo "    the autonomous agent will be unavailable in this dev build."
    SIDECAR_DIR="${REPO_DIR}/../backend/browser-subagent"   # dead path → agent cleanly unavailable
fi
plist_set BrowserSubagentPath        "${SIDECAR_DIR}"
plist_set BrowserSubagentSocketPath  "${REPO_DIR}/support/ipc/subagent.sock"

# Optional: point the dev build at a LOCAL worker (the backend worktree's
# local_dev_server.py on http://localhost:8787) instead of the prod Cloudflare
# worker. Set PERCH_WORKER_BASE_URL to override just the built bundle — the
# committed Info.plist stays pointed at prod. Unset → prod (default).
if [ -n "${PERCH_WORKER_BASE_URL:-}" ]; then
    plist_set WorkerBaseURL "${PERCH_WORKER_BASE_URL}"
    # TranscribeTokenURL is a full path, not a base, and is read independently of
    # WorkerBaseURL (AssemblyAIStreamingTranscriptionProvider). Point it at the same
    # local worker so push-to-talk mints its token there too — otherwise the app
    # registers locally (dev-install-token) but fetches the transcribe token from
    # prod, which rejects that token with 401 and ⌃⌥ never starts listening.
    plist_set TranscribeTokenURL "${PERCH_WORKER_BASE_URL}/transcribe-token"
    echo "   worker:    ${PERCH_WORKER_BASE_URL} (override)"
else
    echo "   worker:    $(/usr/libexec/PlistBuddy -c 'Print :WorkerBaseURL' "${PLIST}") (prod default)"
fi
echo "   identity: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${PLIST}") / \"Perch Dev\""
echo "   repo-root: $(/usr/libexec/PlistBuddy -c 'Print :PerchRepoRoot' "${PLIST}")"
echo "   sidecar:   ${SIDECAR_DIR}"

# ── Re-sign with the stable identity (keeps TCC grants across rebuilds) ──────
echo "▶︎ Re-signing with the stable identity…"
codesign --force --deep --sign "${SIGN_IDENTITY}" --keychain "${KEYCHAIN}" \
    --entitlements "${ENTITLEMENTS}" --timestamp=none "${APP}"
SIGN_AUTHORITY="$(codesign -dv --verbose=4 "${APP}" 2>&1 | grep "Authority" | head -1 || true)"
echo "   ${SIGN_AUTHORITY}"

echo "▶︎ Relaunching Perch Dev…"
open "${APP}"
sleep 2
if pgrep -f "Perch Dev.app/Contents/MacOS/Perch" >/dev/null; then
    echo "✅ Perch Dev running (Release, stable-signed, id ${DEV_BUNDLE_ID})."
else
    echo "⚠️  Perch Dev did not appear to launch — check the notch."
fi
