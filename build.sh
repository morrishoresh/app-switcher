#!/bin/bash
# Builds AppSwitcher.app into ./build. Pass --install to copy it to /Applications and launch it.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

APP=build/AppSwitcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O Tools/IconRenderer/main.swift -o build/icon-renderer
build/icon-renderer appicon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/AppSwitcher "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
# Ad-hoc signatures are identified by their hash, so macOS would drop the Accessibility grant on every rebuild.
# Requiring only the bundle identifier keeps the grant across rebuilds.
codesign --force --sign - --requirements '=designated => identifier "com.morrishoresh.AppSwitcher"' "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x AppSwitcher || true
    rm -rf /Applications/AppSwitcher.app
    cp -R "$APP" /Applications/
    open /Applications/AppSwitcher.app
    echo "Installed and launched /Applications/AppSwitcher.app"
fi
