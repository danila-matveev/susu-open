#!/bin/bash
# Screenshot a Susu window of the running app by title substring.
# Usage: tools/ui/app-shot.sh "Susu" out.png
set -euo pipefail
id=$(swift -e 'import CoreGraphics; import Foundation
let want = CommandLine.arguments[1]
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == "Susu" && ((w["kCGWindowName"] as? String) ?? "").contains(want) && (w["kCGWindowLayer"] as? Int) == 0 { print(w["kCGWindowNumber"]!); break }' "$1")
[ -n "$id" ] || { echo "no Susu window matching '$1'" >&2; exit 1; }
screencapture -x -o -l "$id" "$2"
