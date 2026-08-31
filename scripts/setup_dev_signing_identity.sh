#!/bin/bash
# =============================================================================
# One-time setup for the stable local code-signing identity
# =============================================================================
# build_and_sign.sh and dev.sh sign dev builds with a self-signed identity
# named "Retrace Dev Local" instead of ad-hoc (`--sign -`), so macOS TCC
# grants (Screen Recording, Accessibility) survive every rebuild instead of
# resetting because the ad-hoc signature's identity changes with every build.
#
# This script creates and trusts that identity in the current user's login
# keychain. No sudo, nothing system-wide -- it only affects this machine.
#
# Full explanation, troubleshooting, and the renewal story live in
# AGENTS.md's "Code Signing for Local Development" section. Read that first if anything here fails.
#
# Usage:
#   ./scripts/setup_dev_signing_identity.sh            # create if missing
#   ./scripts/setup_dev_signing_identity.sh --replace   # delete existing
#                                                        # "Retrace Dev Local"
#                                                        # cert(s) first, then
#                                                        # recreate. Use this
#                                                        # to renew an
#                                                        # expiring/expired
#                                                        # cert. Costs one
#                                                        # more TCC re-grant.
# =============================================================================

set -euo pipefail

IDENTITY_NAME="Retrace Dev Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
# 10 years. Keychain Access's Certificate Assistant defaults to 1 year, which
# is a trap here: security find-identity -p codesigning silently stops
# listing an expired cert, both build scripts fall back to ad-hoc signing,
# and the whole point of this setup (never re-grant permissions) silently
# regresses a year later. See AGENTS.md.
VALIDITY_DAYS=3650

REPLACE=false
if [ "${1:-}" = "--replace" ]; then
    REPLACE=true
fi

existing_count=$(security find-certificate -a -c "$IDENTITY_NAME" "$KEYCHAIN" 2>/dev/null | grep -c '^keychain:' || true)

if [ "$existing_count" -gt 0 ]; then
    if [ "$REPLACE" = true ]; then
        echo "Removing $existing_count existing '$IDENTITY_NAME' certificate(s) from the login keychain..."
        while security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN" >/dev/null 2>&1; do
            security delete-certificate -c "$IDENTITY_NAME" "$KEYCHAIN"
        done
    else
        echo "⚠️  A '$IDENTITY_NAME' certificate already exists in the login keychain."
        echo ""
        echo "Not touching it automatically -- replacing a signing identity invalidates"
        echo "the TCC grants tied to it, so Screen Recording/Accessibility will need to"
        echo "be re-granted once after replacement. Check what's there first:"
        echo ""
        echo "    security find-identity -v -p codesigning | grep '$IDENTITY_NAME'"
        echo "    security find-certificate -c '$IDENTITY_NAME' -p | openssl x509 -noout -dates"
        echo ""
        echo "If it's expired, untrusted, or you just want a fresh one, re-run with:"
        echo "    ./scripts/setup_dev_signing_identity.sh --replace"
        exit 1
    fi
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

KEY="$WORKDIR/key.pem"
CERT="$WORKDIR/cert.pem"
P12="$WORKDIR/cert.p12"
P12_PASSWORD=$(openssl rand -base64 24)

cat > "$WORKDIR/codesign.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
x509_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = $IDENTITY_NAME

[v3_req]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

echo "Generating a $((VALIDITY_DAYS / 365))-year self-signed code-signing certificate..."
openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" \
    -days "$VALIDITY_DAYS" -nodes -config "$WORKDIR/codesign.cnf"

# Some macOS/LibreSSL `security import` builds reject the modern PKCS#12
# cipher default; -legacy falls back to one they accept. If -legacy isn't a
# recognized flag on this openssl, fall through to the plain export.
openssl pkcs12 -export -legacy -out "$P12" -inkey "$KEY" -in "$CERT" \
    -passout pass:"$P12_PASSWORD" 2>/dev/null || \
openssl pkcs12 -export -out "$P12" -inkey "$KEY" -in "$CERT" \
    -passout pass:"$P12_PASSWORD"

echo "Importing into the login keychain..."
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security

echo "Trusting it for code signing (user-level, login keychain only -- no sudo)..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$CERT"

echo ""
echo "Verifying the identity actually works for signing..."
echo "(macOS may show a 'codesign wants to use your confidential information"
echo " in Retrace Dev Local' keychain prompt here on first use -- click"
echo " 'Always Allow' so future builds never ask again.)"
TESTFILE="$WORKDIR/sigtest"
cp /bin/echo "$TESTFILE"
# The very first codesign after granting that prompt can fail transiently
# with errSecInternalComponent before the ACL change fully propagates --
# a known macOS quirk, not a real failure. Retry once after a beat.
if ! codesign --force --sign "$IDENTITY_NAME" "$TESTFILE" 2>&1; then
    echo "   (retrying once -- first sign after a keychain prompt can be flaky)"
    sleep 2
    codesign --force --sign "$IDENTITY_NAME" "$TESTFILE"
fi
AUTHORITY=$(codesign -dvvv "$TESTFILE" 2>&1 | grep "^Authority=" | head -1)

if [ "$AUTHORITY" != "Authority=$IDENTITY_NAME" ]; then
    echo "❌ Test sign did not report the expected authority (got: '$AUTHORITY')."
    echo "   Something is wrong with the identity -- see AGENTS.md troubleshooting."
    exit 1
fi

echo "✅ '$IDENTITY_NAME' is set up and verified as a working code-signing identity."
echo ""
echo "One-time next step: the next ./build_and_sign.sh or ./dev.sh run signs with"
echo "this identity. The first launch after that will prompt for Screen"
echo "Recording/Accessibility ONE more time (since it's a new identity to macOS) --"
echo "after that, every future rebuild reuses this identity and the grant persists."
echo "See AGENTS.md for details."
