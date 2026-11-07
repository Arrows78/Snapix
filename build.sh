#!/bin/zsh
# Builds Snapix and wraps it into build/Snapix.app (signed with the local identity when available).
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
# A stable signing identity keeps macOS privacy permissions (screen recording...) across rebuilds;
# an ad-hoc signature changes on every build and makes macOS forget them.
IDENTITY="${SNAPIX_SIGN_IDENTITY:-Snapix Local Signing}"
if security find-identity -v -p codesigning | grep -q "\"$IDENTITY\""; then
  SIGN="$IDENTITY"
else
  SIGN="-"
  echo "warning: signing identity '$IDENTITY' not found, falling back to ad-hoc (permissions will reset on every build)" >&2
fi
codesign --force --deep --sign "$SIGN" "$APP"
echo "Built $APP"
