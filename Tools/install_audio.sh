#!/bin/sh
# install_audio.sh — build and install the PRISM AudioServerPlugIn.
#
# This is onboarding step 3: it makes "PRISM Microphone" appear as a system
# input device. Unlike the camera extension, the HAL plug-in needs no
# provisioning profile and no special entitlement — it is an ordinary bundle
# that coreaudiod loads from /Library/Audio/Plug-Ins/HAL — so this works
# whether or not your Apple Developer account is in order.
#
#   ⚠️  Requires sudo (writes to /Library) and RESTARTS coreaudiod.
#       Restarting coreaudiod interrupts ALL system audio on this Mac for a
#       second or two. Every app playing or recording audio is affected.
#       Do not run this mid-meeting.
#
# To undo:
#   sudo rm -rf /Library/Audio/Plug-Ins/HAL/PRISM.driver
#   sudo killall coreaudiod
#
# Licensed under the Apache License, Version 2.0.

set -eu

cd "$(dirname "$0")/.."

DEST="/Library/Audio/Plug-Ins/HAL"
DRIVER="$DEST/PRISM.driver"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'
    echo
    echo "usage: Tools/install_audio.sh [--yes]"
    exit 0
fi

if [ "${1:-}" != "--yes" ]; then
    echo "This installs the PRISM HAL plug-in and restarts coreaudiod."
    echo "All system audio will be interrupted briefly."
    printf "Continue? [y/N] "
    read -r reply
    case "$reply" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "aborted"; exit 1 ;;
    esac
fi

if command -v xcodegen >/dev/null 2>&1; then
    xcodegen generate >/dev/null
fi

# coreaudiod loads this bundle into its own hardened process, so it must carry
# a valid signature. A local Apple Development certificate is enough; ad-hoc
# works on a SIP-disabled machine but not always otherwise.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development: .*\)"/\1/p' | head -1)
[ -n "$IDENTITY" ] || IDENTITY="-"
echo "==> building PRISMAudioPlugIn (signing as: $IDENTITY)"

LOG="${TMPDIR:-/tmp}/prism-audio-build.log"
status=0
xcodebuild -project PRISM.xcodeproj -target PRISMAudioPlugIn \
    -configuration Release build \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    CODE_SIGN_STYLE=Manual \
    PROVISIONING_PROFILE_SPECIFIER="" \
    >"$LOG" 2>&1 || status=$?

if [ "$status" -ne 0 ]; then
    echo "==> BUILD FAILED — the installed driver was not touched" >&2
    grep -E "error:|\*\* BUILD FAILED" "$LOG" | head -40 >&2 || true
    echo "    full log: $LOG" >&2
    exit "$status"
fi

BUILT="build/Release/PRISM.driver"
[ -d "$BUILT" ] || { echo "install_audio.sh: $BUILT was not produced" >&2; exit 1; }

echo "==> installing to $DRIVER (sudo)"
sudo mkdir -p "$DEST"
sudo rm -rf "$DRIVER"
sudo cp -R "$BUILT" "$DRIVER"
sudo chown -R root:wheel "$DRIVER"

echo "==> restarting coreaudiod — system audio will glitch"
sudo killall coreaudiod || true

# coreaudiod is relaunched by launchd; give it a moment before we look.
sleep 3

echo "==> input devices now present:"
if system_profiler SPAudioDataType 2>/dev/null | grep -q "PRISM"; then
    echo "    PRISM Microphone is registered."
else
    echo "    PRISM not listed yet. coreaudiod refuses plug-ins it cannot"
    echo "    validate — check Console.app for coreaudiod messages. On a"
    echo "    machine with SIP enabled the plug-in must be signed by a"
    echo "    certificate the system trusts."
fi
