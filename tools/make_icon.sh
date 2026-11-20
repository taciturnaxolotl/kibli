#!/bin/sh
# Renders the app icon variants from tools/icon.svg (needs rsvg-convert).
set -e
cd "$(dirname "$0")/.."
out=Kibli/Assets.xcassets/AppIcon.appiconset
rsvg-convert -w 1024 -h 1024 tools/icon.svg -o "$out/AppIcon-light.png"
sed 's/#16191C/#000000/' tools/icon.svg | rsvg-convert -w 1024 -h 1024 -o "$out/AppIcon-dark.png"
sed -e 's/#16191C/#000000/' -e 's/#F2A33A/#9A9A9A/g' -e 's/#F4ECDD/#FFFFFF/g' tools/icon.svg \
  | rsvg-convert -w 1024 -h 1024 -o "$out/AppIcon-tinted.png"
