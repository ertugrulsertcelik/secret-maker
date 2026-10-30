#!/bin/bash
# Secret Bot.app'i derler ve paketler.
#   ./build.sh               build/Secret Bot.app (bu Mac'in mimarisi)
#   ./build.sh --universal   Intel + Apple Silicon tek pakette
#   ./build.sh --zip         ayrıca dist/SecretBot-<sürüm>.zip üretir
#   ./build.sh --install     /Applications'a (veya INSTALL_DIR) kurar ve açar
# Sürüm: VERSION ortam değişkeni, yoksa son git etiketi (v1.2.0 → 1.2.0), yoksa 1.0.0.
set -euo pipefail
cd "$(dirname "$0")"

UNIVERSAL=0; ZIP=0; INSTALL=0
for a in "$@"; do
  case "$a" in
    --universal) UNIVERSAL=1 ;;
    --zip) ZIP=1 ;;
    --install) INSTALL=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "Bilinmeyen seçenek: $a (yardım: ./build.sh --help)"; exit 1 ;;
  esac
done

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
APP_NAME="Secret Bot"
APP="build/$APP_NAME.app"

if [ "$UNIVERSAL" = 1 ]; then
  for arch in arm64 x86_64; do
    echo "▸ Derleniyor: $arch"
    swift build -c release --arch "$arch" --product SecretBot
  done
  BIN="$(mktemp -d)/SecretBot"
  lipo -create .build/arm64-apple-macosx/release/SecretBot .build/x86_64-apple-macosx/release/SecretBot -output "$BIN"
else
  echo "▸ Derleniyor"
  swift build -c release --product SecretBot
  BIN="$(swift build -c release --show-bin-path)/SecretBot"
fi

echo "▸ Paketleniyor"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SecretBot"
cp Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
if [ -f AppIcon.icns ]; then cp AppIcon.icns "$APP/Contents/Resources/"; fi
# Apple geliştirici sertifikası olmadan yerel (ad-hoc) imza.
codesign --force --deep -s - "$APP"
echo "✓ Hazır: $(pwd)/$APP  (sürüm $VERSION, $(lipo -archs "$APP/Contents/MacOS/SecretBot"))"

if [ "$ZIP" = 1 ]; then
  mkdir -p dist
  ZIPF="dist/SecretBot-$VERSION.zip"
  rm -f "$ZIPF"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIPF"
  echo "✓ Zip: $(pwd)/$ZIPF"
fi

if [ "$INSTALL" = 1 ]; then
  DEST="${INSTALL_DIR:-/Applications}"
  osascript -e "quit app \"$APP_NAME\"" >/dev/null 2>&1 || true
  pkill -f "$APP_NAME.app/Contents/MacOS/SecretBot" 2>/dev/null || true
  rm -rf "$DEST/$APP_NAME.app"
  ditto "$APP" "$DEST/$APP_NAME.app"
  echo "✓ Kuruldu: $DEST/$APP_NAME.app"
  open "$DEST/$APP_NAME.app"
fi
