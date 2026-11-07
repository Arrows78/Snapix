#!/bin/sh
# Local CI: release tool tests, release files check, app build, then the non-interactive self-test.
set -eu
cd "$(dirname "$0")/.."
python3 -B -m unittest discover -s scripts/tests -q
python3 -B scripts/release.py check
./build.sh
out=$(mktemp -d)
build/Snapix.app/Contents/MacOS/Snapix --selftest "$out"
rm -rf "$out"
echo "CI OK"
