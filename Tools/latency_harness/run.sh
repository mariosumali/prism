#!/bin/bash
# run.sh — compile and run the PRISM latency harness (Tools/latency_harness).
# The harness is built ad hoc with swiftc (not part of the Xcode project):
# RingBuffer.c is compiled with clang and linked in, and the shared C ring
# API is exposed to Swift through harness-bridging.h.
#
# Licensed under the Apache License, Version 2.0.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$DIR/build"
BIN="$BUILD/prism-latency-harness"

mkdir -p "$BUILD"

echo "==> Compiling RingBuffer.c"
xcrun clang -O2 -c "$DIR/../../PRISMShared/RingBuffer.c" -o "$BUILD/RingBuffer.o"

echo "==> Compiling harness.swift"
xcrun swiftc -O -swift-version 5 \
    "$DIR/harness.swift" \
    "$BUILD/RingBuffer.o" \
    -import-objc-header "$DIR/harness-bridging.h" \
    -framework AVFoundation \
    -framework CoreMedia \
    -framework CoreMediaIO \
    -framework CoreVideo \
    -o "$BIN"

echo "==> Running $BIN $*"
exec "$BIN" "$@"
