#!/bin/bash
# Build build/Susu.app from the SwiftPM product and sign it.
# Signs with "Susu Local Signing" (scripts/make-cert.sh) so permissions survive rebuilds;
# falls back to ad-hoc signing (CI, or before make-cert) with a warning.
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${CONFIG:-release}
IDENTITY=${SUSU_SIGN_IDENTITY:-Susu Local Signing}

swift build -c "$CONFIG" --product Susu
BINDIR=$(swift build -c "$CONFIG" --show-bin-path)
BIN=$BINDIR/Susu

APP=build/Susu.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Susu"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftPM resource bundles (strings catalog etc.); Bundle.module looks in Contents/Resources.
for b in "$BINDIR"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" --identifier app.susu.Susu "$APP"
else
  echo "warning: no \"$IDENTITY\" identity (run: make cert); signing ad-hoc, permissions will reset on rebuild" >&2
  codesign --force --sign - --identifier app.susu.Susu "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"
