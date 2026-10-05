#!/usr/bin/env bash
# Live integration test for the D-Bus GetTasks/TasksChanged API.
# Runs the Sdk-built planify (app + cli) on the host in a fully isolated
# environment: own Xvfb display, own D-Bus session, throwaway data dir.
set -uo pipefail

REPO="${PLANIFY_REPO:-/home/kzeran/Gits/planify}"
BUILD="${PLANIFY_BUILD:-/home/kzeran/planify-build}"
DEPS="${PLANIFY_SDK_DEPS:-/home/kzeran/planify-sdk-deps/prefix}"
WORK=$(mktemp -d /tmp/planify-dbus-test.XXXX)
APP="$BUILD/src/io.github.alainm23.planify"
CLI="$BUILD/cli/io.github.alainm23.planify.cli"

TODAY=$(date +%F)
YESTERDAY=$(date -d yesterday +%F)
TOMORROW=$(date -d tomorrow +%F)

# ---- python checkers (written up front, run inside the nested session) ----

cat > "$WORK/check_tasks.py" <<PYEOF
import ast, json, sys, os
raw = open(sys.argv[1]).read()
tree = ast.literal_eval(raw[raw.index('('):])
s = tree[0] if isinstance(tree, tuple) else tree
doc = json.loads(s)
json.dump(doc, open(sys.argv[2], "w"))
by_id = {t["id"]: t for t in doc["tasks"]}
today = os.environ["TODAY"]; yesterday = os.environ["YESTERDAY"]; tomorrow = os.environ["TOMORROW"]
def chk(name, result):
    print(("PASS: " if result else "FAIL: ") + name)
    return result
ok = True
ok = chk("document version == 1", doc.get("version") == 1) and ok
ok = chk("two visible tasks (today + overdue)", len(doc["tasks"]) == 2) and ok
ok = chk("done_today == 0 initially", doc["done_today"] == 0) and ok
todays = [t for t in by_id.values() if t["due"]["date"] == today]
overdues = [t for t in by_id.values() if t["due"]["date"] == yesterday]
ok = chk("today task present", len(todays) == 1) and ok
ok = chk("overdue task present", len(overdues) == 1) and ok
ok = chk("future task absent", all(t["due"]["date"] != tomorrow for t in by_id.values())) and ok
t = todays[0] if todays else {}
ok = chk("task fields complete", all(k in t for k in ("id","content","description","due","priority","pinned","parent_id","project"))) and ok
ok = chk("project fields complete", all(k in t.get("project", {}) for k in ("id","name","color"))) and ok
ok = chk("due.is_recurring present", "is_recurring" in t.get("due", {})) and ok
sys.exit(0 if ok else 1)
PYEOF

cat > "$WORK/check_after_complete.py" <<PYEOF
import ast, json, sys, os
raw = open(sys.argv[1]).read()
tree = ast.literal_eval(raw[raw.index('('):])
s = tree[0] if isinstance(tree, tuple) else tree
doc = json.loads(s)
today = os.environ["TODAY"]
def chk(name, result):
    print(("PASS: " if result else "FAIL: ") + name)
    return result
ok = True
ok = chk("completed task left the selection", all(t["due"]["date"] != today for t in doc["tasks"])) and ok
ok = chk("done_today == 1 after complete", doc["done_today"] == 1) and ok
sys.exit(0 if ok else 1)
PYEOF

# ---- environment ----

export LD_LIBRARY_PATH="$DEPS/lib64:$DEPS/lib:$BUILD/core"
export XDG_DATA_HOME="$WORK/data"
mkdir -p "$WORK/data/glib-2.0/schemas"
glib-compile-schemas --targetdir="$WORK/data/glib-2.0/schemas" "$REPO/data" 2>/dev/null

Xvfb :97 -screen 0 1280x800x24 >/dev/null 2>&1 &
XVFB_PID=$!
sleep 1

export TODAY YESTERDAY TOMORROW WORK

echo "== launching planify in an isolated session =="
dbus-run-session -- bash -s "$APP" "$CLI" <<'INSIDE' | tee "$WORK/out.log"
set -uo pipefail
APP="$1"; CLI="$2"
export GDK_BACKEND=x11 DISPLAY=:97
export NO_AT_BRIDGE=1
export TODAY YESTERDAY TOMORROW WORK

get_tasks() {
    gdbus call --session --dest io.github.alainm23.planify \
        --object-path /io/github/alainm23/planify \
        --method io.github.alainm23.planify.GetTasks
}

"$APP" --background >/dev/null 2>&1 &
APP_PID=$!

owned=0
for i in $(seq 1 40); do
    owned=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
        --method org.freedesktop.DBus.NameHasOwner io.github.alainm23.planify 2>/dev/null | grep -c true || true)
    [ "$owned" = "1" ] && break
    sleep 0.5
done
if [ "$owned" = "1" ]; then echo "PASS: app owns io.github.alainm23.planify"; else echo "FAIL: app never acquired the bus name"; kill $APP_PID; exit 1; fi
sleep 2

gdbus introspect --session --dest io.github.alainm23.planify \
    --object-path /io/github/alainm23/planify > "$WORK/introspect.xml" 2>/dev/null
grep -q "GetTasks" "$WORK/introspect.xml" && echo "PASS: GetTasks member present" || echo "FAIL: GetTasks member missing"
grep -q "TasksChanged" "$WORK/introspect.xml" && echo "PASS: TasksChanged signal present" || echo "FAIL: TasksChanged signal missing"

"$CLI" add --content "dbus api test today" --due "$TODAY" >/dev/null 2>&1 && echo "PASS: cli add today" || echo "FAIL: cli add today"
"$CLI" add --content "dbus api test overdue" --due "$YESTERDAY" >/dev/null 2>&1 && echo "PASS: cli add overdue" || echo "FAIL: cli add overdue"
"$CLI" add --content "dbus api test future" --due "$TOMORROW" >/dev/null 2>&1 && echo "PASS: cli add future" || echo "FAIL: cli add future"
sleep 1

get_tasks > "$WORK/tasks1.gdbus" 2>&1
python3 "$WORK/check_tasks.py" "$WORK/tasks1.gdbus" "$WORK/tasks1.json"

dbus-monitor --session "type='signal',interface='io.github.alainm23.planify'" > "$WORK/monitor.log" 2>/dev/null &
MONPID=$!
sleep 0.5

TASK_ID=$(python3 -c "import json;doc=json.load(open('$WORK/tasks1.json'));print([t['id'] for t in doc['tasks'] if t['due']['date']=='$TODAY'][0])")
gdbus call --session --dest io.github.alainm23.planify \
    --object-path /io/github/alainm23/planify \
    --method org.freedesktop.Application.ActivateAction "complete" "[<'$TASK_ID'>]" "{}" >/dev/null 2>&1 \
    && echo "PASS: complete GAction accepted" || echo "FAIL: complete GAction rejected"
sleep 2

get_tasks > "$WORK/tasks2.gdbus" 2>&1
python3 "$WORK/check_after_complete.py" "$WORK/tasks2.gdbus"

kill $MONPID 2>/dev/null
sleep 0.5
grep -q "member=TasksChanged" "$WORK/monitor.log" && echo "PASS: TasksChanged signal emitted" || echo "FAIL: TasksChanged signal not seen"

kill $APP_PID 2>/dev/null
INSIDE

FAILED=$(grep -c "^FAIL:" "$WORK/out.log" || true)
if [ "$FAILED" = "0" ]; then
    echo "== ALL INTEGRATION CHECKS PASSED =="
else
    echo "== $FAILED INTEGRATION CHECK(S) FAILED =="
fi

kill "$XVFB_PID" 2>/dev/null
cp -r "$WORK/out.log" /tmp/planify-dbus-out.log 2>/dev/null
rm -rf "$WORK"
exit $(( FAILED > 0 ? 1 : 0 ))
