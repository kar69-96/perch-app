#!/bin/bash
set -euo pipefail

# =============================================================================
# build-perch.sh — Build the notch app (Perch) via xcodebuild, then RE-SIGN it
# with the stable "Clicky Self Signed" identity and relaunch.
#
# WHY: xcodebuild / Xcode "Run" signs ad-hoc ("Sign to Run Locally"), which gives
# a new cdhash every build -> macOS TCC drops Accessibility/Screen Recording/Mic
# grants on each rebuild (so the global hotkeys and the mic silently die).
# Re-signing with the stable self-signed cert (same Designated Requirement every
# time) makes those grants SURVIVE rebuilds.
#
# One-time: ./scripts/setup-signing-identity.sh must have created the identity,
# and you must grant the permissions ONCE after the first stable-signed run.
#
# Usage:  ./scripts/build-perch.sh
# =============================================================================

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_IDENTITY="Clicky Self Signed"
KEYCHAIN="$HOME/Library/Keychains/clickydev.keychain-db"
PROJECT="$REPO_DIR/notch/notch.xcodeproj"
SCHEME="notch"
ENTITLEMENTS="$REPO_DIR/notch/notch/notch.entitlements"
DERIVED_DATA="$REPO_DIR/notch/build/DerivedData"
APP="$DERIVED_DATA/Build/Products/Debug/Perch.app"

# ── Sanity: stable signing identity present ─────────────────────────────────
if ! security find-certificate -c "${SIGN_IDENTITY}" >/dev/null 2>&1; then
    echo "❌ Signing identity '${SIGN_IDENTITY}' not found."
    echo "   Run scripts/setup-signing-identity.sh first, or TCC grants will reset."
    exit 1
fi
security unlock-keychain -p clicky "${KEYCHAIN}" 2>/dev/null || true

echo "▶︎ Building Perch (xcodebuild, ad-hoc)…"
xcodebuild build -project "${PROJECT}" -scheme "${SCHEME}" -configuration Debug \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination 'platform=macOS,arch=arm64' 2>&1 | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" | tail -10

echo "▶︎ Quitting any running instance…"
osascript -e 'quit app "Perch"' 2>/dev/null || true
sleep 1

# ── Repoint the repo-relative paths to THIS checkout ─────────────────────────
# The committed Info.plist hardcodes absolute paths (PerchRepoRoot + the two
# browser-subagent paths). PerchSupportPaths trusts PerchRepoRoot before its
# .git-walk, so a stale path silently strands ALL on-disk state (support/, logs,
# IPC socket, sidecar) in a renamed-away directory. Rewrite the three keys from
# $REPO_DIR on every build so a move/rename of this checkout self-heals. Done
# BEFORE the re-sign below so the stable signature covers the patched plist.
BUILT_INFO_PLIST="${APP}/Contents/Info.plist"
plist_set() { /usr/libexec/PlistBuddy -c "Set :$1 $2" "${BUILT_INFO_PLIST}" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :$1 string $2" "${BUILT_INFO_PLIST}"; }
plist_set PerchRepoRoot              "${REPO_DIR}"
plist_set BrowserSubagentPath        "${REPO_DIR}/browser-subagent"
plist_set BrowserSubagentSocketPath  "${REPO_DIR}/support/ipc/subagent.sock"
echo "   repo-root in app bundle: $(/usr/libexec/PlistBuddy -c 'Print :PerchRepoRoot' "${BUILT_INFO_PLIST}")"

echo "▶︎ Re-signing with the stable identity (keeps TCC grants)…"
codesign --force --deep --sign "${SIGN_IDENTITY}" --entitlements "${ENTITLEMENTS}" \
    --timestamp=none "${APP}"
# Capture-then-print rather than piping into `grep -m1`: under `set -o pipefail`,
# grep closing the pipe early sends SIGPIPE to codesign and aborts the script
# before it can relaunch the app.
SIGN_AUTHORITY="$(codesign -dv --verbose=4 "${APP}" 2>&1 | grep "Authority" | head -1 || true)"
echo "   authority: ${SIGN_AUTHORITY}"

echo "▶︎ Relaunching…"
open "${APP}"
sleep 2
if pgrep -f "Perch.app/Contents/MacOS/Perch" >/dev/null; then
    echo "✅ Perch running with the stable-signed build."
else
    echo "⚠️  Perch did not appear to launch — check the notch."
fi
