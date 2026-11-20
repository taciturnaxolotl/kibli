#!/bin/sh
# Copies captured frames and blackbox recordings off the phone into
# samples/captures and samples/recordings.
# usage: tools/pull_captures.sh [device-name-or-udid]
set -e
device="${1:-Briony}"
cd "$(dirname "$0")/.."
for kind in captures recordings; do
  mkdir -p "samples/$kind"
  xcrun devicectl device copy from --device "$device" \
    --domain-type appDataContainer --domain-identifier sh.dunkirk.kibli \
    --source "Documents/$kind" --destination "samples/$kind" >/dev/null 2>&1 \
    && echo "pulled $kind" || echo "no $kind yet"
done
