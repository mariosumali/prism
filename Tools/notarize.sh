#!/bin/bash
# notarize.sh — notarize and staple PRISM release artifacts (§10):
# dist/PRISM.dmg and dist/PRISM-Audio.pkg, using notarytool with credentials
# from a keychain profile. Credentials are NEVER hardcoded or passed on the
# command line — create the profile once and this script only names it.
#
# Licensed under the Apache License, Version 2.0.
set -euo pipefail

PROFILE="${PRISM_NOTARY_PROFILE:-PRISM_NOTARY}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG="$ROOT/dist/PRISM.dmg"
PKG="$ROOT/dist/PRISM-Audio.pkg"

usage() {
    cat <<EOF
Usage: Tools/notarize.sh [--dmg-only | --pkg-only]

Submits dist/PRISM.dmg and dist/PRISM-Audio.pkg to Apple notarization
(waiting for the verdict) and staples the tickets, so both artifacts work
offline on first launch.

One-time setup — store credentials in your keychain under the profile
name "$PROFILE" (never put credentials in scripts or CI logs):

    xcrun notarytool store-credentials $PROFILE \\
        --apple-id you@example.com \\
        --team-id YOURTEAMID \\
        --password <app-specific password from appleid.apple.com>

Environment:
    PRISM_NOTARY_PROFILE   keychain profile name (default: PRISM_NOTARY)

Both artifacts must already be signed with Developer ID identities
(Tools/build_pkg.sh) — notarization rejects unsigned uploads.
EOF
}

DO_DMG=1
DO_PKG=1
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --dmg-only) DO_PKG=0 ;;
    --pkg-only) DO_DMG=0 ;;
    "") ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
esac

notarize_one() {
    local artifact="$1"
    echo "==> Submitting $(basename "$artifact") (waits for Apple's verdict)"
    xcrun notarytool submit "$artifact" --keychain-profile "$PROFILE" --wait
    echo "==> Stapling $(basename "$artifact")"
    xcrun stapler staple "$artifact"
    xcrun stapler validate "$artifact"
}

MISSING=0
if [ "$DO_DMG" -eq 1 ] && [ ! -f "$DMG" ]; then
    echo "!!  $DMG not found — run Tools/build_pkg.sh first." >&2
    MISSING=$((MISSING + 1))
    DO_DMG=0
fi
if [ "$DO_PKG" -eq 1 ] && [ ! -f "$PKG" ]; then
    echo "!!  $PKG not found — run Tools/build_pkg.sh first." >&2
    MISSING=$((MISSING + 1))
    DO_PKG=0
fi
if [ "$DO_DMG" -eq 0 ] && [ "$DO_PKG" -eq 0 ]; then
    echo "ERROR: nothing to notarize." >&2
    exit 1
fi

[ "$DO_DMG" -eq 1 ] && notarize_one "$DMG"
[ "$DO_PKG" -eq 1 ] && notarize_one "$PKG"

if [ "$MISSING" -gt 0 ]; then
    echo "==> Finished with $MISSING artifact(s) skipped (not built)." >&2
    exit 1
fi
echo "==> Notarization complete: both artifacts stapled and validated."
