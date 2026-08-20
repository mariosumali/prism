#!/bin/sh
# rebuild.sh — one command to get the whole of PRISM running from this checkout.
#
#   ./rebuild.sh                 app only, and offers to ship the driver too
#                                if the installed one is out of date
#   ./rebuild.sh --with-driver   app AND the audio driver (needs sudo)
#   ./rebuild.sh --driver-only   just the audio driver
#   ./rebuild.sh --rollback      put the previously installed app back
#   ./rebuild.sh --no-driver     app only, never ask about the driver
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
INSTALLED="/Applications/PRISM.app"
PREVIOUS="/Applications/PRISM.app.previous"
DO_APP=1
DO_DRIVER=0
ASK_DRIVER=1
DO_ROLLBACK=0

while [ $# -gt 0 ]; do
    case "$1" in
        --with-driver) DO_DRIVER=1 ;;
        --driver-only) DO_DRIVER=1; DO_APP=0 ;;
        --no-driver)   ASK_DRIVER=0 ;;
        --rollback)    DO_ROLLBACK=1; DO_APP=0 ;;
        -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# A bundle directory keeps its own mtime when only the binary inside it is
# relinked, and ditto preserves mtimes when copying — so the directory can read
# minutes older than the build that was just installed, which makes this whole
# report untrustworthy exactly when it matters. The Mach-O inside is the honest
# answer to "when was this built".
built_at() {
    _bin="$1/Contents/MacOS/PRISM"
    [ -f "$_bin" ] || _bin="$1"
    stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$_bin"
}

# Swap the running install with the one kept by Tools/rebuild.sh. Useful when a
# fresh build turns out worse than the one it replaced, without a rebuild.
if [ "$DO_ROLLBACK" -eq 1 ]; then
    if [ ! -d "$PREVIOUS" ]; then
        echo "rebuild.sh: no previous build kept at $PREVIOUS" >&2
        exit 1
    fi
    pkill -x PRISM 2>/dev/null || true
    sleep 1
    # Swap, so a rollback is itself reversible by running --rollback again.
    if [ -d "$INSTALLED" ]; then
        mv "$INSTALLED" "$PREVIOUS.swap"
        mv "$PREVIOUS" "$INSTALLED"
        mv "$PREVIOUS.swap" "$PREVIOUS"
    else
        mv "$PREVIOUS" "$INSTALLED"
    fi
    echo "==> rolled back to the previously installed build"
    open "$INSTALLED"
    exit 0
fi

if [ "$DO_APP" -eq 1 ]; then
    Tools/rebuild.sh
fi

# A stale driver is the single most common reason an audio change appears not
# to work, so offer to fix it rather than only reporting it. Only when there is
# a terminal to prompt on, and never without saying what it costs.
if [ "$DO_DRIVER" -eq 0 ] && [ "$ASK_DRIVER" -eq 1 ] && [ -t 0 ] \
   && driver_is_stale; then
    echo
    echo "The installed driver is older than the driver sources in this"
    echo "checkout, so audio changes here are NOT live."
    echo "Installing it needs sudo and restarts coreaudiod, which briefly cuts"
    echo "ALL system audio on this Mac. Do not do this mid-meeting."
    printf "Install the driver now? [y/N] "
    read -r reply || reply=""
    case "$reply" in
        [yY]*) DO_DRIVER=1 ;;
        *) echo "    skipped — run ./rebuild.sh --driver-only when ready" ;;
    esac
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
if [ -d "$INSTALLED" ]; then
    echo "    app       $(built_at "$INSTALLED")  $INSTALLED"
else
    echo "    app       NOT INSTALLED"
fi
if [ -d "$PREVIOUS" ]; then
    echo "    previous  $(built_at "$PREVIOUS")  (./rebuild.sh --rollback)"
fi
if [ -d "$DRIVER" ]; then
    echo "    driver    $(built_at "$DRIVER")  $DRIVER"
else
    echo "    driver    NOT INSTALLED — 'PRISM Microphone' will not exist"
fi

if [ "$DO_DRIVER" -eq 0 ] && driver_is_stale; then
    echo
    echo "    ⚠  Driver still older than the sources here — audio changes in"
    echo "       this checkout are NOT live:  ./rebuild.sh --driver-only"
fi

# Whether the app came up is a fact worth checking rather than announcing.
if [ "$DO_APP" -eq 1 ]; then
    sleep 2
    if pgrep -x PRISM >/dev/null 2>&1; then
        echo
        echo "    PRISM is running. If the menu bar item is missing, open it"
        echo "    from the Dock — and see the menu-bar note in docs/ before"
        echo "    changing any icon code, which has been the wrong fix before."
    else
        echo
        echo "    ⚠  PRISM is not running after launch — check Console.app." >&2
    fi
fi
