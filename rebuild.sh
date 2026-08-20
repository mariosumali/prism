#!/bin/sh
# rebuild.sh — one command to get the whole of PRISM running from this checkout.
#
#   ./rebuild.sh                 app only, plus a warning if the driver is stale
#   ./rebuild.sh --with-driver   app AND the audio driver (needs sudo)
#   ./rebuild.sh --driver-only   just the audio driver
#
# The app and the "PRISM Microphone" driver install to two different places and
# neither implies the other. Shipping only one of them leaves half a fix live —
# the usual reason a change "didn't work" — so this script always reports which
# halves are current and refuses to imply it installed something it did not.
#
# The work itself is done by the two existing scripts; this is a front door:
#   Tools/rebuild.sh        app  → /Applications/PRISM.app   (no sudo)
#   Tools/install_audio.sh  driver → /Library/Audio/Plug-Ins/HAL  (sudo,
#                           and it restarts coreaudiod, which briefly cuts
#                           ALL system audio on this Mac — not mid-meeting)
#
# Licensed under the Apache License, Version 2.0.

set -eu

cd "$(dirname "$0")"

DRIVER="/Library/Audio/Plug-Ins/HAL/PRISM.driver"
DO_APP=1
DO_DRIVER=0

while [ $# -gt 0 ]; do
    case "$1" in
        --with-driver) DO_DRIVER=1 ;;
        --driver-only) DO_DRIVER=1; DO_APP=0 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "rebuild.sh: unknown option '$1' (try --help)" >&2; exit 2 ;;
    esac
    shift
done

# Is the installed driver older than any driver source file? The driver reads
# the shared ring layout too, so PRISMShared counts as driver source.
driver_is_stale() {
    [ -d "$DRIVER" ] || return 0
    newest=$(find PRISMAudioPlugIn PRISMShared -type f \
                  \( -name '*.cpp' -o -name '*.c' -o -name '*.h' \) \
                  -newer "$DRIVER" -print -quit 2>/dev/null)
    [ -n "$newest" ]
}

if [ "$DO_APP" -eq 1 ]; then
    Tools/rebuild.sh
fi

if [ "$DO_DRIVER" -eq 1 ]; then
    if [ ! -t 0 ]; then
        echo >&2
        echo "rebuild.sh: --with-driver needs a terminal to prompt for sudo." >&2
        echo "            Run it yourself: sudo Tools/install_audio.sh --yes" >&2
        exit 1
    fi
    echo
    echo "==> installing the audio driver (sudo; restarts coreaudiod)"
    Tools/install_audio.sh --yes
fi

# Report only what is actually on disk right now.
echo
echo "==> state"
if [ -d /Applications/PRISM.app ]; then
    echo "    app     $(stat -f '%Sm' -t '%Y-%m-%d %H:%M' /Applications/PRISM.app)  /Applications/PRISM.app"
else
    echo "    app     NOT INSTALLED"
fi
if [ -d "$DRIVER" ]; then
    echo "    driver  $(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$DRIVER")  $DRIVER"
else
    echo "    driver  NOT INSTALLED — 'PRISM Microphone' will not exist"
fi

if [ "$DO_DRIVER" -eq 0 ] && driver_is_stale; then
    echo
    echo "    ⚠  The installed driver is older than the driver sources in this"
    echo "       checkout, so audio changes here are NOT live. To ship them:"
    echo "           ./rebuild.sh --driver-only"
fi

# Whether the app came up is a fact worth checking rather than announcing.
if [ "$DO_APP" -eq 1 ]; then
    sleep 2
    if pgrep -x PRISM >/dev/null 2>&1; then
        echo
        echo "    PRISM is running — open it from the Dock."
        echo "    (The menu bar item exists and works, but macOS is currently"
        echo "     not drawing it on this Mac; the Dock icon is the way in.)"
    else
        echo
        echo "    ⚠  PRISM is not running after launch — check Console.app." >&2
    fi
fi
