#!/usr/bin/env bash
# window-workspace-persist.sh - T3655 acceptance (Linux L11k8; win32 T3187,
# T3137; docs/reference/window-modes.md "Persistence"): in single-window mode a
# relaunch brings every workspace back - each one re-attached to the session
# the agent kept - with the one that was on show on show again, and a manifest
# from either mode restores in the other.
#
#   P1-P4   single mode writes one entry per workspace, in the workspaces'
#           order (on show first), each at the shared window's size, and marks
#           only the one on show `frontmost` - with the toplevel's own
#           workspace closed, so the size comes from the frame (T3652).
#   P5-P8   a crash + relaunch in single mode: three workspaces, ONE window
#           mapped, the same one on show, the same order, the same processes
#           (a parked one re-attaches on first show - T3786 owns starting it
#           while parked, so P8 shows each).
#   P9-P11  the single-mode manifest read in separate mode: three windows,
#           the same processes, the frontmost one built last (in front), and
#           every window at the one frame they shared.
#   P12-P13 a separate-mode manifest whose front window is listed in the
#           middle, read in single mode: the marked one is on show, not the
#           first listed.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-workspace-persist.sh
#
# Oracles: the debug-only `workspaces` seam, +list --json, the manifest file,
# and the restore's own "building window=" log lines.
# Output: one PASS/FAIL line per check, then 'WORKSPACE PERSIST: ALL PASS' or
# 'WORKSPACE PERSIST: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="WORKSPACE PERSIST"

log=/tmp/window-workspace-persist-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "P0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "P0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
serving() { cli +list > /dev/null 2>&1; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
manifest="$XDG_CONFIG_HOME/ghoztty/session-layout-debug.json"

cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
write_cfg() {
    {
        echo 'window-width = 90'
        echo 'window-height = 24'
        echo 'quit-after-last-window-closed = false'
        echo 'confirm-close-surface = false'
        [ -n "$1" ] && echo "macos-window-mode = $1"
    } > "$cfg_dir/config.ghostty"
}
export SHELL=/bin/sh

# ws <python expression over d (the seam's data)> [seam args...]
WS_LAST=""
ws() {
    local expr="$1"; shift
    WS_LAST=$(hl_ipc workspaces "$@" 2>&1)
    printf '%s' "$WS_LAST" > "$XDG_RUNTIME_DIR/ws-last"
    printf '%s' "$WS_LAST" | python3 -I -c '
import json, sys
try:
    r = json.load(sys.stdin)
except Exception as e:
    print("unparsable:", e); sys.exit(1)
d = r.get("data") or {}
row = {o.get("window"): o for o in d.get("order") or []}
print(eval(sys.argv[1]))
' "$expr"
}
wsis() { local want="$1"; shift; [ "$(ws "$@")" = "$want" ]; }
ws_last() { cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null; }

# mq <python expr>: evaluate against the manifest, `m` the file, `w` its windows.
mq() {
    python3 -I -c '
import json, sys
try: m = json.load(open(sys.argv[1]))
except Exception: m = None
w = (m or {}).get("windows", [])
print(eval(sys.argv[2]))
' "$manifest" "$1" 2>/dev/null
}
# pid_of <pane-name>: the +list pid of that pane.
pid_of() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
want = sys.argv[1]
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for win in d["windows"]:
    for t in win["tabs"]:
        for l in walk(t["splits"]):
            if l.get("name") == want: print(l.get("pid") or 0); sys.exit(0)
print(0)
' "$1" 2>/dev/null
}
targets() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
print(sorted(w.get("target") or "-" for w in d["windows"]))
' 2>/dev/null
}
stop_app() {
    kill -TERM "$1" 2>/dev/null
    hl_wait_for 5 sh -c "! kill -0 $1 2>/dev/null" || kill -KILL "$1" 2>/dev/null
    hl_wait_for 10 sh -c "! kill -0 $1 2>/dev/null"
}
crash_app() {
    kill -KILL "$1" 2>/dev/null
    hl_wait_for 10 sh -c "! kill -0 $1 2>/dev/null"
}

# ---- 1. single mode: three named workspaces, two on show -------------------
write_cfg single
hl_launch APP "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_check "P0c the app serves its socket" $?
hl_wait_for 10 wsis True 'd["toplevel_mapped"]'
first=$(ws 'd["toplevel"]')
for n in one two three; do
    cli +new-window --target=$n --name=p$n --command="echo ready-$n; exec sleep 100000" > /dev/null 2>&1
done
hl_wait_for 10 wsis 4 'len(d["order"])'
# Each goes on show once, so its terminal starts (a parked one starts on first
# show, T3786) and has a session to re-attach; two last, so it is on show.
for n in one three two; do
    wsis True 'd["shown"]' --show=$n
done
started() { for n in one two three; do [ "$(pid_of p$n)" -gt 0 ] 2>/dev/null || return 1; done; }
hl_wait_for 20 started
hl_check "P1a three workspaces' shells run (pids $(pid_of pone) $(pid_of ptwo) $(pid_of pthree))" $?
# Close the toplevel's own workspace: its GtkWindow stays as the frame (T3652).
for _ in 1 2 3; do
    wsis True "'$first' in row" || break
    cli +close --target="$first" --force > /dev/null 2>&1
    sleep 0.5
done
hl_wait_for 10 wsis "(3, 'two', True, 1)" 'len(d["order"]), d["active"], d["toplevel_frame"], d["mapped_windows"]'
hl_check "P1 $first closed and left the frame: two on show, three workspaces, one window mapped" $? "$(ws_last)"
pid1=$(pid_of pone); pid2=$(pid_of ptwo); pid3=$(pid_of pthree)

recorded() { [ "$(mq '[x.get("ipc_name") for x in w]')" = "['two', 'three', 'one']" ]; }
hl_wait_for 10 recorded
hl_check "P2 the manifest records one entry per workspace in the workspaces' order (on show first)" $? "$(mq '[x.get("ipc_name") for x in w]')"
[ "$(mq '[bool(x.get("frontmost")) for x in w]')" = "[True, False, False]" ]
hl_check "P3 only the workspace on show is marked frontmost" $? "$(mq '[(x.get("ipc_name"), x.get("frontmost")) for x in w]')"
frame=$(mq '(w[0]["frame"]["w"], w[0]["frame"]["h"])')
[ "$(mq 'len(set((x["frame"]["w"], x["frame"]["h"]) for x in w)) == 1 and w[0]["frame"]["w"] > 0 and w[0]["frame"]["h"] > 0')" = True ]
hl_check "P4 every workspace records the shared window's size $frame, parked ones included" $? "$(mq '[(x.get("ipc_name"), x.get("frame")) for x in w]')"
[ "$(mq 'all(n.get("leaf", {}).get("session_id") for x in w for t in x["tabs"] for n in t["nodes"] if "leaf" in n)')" = True ]
hl_check "P4b every workspace's pane records its agent session" $? "$(mq '[n.get("leaf", {}).get("session_id") for x in w for t in x["tabs"] for n in t["nodes"]]')"

# ---- 2. crash + relaunch in single mode ------------------------------------
crash_app "$APP"
alive "$pid1" && alive "$pid2" && alive "$pid3"
hl_check "P5 every workspace's process outlives the SIGKILLed app" $?
hl_launch APP2 "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_wait_for 15 wsis 3 'len(d["order"])'
wsis "('two', ('two', 'three', 'one'))" 'd["active"], tuple(o["window"] for o in d["order"])'
hl_check "P6 the relaunch brings every workspace back, two on show, in the same order" $? "$(ws_last)"
wsis "(1, True)" 'd["mapped_windows"], d["toplevel_mapped"]'
hl_check "P7 ...in ONE window: only the shared toplevel is mapped" $? "$(ws_last)"
same_pids() { [ "$(pid_of pone)" = "$pid1" ] && [ "$(pid_of ptwo)" = "$pid2" ] && [ "$(pid_of pthree)" = "$pid3" ]; }
two_same() { [ "$(pid_of ptwo)" = "$pid2" ]; }
hl_wait_for 15 two_same
hl_check "P8a two, on show, re-attached to its own process $pid2" $? "now: $(pid_of ptwo)"
# A parked workspace's terminal starts on first show (T3786 owns starting it
# while parked): show each, then two again, and every pane is its own process.
for n in three one two; do wsis True 'd["shown"]' --show=$n; done
hl_wait_for 15 same_pids
hl_check "P8 every workspace re-attached to its own process once on show ($pid1 $pid2 $pid3)" $? "now: $(pid_of pone) $(pid_of ptwo) $(pid_of pthree)"
grep "session layout: building window=" "$APP2_LOG" | tail -1 | grep -q "window=two frontmost=true"
hl_check "P8b the restore built two (frontmost) last" $? "$(grep 'session layout: building' "$APP2_LOG")"

# ---- 3. the single-mode manifest read in separate mode ---------------------
stop_app "$APP2"
[ "$(mq '[(x.get("ipc_name"), bool(x.get("frontmost"))) for x in w]')" = "[('two', True), ('one', False), ('three', False)]" ]
hl_check "P8c the quit's write follows the new order (two, one, three) and keeps two marked" $? "$(mq '[(x.get("ipc_name"), x.get("frontmost")) for x in w]')"
write_cfg ""
hl_launch APP3 "$app" --gtk-single-instance=false
hl_wait_for 30 serving
three_windows() { [ "$(targets)" = "['one', 'three', 'two']" ]; }
hl_wait_for 15 three_windows
wsis "('separate', 0)" 'd["mode"], len(d["order"])'
hl_check "P9 read in separate mode the workspaces come back as three windows, no workspaces" $? "targets=$(targets) $(ws_last)"
hl_wait_for 15 same_pids
hl_check "P10 ...on the same processes" $? "now: $(pid_of pone) $(pid_of ptwo) $(pid_of pthree)"
grep "session layout: building window=" "$APP3_LOG" | tail -1 | grep -q "window=two frontmost=true"
hl_check "P11 ...two, the one on show, built last so it is in front" $? "$(grep 'session layout: building' "$APP3_LOG")"
one_frame() { [ "$(mq 'len(w) == 3 and all((x["frame"]["w"], x["frame"]["h"]) == '"$frame"' for x in w)')" = True ]; }
hl_wait_for 10 one_frame
hl_check "P11b ...every window at the one frame they shared $frame" $? "$(mq '[(x.get("ipc_name"), x.get("frame")) for x in w]')"

# ---- 4. a separate-mode manifest read in single mode -----------------------
stop_app "$APP3"
# The front window of a separate-mode manifest, listed in the middle (another
# focus order, or another lineage): the mark decides, not the position.
python3 -I -c '
import json, sys
p = sys.argv[1]
m = json.load(open(p))
for x in m["windows"]:
    x.pop("frontmost", None)
names = [x.get("ipc_name") for x in m["windows"]]
m["windows"].sort(key=lambda x: ["three", "one", "two"].index(x.get("ipc_name")))
m["windows"][1]["frontmost"] = True
open(p, "w").write(json.dumps(m))
' "$manifest"
[ "$(mq '[(x.get("ipc_name"), bool(x.get("frontmost"))) for x in w]')" = "[('three', False), ('one', True), ('two', False)]" ]
hl_check "P12a the separate-mode manifest lists three, one (front), two" $? "$(mq '[(x.get("ipc_name"), x.get("frontmost")) for x in w]')"
write_cfg single
hl_launch APP4 "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_wait_for 15 wsis 3 'len(d["order"])'
wsis "('single', 'one', 1)" 'd["mode"], d["active"], d["mapped_windows"]'
hl_check "P12 read in single mode the windows come back as three workspaces in one window, the front one (one) on show" $? "$(ws_last)"
for n in two three one; do wsis True 'd["shown"]' --show=$n; done
hl_wait_for 15 same_pids
hl_check "P13 ...on the same processes, each once on show" $? "now: $(pid_of pone) $(pid_of ptwo) $(pid_of pthree)"
stop_app "$APP4"

hl_finish "$L"
