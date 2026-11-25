#!/bin/bash
# Export the open part of the repository into an empty folder: code, tests, build scripts, licence.
# The private repository stays the source of truth (mandate, plans, research, full history).
#   scripts/export-public.sh <empty destination folder>
# Copies an allow-list of tracked paths at HEAD, then refuses to finish if anything private is found
# in the result. Screenshots cannot be searched for text: snapshot data must stay synthetic.
set -euo pipefail
cd "$(dirname "$0")/.."
DEST=${1:?usage: scripts/export-public.sh <empty destination folder>}
[ -z "$(git status --porcelain)" ] || { echo "uncommitted changes: commit first"; exit 1; }
mkdir -p "$DEST"
[ -z "$(ls -A "$DEST" | grep -v '^\.git$' || true)" ] || { echo "$DEST is not empty"; exit 1; }

ALLOW=(Package.swift Package.resolved Makefile LICENSE README.md .gitignore .github Resources Sources Tests scripts tools)
git archive HEAD "${ALLOW[@]}" | tar -x -C "$DEST"

# The private launcher and docs links make no sense outside the private repository.
rm -f "$DEST"/tools/e2e/*.command
python3 -I - "$DEST" <<'PY'
import re, sys, pathlib
dest = pathlib.Path(sys.argv[1])
readme = dest / "README.md"
readme.write_text("".join(l for l in readme.read_text(encoding="utf-8").splitlines(True) if "docs/" not in l), encoding="utf-8")
# The public repository runs CI on every pull request and push: its runner minutes are free.
ci = dest / ".github/workflows/ci.yml"
text = ci.read_text(encoding="utf-8")
text, n = re.subn(r"(?ms)^#[^\n]*\n(?:#[^\n]*\n)*on:\n  workflow_dispatch:\n", "on:\n  pull_request:\n  push:\n    branches: [main]\n  workflow_dispatch:\n", text)
if n != 1: sys.exit("ci.yml: trigger block not found")
ci.write_text(text, encoding="utf-8")
PY

# Gate: names, company, personal paths, addresses, key shapes. Any hit stops the export.
DENY='wookiee|вуки|danila|данил|matveev|liceist|/Users/[a-z][a-z]|@gmail\.com|@icloud\.com|27 ?248|gsk_[A-Za-z0-9]{20,}|sk-or-[A-Za-z0-9-]{20,}|AIza[0-9A-Za-z_-]{30,}|ghp_[A-Za-z0-9]{30,}|-----BEGIN [A-Z ]*PRIVATE KEY'
if HITS=$(grep -r -I -n -i -E "$DENY" "$DEST" --exclude-dir=.git --exclude=export-public.sh); then
  echo "$HITS" | cut -c1-220 | head -40
  echo "export stopped: private text found (see above)"; exit 1
fi
for p in docs SUSU.md AGENTS.md CLAUDE.md research-private .env; do
  [ ! -e "$DEST/$p" ] || { echo "export stopped: $p must not be exported"; exit 1; }
done
echo "exported $(cd "$DEST" && find . -type f -not -path './.git/*' | wc -l | tr -d ' ') files from $(git rev-parse --short HEAD) to $DEST"
