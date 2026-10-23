#!/bin/bash
# Baut "HDMI Capture.app" im Ordner build/
set -euo pipefail
cd "$(dirname "$0")"

APP="build/HDMI Capture.app"
mkdir -p build
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Kompiliere …"
swiftc -O -swift-version 5 Sources/*.swift -o "$APP/Contents/MacOS/HDMICapture"

if [ ! -f build/AppIcon.icns ]; then
    echo "▸ Erzeuge Icon …"
    if swiftc -O Tools/MakeIcon.swift -o build/makeicon && build/makeicon build/icon_1024.png; then
        rm -rf build/AppIcon.iconset
        mkdir -p build/AppIcon.iconset
        for s in 16 32 128 256 512; do
            d=$((s * 2))
            sips -z $s $s build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
            sips -z $d $d build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
        done
        iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns || echo "  (Icon übersprungen)"
    else
        echo "  (Icon übersprungen)"
    fi
fi
if [ -f build/AppIcon.icns ]; then cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"; fi

cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "✓ Fertig: $APP"
