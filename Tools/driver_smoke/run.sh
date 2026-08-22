#!/bin/bash
# run.sh — build and run the PRISM AudioServerPlugIn driver smoke test.
#
# Compiles the driver sources directly into a CLI (no bundle loading) and
# executes it. Exits nonzero if compilation fails or any assertion FAILs.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SRC="$DIR"
BIN="${TMPDIR:-/tmp}/prism_driver_smoke"

if pgrep -x PRISM >/dev/null 2>&1; then
  echo "driver_smoke: quit PRISM before running this test." >&2
  echo "              The smoke test owns and resets the production audio ring." >&2
  exit 2
fi

OBJDIR="$(mktemp -d "${TMPDIR:-/tmp}/prism_driver_smoke_obj.XXXXXX")"
trap 'rm -rf "$OBJDIR"' EXIT

# RingBuffer.c is C11 (C11 _Atomic, C semantics) — compile it as C in its own
# step; a clang++ driver invocation would treat it as C++ and -std=c++17 is
# not a valid C mode.
xcrun clang -std=c11 -Wall -Wextra \
  -I"$ROOT/PRISMShared" \
  -c "$ROOT/PRISMShared/RingBuffer.c" \
  -o "$OBJDIR/RingBuffer.o"

# The driver sources and the test are C++17.
xcrun clang++ -std=c++17 -Wall -Wextra \
  -I"$ROOT/PRISMShared" \
  -I"$ROOT/PRISMAudioPlugIn" \
  "$SRC/main.cpp" \
  "$ROOT/PRISMAudioPlugIn/PRISM_PlugIn.cpp" \
  "$ROOT/PRISMAudioPlugIn/PRISM_Device.cpp" \
  "$ROOT/PRISMAudioPlugIn/PRISM_Stream.cpp" \
  "$OBJDIR/RingBuffer.o" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$BIN"

exec "$BIN"
