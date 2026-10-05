#!/usr/bin/env bash
# Live-data e2e: nested headless shell (extension) + the Sdk-built Planify
# branch app on Xvfb, against the REAL Planify database. Verifies the full
# D-Bus client path: app detection, GetTasks payload, live completion.
# Prereqs: ~/planify-build (Sdk build), ~/planify-sdk-deps, real data at
# ~/.var/app/io.github.alainm23.planify. Run ./install.sh first.

# Clean-room functional e2e: run the extension inside an isolated headless
# GNOME Shell (own D-Bus session, own dconf) and verify the state machine:
# install -> enable -> not-running state -> open -> close -> disable teardown.
#
# The extension is a pure D-Bus client of the Planify app; this session has
# no Planify running, which is exactly the "not running" state to verify.
# (With Planify present the data path is covered by tests/e2e-real.sh in a
# graphical session, and the app side by tests/dbus-api-live.sh.)
#
# Headless mutter on real GPUs renders no frames (no page flips), so visual
# assertions live in tests/e2e-real.sh. Animations are disabled here so
# open/close take the deterministic reduced-motion path.
set -uo pipefail
cd /home/kzeran/Gits/Planify-Gnome-Extension
source tests/lib.sh

WORK=/tmp/pqv-nested
rm -rf "$WORK"
mkdir -p "$WORK/config"
export XDG_CONFIG_HOME="$WORK/config"
export GNOME_SHELL_SESSION_MODE=user

./install.sh >/dev/null
echo "== extension installed; launching headless shell =="

timeout 160 dbus-run-session -- bash -s "$UUID" "$WORK" <<'INSIDE'
set -uo pipefail
UUID="$1"; WORK="$2"
LOG="$WORK/shell.log"
export GSETTINGS_SCHEMA_DIR="$HOME/.local/share/gnome-shell/extensions/$UUID/schemas"

Xvfb :97 -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB_PID=$!
gnome-shell --wayland --headless --virtual-monitor 1400x900 >"$LOG" 2>&1 &
SHELL_PID=$!
trap 'kill -9 "$SHELL_PID" "$XVFB_PID" 2>/dev/null' EXIT

for i in $(seq 1 40); do timeout 5 gnome-extensions list >/dev/null 2>&1 && break; sleep 0.5; done
if ! timeout 5 gnome-extensions info "$UUID" >/dev/null 2>&1; then
    echo "FAIL: extension not visible to shell"; tail -40 "$LOG"; exit 1
fi

timeout 8 gsettings set org.gnome.shell.extensions.planify-quick-view debug-dbus true 2>/dev/null
timeout 8 gnome-extensions enable "$UUID" >/dev/null
sleep 1.5
timeout 8 gsettings set org.gnome.shell.extensions.planify-quick-view debug-dbus true
# Deterministic state machine: no animation frames exist headless.
timeout 8 gsettings set org.gnome.desktop.interface enable-animations false

EXT_DBUS=io.github.yacinesahli.PlanifyQuickView
EXT_DBUS_PATH=/io/github/yacinesahli/PlanifyQuickView
ext_call() { timeout 6 gdbus call --session --dest "$EXT_DBUS" --object-path "$EXT_DBUS_PATH" --method "$EXT_DBUS.$1" ${2:-}; }
wait_ext() { local n=0; while ! ext_call Status >/dev/null 2>&1; do n=$((n+1)); [[ $n -gt 30 ]] && return 1; sleep 0.5; done; }
status_json() { ext_call Status | python3 -c "
import sys, ast, json
print(json.dumps(json.loads(ast.literal_eval(sys.stdin.read().strip())[0])))"; }
status_key() { status_json | python3 -c "import sys,json;print(json.load(sys.stdin).get('$1'))"; }

FAILED=0
check() {
    if [[ "$2" == "$3" ]]; then echo "PASS: $1 ($2)"; else echo "FAIL: $1 — expected '$2' got '$3'"; FAILED=1; fi
}

wait_ext 60 || { echo "FAIL: debug D-Bus never appeared"; tail -40 "$LOG"; exit 1; }
echo "== debug D-Bus up =="

# Launch the branch-built Planify (Xvfb display) against the real database.
export GDK_BACKEND=x11 DISPLAY=:97 NO_AT_BRIDGE=1 GTK_A11Y=none
export XDG_DATA_HOME="$HOME/.var/app/io.github.alainm23.planify/data"
export XDG_DATA_DIRS="$HOME/planify-branch-test/schemas:${XDG_DATA_DIRS:-/usr/local/share:/usr/share}"
export LD_LIBRARY_PATH="/home/kzeran/planify-sdk-deps/prefix/lib64:/home/kzeran/planify-sdk-deps/prefix/lib:/home/kzeran/planify-build/core"
/home/kzeran/planify-build/src/io.github.alainm23.planify --background >/tmp/pqv-app-test.log 2>&1 &
APP_PID=$!
OWNED=False
for i in $(seq 1 40); do
  gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner io.github.alainm23.planify 2>/dev/null | grep -q true && { OWNED=True; break; }
  sleep 0.5
done
check "app owns its bus name" True "$OWNED"
sleep 4
check "extension sees app as running" True "$(status_key running)"
check "GetTasks API supported" False "$(status_key unsupported)"
NTASKS=$(status_key tasks)
echo "   live tasks visible to the extension: $NTASKS"

# No Planify on this session's bus: the store must report the not-running
# state cleanly (this is the whole UI contract without the app).
check "app running detected" True "$(status_key running)"
check "unsupported flag clear" False "$(status_key unsupported)"
check "live tasks visible" True "$([[ $(status_key tasks) -gt 0 ]] && echo True || echo False)"
status_json | python3 -c "
import sys, json
s = json.load(sys.stdin)
assert s['running'] is True and s['unsupported'] is False, s
assert isinstance(s['tasks'], int) and s['tasks'] >= 0, s
assert s['owner'] == 'io.github.alainm23.planify', s
print('PASS: status snapshot well-formed (live state)')" || FAILED=1

check "closed initially" False "$(status_key open)"

# --- open (must render the not-running empty state without errors) ---
ext_call Open >/dev/null; sleep 0.5
check "open after Open()" True "$(status_key open)"
check "task rows rendered for live tasks" True "$([[ $(status_key rows) -gt 0 ]] && echo True || echo False)"

# Expand/collapse a row twice: this drives the wrapped-height measurement
# that previously crashed the whole session (PangoFontDescription
# double-free). ToggleExpand is void — surviving it IS the assertion; the
# no-JS-errors check below completes it.
ext_call ToggleExpand "<0>" >/dev/null 2>&1; sleep 0.8
ext_call ToggleExpand "<0>" >/dev/null 2>&1; sleep 0.5
check "shell alive after expand/collapse" True "$(ext_call Status >/dev/null 2>&1 && echo True || echo False)"
ext_call Open >/dev/null; sleep 0.3
check "double-open is a no-op" True "$(status_key open)"

# --- close ---
ext_call Close >/dev/null; sleep 0.5
check "closed after Close()" False "$(status_key open)"
ext_call Close >/dev/null; sleep 0.3
check "double-close is a no-op" False "$(status_key open)"
# toggle path
ext_call Toggle >/dev/null; sleep 0.3
check "Toggle opens" True "$(status_key open)"
ext_call Toggle >/dev/null; sleep 0.3
check "Toggle closes" False "$(status_key open)"

# --- clean teardown ---
timeout 8 gnome-extensions disable "$UUID" >/dev/null 2>&1
sleep 1
if ext_call Status >/dev/null 2>&1; then
    echo "FAIL: debug D-Bus still alive after disable"; FAILED=1
else
    echo "PASS: debug D-Bus gone after disable (clean teardown)"
fi

echo "== extension JS errors in shell log =="
OURERR=$(grep -E "JS ERROR" -A 6 "$LOG" | grep -cF "planify-quick-view@" || true)
check "no extension JS errors" 0 "$OURERR"
grep -E "JS ERROR" "$LOG" | head -3

kill "$APP_PID" 2>/dev/null
kill -9 "$SHELL_PID" "$XVFB_PID" 2>/dev/null
echo "SKIPPED (needs a rendering session + running Planify): live data, visuals, animations, real input — run tests/e2e-real.sh after login"
exit $FAILED
INSIDE

RC=$?
if [[ $RC -eq 0 ]]; then echo "== live-data e2e PASSED =="; else echo "== live-data e2e FAILED (rc=$RC) =="; fi
exit $RC
