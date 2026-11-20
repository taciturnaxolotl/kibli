#!/bin/sh
# Copies captured frames off the phone into samples/captures.
# usage: tools/pull_captures.sh [device-name-or-udid]
set -e
device="${1:-Briony}"
cd "$(dirname "$0")/.."
mkdir -p samples/captures
xcrun devicectl device copy from --device "$device" \
  --domain-type appDataContainer --domain-identifier sh.dunkirk.kibli \
  --source Documents/captures --destination samples/captures
