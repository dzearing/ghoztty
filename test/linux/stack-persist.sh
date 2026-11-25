#!/usr/bin/env bash
# stack-persist.sh - T3627 acceptance (Linux L11e-4; docs/reference/
# stacked-panes.md "Saved with the window"): on the GTK debug app a row the
# user collapsed lasts. An undone close puts the row back exactly as it was -
# a pane that was a strip comes back a strip, and the caret stays where it
# is (`Saved`, win32 T2126). The collapse and the focus history ride the
# session layout by leaf position (`PaneStackState.Persisted`, the manifest's
# `pane_stack`), so a relaunch after a crash lays the row out as the user
# left it, and the restore puts the caret in the pane focused last - never in
# the blade at the row's leading edge, which focusing would bring back out
# (`restoredFocusTarget`).
#
# The collapse is the user's own (a gutter dragged past a pane's minimum, in
# a row that fits side by side), so a fresh layout would show both panes:
# every check here fails on a build without T3627.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\stack-persist.sh
#
# Everything runs inside the private headless Weston (test/linux/lib/headless.sh),
# whose private XDG_CONFIG_HOME holds the agent's state dir and the manifest.
#
# Output: one PASS/FAIL line per check, then 'STACK PERSIST: ALL PASS' or
# 'STACK PERSIST: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="STACK PERSIST"

log=/tmp/stack-persist-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "P1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
app=$(hl_ghoztty) || hl_finish "$L"
manifest="$XDG_CONFIG_HOME/ghoztty/session-layout-debug.json"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
serving() { cli +list > /dev/null 2>&1; }
export SHELL=/bin/sh

# A 400px minimum: two panes fit side by side in the harness's window, so
# nothing stacks unless the user collapses it.
mkdir -p "$XDG_CONFIG_HOME/ghostty"
printf 'macos-pane-min-width = 400\nwindow-width = 150\nwindow-height = 30\n' > "$XDG_CONFIG_HOME/ghostty/config.ghostty"
launch_args=(--gtk-single-instance=false --undo-timeout=60s --confirm-close-surface=false)

# st [seam args...]: the pane-stack seam's reply for pane pb's tab.
st() { hl_ipc pane-stack "--target=pb" "$@"; }
# sq <reply> <python expr over s (the stage), r (the reply), N (stage pane by
# +list name)>: print it.
sq() {
    printf '%s' "$1" | NAMES="$(names)" python3 -I -c '
import json, os, sys
r = json.loads(sys.stdin.read()); s = r.get("stage") or {}
P = {p["pane"]: p for p in s.get("panes", [])}
ids = dict(kv.split("=", 1) for kv in os.environ["NAMES"].split() if "=" in kv)
N = {n: P.get(i) for n, i in ids.items()}
print(eval(sys.argv[1]))' "$2" 2>/dev/null
}
# names: "name=id ..." for every named pane.
names() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
print(" ".join("%s=%s" % (l["name"], l["id"]) for w in d["windows"] for t in w["tabs"] for l in walk(t["splits"]) if l.get("name")))' 2>/dev/null
}
# state: "pa:<min>/<focused> pb:<min>/<focused>" from the stage.
state() { sq "$(st)" '" ".join("%s:%s/%s" % (n, int(N[n]["minimized"]), int(N[n]["focused"])) for n in ("pa", "pb") if N.get(n))'; }
state_is() { [ "$(state)" = "$1" ]; }
two_panes() { [ "$(sq "$(st)" 'len(s.get("panes", []))')" = 2 ]; }
manifest_q() {
    python3 -I -c '
import json, sys
try: m = json.load(open(sys.argv[1]))
except Exception: m = None
w = next((w for w in (m or {}).get("windows", []) if w.get("ipc_name") == "sw"), None)
t = (w or {}).get("tabs", [{}])[0] if w else {}
print(eval(sys.argv[2]))' "$manifest" "$1" 2>/dev/null
}

# ---- 1. the user collapses a row that fits --------------------------------
hl_launch APP "$app" "${launch_args[@]}"
hl_wait_for 30 serving
hl_check "P2 the app serves its socket" $?
cli +new-window --target=sw --name=pa > /dev/null 2>&1
cli +split --target=pa --name=pb --direction=right --focus > /dev/null 2>&1
hl_wait_for 15 two_panes
hl_wait_for 5 state_is "pa:0/0 pb:0/1"
hl_check "P3 pa and pb fit side by side, pb focused" $? "$(state)"

r=$(st)
gx=$(sq "$r" '[g for g in s["gutters"] if g["kind"] in ("divider", "grip") and g["direction"] == "horizontal"][0]["rect"][0] + 2')
gy=$(sq "$r" '[g for g in s["gutters"] if g["kind"] in ("divider", "grip") and g["direction"] == "horizontal"][0]["rect"][1] + 20')
st "--press=$gx,$gy" "--drag=-2000,0" "--release=-2000,0" > /dev/null
hl_wait_for 5 state_is "pa:1/0 pb:0/1"
hl_check "P4 the divider dragged past pa's minimum tucks pa (the leading pane) into a strip; pb keeps the caret" $? "$(state)"

# ---- 2. an undone close puts the strip back a strip ----------------------
cli +close --target=pa > /dev/null 2>&1
one_pane() { ! names | tr ' ' '\n' | grep -q '^pa='; }
hl_wait_for 10 one_pane
hl_check "P5 +close takes pa out of the tab" $? "names=$(names)"
hl_ipc press-key --target=pb --key=ctrl+shift+z > /dev/null 2>&1
hl_wait_for 10 two_panes
hl_check "P6 ctrl+shift+z puts pa back" $? "names=$(names)"
hl_wait_for 5 state_is "pa:1/0 pb:0/1"
hl_check "P7 pa comes back as the strip it was, and the caret stays in pb" $? "$(state)"
! grep -q 'stacked rows not restored by undo' "$APP_LOG"
hl_check "P8 the app logged no failure restoring the rows" $? "$(grep -m1 'stacked rows' "$APP_LOG")"

# ---- 3. the collapse rides the manifest ----------------------------------
saved() { [ "$(manifest_q '[(x["leaves"], x["start"], x["count"]) for x in (t.get("pane_stack") or {}).get("rows", [])]')" = "[([0, 1], 1, 1)]" ]; }
hl_wait_for 10 saved
hl_check "P9 the manifest's tab records the collapse by leaf position: leaves [0,1], run from 1, one on show" $? "$(manifest_q 't.get("pane_stack")')"
[ "$(manifest_q '(t.get("pane_stack") or {}).get("recency", [None])[0]')" = 1 ]
hl_check "P10 ... and pb (leaf 1) heads its focus history" $? "$(manifest_q 't.get("pane_stack")')"

# ---- 4. a crash and relaunch keeps it ------------------------------------
kill -KILL "$APP" 2>/dev/null; wait "$APP" 2>/dev/null
hl_launch APP2 "$app" "${launch_args[@]}"
hl_wait_for 30 serving
hl_wait_for 20 two_panes
hl_check "P11 the relaunch rebuilds window sw with pa and pb" $? "names=$(names)"
hl_wait_for 5 state_is "pa:1/0 pb:0/1"
hl_check "P12 the relaunch lays the row out as the user left it: pa a strip, pb on show with the caret (not the leading blade)" $? "$(state)"
sleep 2
state_is "pa:1/0 pb:0/1"
hl_check "P13 nothing focuses the blade behind the restore's back: two seconds on, pa is still a strip" $? "$(state)"

# ---- 5. bringing the strip out is still the user's -------------------------
r=$(st)
cx=$(sq "$r" 'N["pa"]["strip"][0] + N["pa"]["strip"][2] // 2')
cy=$(sq "$r" 'N["pa"]["strip"][1] + N["pa"]["strip"][3] // 2')
st "--press=$cx,$cy" "--release=0,0" > /dev/null
sleep 0.5
r=$(state)
case "$r" in "pa:0/1 pb:"*) true ;; *) false ;; esac
hl_check "P14 clicking the restored strip brings pa forward with the caret" $? "$r"

! grep -E "Gtk-CRITICAL|Allocation (width|height) too small" "$APP_LOG" "$APP2_LOG" > /dev/null
hl_check "P15 neither run logged a GTK critical or allocation warning" $? "$(grep -h -m3 -E 'Gtk-CRITICAL|too small' "$APP_LOG" "$APP2_LOG")"

hl_finish "$L"
