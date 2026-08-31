#!/bin/bash

# Build and run Retrace in DEBUG mode with hot reloading support
# Usage: ./dev.sh

set -e

BUILD_CONFIG="debug"

# ---------------------------------------------------------------------------
# Parse version metadata from project.yml
# ---------------------------------------------------------------------------
MARKETING_VERSION=$(grep 'MARKETING_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
BUILD_NUMBER=$(grep 'CURRENT_PROJECT_VERSION' project.yml | head -1 | sed 's/.*"\(.*\)".*/\1/')
: "${MARKETING_VERSION:=0.0.0}"
: "${BUILD_NUMBER:=0}"

# ---------------------------------------------------------------------------
# Collect build metadata for standalone SwiftPM dev runs
# ---------------------------------------------------------------------------
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT_FULL=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
REMOTE_URL=$(git remote get-url origin 2>/dev/null || true)
FORK_NAME=$(printf "%s" "$REMOTE_URL" | sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##')

echo "🔨 Building Retrace v${MARKETING_VERSION} (DEBUG)..."
echo "   commit: ${GIT_COMMIT} (${GIT_BRANCH})"
swift build -c debug

# ---------------------------------------------------------------------------
# Code-sign the debug executable with a stable identity
# ---------------------------------------------------------------------------
# `swift build` leaves the binary ad-hoc signed (or unsigned), which is
# content-derived -- every rebuild gets a new identity and macOS re-requires
# Screen Recording/Accessibility permission on every single `./dev.sh` run.
# Sign with the same stable "Retrace Dev Local" identity build_and_sign.sh
# uses (see local/docs for one-time setup) so TCC grants persist across dev
# iterations too. Uses a distinct bundle identifier from the installed
# release build (io.retrace.app) so the two don't share -- or fight over --
# the same TCC grant; you'll need to grant permissions once for this dev
# identity, but it'll then survive every subsequent `./dev.sh` rebuild.
DEBUG_BIN="$(swift build -c debug --show-bin-path)/Retrace"
SIGN_IDENTITY="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"Retrace Dev Local\""; then
    SIGN_IDENTITY="Retrace Dev Local"
else
    echo "ℹ️  No trusted 'Retrace Dev Local' signing identity found; signing ad-hoc."
    echo "   Permissions (Screen Recording/Accessibility) will need to be re-granted"
    echo "   after every dev.sh rebuild until that identity is set up. See local/docs."
fi
codesign --force --sign "$SIGN_IDENTITY" --identifier "io.retrace.app.dev" \
    --entitlements "UI/Retrace.entitlements" "$DEBUG_BIN"

echo ""
echo "🚀 Starting Retrace..."
echo ""

# Gracefully quit any running instance (dev or production build -- they share
# the process name "Retrace" and the app's single-instance lock) so this
# rebuild takes over with minimal downtime and no manual quit/relaunch.
source "$(dirname "$0")/scripts/quit_app_gracefully.sh"
quit_running_app_gracefully "Retrace"

# Run the executable directly for hot reload support
RETRACE_VERSION="$MARKETING_VERSION" \
RETRACE_BUILD_NUMBER="$BUILD_NUMBER" \
RETRACE_GIT_COMMIT="$GIT_COMMIT" \
RETRACE_GIT_COMMIT_FULL="$GIT_COMMIT_FULL" \
RETRACE_GIT_BRANCH="$GIT_BRANCH" \
RETRACE_BUILD_DATE="$BUILD_DATE" \
RETRACE_BUILD_CONFIG="$BUILD_CONFIG" \
RETRACE_IS_DEV_BUILD="true" \
RETRACE_FORK_NAME="$FORK_NAME" \
"$DEBUG_BIN"
