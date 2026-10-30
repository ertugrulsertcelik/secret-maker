#!/bin/bash
# Secret Bot.app oluşturur: ./build.sh  (çıktı: build/Secret Bot.app)
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN=$(swift build -c release --show-bin-path)

APP="build/Secret Bot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SecretBot" "$APP/Contents/MacOS/SecretBot"
cp Info.plist "$APP/Contents/Info.plist"

# Simge: AppIcon.icns varsa ekle
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/"; fi

codesign --force --deep -s - "$APP"
echo "Hazır: $(pwd)/$APP"
