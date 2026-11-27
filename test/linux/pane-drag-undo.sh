#!/usr/bin/env bash
# pane-drag-undo.sh - T3706 (Linux L11b6) acceptance: undo puts back a pane
# drag, as on the Mac (PaneMoveCoordinator registers every move under the
# undo action "Move Pane", across both windows' trees). Every kind of drop is
# ONE undoable step on Ctrl+Shift+Z, and Ctrl+Shift+Y does it again:
#
#   M5-M8   a drop inside the pane's own tab
#   M9-M11  a drop on the tab bar: the pane's new tab goes again on undo, and
#           comes back on redo
#   M12-M14 a drop from another tab that EMPTIES the tab it left: undo
#           brings that tab back, with the pane in it
#   M15-M16 a drop into another window, undone from that window
#   M17-M19 a window's last pane joining another window: the window it
#           emptied comes back on undo, and goes again on redo
#   M20-M22 a pop-out into a new window: undo closes that window and puts the
#           pane back; redo opens it again
#
# Every move keeps the very same panes (same shells, same pids, M23). Drops
# go through the debug-only `pane-drag` seam - the code a real release calls
# (SplitTree.dropPaneAt, Window.dropOnTabBar, Window.popOutPane) - and keys
# through `press-key`: the headless harness has no seat, so a pointer drag
# cannot START here (that half is NOT RUN, as in cli-pane-drag.sh).
#
# Run it ONLY through the wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\pane-drag-undo.sh
#
# NEGATIVE=1 launches with --undo-timeout=0 (undo off): every undo and redo
# check must FAIL (M6, M7, M8, M10, M11, M13, M14, M16, M18, M19, M21, M22,
# M24), and nothing else.
# Output: one PASS/FAIL line per check, then 'PANE DRAG UNDO: ALL PASS' or
# 'PANE DRAG UNDO: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PANE DRAG UNDO"
timeout_s=60
[ "${NEGATIVE:-0}" = 1 ] && { timeout_s=0; echo "  NEGATIVE CONTROL: undo-timeout=0 - this run MUST fail"; }

log=/tmp/pane-drag-undo-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "M1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "M2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    --undo-timeout=${timeout_s}s --confirm-close-surface=false \
    -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
hl_check "M3 the app serves its socket" $?

# tabs_of <window>: every tab's shape in tab order, '*' before the selected
# one: "*a | V(b,c)". An unnamed pane's name is its id.
tabs_of() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
d = json.load(sys.stdin)["data"]
def shape(n):
    if n["type"] == "split":
        return "%s(%s,%s)" % (n["direction"][0].upper(), shape(n["left"]), shape(n["right"]))
    return n["terminal"].get("name", "")
for w in d["windows"]:
    if (w.get("target") or "") != want: continue
    print(" | ".join(("*" if t.get("selected") else "") + shape(t["splits"]) for t in w["tabs"]))
' "$1" 2>/dev/null
}
# plain <window>: tabs_of without the selection mark.
plain() { tabs_of "$1" | tr -d '*'; }
is() { [ "$(plain "$1")" = "$2" ]; }
has_window() { cli +list --json 2>/dev/null | grep -q "\"target\":\"$1\""; }
# pid_of <name>: the shell pid of the pane so named, in any window.
pid_of() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
name = sys.argv[1]
d = json.load(sys.stdin)["data"]
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    for t in w["tabs"]:
        for l in leaves(t["splits"]):
            if l.get("name") == name: print(l.get("pid") or "")
' "$1" 2>/dev/null
}
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
pd() { hl_ipc pane-drag "$@"; }
pf() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$2" 2>/dev/null; }
nwin() { pf "$(pd --target="$1")" "d['window_count']"; }
undo() { hl_ipc press-key --target="$1" --key=ctrl+shift+z > /dev/null; }
redo() { hl_ipc press-key --target="$1" --key=ctrl+shift+y > /dev/null; }
# drop <label> <pd args...>: a drop that must report outcome=moved.
drop() {
    local label=$1; shift
    local r; r=$(pd "$@")
    [ "$(pf "$r" "d['drop']['outcome']")" = moved ]
    hl_check "$label" $? "$r"
}

# dw: a (unnamed) | V(b, c), in rearrange mode so its tab bar is a target.
cli +new-window --target=dw > /dev/null 2>&1
hl_wait_for 15 has_window dw
a=$(plain dw)
cli +split --target=dw --name=b > /dev/null 2>&1
cli +split --pane=b --name=c --direction=down > /dev/null 2>&1
start="H($a,V(b,c))"
hl_wait_for 15 is dw "$start"
hl_check "M4 window dw holds $start" $? "dw=$(tabs_of dw)"
hl_ipc press-key --target=b --key=ctrl+shift+period > /dev/null
bar_up() { [ "$(pf "$(pd --target=b)" "d['tab_buttons']")" = 1 ]; }
hl_wait_for 5 bar_up
pid_a=$(pid_of "$a"); pid_b=$(pid_of b); pid_c=$(pid_of c)

# --- in its own tab ---------------------------------------------------------------

drop "M5 c dropped on a's left edge moves inside the tab" --target=c --drop-on="$a" --fx=0.06 --fy=0.5
moved_in=$(plain dw)
[ "$moved_in" != "$start" ]
hl_check "M5b the layout changed" $? "dw=$moved_in"
undo b
hl_wait_for 5 is dw "$start"
hl_check "M6 Ctrl+Shift+Z puts the in-tab drop back: $start" $? "dw=$(tabs_of dw)"
redo b
hl_wait_for 5 is dw "$moved_in"
hl_check "M7 Ctrl+Shift+Y makes it again: $moved_in" $? "dw=$(tabs_of dw)"
undo b
hl_wait_for 5 is dw "$start"
hl_check "M8 and undo again puts it back" $? "dw=$(tabs_of dw)"

# --- the tab bar: a new tab ---------------------------------------------------------

drop "M9 b dropped on the tab button becomes a new tab before it" --target=b --drop-tab=0
hl_wait_for 5 is dw "b | H($a,c)"
undo c
hl_wait_for 5 is dw "$start"
hl_check "M10 undo puts b back in its tab, and the tab it made goes" $? "dw=$(tabs_of dw)"
redo c
hl_wait_for 5 is dw "b | H($a,c)"
hl_check "M11 redo makes b's tab again" $? "dw=$(tabs_of dw)"

# --- from another tab, emptying the one it left -------------------------------------

# A drag resting on the other tab's button opens it (the dwell), then the
# drop lands in that tab's layout - as a real drag goes.
pd --target=b --hover-tab=1 > /dev/null
second_on_show() { [ "$(pf "$(pd --target=b)" "d['selected_tab']")" = 1 ]; }
hl_wait_for 5 second_on_show
drop "M12 b, its tab's only pane, dropped on c in the other tab: its tab empties" \
    --target=b --drop-on=c --fx=0.5 --fy=0.94
one_tab() { [ "$(plain dw | grep -o ' | ' | wc -l)" = 0 ] && plain dw | grep -q 'b'; }
hl_wait_for 5 one_tab
joined=$(plain dw)
one_tab
hl_check "M12b dw is down to one tab, b in it: $joined" $? "dw=$(tabs_of dw)"
undo c
hl_wait_for 5 is dw "b | H($a,c)"
hl_check "M13 undo brings the emptied tab back, b in it" $? "dw=$(tabs_of dw) (after the drop: $joined)"
redo c
hl_wait_for 5 is dw "$joined"
hl_check "M14 redo empties it again: $joined" $? "dw=$(tabs_of dw)"

# --- into another window ------------------------------------------------------------

cli +new-window --target=w2 > /dev/null 2>&1
hl_wait_for 15 has_window w2
f=$(plain w2); pid_f=$(pid_of "$f")
before_dw=$(plain dw)
drop "M15 c dropped on f in window w2 splits f there" --target=c --drop-on="$f" --fx=0.94 --fy=0.5
hl_wait_for 5 is w2 "H($f,c)"
undo "$f"
hl_wait_for 5 is dw "$before_dw"
is w2 "$f"
hl_check "M16 undo from w2 sends c home: dw $before_dw, w2 $f" $? "dw=$(tabs_of dw) w2=$(tabs_of w2)"

# --- a window's last pane: the window it empties ------------------------------------

cli +new-window --target=solo > /dev/null 2>&1
hl_wait_for 15 has_window solo
s=$(plain solo); pid_s=$(pid_of "$s")
win0=$(nwin "$f")
drop "M17 solo's only pane dropped on f in w2: solo closes" --target="$s" --drop-on="$f" --fx=0.94 --fy=0.5
gone() { ! has_window solo; }
hl_wait_for 5 gone
hl_check "M17b solo is gone, its pane in w2" $? "w2=$(tabs_of w2) windows=$(nwin "$f")"
undo "$f"
hl_wait_for 5 has_window solo
is solo "$s" && is w2 "$f" && [ "$(nwin "$f")" = "$win0" ] && [ "$(pid_of "$s")" = "$pid_s" ]
hl_check "M18 undo brings solo back with its pane, same shell" $? "solo=$(tabs_of solo) w2=$(tabs_of w2) windows=$(nwin "$f") pid=$(pid_of "$s")/$pid_s"
redo "$f"
hl_wait_for 5 gone
is w2 "H($f,$s)"
hl_check "M19 redo closes solo again, its pane back in w2" $? "w2=$(tabs_of w2) solo=$(tabs_of solo)"

# --- a pop-out into a new window ----------------------------------------------------

win1=$(nwin "$f")
r=$(pd --target="$s" --pop-out)
[ "$(pf "$r" "d['drop']['outcome']")" = moved ] && is w2 "$f"
hl_check "M20 s pops out of w2 into a new window" $? "$r w2=$(tabs_of w2)"
popped() { [ "$(nwin "$f")" = $((win1 + 1)) ]; }
hl_wait_for 5 popped
undo "$f"
back_in() { is w2 "H($f,$s)" && [ "$(nwin "$f")" = "$win1" ]; }
hl_wait_for 5 back_in
hl_check "M21 undo puts s back in w2 and closes the window it popped into" $? "w2=$(tabs_of w2) windows=$(nwin "$f")/$win1"
redo "$f"
out_again() { is w2 "$f" && [ "$(nwin "$f")" = $((win1 + 1)) ]; }
hl_wait_for 5 out_again
hl_check "M22 redo pops it out again, into a window of its own" $? "w2=$(tabs_of w2) windows=$(nwin "$f")/$win1"

[ "$(pid_of "$a")" = "$pid_a" ] && [ "$(pid_of b)" = "$pid_b" ] && [ "$(pid_of c)" = "$pid_c" ] \
    && [ "$(pid_of "$f")" = "$pid_f" ] && [ "$(pid_of "$s")" = "$pid_s" ] \
    && alive "$pid_a" && alive "$pid_b" && alive "$pid_c" && alive "$pid_f" && alive "$pid_s"
hl_check "M23 every move, undo and redo kept the same panes: same shells, still running" $? \
    "a=$pid_a/$(pid_of "$a") b=$pid_b/$(pid_of b) c=$pid_c/$(pid_of c) f=$pid_f/$(pid_of "$f") s=$pid_s/$(pid_of "$s")"
grep -q 'pane move recorded for undo' "$APP_LOG" && grep -q 'pane move emptied a window: kept for undo' "$APP_LOG" \
    && grep -q 'pane move emptied the tab at' "$APP_LOG"
hl_check "M24 the app logged the recorded moves, the emptied tab and the emptied window" $?
[ -s "$APP_LOG" ] && ! grep -E -- '-(CRITICAL|WARNING) \*\*' "$APP_LOG" > /dev/null
hl_check "M25 the app logged no GTK critical or warning through the moves and undos" $? "$(grep -E -m5 -- '-(CRITICAL|WARNING) \*\*' "$APP_LOG" | tr '\n' ' ')"

hl_finish "$L"
