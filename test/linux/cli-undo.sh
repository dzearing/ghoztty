#!/usr/bin/env bash
# cli-undo.sh - T3384 acceptance: on Linux a closed pane, or a pane a
# +rearrange left out, can be undone, as on Mac (ExpiringUndoManager) and
# Windows (T1825 close-undo.ps1, T2234 rearrange-undo.ps1). For undo-timeout
# the pane is out of +list but its shell keeps running; ctrl+shift+z puts it
# back where it was, by name, same shell; ctrl+shift+y does it again; only
# when the undo expires does the shell end. `+close --force` is never undoable,
# and an undo in one window never reaches another. Run it ONLY through the
# wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-undo.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Keys reach the app
# through the debug-only `press-key` IPC seam, which feeds the chord through a
# pane's real binding table (Wayland has no input injection, and the headless
# Weston has no seat). Everything runs inside the private headless Weston
# (test/linux/lib/headless.sh), so no window ever reaches WSLg or the desktop.
#
# NEGATIVE=1 launches with --undo-timeout=0 (undo off): that run MUST fail.
#
# Output: one PASS/FAIL line per check, then 'CLI UNDO: ALL PASS' or
# 'CLI UNDO: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI UNDO"
timeout_s=6
[ "${NEGATIVE:-0}" = 1 ] && { timeout_s=0; echo "  NEGATIVE CONTROL: undo-timeout=0 - this run MUST fail"; }

log=/tmp/cli-undo-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "U1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "U2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    --undo-timeout=${timeout_s}s -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
hl_check "U3 the app serves its socket" $?

# list_py <mode> <window> [arg]: read +list once (cli-rearrange.sh's reader).
#   shape - the window's active-tab tree as H50(a,V50(b,c)); a leaf is its
#           name (an unnamed pane's is its id), a split its direction and ratio.
#   id/pid - the id / shell pid of the leaf named [arg].
list_py() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
mode, want = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
d = json.load(sys.stdin)["data"]
def shape(n):
    if n["type"] == "split":
        return "%s%d(%s,%s)" % (n["direction"][0].upper(), round(n["ratio"] * 100),
                                shape(n["left"]), shape(n["right"]))
    return n["terminal"].get("name", "")
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if (w.get("target") or "") != want: continue
    tab = next((t for t in w["tabs"] if t.get("selected")), w["tabs"][0])
    if mode == "shape": print(shape(tab["splits"]))
    for l in leaves(tab["splits"]):
        if mode == "id" and l.get("name") == arg: print(l["id"])
        if mode == "pid" and l.get("name") == arg: print(l.get("pid") or "")
' "$@" 2>/dev/null
}
shape_of() { list_py shape "$1"; }
shape_is() { [ "$(shape_of "$1")" = "$2" ]; }
has_window() { cli +list --json 2>/dev/null | grep -q "\"target\":\"$1\""; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
dead() { ! alive "$1"; }
dump() { echo "uw=$(shape_of uw) ux=$(shape_of ux)"; }
# press <pane> <chord>: one key press through the pane's binding table.
press() { hl_ipc press-key "--target=$1" "--key=$2" 2>&1; }
undo() { press "$1" ctrl+shift+z; }
redo() { press "$1" ctrl+shift+y; }

# uw: a (unnamed - addressed by id), b right of it, c below b.
cli +new-window --target=uw > /dev/null 2>&1
hl_wait_for 15 has_window uw
a=$(shape_of uw)
cli +split --target=uw --name=b > /dev/null 2>&1
cli +split --pane=b --name=c --direction=down > /dev/null 2>&1
full="H50($a,V50(b,c))"
hl_wait_for 15 shape_is uw "$full"
hl_check "S1 window uw holds a, b and c as $full" $? "$(dump)"
# ux: a second window, to prove the undo is per window.
cli +new-window --target=ux > /dev/null 2>&1
hl_wait_for 15 has_window ux
x=$(shape_of ux)
pid_b=$(list_py pid uw b)
pid_c=$(list_py pid uw c)
alive "$pid_b" && alive "$pid_c" && [ -n "$x" ]
hl_check "S2 b and c have live shells; window ux has its own pane" $? "b=$pid_b c=$pid_c x=$x"

# --- a closed pane --------------------------------------------------------------

cli +close --target=c > /dev/null 2>&1
hl_wait_for 10 shape_is uw "H50($a,b)"
hl_check "C1 +close c: c leaves +list, the layout is H50(a,b)" $? "$(dump)"
alive "$pid_c"
hl_check "C2 c's shell is still running while the undo lasts" $? "pid_c=$pid_c"

out=$(undo "$x")
sleep 1
shape_is uw "H50($a,b)"
hl_check "C3 ctrl+shift+z in window ux does not reach uw's close" $? "out=$out $(dump)"

out=$(undo "$a")
echo "$out" | grep -q '"effect":"consumed"'
hl_check "C4 ctrl+shift+z in uw is consumed by the undo binding" $? "out=$out"
hl_wait_for 10 shape_is uw "$full"
hl_check "C5 c is back where it was: $full" $? "$(dump)"
[ "$(list_py pid uw c)" = "$pid_c" ]
hl_check "C6 by name, with the same shell (pid $pid_c)" $? "now=$(list_py pid uw c)"
cli +send-keys --target=c 'echo C7_$((40+2))' Enter > /dev/null 2>&1
read_c() { cli +read --name=c --lines=20 2>/dev/null | grep -q 'C7_42'; }
hl_wait_for 10 read_c
hl_check "C7 the restored c answers to its name and runs what it is sent" $? "$(cli +read --name=c --lines=6 2>&1 | tr '\n' '|' | head -c 300)"

out=$(redo "$a")
hl_wait_for 10 shape_is uw "H50($a,b)"
hl_check "C8 ctrl+shift+y closes c again" $? "out=$out $(dump)"
alive "$pid_c"
hl_check "C9 ...and parks it again: its shell still runs" $? "pid_c=$pid_c"
out=$(undo "$a")
hl_wait_for 10 shape_is uw "$full"
hl_check "C10 ctrl+shift+z after the redo brings c back again" $? "out=$out $(dump)"

# --- a pane a +rearrange left out ---------------------------------------------

lay="{\"direction\":\"horizontal\",\"ratio\":70,\"left\":{\"pane\":\"c\"},\"right\":{\"pane\":\"$a\"}}"
out=$(cli +rearrange --target=uw "--layout=$lay" 2>&1); rc=$?
hl_wait_for 10 shape_is uw "H70(c,$a)"
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ]
hl_check "R1 a +rearrange without b gives H70(c,a)" $? "rc=$rc out=$out $(dump)"
[ -z "$(list_py id uw b)" ] && alive "$pid_b"
hl_check "R2 b left +list, and its shell is still running" $? "pid_b=$pid_b $(dump)"
out=$(undo "$a")
hl_wait_for 10 shape_is uw "$full"
hl_check "R3 ctrl+shift+z puts the previous layout back: $full" $? "out=$out $(dump)"
[ "$(list_py pid uw b)" = "$pid_b" ]
hl_check "R4 b is back by name, with the same shell" $? "now=$(list_py pid uw b)"
cli +send-keys --target=b 'echo R5_$((40+2))' Enter > /dev/null 2>&1
read_b() { cli +read --name=b --lines=20 2>/dev/null | grep -q 'R5_42'; }
hl_wait_for 10 read_b
hl_check "R5 the restored b runs what it is sent" $? "$(cli +read --name=b --lines=6 2>&1 | tr '\n' '|' | head -c 300)"
out=$(redo "$a")
hl_wait_for 10 shape_is uw "H70(c,$a)"
hl_check "R6 ctrl+shift+y puts the rearranged layout back" $? "out=$out $(dump)"
alive "$pid_b"
hl_check "R7 ...and b is parked again, not ended" $? "pid_b=$pid_b"
out=$(undo "$a")
hl_wait_for 10 shape_is uw "$full"
hl_check "R8 ctrl+shift+z after the redo restores it again" $? "out=$out $(dump)"

swap="{\"direction\":\"horizontal\",\"left\":{\"pane\":\"$a\"},\"right\":{\"direction\":\"vertical\",\"left\":{\"pane\":\"c\"},\"right\":{\"pane\":\"b\"}}}"
cli +rearrange --target=uw "--layout=$swap" > /dev/null 2>&1
hl_wait_for 10 shape_is uw "H50($a,V50(c,b))"
swapped=$?
out=$(undo "$a")
hl_wait_for 10 shape_is uw "$full"
back=$?
[ $swapped = 0 ] && [ $back = 0 ]
hl_check "R9 a rearrange that leaves nothing out (b and c swapped) undoes too" $? "out=$out $(dump)"

# --- expiry ---------------------------------------------------------------------

cli +close --target=c > /dev/null 2>&1
hl_wait_for 10 shape_is uw "H50($a,b)"
alive "$pid_c"
hl_check "X1 closing c again parks it" $? "pid_c=$pid_c $(dump)"
hl_wait_for $((timeout_s + 10)) dead "$pid_c"
hl_check "X2 c's shell ends once the undo expires (undo-timeout=${timeout_s}s)" $? "pid_c=$pid_c"
out=$(undo "$a")
sleep 1
shape_is uw "H50($a,b)"
hl_check "X3 nothing is left to undo: the layout stays H50(a,b)" $? "out=$out $(dump)"

# --- +close --force is never undoable -------------------------------------------

cli +split --pane=b --name=d --direction=down > /dev/null 2>&1
hl_wait_for 10 shape_is uw "H50($a,V50(b,d))"
pid_d=$(list_py pid uw d)
cli +close --target=d --force > /dev/null 2>&1
hl_wait_for 10 shape_is uw "H50($a,b)"
hl_wait_for 3 dead "$pid_d"
hl_check "F1 +close --force ends d's shell at once, not at the expiry" $? "pid_d=$pid_d $(dump)"
out=$(undo "$a")
sleep 1
shape_is uw "H50($a,b)"
hl_check "F2 and leaves nothing to undo" $? "out=$out $(dump)"

grep -q "panic\|reached unreachable" "$APP_LOG"
[ $? != 0 ]
hl_check "P1 the app logged no panic" $? "$(grep -m3 'panic\|unreachable' "$APP_LOG")"
grep -q "GLib-GObject-CRITICAL\|Gtk-CRITICAL" "$APP_LOG"
[ $? != 0 ]
hl_check "P2 the app logged no GTK/GObject critical" $? "$(grep -m3 'CRITICAL' "$APP_LOG")"

hl_finish "$L"
