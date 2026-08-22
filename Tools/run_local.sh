#!/bin/sh
# run_local.sh — build and launch PRISM.app on this machine, ad-hoc signed.
#
# Use this when provisioning is unavailable (expired Program License Agreement,
# no paid membership, a fresh clone) or when you just want to iterate on the UI
# and the video pipeline without touching Apple's servers.
#
# It signs with your local Apple Development certificate (no profile needed —
# a profile is only required for restricted entitlements) and uses
# PRISM/PRISM-Local.entitlements, which drops exactly the two keys Apple gates
# behind a profile. With no certificate at all it falls back to an ad-hoc
# signature.
#
#   WORKS   menu bar agent, popover, live preview, the whole Metal effects
#           chain, freeze, clips, presets, hotkeys, latency meter, physical
#           camera and microphone capture
#   BROKEN  "PRISM Camera" in other apps — installing the camera system
#           extension requires the entitlement, so onboarding stays incomplete
#           and the popover shows a setup banner. That is expected here.
#
# Do NOT strip the entitlements entirely: PRISM builds with the hardened
# runtime, and under it com.apple.security.device.{camera,audio-input} gate
# capture. Without them macOS denies the camera with no prompt and no TCC
# record, and the preview is simply black.
#
# For the real thing (virtual camera visible to Zoom/FaceTime) you need a
# provisioning profile: see README, "Read this first".
#
# Licensed under the Apache License, Version 2.0.

set -eu

cd "$(dirname "$0")/.."

BUILD_ONLY=0
WITH_LOGIN_ITEM=0
for arg in "$@"; do
    case "$arg" in
        --build-only) BUILD_ONLY=1 ;;
        --with-login-item) WITH_LOGIN_ITEM=1 ;;
        -h|--help)
            sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
            echo
            echo "usage: Tools/run_local.sh [--build-only] [--with-login-item]"
            exit 0
            ;;
        *) echo "run_local.sh: unknown option '$arg'" >&2; exit 2 ;;
    esac
done

if command -v xcodegen >/dev/null 2>&1; then
    echo "==> xcodegen generate"
    xcodegen generate >/dev/null
fi

# PRISM registers itself as a login item on first launch (§7). A build living
# in ./build is not something anyone wants launching at login, so trip the
# app's own one-shot guard first. Pass --with-login-item to allow it.
if [ "$WITH_LOGIN_ITEM" -eq 0 ]; then
    defaults write horse.prism.PRISM PRISMLoginItemDidRegister -bool true
fi

# A real certificate gives the bundle a stable TeamIdentifier, so the camera
# and microphone grants survive a rebuild. Ad-hoc signatures change hash every
# build and macOS re-asks (or silently stops trusting) each time.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)
if [ -n "$IDENTITY" ]; then
    echo "==> signing as: $IDENTITY"
else
    IDENTITY="-"
    echo "==> no Apple Development certificate found; signing ad-hoc"
    echo "    (camera and microphone grants will reset on every rebuild)"
fi

echo "==> building"
LOG="${TMPDIR:-/tmp}/prism-local-build.log"
LOCAL_DERIVED_DATA="$PWD/build/LocalDerivedData"
status=0
xcodebuild -project PRISM.xcodeproj -scheme PRISM -configuration Debug build \
    -derivedDataPath "$LOCAL_DERIVED_DATA" \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_ENTITLEMENTS="PRISM/PRISM-Local.entitlements" \
    PROVISIONING_PROFILE_SPECIFIER="" \
    >"$LOG" 2>&1 || status=$?

if [ "$status" -ne 0 ]; then
    echo "==> BUILD FAILED — existing build was not launched" >&2
    grep -E "error:|\*\* BUILD FAILED" "$LOG" | head -40 >&2 || true
    echo "    full log: $LOG" >&2
    exit "$status"
fi

grep -E "warning: .*(deprecat|unused)" "$LOG" || true

APP="$LOCAL_DERIVED_DATA/Build/Products/Debug/PRISM.app"
[ -x "$APP/Contents/MacOS/PRISM" ] || {
    echo "run_local.sh: $APP was not produced completely" >&2
    exit 1
}
if ! codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    echo "run_local.sh: $APP failed signature verification" >&2
    exit 1
fi

# A build product is not another installed copy of PRISM. Xcode can register
# it while building even when --build-only is used, so remove that transient
# Launch Services record before returning (and again after `open` below).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
unregister_build_copy() {
    if [ -x "$LSREGISTER" ]; then
        "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    fi
}

if [ "$BUILD_ONLY" -eq 1 ]; then
    unregister_build_copy
    echo "==> built $APP (not launched)"
    exit 0
fi

# A second copy in the menu bar helps nobody.
if pgrep -x PRISM >/dev/null 2>&1; then
    echo "==> stopping the running PRISM"
    pkill -x PRISM || true
    sleep 1
fi

echo "==> launching — look for the prism glyph in the menu bar"
echo "    (first launch prompts for camera and microphone access)"
open "$APP"
sleep 1
unregister_build_copy
