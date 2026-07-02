#!/bin/bash
set -euo pipefail

# =============================================================================
# package-release.sh — Build + package the public Perch release DMG.
#
# Produces dist/notch.dmg (the exact asset name SETUP.md and the site's
# releases/latest/download URL expect), containing Perch.app with the prod
# identity (app.perch.notch) and the browser-subagent sidecar bundled into
# Contents/Resources.
#
# This is NOT a notarized release. macOS Gatekeeper quarantines the app on any
# machine other than the one that built it; SETUP.md walks users past it
# (xattr -dr com.apple.quarantine). A trusted double-clickable build needs an
# Apple Developer Program membership, a Developer ID cert, and notarization.
#
# What it does:
#   1. Fresh Release xcodebuild into its OWN DerivedData (never the dev one —
#      build-perch-dev.sh rebrands its Release product to "Perch Dev.app" in
#      place, so dev DerivedData must never be packaged).
#   2. Copies Perch.app to a staging dir (originals stay untouched).
#   3. Clears machine-specific Info.plist paths (BrowserSubagentPath,
#      PerchRepoRoot, BrowserSubagentSocketPath) so an installed app uses its
#      fallbacks (state → ~/.perch-support). Defensive: the committed
#      Info.plist doesn't carry them; only dev builds inject them.
#   4. Bundles the browser-subagent sidecar source into Contents/Resources —
#      same seam BrowserSubagentProcessSupervisor resolves. Its venv +
#      Chromium are provisioned at first agent use into the writable support
#      dir (the supervisor sets PERCH_SIDECAR_STATE_DIR), never the signed
#      bundle.
#   5. Deep re-signs with the stable "Perch Self Signed" identity +
#      entitlements. Stable cert → stable Designated Requirement → users'
#      Accessibility/Screen Recording/Mic grants survive app UPDATES. Every
#      future release MUST use the same cert (keep perchdev.keychain-db safe).
#   6. Builds a compressed DMG with an /Applications drop symlink.
#
# Usage:
#   ./scripts/package-release.sh
#
# Env:
#   PERCH_SKIP_BUILD=1               reuse an existing Release Perch.app
#   PERCH_SIDECAR_SOURCE=<dir>       sidecar source (default: sibling backend
#                                    repo ../beta-backend-perch/browser-subagent)
#   PERCH_ALLOW_NO_SIDECAR=1         package without the sidecar (agent feature
#                                    will be unavailable in the shipped app)
#   PERCH_SIGN_KEYCHAIN_PASSWORD     perchdev keychain password (default: perch)
#   PERCH_WORKFLOW_SHARE_CLIENT_SECRET
#                                    real X-Perch-Client secret injected into the
#                                    staged Info.plist (also read from ./.env,
#                                    which is gitignored). The committed plist
#                                    carries only the YOUR_WORKFLOW_SHARE_SECRET
#                                    placeholder; without a real value the
#                                    shipped app's workflow-share upload 401s.
# =============================================================================

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_DIR/perch/notch.xcodeproj"
SCHEME="notch"
ENTITLEMENTS="$REPO_DIR/perch/notch/notch.entitlements"
# Dedicated DerivedData — see step 1 in the header.
DERIVED_DATA="$REPO_DIR/perch/build/DerivedData-release"
SOURCE_APP="$DERIVED_DATA/Build/Products/Release/Perch.app"
STAGING_DIR="$REPO_DIR/dist/staging"
APP_COPY="$STAGING_DIR/Perch.app"
DMG_PATH="$REPO_DIR/dist/notch.dmg"
VOLUME_NAME="Perch"
SIGN_IDENTITY="Perch Self Signed"
KEYCHAIN="$HOME/Library/Keychains/perchdev.keychain-db"

# ── 1. Release build ─────────────────────────────────────────────────────────
if [ "${PERCH_SKIP_BUILD:-0}" = "1" ] && [ -d "$SOURCE_APP" ]; then
    echo "▶︎ PERCH_SKIP_BUILD=1 — reusing $SOURCE_APP"
else
    echo "▶︎ Building Perch (Release, fresh DerivedData — takes a few minutes)…"
    xcodebuild build -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
        -derivedDataPath "$DERIVED_DATA" \
        -destination 'platform=macOS,arch=arm64' 2>&1 \
        | grep -E "error:|warning: .*deprecated|BUILD SUCCEEDED|BUILD FAILED" | tail -10
fi
if [ ! -d "$SOURCE_APP" ]; then
    echo "❌ Release app not found at $SOURCE_APP"
    exit 1
fi

# ── 2. Stage a copy ──────────────────────────────────────────────────────────
echo "▶︎ Staging a copy (the built product is left untouched)…"
rm -rf "$STAGING_DIR" "$DMG_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$SOURCE_APP" "$APP_COPY"

# ── 3. Clear machine-specific Info.plist paths ───────────────────────────────
echo "▶︎ Clearing machine-specific Info.plist paths…"
PLIST="$APP_COPY/Contents/Info.plist"
for key in BrowserSubagentPath PerchRepoRoot BrowserSubagentSocketPath; do
    plutil -remove "$key" "$PLIST" 2>/dev/null || true
done

# ── 3.5. Inject the workflow-share client secret ─────────────────────────────
# The committed Info.plist holds only a placeholder so the public repo never
# carries the real secret. Releases get the real value here, from the env or
# the gitignored .env at the repo root.
if [ -z "${PERCH_WORKFLOW_SHARE_CLIENT_SECRET:-}" ] && [ -f "$REPO_DIR/.env" ]; then
    PERCH_WORKFLOW_SHARE_CLIENT_SECRET="$(grep -m1 '^PERCH_WORKFLOW_SHARE_CLIENT_SECRET=' \
        "$REPO_DIR/.env" | cut -d= -f2-)"
fi
if [ -n "${PERCH_WORKFLOW_SHARE_CLIENT_SECRET:-}" ]; then
    echo "▶︎ Injecting workflow-share client secret…"
    plutil -replace WorkflowShareClientSecret \
        -string "$PERCH_WORKFLOW_SHARE_CLIENT_SECRET" "$PLIST"
else
    echo "⚠️  PERCH_WORKFLOW_SHARE_CLIENT_SECRET not set (env or .env) — the"
    echo "   placeholder ships and workflow-share uploads will 401 in this build."
fi

# ── 4. Bundle the sidecar (open-core seam) ───────────────────────────────────
SIDECAR_SOURCE="${PERCH_SIDECAR_SOURCE:-$REPO_DIR/../beta-backend-perch/browser-subagent}"
if [ -f "$SIDECAR_SOURCE/run.sh" ]; then
    echo "▶︎ Bundling sidecar from $SIDECAR_SOURCE → Contents/Resources/browser-subagent…"
    DEST_SIDECAR="$APP_COPY/Contents/Resources/browser-subagent"
    mkdir -p "$DEST_SIDECAR"
    rsync -a --delete \
        --exclude '.venv/' --exclude '__pycache__/' --exclude '*.pyc' \
        --exclude 'ms-playwright/' --exclude '.env' --exclude 'agent-profile/' \
        --exclude '.pytest_cache/' --exclude '.ruff_cache/' --exclude 'tests/' \
        --exclude '*.egg-info/' --exclude 'eval/' --exclude 'routing_eval/' \
        "$SIDECAR_SOURCE/" "$DEST_SIDECAR/"
elif [ "${PERCH_ALLOW_NO_SIDECAR:-0}" = "1" ]; then
    echo "⚠️  No sidecar at $SIDECAR_SOURCE — packaging WITHOUT the browser agent."
else
    echo "❌ Sidecar source not found at $SIDECAR_SOURCE"
    echo "   The public release bundles the browser-subagent. Point"
    echo "   PERCH_SIDECAR_SOURCE at a checkout, or set PERCH_ALLOW_NO_SIDECAR=1"
    echo "   to ship without the agent feature."
    exit 1
fi

# ── 5. Re-sign ───────────────────────────────────────────────────────────────
# Ad-hoc `--deep --sign -` with no --entitlements would STRIP the app's
# entitlements (mic, apple-events, network…), and an ad-hoc signature has no
# stable Designated Requirement, so users' TCC grants would reset on every
# update. Sign with the stable identity + the real entitlements file.
echo "▶︎ Re-signing…"
if [ -f "$KEYCHAIN" ] && security find-certificate -c "$SIGN_IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    security unlock-keychain -p "${PERCH_SIGN_KEYCHAIN_PASSWORD:-perch}" "$KEYCHAIN" 2>/dev/null || true
    echo "   identity: $SIGN_IDENTITY (stable → users' TCC grants persist across updates)"
    codesign --force --deep --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN" \
        --entitlements "$ENTITLEMENTS" --timestamp=none "$APP_COPY"
else
    echo "   ⚠️  '$SIGN_IDENTITY' not found — ad-hoc fallback. DO NOT publish this"
    echo "      DMG: users' hotkey/TCC grants won't persist across updates."
    echo "      Run ./scripts/setup-signing-identity.sh and re-package."
    codesign --force --deep --sign - --entitlements "$ENTITLEMENTS" --timestamp=none "$APP_COPY"
fi
codesign --verify --deep --strict "$APP_COPY" && echo "   signature verifies"

# ── 6. Build the DMG ─────────────────────────────────────────────────────────
echo "▶︎ Building DMG…"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "$VOLUME_NAME" -srcfolder "$STAGING_DIR" \
    -ov -format UDZO "$DMG_PATH" >/dev/null
rm -rf "$STAGING_DIR"

SHA="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
SIZE="$(du -h "$DMG_PATH" | cut -f1)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || echo '?')"

cat <<EOF

✅ Release DMG ready
   Path:    $DMG_PATH
   Version: $VERSION
   Size:    $SIZE
   SHA256:  $SHA

Publish (asset name must stay notch.dmg — SETUP.md and the site depend on it):
  gh release create v$VERSION "$DMG_PATH" --target main \\
      --title "Perch v$VERSION" --notes "…"

Users install via SETUP.md — the app is not notarized, so the guide has them
clear quarantine (xattr -dr com.apple.quarantine).
EOF
