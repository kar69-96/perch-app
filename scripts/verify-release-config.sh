#!/usr/bin/env bash
#
# verify-release-config.sh — beta release-config guardrails.
#
# Asserts that a PACKAGED beta artifact (a .app or a .dmg produced by
# package-release.sh) is wired the way production needs. This is the class of check
# that would have caught the "app listens but does nothing" outage: a placeholder
# backend URL, a sidecar that never got bundled, machine-specific dev paths left in
# the shipped Info.plist, or the dev-only on-computer browser leaking into beta.
#
# Usage:
#   scripts/verify-release-config.sh [PATH]            # PATH = a .app or .dmg
#   scripts/verify-release-config.sh                   # auto-find dist/*.dmg
#   scripts/verify-release-config.sh --no-network      # skip the live gateway probe
#
# Exit code: 0 = all guardrails pass, 1 = one or more failed.
#
# Runs in dev against any built artifact (e.g. the beta DMG) — it inspects a build,
# it does not need this checkout to be the one that produced it.
set -uo pipefail

# ── The two known placeholders the packaging step must have replaced ──────────
readonly PLACEHOLDER_WORKER="https://your-worker-name.your-subdomain.workers.dev"
readonly PLACEHOLDER_SECRET="YOUR_WORKFLOW_SHARE_SECRET"

# ── Result accounting ─────────────────────────────────────────────────────────
PASS=0
FAIL=0
pass() { printf "  \033[32m✓\033[0m %s\n" "$1"; PASS=$((PASS + 1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; FAIL=$((FAIL + 1)); }
warn() { printf "  \033[33m•\033[0m %s\n" "$1"; }
section() { printf "\n\033[1m%s\033[0m\n" "$1"; }

NO_NETWORK=0
ARG=""
for a in "$@"; do
  case "$a" in
    --no-network) NO_NETWORK=1 ;;
    *) ARG="$a" ;;
  esac
done

# ── Resolve the artifact, mounting a DMG if needed ────────────────────────────
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOUNTPOINT=""
cleanup() { [ -n "$MOUNTPOINT" ] && hdiutil detach "$MOUNTPOINT" >/dev/null 2>&1 || true; }
trap cleanup EXIT

resolve_app() {
  local target="$1"
  if [ -z "$target" ]; then
    target="$(ls -t "$REPO_DIR"/dist/*.dmg 2>/dev/null | head -1)"
    [ -z "$target" ] && { echo "No artifact given and no dist/*.dmg found." >&2; echo "Usage: $0 [path-to-.app-or-.dmg]" >&2; exit 2; }
  fi
  if [ ! -e "$target" ]; then echo "Artifact not found: $target" >&2; exit 2; fi

  case "$target" in
    *.dmg)
      MOUNTPOINT="$(mktemp -d)/mnt"
      mkdir -p "$MOUNTPOINT"
      hdiutil attach "$target" -nobrowse -readonly -mountpoint "$MOUNTPOINT" >/dev/null 2>&1 \
        || { echo "Failed to mount DMG: $target" >&2; exit 2; }
      APP="$(ls -d "$MOUNTPOINT"/*.app 2>/dev/null | head -1)"
      [ -z "$APP" ] && { echo "No .app inside DMG: $target" >&2; exit 2; }
      ;;
    *.app) APP="$target" ;;
    *) echo "Expected a .app or .dmg, got: $target" >&2; exit 2 ;;
  esac
}

resolve_app "$ARG"
PLIST="$APP/Contents/Info.plist"
[ -f "$PLIST" ] || { echo "No Info.plist in $APP" >&2; exit 2; }

echo "Verifying release config of: $(basename "$APP")"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST" 2>/dev/null || echo '?')"
BUILD="$(plutil -extract CFBundleVersion raw "$PLIST" 2>/dev/null || echo '?')"
echo "Version $VERSION (build $BUILD)"

# Helper: read an Info.plist key (empty string if absent).
plist_get() { plutil -extract "$1" raw "$PLIST" 2>/dev/null; }
# Helper: is a key ABSENT from the Info.plist?
plist_absent() { ! plutil -extract "$1" raw "$PLIST" >/dev/null 2>&1; }

# ── 1. Backend URL is real (not a placeholder) and internally consistent ──────
section "Backend URL"
WORKER_URL="$(plist_get WorkerBaseURL)"
if [ -z "$WORKER_URL" ]; then
  fail "WorkerBaseURL is missing"
elif [ "$WORKER_URL" = "$PLACEHOLDER_WORKER" ]; then
  fail "WorkerBaseURL is still the placeholder ($PLACEHOLDER_WORKER)"
elif [[ "$WORKER_URL" != https://* ]]; then
  fail "WorkerBaseURL is not https: $WORKER_URL"
else
  pass "WorkerBaseURL is real: $WORKER_URL"
fi

WORKER_HOST="${WORKER_URL#https://}"; WORKER_HOST="${WORKER_HOST%%/*}"

TT_URL="$(plist_get TranscribeTokenURL)"
if [[ "$TT_URL" == https://"$WORKER_HOST"/* ]]; then
  pass "TranscribeTokenURL points at the same gateway host"
else
  fail "TranscribeTokenURL host mismatch or missing: '$TT_URL'"
fi

WS_URL="$(plist_get WorkflowShareBaseURL)"
if [[ "$WS_URL" == https://* ]]; then
  pass "WorkflowShareBaseURL is https: $WS_URL"
else
  fail "WorkflowShareBaseURL is not https or missing: '$WS_URL'"
fi

# ── 2. Injected secrets replaced the committed placeholders ───────────────────
section "Injected secrets"
SECRET="$(plist_get WorkflowShareClientSecret)"
if [ -z "$SECRET" ]; then
  fail "WorkflowShareClientSecret is missing"
elif [ "$SECRET" = "$PLACEHOLDER_SECRET" ]; then
  fail "WorkflowShareClientSecret is still the placeholder — workflow-share will 401"
else
  pass "WorkflowShareClientSecret was injected (not the placeholder)"
fi

# ── 3. Auto-update (Sparkle) is configured ────────────────────────────────────
section "Auto-update (Sparkle)"
FEED="$(plist_get SUFeedURL)"
[[ "$FEED" == https://* ]] && pass "SUFeedURL is https: $FEED" || fail "SUFeedURL missing or not https: '$FEED'"
EDKEY="$(plist_get SUPublicEDKey)"
[ -n "$EDKEY" ] && pass "SUPublicEDKey present (update signature can be verified)" || fail "SUPublicEDKey missing"

# ── 4. Machine-specific dev paths were stripped ───────────────────────────────
section "No machine-specific dev paths (package-release.sh strips these)"
for key in BrowserSubagentPath PerchRepoRoot BrowserSubagentSocketPath; do
  if plist_absent "$key"; then
    pass "$key is absent"
  else
    fail "$key is present in a release Info.plist: '$(plist_get "$key")' (points at the builder's machine)"
  fi
done

# ── 5. The sidecar is actually bundled ────────────────────────────────────────
section "Bundled sidecar"
SIDECAR="$APP/Contents/Resources/browser-subagent"
if [ -f "$SIDECAR/run.sh" ] && [ -d "$SIDECAR/perch_subagent" ]; then
  pass "Sidecar bundled (run.sh + perch_subagent present in Resources)"
else
  fail "Sidecar NOT bundled — $SIDECAR/run.sh missing (the agent can never start)"
fi

# ── 6. Not sandboxed — a sandboxed app cannot spawn the sidecar ───────────────
section "Entitlements"
ENTS="$(mktemp)"
codesign -d --entitlements - --xml "$APP" >"$ENTS" 2>/dev/null
SANDBOX="$(plutil -extract com.apple.security.app-sandbox raw "$ENTS" 2>/dev/null || echo 'absent')"
if [ "$SANDBOX" = "false" ] || [ "$SANDBOX" = "absent" ]; then
  pass "app-sandbox is off — the app can spawn the local sidecar"
else
  fail "app-sandbox is ON — the app cannot spawn /bin/zsh ./run.sh (sidecar dead)"
fi
rm -f "$ENTS"

# ── 7. Dev-only capabilities must NOT be enabled in beta ───────────────────────
# The on-computer browser lane is dev-only (see /sync skill: DEV-ONLY CAPABILITIES).
# Its enable flag must never be baked into a beta Info.plist.
section "Dev-only capability leak guard"
if plist_absent PerchLocalBrowserEnabled; then
  pass "PerchLocalBrowserEnabled is not baked into the release (on-computer browser stays dev-only)"
else
  fail "PerchLocalBrowserEnabled is present in a beta build — the dev-only browser lane leaked to users"
fi

# PerchComposioDirect is the DEV-ONLY flag that reaches Composio directly with the
# sidecar's own dev key. If it leaked into a beta build, the release would bypass the
# Worker proxy — shipping the real project key on user machines and dropping per-user
# isolation. Beta must ALWAYS route Composio through the Worker.
if plist_absent PerchComposioDirect; then
  pass "PerchComposioDirect is not baked into the release (Composio stays behind the Worker proxy for beta)"
else
  fail "PerchComposioDirect is present in a beta build — Composio would bypass the Worker proxy (key on-device + cross-tenant)"
fi

# PerchWarmSidecarOnLaunch is the DEV-ONLY flag that eager-spawns the sidecar at app
# launch (so the first agent action isn't cold). Beta must spawn it lazily on first use.
# Stripped by package-release.sh — assert it here too so a broken strip can't ship it.
if plist_absent PerchWarmSidecarOnLaunch; then
  pass "PerchWarmSidecarOnLaunch is not baked into the release (sidecar stays lazy-spawned for beta)"
else
  fail "PerchWarmSidecarOnLaunch is present in a beta build — the dev-only eager warm-up leaked to users"
fi

# ── 8. The baked-in gateway URL actually responds (live) ──────────────────────
if [ "$NO_NETWORK" = "0" ] && [ -n "$WORKER_URL" ] && [[ "$WORKER_URL" == https://* ]]; then
  section "Live gateway reachability (the URL this build will actually call)"
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$WORKER_URL/daily-headlines" 2>/dev/null || echo '000')"
  if [ "$CODE" = "200" ]; then
    pass "GET $WORKER_URL/daily-headlines → 200 (gateway is live and serving)"
  elif [ "$CODE" = "000" ]; then
    warn "Could not reach $WORKER_URL (no network?) — re-run online or with --no-network to skip"
  else
    fail "GET $WORKER_URL/daily-headlines → $CODE (the baked-in gateway URL does not resolve/serve)"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
printf "\n\033[1mResult:\033[0m %d passed, %d failed\n" "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || { echo "Beta release config has problems — do NOT ship."; exit 1; }
echo "Beta release config looks good."
