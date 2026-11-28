#!/usr/bin/env bash
# window-goto-separate.sh - T3784 acceptance for goto_window in SEPARATE
# window mode on the GTK debug app (Mac 997b26535
# `BaseTerminalController.gotoWindow`, win32 T3132 `App.gotoWindow`).
#
# goto_window previous/next walks the pane sidebar's all-windows list - every
# tab of every visible window one stop, the list's order, wrapping at both
# ends - starting from the tab the chord was pressed in. Landing on a stop
# selects its tab in its window and raises that window. GTK's toplevel list
# (the order the windows opened in) and GTK's "active window" (which Weston
# headless never reports) play no part.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-goto-separate.sh
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'NEGATIVE=1 bash test/linux/window-goto-separate.sh'
#
# NEGATIVE=1 runs the same steps in `single` mode, where goto_window walks
# workspaces instead (window-workspace-switch.sh's job): the separate walk
# never runs, so it must FAIL from G1 on. Measured: 8 failures.
#
# Oracles: the debug-only `workspaces` seam's `stops` (the list's stops in
# order: window, tab position, whether it is the window's selected tab), the
# app log's `goto_window <dir>: <from> -> <to> of <n>` line, and +list --json
# for the pane ids to press in. Keys go in through `press-key`. Output: one
# PASS/FAIL line per check, then 'WINDOW GOTO SEPARATE: ALL PASS' or
# 'WINDOW GOTO SEPARATE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="WINDOW GOTO SEPARATE"
NEGATIVE=${NEGATIVE:-0}

log=/tmp/window-goto-separate-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "G0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "G0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
mode=separate
[ "$NEGATIVE" = 1 ] && mode=single
{
    echo 'window-width = 90'
    echo 'window-height = 24'
    echo 'quit-after-last-window-closed = false'
    echo 'confirm-close-surface = false'
    echo "macos-window-mode = $mode"
    echo 'macos-pane-sidebar = expanded'
    echo 'keybind = ctrl+shift+t=new_tab'
    echo 'keybind = ctrl+shift+down=goto_window:next'
    echo 'keybind = ctrl+shift+up=goto_window:previous'
} > "$cfg_dir/config.ghostty"
export SHELL=/bin/sh

# ws <python expression over d (the workspaces seam's data)>
ws() {
    hl_ipc workspaces > "$XDG_RUNTIME_DIR/ws-last" 2>&1
    python3 -I -c '
import json, sys
try:
    r = json.load(open(sys.argv[2]))
except Exception as e:
    print("unparsable:", e); sys.exit(1)
d = r.get("data") or {}
print(eval(sys.argv[1]))
' "$1" "$XDG_RUNTIME_DIR/ws-last"
}
wsis() { local want="$1"; shift; [ "$(ws "$@")" = "$want" ]; }
last() { cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null; }
# The first pane id of the selected tab of the window called <target>.
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
        print(next(leaves(tab["splits"]))["id"]); break
' "$1" 2>/dev/null
}
press() { hl_ipc press-key "--target=$1" "--key=$2" > /dev/null 2>&1; }
walks() { grep -c "goto_window $1: " "$APP_LOG" 2>/dev/null; }
# step <dir> <key> <from-stop>: press <key> in the window of stop <from-stop>
# (its selected tab), then check the walk logged <from> -> <from+-1> and that
# the stop landed on is now its window's selected tab. Sets CUR to it.
step() {
    local dir=$1 key=$2 from=$3 n w pane before want to_w line
    n=$(ws 'len(d["stops"])')
    w=$(ws "d['stops'][$from]['window']")
    if [ "$dir" = next ]; then want=$(( (from + 1) % n )); else want=$(( (from + n - 1) % n )); fi
    to_w=$(ws "d['stops'][$want]['window']")
    pane=$(pane_of "$w")
    before=$(walks "$dir")
    press "$pane" "$key"
    hl_wait_for 10 test "$(walks "$dir")" -gt "$before"
    line=$(grep "goto_window $dir: " "$APP_LOG" | tail -1)
    case "$line" in
        *"goto_window $dir: $from -> $want of $n window=$to_w"*) ;;
        *) STEP_WHY="pressed in $w (stop $from) want $from -> $want of $n window=$to_w; log: $line"; return 1 ;;
    esac
    hl_wait_for 10 wsis True "d['stops'][$want]['selected']" || {
        STEP_WHY="stop $want ($to_w) is not its window's selected tab: $(last)"; return 1; }
    CUR=$want
}

hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "G0c the app serves its socket" $?

cli +new-window --target=two --title=two > /dev/null 2>&1
cli +new-window --target=three --title=three > /dev/null 2>&1
hl_wait_for 10 wsis 3 'len(d["stops"])'
# A second tab in two: two windows' worth of stops in one GTK window.
press "$(pane_of two)" ctrl+shift+t
hl_wait_for 10 wsis 4 'len(d["stops"])'
hl_check "G1 four stops: the first window, three, and two's two tabs" $? "$(last)"
wsis "('separate', 2)" 'd["mode"], sum(1 for s in d["stops"] if s["window"] == "two")'
hl_check "G1b separate mode, two's tabs are two stops of the list" $? "$(last)"
echo "stops: $(ws 'd["stops"]')"

# ---- 1. next from a window that is not the first in the toplevel list -----
CUR=$(ws '[i for i, s in enumerate(d["stops"]) if s["window"] == "three" and s["selected"]][0]')
STEP_WHY=""; step next ctrl+shift+down "$CUR"
hl_check "G2 goto_window:next from three steps one along the list, from three's stop" $? "$STEP_WHY"

# ---- 2. a full lap: every stop visited, wrapping past the end -------------
n=$(ws 'len(d["stops"])'); start=$CUR; ok=0; why=""; visited="$CUR"
for _ in $(seq 1 "$n"); do
    STEP_WHY=""; step next ctrl+shift+down "$CUR" || { ok=1; why=$STEP_WHY; break; }
    visited="$visited $CUR"
done
[ $ok = 0 ] && [ "$CUR" = "$start" ]
hl_check "G3 $n more nexts visit every stop and wrap back to the start ($visited)" $? "$why"
grep -q "goto_window next: $((n - 1)) -> 0 of $n" "$APP_LOG"
hl_check "G3b ...the lap wrapped from the last stop to the first" $? "$(grep 'goto_window next: ' "$APP_LOG" | tail -5)"

# ---- 3. previous, wrapping past the start ---------------------------------
ok=0; why=""
for _ in $(seq 1 "$n"); do
    STEP_WHY=""; step previous ctrl+shift+up "$CUR" || { ok=1; why=$STEP_WHY; break; }
done
[ $ok = 0 ] && [ "$CUR" = "$start" ]
hl_check "G4 $n previouses walk the list backwards to the start" $? "$why"
grep -q "goto_window previous: 0 -> $((n - 1)) of $n" "$APP_LOG"
hl_check "G4b ...wrapping from the first stop to the last" $? "$(grep 'goto_window previous: ' "$APP_LOG" | tail -5)"

# ---- 4. the walk lands on a window's other tab -----------------------------
grep -qE "goto_window (next|previous): [0-9]+ -> [0-9]+ of $n window=two" "$APP_LOG"
hl_check "G5 the walk landed in two (and step checked the landed tab became selected each time)" $? "$(grep 'goto_window' "$APP_LOG" | tail -8)"

grep -q "panic\|reached unreachable" "$APP_LOG"
[ $? != 0 ]
hl_check "G6 the app logged no panic" $? "$(grep -m3 'panic\|unreachable' "$APP_LOG")"
kill -0 "$APP" 2>/dev/null
hl_check "G7 the app is alive" $?
hl_finish "$L"
