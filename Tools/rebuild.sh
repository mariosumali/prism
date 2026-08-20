#!/bin/bash
# rebuild.sh — build the current branch and (re)install it to /Applications.
#
#   Tools/rebuild.sh
#
# Regenerates the Xcode project, builds the PRISM scheme (Debug), then
# replaces /Applications/PRISM.app with the fresh build and launches it.
# The build that was installed before is kept as PRISM.app.previous so a bad
# build can be backed out without a rebuild. If anything fails, the app that
# was already installed is left running and untouched.
#
# Licensed under the Apache License, Version 2.0.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT=PRISM.xcodeproj
SCHEME=PRISM
CONFIG=Debug
INSTALLED=/Applications/PRISM.app
# Deliberately NOT named "*.app": a second real bundle in /Applications would
# register with Launch Services as another copy of PRISM, which is the exact
# duplicate-registration problem the app already has a history of. With a
# .previous extension it is an inert directory that Launch Services ignores.
PREVIOUS=/Applications/PRISM.app.previous
LOG="${TMPDIR:-/tmp}/prism-build.log"

# Always regenerate. project.yml lists sources as directories ("- path: PRISM"),
# so xcodegen enumerates the file tree when it runs: adding or deleting any
# source file changes the project even though project.yml itself did not. The
# old "regenerate only if project.yml is newer than project.pbxproj" test
# therefore built happily against a stale project, silently leaving new files
# out of the app and out of the test target. Generation costs ~0.1s; there was
# never anything to save by skipping it.
echo "==> generating project (xcodegen)"
xcodegen generate >/dev/null

# Warnings are kept out of the terminal and put in a log: this build emits
# dozens, and a real error scrolling past inside them is how a failed build
# gets mistaken for a successful one.
echo "==> building $SCHEME ($CONFIG)"
status=0
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -quiet build >"$LOG" 2>&1 || status=$?

if [ "$status" -ne 0 ]; then
    echo >&2
    echo "==> BUILD FAILED — nothing was installed, $INSTALLED is untouched" >&2
    echo >&2
    grep -E 'error:|\*\* BUILD FAILED' "$LOG" | head -40 >&2 || true
    echo >&2
    echo "    full log: $LOG" >&2
    exit "$status"
fi

# grep -c prints "0" AND exits 1 when there is no match, so the usual
# "|| echo 0" fallback would print a second zero. Take the count, then
# default it only if grep produced nothing at all.
warnings=$(grep -c "warning:" "$LOG" 2>/dev/null || true)
[ -n "$warnings" ] || warnings=0
if [ "$warnings" -eq 0 ]; then
    # Zero is also what an incremental build reports when nothing recompiled,
    # so do not let it read as "the warnings were fixed".
    echo "    ok — nothing new compiled, or no warnings (log: $LOG)"
else
    echo "    ok — $warnings warnings (log: $LOG)"
fi

# Ask xcodebuild where the product landed instead of hardcoding the
# DerivedData hash (it changes if the checkout ever moves).
APP=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ CODESIGNING_FOLDER_PATH =/{print $2; exit}')
[ -d "$APP" ] || { echo "rebuild.sh: built app not found at '$APP'" >&2; exit 1; }

if pgrep -x PRISM >/dev/null 2>&1; then
    echo "==> stopping the running PRISM"
    pkill -x PRISM || true
    sleep 1
fi

# Rotate rather than delete: keep exactly one generation back. The move is
# within /Applications so it is a rename, not a 21MB copy.
echo "==> installing to /Applications"
if [ -d "$INSTALLED" ]; then
    rm -rf "$PREVIOUS"
    mv "$INSTALLED" "$PREVIOUS"
fi

if ! ditto "$APP" "$INSTALLED"; then
    echo "rebuild.sh: install failed; restoring the previous build" >&2
    rm -rf "$INSTALLED"
    [ -d "$PREVIOUS" ] && mv "$PREVIOUS" "$INSTALLED"
    exit 1
fi

echo "==> launching"
open "$INSTALLED"
