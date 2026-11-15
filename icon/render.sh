#!/bin/zsh
# Renders hush-icon.svg -> hush-icon-1024.png (Chrome, for full SVG filter support) -> AppIcon.icns
set -euo pipefail
cd "${0:A:h}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
  --window-size=1024,1024 --screenshot="$PWD/hush-icon-1024.png" "file://$PWD/hush-icon.svg" >/dev/null 2>&1
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  magick hush-icon-1024.png -filter Lanczos -resize ${s}x${s} AppIcon.iconset/icon_${s}x${s}.png
  magick hush-icon-1024.png -filter Lanczos -resize $((s*2))x$((s*2)) AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
echo "wrote AppIcon.icns"
