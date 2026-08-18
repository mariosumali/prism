#!/bin/bash
# run.sh — record from the installed "PRISM Microphone" and report whether
# audio actually arrives.
#
#   Tools/mic_probe/run.sh [seconds] [--control]
#
# The end-to-end counterpart to Tools/driver_smoke/run.sh: that one calls the
# driver directly and can only confirm the driver matches the test's idea of
# the contract; this one goes through the real HAL, the way a video call does.
# Run it after any change to PRISMAudioPlugIn, and after install_audio.sh.
#
#   --control   record from the built-in microphone instead, to prove this
#               probe holds microphone permission (a TCC-denied client
#               receives callbacks full of zeros — indistinguishable from a
#               broken device).
#
# Exits 0 when audio was captured, 1 on silence.
#
# Licensed under the Apache License, Version 2.0.

set -euo pipefail

cd "$(dirname "$0")/../.."

BIN="${TMPDIR:-/tmp}/prism_mic_probe"

xcrun clang -std=c11 -Wall -Wextra -O1 \
    -I PRISMShared \
    Tools/mic_probe/main.c \
    -framework AudioToolbox -framework CoreAudio -framework CoreFoundation \
    -o "$BIN"

exec "$BIN" "$@"
