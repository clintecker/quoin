#!/usr/bin/env bash
# Regenerates docs/images from the fixtures: hero (light/dark) + gallery grid.
# Requires ImageMagick for the montage step.
set -euo pipefail
cd "$(dirname "$0")/.."
GEN_DOC_IMAGES=1 swift test --filter DocImageGeneration
FONT=/System/Library/Fonts/Supplemental/Arial.ttf
[ -f "$FONT" ] || FONT=/System/Library/Fonts/Helvetica.ttc
cd docs/images
magick montage \
  -font "$FONT" -pointsize 26 -background white -fill '#1a1a1a' \
  $(for f in $(ls tiles/*.png | sort); do echo -label "$(basename "${f%.png}")" "$f"; done) \
  -tile 4x6 -geometry '440x380>+10+12' gallery.png
# Flat-color diagrams quantize to 8-bit with no visible loss — ~4x smaller.
magick gallery.png -colors 255 -define png:compression-level=9 gallery.png
for f in hero-light.png hero-dark.png; do
  magick "$f" -resize 2200 -colors 255 -define png:compression-level=9 "$f"
done
rm -rf tiles
echo "docs/images: hero-light.png hero-dark.png gallery.png"
