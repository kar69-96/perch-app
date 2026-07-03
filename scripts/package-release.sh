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
#   7. Signs the DMG with the Sparkle EdDSA key and prepends the release to
#      perch/updater/appcast.xml. Installed apps poll that file from
#      raw.githubusercontent.com (SUFeedURL) and verify the signature against
#      SUPublicEDKey — so updates only reach users after the appcast change
#      lands on main AND the release asset is published.
#
# Usage:
#   ./scripts/package-release.sh
#
# Env:
#   PERCH_SKIP_BUILD=1               reuse an existing Release Perch.app
#   PERCH_SPARKLE_KEY_FILE=<path>    Sparkle EdDSA private key (default:
#                                    ~/.perch-release/sparkle_ed25519_key —
#                                    also backed up in the login Keychain as
#                                    "Private key for signing Sparkle updates").
#                                    Losing this key means shipped apps can
#                                    NEVER auto-update again; guard it like
#                                    perchdev.keychain-db.
#   PERCH_RELEASE_NOTES_HTML=<html>  appcast release notes body (default links
#                                    to the GitHub release page)
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
APPCAST="$REPO_DIR/perch/updater/appcast.xml"
SPARKLE_KEY_FILE="${PERCH_SPARKLE_KEY_FILE:-$HOME/.perch-release/sparkle_ed25519_key}"
SPARKLE_VERSION="2.9.1"  # keep in lockstep with the Sparkle SPM dependency
SPARKLE_BIN="$REPO_DIR/perch/build/sparkle-tools/bin"

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
    echo "❌ Signing identity '$SIGN_IDENTITY' not found in $KEYCHAIN."
    echo "   Refusing to package: an ad-hoc signature has no stable Designated"
    echo "   Requirement, so every user's Accessibility/Screen Recording/Mic"
    echo "   grants would reset on this update (and on every rebuild)."
    echo "   Run ./scripts/setup-signing-identity.sh, then re-run this script."
    exit 1
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
    "$SOURCE_APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    "$SOURCE_APP/Contents/Info.plist")"

# ── 7. Sparkle: sign the DMG + refresh the appcast ───────────────────────────
# Sparkle rejects any update whose EdDSA signature doesn't match SUPublicEDKey,
# so an unsigned DMG is invisible to installed apps — fail loudly, don't skip.
if [ ! -f "$SPARKLE_KEY_FILE" ]; then
    echo "❌ Sparkle private key not found at $SPARKLE_KEY_FILE"
    echo "   Point PERCH_SPARKLE_KEY_FILE at it, or re-export from the login"
    echo "   Keychain: generate_keys -x <path>  (Sparkle $SPARKLE_VERSION tools)"
    exit 1
fi
if [ ! -x "$SPARKLE_BIN/sign_update" ]; then
    echo "▶︎ Fetching Sparkle $SPARKLE_VERSION sign_update tool…"
    mkdir -p "$(dirname "$SPARKLE_BIN")"
    curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
        | tar -xJ -C "$(dirname "$SPARKLE_BIN")" bin/sign_update
fi

echo "▶︎ Signing DMG for Sparkle…"
SIGN_OUTPUT="$("$SPARKLE_BIN/sign_update" -f "$SPARKLE_KEY_FILE" "$DMG_PATH")"
ED_SIGNATURE="$(echo "$SIGN_OUTPUT" | sed -n 's/.*edSignature="\([^"]*\)".*/\1/p')"
DMG_LENGTH="$(echo "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [ -z "$ED_SIGNATURE" ] || [ -z "$DMG_LENGTH" ]; then
    echo "❌ Could not parse sign_update output: $SIGN_OUTPUT"
    exit 1
fi

echo "▶︎ Updating ${APPCAST}…"
PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")" \
VERSION="$VERSION" BUILD="$BUILD" ED_SIGNATURE="$ED_SIGNATURE" \
DMG_LENGTH="$DMG_LENGTH" APPCAST="$APPCAST" \
NOTES_HTML="${PERCH_RELEASE_NOTES_HTML:-}" \
python3 <<'PY'
import os, re, sys

env = os.environ
appcast, version, build = env["APPCAST"], env["VERSION"], env["BUILD"]
notes = env["NOTES_HTML"] or (
    f'<p>See the <a href="https://github.com/Useperch/perch-app/releases/tag/'
    f'v{version}">release notes</a> for details.</p>')

item = f"""        <item>
            <title>{version}</title>
            <pubDate>{env["PUB_DATE"]}</pubDate>
            <link>https://github.com/Useperch/perch-app/releases/tag/v{version}</link>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[{notes}]]></description>
            <enclosure url="https://github.com/Useperch/perch-app/releases/download/v{version}/notch.dmg" length="{env["DMG_LENGTH"]}" type="application/octet-stream" sparkle:edSignature="{env["ED_SIGNATURE"]}"/>
        </item>"""

with open(appcast) as f:
    xml = f.read()

# Re-packaging the same build replaces its entry instead of duplicating it.
for existing in re.findall(r" {8}<item>.*?</item>\n", xml, flags=re.S):
    if f"<sparkle:version>{build}</sparkle:version>" in existing:
        xml = xml.replace(existing, "")

stale = [int(m) for m in re.findall(r"<sparkle:version>(\d+)</sparkle:version>", xml)
         if int(m) >= int(build)]
if stale:
    print(f"   ⚠️  appcast already lists build {max(stale)} ≥ this build {build} —"
          f" installed apps won't see this as an update. Bump MARKETING_VERSION"
          f" and CURRENT_PROJECT_VERSION in notch.xcodeproj.")

anchor = "        <link>https://github.com/Useperch/perch-app</link>\n"
if anchor not in xml:
    sys.exit(f"channel <link> anchor not found in {appcast} — was it hand-edited?")
with open(appcast, "w") as f:
    f.write(xml.replace(anchor, anchor + item + "\n", 1))
print(f"   appcast entry added: v{version} (build {build})")
PY

cat <<EOF

✅ Release DMG ready
   Path:    $DMG_PATH
   Version: $VERSION (build $BUILD)
   Size:    $SIZE
   SHA256:  $SHA
   Sparkle: signed; appcast updated at perch/updater/appcast.xml

Publish — updates reach installed apps only after BOTH steps:
  1. gh release create v$VERSION "$DMG_PATH" --target main \\
         --title "Perch v$VERSION" --notes "…"
     (asset name must stay notch.dmg — SETUP.md, the site, and the appcast
      enclosure URL all depend on it)
  2. git add perch/updater/appcast.xml && git commit && git push
     (installed apps poll the appcast from raw.githubusercontent.com/…/main)

Before the NEXT release: bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in
notch.xcodeproj — Sparkle only offers an update when CFBundleVersion increases.

Users install via SETUP.md — the app is not notarized, so the guide has them
clear quarantine (xattr -dr com.apple.quarantine). Sparkle-installed UPDATES
are not quarantined, so only the first install needs that step.
EOF
