#!/bin/bash
set -euo pipefail

# =============================================================================
# setup-signing-identity.sh — Create the stable self-signed code-signing
# identity used by build-perch.sh (one-time setup).
#
# WHY: Without a paid Apple Developer identity we sign the local build ourselves.
# Ad-hoc signing (`-s -`) produces a new cdhash every build, which makes macOS
# TCC reset ALL permission grants (Accessibility, Screen Recording, Microphone)
# on every rebuild. A stable self-signed cert fixes that: TCC keys its grants off
# the signature's Designated Requirement, which references this cert. Same cert →
# same requirement → grants persist across rebuilds.
#
# HOW (the trick that avoids any GUI/password prompt): the cert lives in a
# DEDICATED keychain whose password this script sets. Because we own that
# password, we can set the key's partition list non-interactively — the step that
# otherwise fails with errSecInternalComponent or pops a system auth dialog when
# done against the login keychain. The cert does NOT need to be system-trusted
# for codesign to sign with it. The password protects only this throwaway local
# signing keychain; override it with PERCH_SIGN_KEYCHAIN_PASSWORD if you like.
#
# Run once:  ./scripts/setup-signing-identity.sh
# Then:      ./scripts/build-perch.sh   (uses the identity automatically)
#
# IDEMPOTENT: if the identity already exists and can sign, this script reuses it
# and exits — regenerating the cert would change the Designated Requirement and
# reset every TCC grant on every machine that trusts the old cert. Pass
# PERCH_FORCE_NEW_IDENTITY=1 to deliberately regenerate (you will have to
# re-grant Accessibility / Screen Recording / Microphone afterwards).
#
# After the FIRST build signed with this identity, re-grant the permissions once.
# They will then survive all subsequent rebuilds.
# =============================================================================

CN="Perch Self Signed"
KCNAME="perchdev.keychain"
KEYCHAIN_DB="$HOME/Library/Keychains/perchdev.keychain-db"
PW="${PERCH_SIGN_KEYCHAIN_PASSWORD:-perch}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sign_test() {
    local testbin="$WORK/signtest"
    printf '#!/bin/sh\necho hi\n' > "$testbin"; chmod +x "$testbin"
    codesign --force --sign "${CN}" --timestamp=none "$testbin" >/dev/null 2>&1
}

# ── Reuse the existing identity if it still works ────────────────────────────
if [ "${PERCH_FORCE_NEW_IDENTITY:-0}" != "1" ] && [ -f "$KEYCHAIN_DB" ] \
    && security find-certificate -c "${CN}" "$KEYCHAIN_DB" >/dev/null 2>&1; then
    security unlock-keychain -p "${PW}" "${KCNAME}" 2>/dev/null || true
    if sign_test; then
        echo "✅ Existing identity '${CN}' found and usable — reusing it."
        echo "   (Regenerating would reset all TCC permission grants. If you"
        echo "    really need a fresh cert, run with PERCH_FORCE_NEW_IDENTITY=1.)"
        exit 0
    fi
    echo "❌ Identity '${CN}' exists in ${KEYCHAIN_DB} but cannot sign."
    echo "   Check PERCH_SIGN_KEYCHAIN_PASSWORD (keychain may be locked), or run"
    echo "   with PERCH_FORCE_NEW_IDENTITY=1 to regenerate — note that ALL TCC"
    echo "   grants (Accessibility, Screen Recording, Mic) will need re-granting."
    exit 1
fi

if [ -f "$KEYCHAIN_DB" ]; then
    echo "⚠️  PERCH_FORCE_NEW_IDENTITY=1 — replacing the existing identity."
    echo "   ALL TCC permission grants tied to the old cert will stop validating;"
    echo "   remove Perch from each Privacy & Security list and re-grant after the"
    echo "   next build (or: tccutil reset Accessibility app.perch.notch)."
fi

echo "▶︎ Generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=${CN}" \
    -addext "extendedKeyUsage=codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" >/dev/null 2>&1

# -legacy: macOS Security framework can't read OpenSSL 3's default PKCS12 MAC.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/cert.p12" -passout "pass:${PW}" -name "${CN}" >/dev/null 2>&1

echo "▶︎ Creating dedicated keychain (password we control)…"
security delete-keychain "${KCNAME}" 2>/dev/null || true
security create-keychain -p "${PW}" "${KCNAME}"
security set-keychain-settings "${KCNAME}"            # disable auto-lock timeout
security unlock-keychain -p "${PW}" "${KCNAME}"

echo "▶︎ Importing identity and allowing codesign to use it…"
security import "$WORK/cert.p12" -k "${KCNAME}" -P "${PW}" -T /usr/bin/codesign -A >/dev/null 2>&1

echo "▶︎ Setting key partition list (no GUI — we own the keychain password)…"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${PW}" "${KCNAME}" >/dev/null 2>&1

echo "▶︎ Adding keychain to the user search list (keeping existing)…"
EXISTING=$(security list-keychains -d user | sed 's/[",]//g' | xargs)
case " ${EXISTING} " in
    *"${KEYCHAIN_DB}"*) ;;  # already in the search list
    *) security list-keychains -d user -s ${EXISTING} "${KCNAME}" ;;
esac

echo "▶︎ Verifying codesign can sign with it…"
if sign_test; then
    echo "✅ Signing identity '${CN}' is ready. Run ./scripts/build-perch.sh to build."
else
    echo "❌ Test sign failed — identity not usable."
    exit 1
fi
