#!/bin/zsh
# Builds Snapix and wraps it into build/Snapix.app (ad-hoc signed).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Snapix"
APP=build/Snapix.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snapix"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
for lp in Resources/*.lproj; do [ -d "$lp" ] && cp -R "$lp" "$APP/Contents/Resources/"; done
codesign --force --deep --sign - "$APP"
echo "Built $APP"
