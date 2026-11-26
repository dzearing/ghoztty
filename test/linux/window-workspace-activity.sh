#!/usr/bin/env bash
# window-workspace-activity.sh - T3654 acceptance for single-window mode's
# activity on the GTK debug app (docs/reference/window-modes.md "State never
# pauses"; Linux L11k7; win32 T3186).
#
# With `macos-window-mode = single`:
# - the shared window's activity is the most urgent of EVERY workspace's,
#   parked ones included (Mac `WorkspaceHost.refreshWindowActivity`);
# - a parked workspace that starts waiting on a question asks for attention
#   on the shared toplevel (urgency when that window is in the background),
#   once per move into `needs_input`;
# - the toplevel's title suffix stays the workspace on show's own;
# - a workspace's activity leaves the roll-up when it closes.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-workspace-activity.sh
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'NEGATIVE=1 bash test/linux/window-workspace-activity.sh'
#
# NEGATIVE=1 runs the same steps in `separate` mode, where nothing rolls up:
# it must FAIL from A3 on.
#
# Oracles: the debug-only `workspaces` seam (`activity`, each row's
# `activity`, `toplevel_title`) and the app log's `window activity rolled up`
# and `activity attention` lines. Output: one PASS/FAIL line per check, then
# 'WINDOW WORKSPACE ACTIVITY: ALL PASS' or
# 'WINDOW WORKSPACE ACTIVITY: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="WINDOW WORKSPACE ACTIVITY"
NEGATIVE=${NEGATIVE:-0}

log=/tmp/window-workspace-activity-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "A0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "A0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
mode=single
[ "$NEGATIVE" = 1 ] && mode=separate
{
    echo 'window-width = 90'
    echo 'window-height = 24'
    echo 'quit-after-last-window-closed = false'
    echo 'confirm-close-surface = false'
    echo "macos-window-mode = $mode"
} > "$cfg_dir/config.ghostty"
export SHELL=/bin/sh

# ws <python expression over d (the seam's data), row (by window name)>
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
last() { cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null; }
# The first pane id of the window called <target> (its selected tab).
pane_of() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if (w.get("target") or "") == sys.argv[1]:
        tab = next((t for t in w["tabs"] if t.get("selected")), w["tabs"][0])
        print(next(leaves(tab["splits"]))["id"])
' "$1" 2>/dev/null
}
state() { cli +set-state --target="$1" --state="$2" > /dev/null 2>&1; }
attn_lines() { grep -c "activity attention needs_input=" "$APP_LOG"; }

hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "A0c the app serves its socket" $?
hl_wait_for 10 wsis True 'd["toplevel_mapped"] or d["mode"] == "separate"'
first=$(ws 'd["toplevel"]')
[ "$NEGATIVE" = 1 ] && first=$(cli +list --json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"]["windows"][0].get("target") or "")')
echo "first window: $first"

# two and three each start on show (a terminal parked from birth has not
# started, T3786), then park behind $first.
cli +new-window --target=two --title=two --focus > /dev/null 2>&1
hl_wait_for 10 wsis True '"two" in row'
cli +new-window --target=three --title=three --focus > /dev/null 2>&1
hl_wait_for 10 wsis True '"three" in row'
cli +new-window --target="$first" --focus > /dev/null 2>&1
hl_wait_for 10 wsis "('$first', True, True)" 'd["active"], row["two"]["parked"], row["three"]["parked"]'
hl_check "A1 two and three are parked behind $first" $? "$(last)"
p1=$(pane_of "$first"); p2=$(pane_of two); p3=$(pane_of three)
echo "panes: $first=$p1 two=$p2 three=$p3"

wsis "('idle', 'idle', 'idle')" 'd["activity"], row["two"]["activity"], row["three"]["activity"]'
hl_check "A2 nothing is busy: the window's activity is idle" $? "$(last)"

# ---- 1. a parked workspace's state rolls up --------------------------------
state "$p2" busy
hl_wait_for 5 wsis "('busy', 'busy')" 'd["activity"], row["two"]["activity"]'
hl_check "A3 a parked workspace going busy makes the window busy" $? "$(last)"
grep -q "window activity rolled up state=busy workspaces=3" "$APP_LOG"
hl_check "A3b ...logged as a roll-up over three workspaces" $? "$(grep 'rolled up' "$APP_LOG" | tail -3)"
wsis True '"(busy)" not in (d["toplevel_title"] or "")'
hl_check "A4 the title suffix stays $first's own: no (busy)" $? "$(last)"

# ---- 2. a parked question asks for attention on the toplevel ---------------
before=$(attn_lines)
state "$p2" needs_input
hl_wait_for 5 wsis "needs_input" 'd["activity"]'
hl_check "A5 a parked question makes the window wait on one" $? "$(last)"
line=$(grep "activity attention needs_input=true" "$APP_LOG" | tail -1)
echo "$line" | grep -q "parked=true target=$first"
hl_check "A6 the parked workspace asks for attention on the shared toplevel ($first)" $? "$line"
active=$(echo "$line" | sed -n 's/.* active=\([a-z]*\) .*/\1/p')
urgent=$(echo "$line" | sed -n 's/.* urgent=\([a-z]*\) .*/\1/p')
if [ "$active" = false ]; then want=true; else want=false; fi
[ -n "$active" ] && [ "$urgent" = "$want" ]
hl_check "A7 the toplevel is marked urgent exactly when it is in the background (active=$active)" $? "$line"
wsis True '"(question)" not in (d["toplevel_title"] or "")'
hl_check "A8 ...and the title still shows no (question): that is two's, not $first's" $? "$(last)"
state "$p2" needs_input
sleep 0.5
[ "$(attn_lines)" = $((before + 1)) ]
hl_check "A9 a repeat question asks once, not again" $? "before=$before now=$(attn_lines)"

# ---- 3. the on-show workspace's own suffix, and the max ---------------------
state "$p1" busy
hl_wait_for 5 wsis True '"(busy)" in (d["toplevel_title"] or "")'
hl_check "A10 $first going busy titles the toplevel (busy)" $? "$(last)"
wsis needs_input 'd["activity"]'
hl_check "A11 ...while the window still reports two's question (the most urgent)" $? "$(last)"
state "$p2" idle
hl_wait_for 5 wsis busy 'd["activity"]'
hl_check "A12 two answering drops the window to $first's busy" $? "$(last)"
grep -q "activity attention needs_input=false .* parked=true" "$APP_LOG"
hl_check "A12b ...and two's leaving needs_input is logged" $? "$(grep 'activity attention' "$APP_LOG" | tail -2)"

# ---- 4. a closing workspace leaves the roll-up -----------------------------
state "$p1" idle
state "$p3" busy
hl_wait_for 5 wsis "('busy', 'busy')" 'd["activity"], row["three"]["activity"]'
hl_check "A13 parked three busy: the window is busy" $? "$(last)"
o=$(cli +close --target=three --force 2>&1)
hl_wait_for 10 wsis "('idle', False)" 'd["activity"], "three" in row'
hl_check "A14 closing three takes its busy out of the roll-up" $? "$o $(last)"

alive "$APP"; hl_check "A15 the app is alive" $?
grep -E "rolled up|activity attention|workspace:" "$APP_LOG" | tail -30
hl_finish "$L"
