# Shared E2E helpers. Source it: . tools/e2e/lib.sh
# BlackHole 2ch is the virtual microphone: what we play into it, Susu hears as the mic.
E2E_DEVICE=${E2E_DEVICE:-BlackHole 2ch}
SUSU_TESTSET=${SUSU_TESTSET:-$HOME/Projects/susu/research-private/stt}
SUSU_DB=${SUSU_DB:-"$HOME/Library/Application Support/Susu/susu.sqlite"}
E2E_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HELPER="$E2E_ROOT/build/e2e-helper"

# Only the app built in this checkout is ever started or stopped. The user's own running Susu (another
# checkout or /Applications) is never touched: no pkill by name.
E2E_APP_BIN="$E2E_ROOT/build/Susu.app/Contents/MacOS/Susu"
e2e_app_pid() { pgrep -n -f "$E2E_APP_BIN"; }
e2e_kill_app() { pkill -f "$E2E_APP_BIN"; return 0; }

# False when another Susu is running and its own settings use this modifier as a hotkey:
# the test's key presses would start a dictation in that app too.
e2e_trigger_free() {
  pgrep -f "Susu.app/Contents/MacOS/Susu" | grep -qvx "$(e2e_app_pid || echo none)" || return 0
  python3 -I -c 'import json, os, sys
try: h = json.load(open(os.path.expanduser("~/Library/Application Support/Susu/settings.json"))).get("hotkeys", {})
except Exception: sys.exit(0)
used = {v.get("modifierKey") for v in h.values() if isinstance(v, dict)}
sys.exit(1 if sys.argv[1] in used else 0)' "$1"
}

e2e_build_helper() {  # compile once; rebuild when the source is newer
  if [ ! -x "$HELPER" ] || [ "$E2E_ROOT/tools/e2e/helper.swift" -nt "$HELPER" ]; then
    mkdir -p "$E2E_ROOT/build"
    swiftc -O "$E2E_ROOT/tools/e2e/helper.swift" -o "$HELPER"
  fi
}

e2e_has_device() { system_profiler SPAudioDataType 2>/dev/null | grep -q "$E2E_DEVICE"; }

# Play a WAV into the virtual mic (blocks until done).
e2e_play() { sox -q "$1" -t coreaudio "$E2E_DEVICE"; }

# Record N seconds from the virtual mic into a WAV (needs Microphone permission for the running app).
e2e_record() { sox -q -t coreaudio "$E2E_DEVICE" -c 1 -r 16000 "$2" trim 0 "$1"; }

# Peak amplitude 0..1 of a WAV.
e2e_peak() { sox "$1" -n stat 2>&1 | awk '/Maximum amplitude/ {print $3}'; }

# Hold a key (keycode, 59 = left Ctrl) for the duration of a command, like a person holding Ctrl while speaking.
e2e_hold() { local code=$1; shift; "$HELPER" key-down "$code"; "$@"; "$HELPER" key-up "$code"; }

e2e_field_text() { "$HELPER" field-text "$1"; }

# latency_ms of the newest dictation in Susu's database (spec 5.2), available from M1.
e2e_last_latency() { sqlite3 -readonly "$SUSU_DB" "SELECT latency_ms FROM dictation ORDER BY created_at DESC LIMIT 1"; }
