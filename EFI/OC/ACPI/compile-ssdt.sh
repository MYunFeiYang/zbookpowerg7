#!/bin/sh
# Compile SSDT sources in this directory.
set -e
cd "$(dirname "$0")"
IASL="./iasl"
if [ ! -x "$IASL" ]; then
    IASL="$(command -v iasl || true)"
fi
if [ -z "$IASL" ] || [ ! -x "$IASL" ]; then
    echo "iasl not found. Copy from MaciASL.app/Contents/MacOS/iasl-stable to ./iasl" >&2
    exit 1
fi
for dsl in *.dsl; do
    [ -f "$dsl" ] || continue
    "$IASL" -ve "$dsl"
done
echo "Done."
