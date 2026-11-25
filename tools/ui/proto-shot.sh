#!/bin/bash
# Screenshot a prototype page with headless Chrome (own throwaway profile, does not touch the user's browser).
# Usage: tools/ui/proto-shot.sh docs/design/prototype/window-history.html out.png [1400x900] [extra query, e.g. "theme=dark"]
set -euo pipefail
page=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
out=$2; size=${3:-1400x900}; q=${4:-}
prof=$(mktemp -d)
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu --hide-scrollbars \
  --user-data-dir="$prof" --window-size="${size/x/,}" --screenshot="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")" \
  "file://$page${q:+?$q}" >/dev/null 2>&1
rm -rf "$prof"
