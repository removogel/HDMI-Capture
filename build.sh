#!/bin/bash
# Baut "HDMI Capture.app" als Universal-App (Apple Silicon + Intel) im Ordner build/
# Optional: VERSION=1.2.0 ./build.sh setzt die Versionsnummer im Info.plist
set -euo pipefail
cd "$(dirname "$0")"

APP="build/HDMI Capture.app"
MIN_MACOS=14.0
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    echo "▸ Compiling ($arch) …"
    swiftc -O -swift-version 5 -target "$arch-apple-macos$MIN_MACOS" Sources/*.swift -o "build/HDMICapture-$arch"
done
lipo -create build/HDMICapture-arm64 build/HDMICapture-x86_64 -output "$APP/Contents/MacOS/HDMICapture"

if [ ! -f build/AppIcon.icns ]; then
    echo "▸ Generating icon …"
    if swiftc -O Tools/MakeIcon.swift -o build/makeicon && build/makeicon build/icon_1024.png; then
        rm -rf build/AppIcon.iconset
        mkdir -p build/AppIcon.iconset
        for s in 16 32 128 256 512; do
            d=$((s * 2))
            sips -z $s $s build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
            sips -z $d $d build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
        done
        iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns || echo "  (icon skipped)"
    else
        echo "  (icon skipped)"
    fi
fi
if [ -f build/AppIcon.icns ]; then cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

cp Info.plist "$APP/Contents/Info.plist"
if [ -n "${VERSION:-}" ]; then
    plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
    plutil -replace CFBundleVersion -string "$VERSION" "$APP/Contents/Info.plist"
fi
codesign --force --sign - "$APP"
echo "✓ Done: $APP ($(lipo -archs "$APP/Contents/MacOS/HDMICapture"))"
