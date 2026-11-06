#!/bin/zsh
# Builds Snapix and installs it into /Applications (replacing any previous copy), then relaunches it.
# Usage: ./install.sh [--no-launch]
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

DEST=/Applications/Snapix.app
if pgrep -x Snapix >/dev/null; then
  echo "Quitting running Snapix…"
  osascript -e 'tell application id "com.labs.snapix" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -x Snapix >/dev/null || break; sleep 0.25; done
  pkill -x Snapix 2>/dev/null || true
fi

rm -rf "$DEST"
cp -R build/Snapix.app "$DEST"
codesign --verify --deep "$DEST"
echo "Installed $DEST"

[[ "${1:-}" == "--no-launch" ]] || open "$DEST"
