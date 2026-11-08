#!/bin/sh
# Checks that need a real screen or a network peer, run against build/Snapix.app:
#   - a short recording of a small region (pause, speed, mute, GIF conversion; only durations and tracks are read),
#   - a captured test window on a solid background,
#   - S3 requests and the custom OCR client against local mock servers that recompute the signature on their own.
# Needs the Screen Recording permission for the build; not part of scripts/ci.sh for that reason.
set -eu
cd "$(dirname "$0")/.."
./build.sh >/dev/null
BIN=build/Snapix.app/Contents/MacOS/Snapix
work=$(mktemp -d)
python3 -I scripts/live/mock_servers.py > "$work/ports" &
server=$!
trap 'kill $server 2>/dev/null; wait $server 2>/dev/null; rm -rf "$work"' EXIT
sleep 1.5
read -r s3port ocrport < "$work/ports"
fail=0
echo "== window background";  "$BIN" --check window || fail=1
echo "== recording";          "$BIN" --check record "$work" || fail=1
echo "== s3";                 "$BIN" --check s3 "http://127.0.0.1:$s3port" snapix-bucket AKTEST 's3cr3t/KEY+test' || fail=1
echo "== custom ocr";         "$BIN" --check ocr "http://127.0.0.1:$ocrport" mock-vision || fail=1
[ "$fail" = 0 ] && echo "LIVE CHECKS OK" || { echo "LIVE CHECKS FAILED"; exit 1; }
