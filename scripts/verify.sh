#!/bin/bash
# One verification command (SUSU.md, section 10 "Release policy").
#   scripts/verify.sh            dev check: build, tests, app bundle. NOT_RUN steps are reported, not counted as pass.
#   scripts/verify.sh --release  release gate: every mandatory step must PASS for this exact commit; NOT_RUN fails.
# Writes build/verify.json and exits non-zero when the chosen gate is not met.
set -uo pipefail
cd "$(dirname "$0")/.."
MODE=dev; [ "${1:-}" = "--release" ] && MODE=release
mkdir -p build/verify
COMMIT=$(git rev-parse HEAD)
DIRTY=$([ -n "$(git status --porcelain)" ] && echo true || echo false)
RESULTS=()
FAILED=0

record() { # name status detail
  RESULTS+=("{\"step\":\"$1\",\"status\":\"$2\",\"detail\":\"$3\"}")
  printf '%-22s %s  %s\n' "$1" "$2" "$3"
  case "$2" in
    FAIL) FAILED=1 ;;
    NOT_RUN) [ "$MODE" = release ] && FAILED=1 ;;
  esac
}

run() { # name command...
  local name=$1; shift
  if "$@" >"build/verify/$name.log" 2>&1; then record "$name" PASS "exit 0"
  else record "$name" FAIL "exit $?, see build/verify/$name.log"; fi
}

run build swift build
run unit_tests swift test
run eval_selftest python3 -I tools/stt-eval/test_check.py
run app_bundle scripts/build-app.sh

if APP_SHA=$(scripts/app-id.sh) && [ -n "$APP_SHA" ]; then
  # The bundle's code directory hash: stable across re-signing the same build, changes with any
  # change to the executable, Info.plist or a sealed resource (see scripts/app-id.sh).
  IDENTITY=${SUSU_SIGN_IDENTITY:-Susu Local Signing}
  SIGINFO=$(codesign -dvv build/Susu.app 2>&1)   # captured first: grep -q in a pipe would trip pipefail
  if grep -qx "Authority=$IDENTITY" <<<"$SIGINFO"; then record signature PASS "$IDENTITY"
  else record signature NOT_RUN "not signed with $IDENTITY: permissions reset on rebuild (run make cert)"; fi
else APP_SHA=""; record signature FAIL "bundle missing or signature invalid"; fi

# Steps that need the interactive Mac (screen, microphone, permissions). A result counts only when
# it is valid JSON whose top-level commit and app_cdhash name this exact candidate.
evidence() { # name file
  local out
  out=$(python3 -I - "$2" "$COMMIT" "$APP_SHA" <<'PY' 2>&1
import json, sys
path, commit, sha = sys.argv[1:4]
try:
    d = json.load(open(path))
except FileNotFoundError:
    print("NOT_RUN no result file"); sys.exit()
except Exception as e:
    print("FAIL invalid JSON: %s" % e); sys.exit()
if not isinstance(d, dict): print("FAIL not a JSON object")
elif d.get("commit") != commit: print("NOT_RUN result is for another commit")
elif not sha or d.get("app_cdhash") != sha: print("NOT_RUN result is for another build of the app")
elif d.get("verdict") != "PASS": print("FAIL verdict is %s" % d.get("verdict"))
else: print("PASS ok")
PY
  ) || out="FAIL checker crashed"
  record "$1" "${out%% *}" "$2: ${out#* }"
}
evidence packaged_e2e build/verify/e2e.json
evidence first_run build/verify/first-run.json
evidence performance build/verify/performance.json
evidence independent_audit build/verify/codex.json

[ "$DIRTY" = true ] && [ "$MODE" = release ] && record clean_tree FAIL "uncommitted changes"

STATUS=PASS; [ $FAILED -ne 0 ] && STATUS=FAIL
{
  printf '{"mode":"%s","commit":"%s","dirty":%s,"app_cdhash":"%s","status":"%s","steps":[' "$MODE" "$COMMIT" "$DIRTY" "$APP_SHA" "$STATUS"
  (IFS=,; printf '%s' "${RESULTS[*]}")
  printf ']}\n'
} > build/verify.json || { echo "could not write build/verify.json"; FAILED=1; STATUS=FAIL; }
python3 -I -c 'import json,sys; json.load(open("build/verify.json"))' || { echo "build/verify.json is not valid JSON"; FAILED=1; STATUS=FAIL; }
echo "verify ($MODE): $STATUS -> build/verify.json"
exit $FAILED
