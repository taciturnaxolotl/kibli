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

# devicectl sometimes stops early without an error. Re-fetch any recording
# whose log mentions frames that didn't arrive.
for dir in samples/recordings/*/; do
  name=$(basename "$dir")
  [ -f "$dir/log.jsonl" ] || continue
  wanted=$(grep -o '"frames/[0-9]*\.[a-z]*"' "$dir/log.jsonl" | sort -u | wc -l | tr -d ' ')
  have=$(ls "$dir/frames" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$have" -lt "$wanted" ]; then
    echo "re-fetching $name ($have of $wanted frame files)"
    xcrun devicectl device copy from --device "$device" \
      --domain-type appDataContainer --domain-identifier sh.dunkirk.kibli \
      --source "Documents/recordings/$name" --destination "$dir" >/dev/null 2>&1 || true
  fi
done
