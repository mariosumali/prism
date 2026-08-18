#!/bin/bash
# rebuild.sh — build the current branch and (re)install it to /Applications.
#
#   Tools/rebuild.sh
#
# Regenerates the Xcode project only when project.yml has changed, builds the
# PRISM scheme (Debug), then replaces /Applications/PRISM.app with the fresh
# build and launches it. If the build fails, the running app is left untouched.
#
# Licensed under the Apache License, Version 2.0.

set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT=PRISM.xcodeproj
SCHEME=PRISM
CONFIG=Debug

# Regenerate only if project.yml is newer than the generated project.
if [ project.yml -nt "$PROJECT/project.pbxproj" ]; then
    echo "==> project.yml changed; running xcodegen"
    xcodegen generate
fi

echo "==> building $SCHEME ($CONFIG)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
    -quiet build

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

echo "==> installing to /Applications"
rm -rf /Applications/PRISM.app
ditto "$APP" /Applications/PRISM.app

echo "==> launching"
open /Applications/PRISM.app
