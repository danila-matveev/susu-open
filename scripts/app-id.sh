#!/bin/bash
# Identity of build/Susu.app for evidence files: the code directory hash (CDHash) of a bundle that
# passes strict verification. It covers the executable, Info.plist and every sealed resource, and,
# unlike a hash of the files, does not change when the same build is signed again (the signature
# carries its signing time). Prints the hash; prints nothing and fails when the bundle is missing or invalid.
set -uo pipefail
cd "$(dirname "$0")/.."
APP=${1:-build/Susu.app}
[ -d "$APP" ] || exit 1
codesign --verify --strict "$APP" 2>/dev/null || exit 1
INFO=$(codesign -dvvv "$APP" 2>&1) || exit 1
ID=$(sed -n 's/^CDHash=//p' <<<"$INFO" | head -1)
[ -n "$ID" ] || exit 1
echo "$ID"
