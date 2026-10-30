#!/bin/bash
# Simgeyi çizer ve AppIcon.icns üretir: ./icon/make_icns.sh
set -euo pipefail
cd "$(dirname "$0")"
swift make_icon.swift AppIcon-1024.png
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  sips -z $s $s AppIcon-1024.png --out "AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) AppIcon-1024.png --out "AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns AppIcon.iconset -o ../AppIcon.icns
rm -rf AppIcon.iconset
echo "✓ AppIcon.icns güncellendi"
