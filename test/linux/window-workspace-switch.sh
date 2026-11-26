#!/usr/bin/env bash
# window-workspace-switch.sh - T3649 acceptance for single-window mode's
# switching and open paths on the GTK debug app (docs/reference/window-modes.md
# "Opening, switching, closing"; Linux L11k2; win32 T3182/T3194/T3205).
#
# With `macos-window-mode = single`:
# - a click on a workspace's row (or one of its panes' rows) in the pane
#   sidebar's all-windows list puts it on show in the one toplevel;
# - next/previous/last/N tab and goto_window walk the workspaces in the
#   list's order;
# - a new tab, Ctrl+Shift+N and a pane popped out each open a NEW WORKSPACE
#   on show - never a second window, never a second tab;
# - `--focus` on an existing parked workspace puts it on show, and a
#   `+new-window` without it stays parked.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-workspace-switch.sh
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'NEGATIVE=1 bash test/linux/window-workspace-switch.sh'
#
# NEGATIVE=1 runs the same steps in `separate` mode, where there are no
# workspaces: it must FAIL S2 (a sidebar click raises a window, nothing is
# put on show).
#
# Oracles: the debug-only `workspaces` seam (who is on show, whose content IS
# the toplevel's, whose own GtkWindow is mapped, which workspace has the
# toplevel's keyboard focus, the list's order) and the `pane-sidebar` seam to
# click rows; keys go in through `press-key`. Output: one PASS/FAIL line per
# check, then 'WINDOW WORKSPACE SWITCH: ALL PASS' or
# 'WINDOW WORKSPACE SWITCH: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="WINDOW WORKSPACE SWITCH"
NEGATIVE=${NEGATIVE:-0}

log=/tmp/window-workspace-switch-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "S0b a private headless Weston is up" $?
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
    echo 'macos-pane-sidebar = expanded'
    echo 'keybind = ctrl+shift+t=new_tab'
    echo 'keybind = ctrl+shift+n=new_window'
    echo 'keybind = ctrl+page_down=next_tab'
    echo 'keybind = ctrl+page_up=previous_tab'
    echo 'keybind = alt+one=goto_tab:1'
    echo 'keybind = alt+nine=last_tab'
    echo 'keybind = ctrl+shift+down=goto_window:next'
    echo 'keybind = ctrl+shift+up=goto_window:previous'
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
# sb <target> [seam args...] / sbf <target> <python expr over r (rows)>
sb() { local t=$1; shift; hl_ipc pane-sidebar "--target=$t" "$@" 2>/dev/null; }
sbf() {
    sb "$1" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
r = (d.get("sidebar") or {}).get("rows") or []
def row(label, kind="window"):
    return next((x for x in r if x["label"] == label and x["kind"] == kind), {})
print(eval(sys.argv[1]))
' "$2" 2>/dev/null
}
# The pane ids of the window called <target> (its selected tab), space-separated.
panes_of() {
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
        print(" ".join(l["id"] for l in leaves(tab["splits"])))
' "$1" 2>/dev/null
}
# The pane the toplevel's focus is in: the first pane of the workspace on show.
active() { ws 'd["active"]'; }
press() { hl_ipc press-key "--target=$1" "--key=$2" > /dev/null 2>&1; }
# press_on_show <key>: press it on a pane of the workspace on show.
press_on_show() { local a; a=$(active); press "$(panes_of "$a" | cut -d' ' -f1)" "$1"; }
# The list entry <offset> along from the workspace on show, wrapping.
along() { ws "d['list'][(d['list'].index(d['active']) + ($1)) % len(d['list'])]"; }

hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "S0c the app serves its socket" $?
hl_wait_for 10 wsis True 'd["toplevel_mapped"] or d["mode"] == "separate"'
first=$(ws 'd["toplevel"]')
[ "$NEGATIVE" = 1 ] && first=$(cli +list --json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"]["windows"][0].get("target") or "")')
echo "first window: $first"

cli +new-window --target=two --title=two > /dev/null 2>&1
cli +new-window --target=three --title=three > /dev/null 2>&1
hl_wait_for 10 wsis 3 'len(d["order"])'
wsis "('$first', True, True)" 'd["active"], row["two"]["parked"], row["three"]["parked"]'
hl_check "S1 two and three open parked behind $first ($first keeps the toplevel)" $? "$(last)"

# ---- 1. the sidebar switches workspaces ------------------------------------
two_row=$(sbf "$first" 'row("two")["pane"]')
sb "$first" "--click=$two_row" > /dev/null
hl_wait_for 10 wsis "('two', 'two', False, True)" 'd["active"], d["content"], row["two"]["mapped"], d["toplevel_mapped"]'
hl_check "S2 a click on two's row puts two on show IN the toplevel; its own window never maps" $? "row=$two_row $(last)"
grep -q "workspace switch from the sidebar key=" "$APP_LOG"
hl_check "S2b ...a turn after the click (logged)" $? "$(grep 'pane sidebar window clicked\|workspace switch' "$APP_LOG" | tail -3)"
hl_wait_for 5 wsis two 'd["focus_window"]'
hl_check "S2c the keyboard focus is in two's pane" $? "$(last)"
wsis True 'row["'$first'"]["parked"] and not row["'$first'"]["seen"]'
hl_check "S2d $first is parked and unseen" $? "$(last)"

three_row=$(sbf two 'row("three")["pane"]')
sb two "--click=fold:$three_row" > /dev/null
three_pane=$(panes_of three | cut -d' ' -f1)
for _ in $(seq 1 20); do
    [ "$(sbf two "any(x['pane'] == '$three_pane' for x in r)")" = True ] && break
    sleep 0.5
done
sb two "--click=$three_pane" > /dev/null
hl_wait_for 10 wsis "('three', 'three', 'three')" 'd["active"], d["content"], d["focus_window"]'
hl_check "S3 a click on a parked workspace's PANE row puts it on show, that pane focused" $? "pane=$three_pane $(last)"
grep -q "workspace switch from the sidebar pane=$three_pane" "$APP_LOG"
hl_check "S3b ...through the deferred switch" $? "$(grep 'workspace switch' "$APP_LOG" | tail -3)"

# ---- 2. goto_tab walks the list --------------------------------------------
want=$(along 1); press_on_show ctrl+page_down
hl_wait_for 10 wsis "$want" 'd["active"]'
hl_check "S4 next_tab puts the next workspace in the list on show ($want)" $? "$(last)"
want=$(along -1); press_on_show ctrl+page_up
hl_wait_for 10 wsis "$want" 'd["active"]'
hl_check "S5 previous_tab puts the previous one on show ($want)" $? "$(last)"
want=$(ws 'd["list"][0]'); press_on_show alt+one
hl_wait_for 10 wsis "$want" 'd["active"]'
hl_check "S6 goto_tab:1 puts the list's first on show ($want)" $? "$(last)"
want=$(ws 'd["list"][-1]'); press_on_show alt+nine
hl_wait_for 10 wsis "$want" 'd["active"]'
hl_check "S6b last_tab puts the list's last on show ($want)" $? "$(last)"
grep -q "goto_tab .* over workspaces:" "$APP_LOG"
hl_check "S6c the walk is over workspaces (logged)" $? "$(grep 'over workspaces' "$APP_LOG" | tail -3)"

# ---- 3. goto_window walks the list -----------------------------------------
want=$(along 1); press_on_show ctrl+shift+down
hl_wait_for 10 wsis "$want" 'd["active"]'
hl_check "S7 goto_window:next puts the next workspace on show ($want)" $? "$(last)"
want=$(along -1); press_on_show ctrl+shift+up
hl_wait_for 10 wsis "$want" 'd["active"]'
hl_check "S7b goto_window:previous puts the previous one on show ($want)" $? "$(last)"
wsis "True" 'all(not o["mapped"] for o in d["order"] if o["window"] != d["toplevel"])'
hl_check "S7c no workspace's own window ever mapped: one window throughout" $? "$(last)"

# ---- 4. every open path opens a workspace, on show -------------------------
n0=$(ws 'len(d["order"])'); from=$(active)
press_on_show ctrl+shift+t
hl_wait_for 10 wsis $((n0 + 1)) 'len(d["order"])'
wsis "(True, 1, 1, True)" 'd["active"] != "'$from'" and d["active"] == d["content"], d["order"][0]["tabs"], row["'$from'"]["tabs"], d["toplevel_mapped"]'
hl_check "S8 new_tab opens a new workspace on show, one tab each; $from keeps its one tab" $? "$(last)"
grep -q "new_tab in single-window mode opens a workspace" "$APP_LOG"
hl_check "S8b ...logged as a workspace" $? "$(grep 'new_tab' "$APP_LOG" | tail -2)"

n0=$(ws 'len(d["order"])'); from=$(active)
press_on_show ctrl+shift+n
hl_wait_for 10 wsis $((n0 + 1)) 'len(d["order"])'
wsis "True" 'd["active"] != "'$from'" and d["active"] == d["content"]'
hl_check "S9 Ctrl+Shift+N opens a new workspace on show" $? "$(last)"

# A pane popped out of a two-pane workspace on show (rearrange mode, then a
# drag released over nothing - the pop-out path): a new workspace.
cli +split --target=two --direction=right > /dev/null 2>&1
hl_wait_for 10 wsis 2 'row["two"]["panes"]'
cli +new-window --target=two --focus > /dev/null 2>&1
hl_wait_for 10 wsis two 'd["active"]'
n0=$(ws 'len(d["order"])')
pop=$(panes_of two | cut -d' ' -f2)
press "$pop" ctrl+shift+period
sleep 1
pd_out=$(hl_ipc pane-drag "--target=$pop" --release-nowhere 2>&1)
hl_wait_for 10 wsis $((n0 + 1)) 'len(d["order"])'
wsis "(1, True, True)" 'row["two"]["panes"], d["active"] == d["content"] and d["active"] != "two", d["toplevel_mapped"]'
hl_check "S10 a pane popped out opens a new workspace on show, not a second window" $? "pane=$pop drag=$pd_out $(last)"
wsis "True" 'all(not o["mapped"] for o in d["order"] if o["window"] != d["toplevel"])'
hl_check "S10b only the toplevel is mapped" $? "$(last)"

# ---- 5. focus policy -------------------------------------------------------
from=$(active)
cli +new-window --target=five > /dev/null 2>&1
hl_wait_for 10 wsis True '"five" in row'
wsis "('$from', True)" 'd["active"], row["five"]["parked"]'
hl_check "S11 +new-window without --focus stays parked; $from keeps the window" $? "$(last)"
o=$(cli +new-window --target=two --focus 2>&1)
hl_wait_for 10 wsis "('two', 'two')" 'd["active"], d["content"]'
hl_check "S12 the idempotent --target=two --focus puts the parked two on show" $? "$o $(last)"
o=$(cli +split --target=five --direction=down --focus 2>&1)
hl_wait_for 10 wsis "five" 'd["active"]'
hl_check "S12b a --focus split into a parked workspace puts it on show" $? "$o $(last)"

alive "$APP"; hl_check "S13 the app is alive" $?
grep -E "workspace|over workspaces|new_tab|pop out|focus:" "$APP_LOG" | tail -40
hl_finish "$L"
