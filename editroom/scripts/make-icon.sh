#!/bin/zsh
# Rebuilds the app icon set from one square image (PNG, JPEG or WebP).
#   scripts/make-icon.sh path/to/artwork.png [scale]
# The artwork is placed on the standard macOS rounded-square tile (824pt inside a 1024pt canvas,
# transparent corners, soft shadow) and written out at every size the asset catalog needs.
set -e
[[ -f "$1" ]] || { echo "usage: scripts/make-icon.sh <square image>"; exit 1 }
root="${0:A:h:h}"
set_dir="$root/Editroom/Assets.xcassets/AppIcon.appiconset"
master="$(mktemp -d)/icon_1024.png"
swift "$root/scripts/make-icon.swift" "$1" "$master" "${2:-1}"
for n in 16 32 128 256 512; do
  for s in 1 2; do
    sips -z $((n * s)) $((n * s)) "$master" --out "$set_dir/icon_${n}x${n}@${s}x.png" >/dev/null
  done
done
echo "Icon set updated. Rebuild the app to pick it up."
