#!/bin/bash
# Synthesize the 15-language set with built-in macOS voices: <lang>a.wav (plain) and <lang>b.wav (mixed with English),
# 16 kHz mono Int16. WAVs never go into git. usage: gen.sh OUT_DIR
set -euo pipefail
OUT=${1:?usage: gen.sh OUT_DIR}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
python3 -I -c 'import json,sys
for l, t in json.load(open(sys.argv[1])).items():
    for k in "ab": print(l + k, t["v"], t[k], sep="\t")' "$HERE/texts.json" |
while IFS=$'\t' read -r id voice text; do
  say -v "$voice" -o "$OUT/$id.aiff" -- "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/$id.aiff" "$OUT/$id.wav"
  rm "$OUT/$id.aiff"
done
echo "$(ls "$OUT"/*.wav | wc -l | tr -d ' ') files in $OUT"
