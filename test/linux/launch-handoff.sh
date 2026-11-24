#!/usr/bin/env bash
# launch-handoff.sh - T3598 acceptance: launching a DIFFERENT Ghoztty build
# while one already serves the CLI socket asks Switch / Open Window / Cancel
# (win32's T1023/T1070 launch half; the server half is T3595,
# test/linux/cli-handoff-quit.sh). The same build is never asked about; Open
# Window forwards the launch's window (its -e command included) to the running
# build; Switch quits the running build - its agent-hosted pane detaches - and
# the launch starts in its place and re-attaches that same shell; Cancel opens
# nothing.
#
# "Another build" is the one zig-out binary claiming a different identity
# (debug-only GHOZTTY_HANDOFF_VERSION / GHOZTTY_HANDOFF_COMMIT, win32's seam);
# answers are GHOZTTY_HANDOFF_PROMPT=join|switch (win32's automation hook);
# the dialog itself is proven by GHOZTTY_TEST_HANDOFF_DIALOG, which records it
# and ends it a moment later (Cancel) - Wayland has no input injection.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\launch-handoff.sh
#
# Everything runs inside the private headless Weston (test/linux/lib/headless.sh).
# Output: one PASS/FAIL line per check, then 'LAUNCH HANDOFF: ALL PASS' or
# 'LAUNCH HANDOFF: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="LAUNCH HANDOFF"

log=/tmp/launch-handoff-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "H1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
app=$(hl_ghoztty) || hl_finish "$L"
export SHELL=/bin/sh
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
serving() { cli +list > /dev/null 2>&1; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
gone() { ! kill -0 "$1" 2>/dev/null; }
# exit_code <pid> <secs>: wait for a launched child to end and set $rc to its
# status (124 when it is still running after <secs>). Not a $(...): a
# subshell cannot `wait` for the parent shell's child.
exit_code() {
    rc=124
    hl_wait_for "$2" gone "$1" || return 0
    wait "$1" 2>/dev/null; rc=$?
}
# crash_of <log>: the first lines of a crash in an app log, for a FAIL detail.
crash_of() { grep -m1 -B4 -A24 -E 'panic|Segmentation fault|reached unreachable|SIGABRT|Abort' "$1" 2>/dev/null | grep -v -E 'debug\(|program destroyed|EGL context' | tr '\n' ' ' | head -c 3000; }
vfield() {
    hl_ipc version 2>/dev/null | python3 -c '
import json, sys
print(json.load(sys.stdin)["data"].get(sys.argv[1]))' "$1" 2>/dev/null
}
windows() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
print(len(json.load(sys.stdin)["data"]["windows"]))' 2>/dev/null
}
pane_pid() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
want = sys.argv[1]
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if l.get("name") == want: print(l.get("pid") or 0); sys.exit(0)' "$1" 2>/dev/null
}
OTHER=(GHOZTTY_HANDOFF_VERSION=9.9.9-other GHOZTTY_HANDOFF_COMMIT=0000000)

# ---- 0. the running build, with an agent-hosted pane ------------------------
hl_launch APP "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_check "H2 the first build serves its socket" $?
beat="$HL_RUNTIME/beat"; spid="$HL_RUNTIME/spid"
cli +new-window --target=wh --name=ph --command="echo \$\$ > $spid; while :; do date +%s%N > $beat; sleep 0.2; done" > /dev/null 2>&1
hl_wait_for 20 test -s "$spid"
shell=$(cat "$spid" 2>/dev/null); listed=$(pane_pid ph)
alive "$shell" && alive "$listed"
hl_check "H3 an agent-hosted pane 'ph' runs a heartbeat shell" $? "pid=$shell listed=$listed"
w0=$(windows)

# ---- 1. the same build is never asked about ---------------------------------
dlg="$HL_RUNTIME/dialog"
hl_launch SAME env GHOZTTY_TEST_HANDOFF_DIALOG="$dlg" "$app" --gtk-single-instance=false
hl_wait_for 20 grep -q 'another instance already serves' "$SAME_LOG"
hl_check "H4 a launch of the same build starts without a question (as before)" $? "$(tail -n 3 "$SAME_LOG" | tr '\n' ' ')"
! test -e "$dlg" && ! grep -q 'different build' "$SAME_LOG"
hl_check "H5 ... no dialog was shown and nothing logged a different build" $?
kill -TERM "$SAME" 2>/dev/null; hl_wait_for 10 gone "$SAME"

# ---- 2. a different build is asked; ending the dialog is Cancel -------------
hl_launch ASK env "${OTHER[@]}" GHOZTTY_TEST_HANDOFF_DIALOG="$dlg" "$app" --gtk-single-instance=false
exit_code "$ASK" 20
line=$(head -n1 "$dlg" 2>/dev/null)
case "$line" in "shown A different Ghoztty is already running|Switch,Open Window,Cancel|"*) true ;; *) false ;; esac
hl_check "H6 another build's launch shows the dialog: title, then [Switch] [Open Window] [Cancel]" $? "$line"
printf '%s' "$line" | grep -q 'The copy you started is 9.9.9-other' && printf '%s' "$line" | grep -q 'your terminals will reopen in it'
hl_check "H7 ... it names the build started and says Switch keeps the terminals" $?
[ "$rc" = 0 ] && grep -q 'launch cancelled: a different build serves the socket' "$ASK_LOG"
hl_check "H8 Cancel opens nothing and the launch exits 0" $? "rc=$rc"
alive "$APP" && serving && [ "$(windows)" = "$w0" ]
hl_check "H9 ... the running build is untouched (still serving, $w0 window(s))" $? "windows=$(windows)"

# ---- 3. Open Window: the window and its -e command open in the running build -
mark="$HL_RUNTIME/joined"
hl_launch JOIN env "${OTHER[@]}" GHOZTTY_HANDOFF_PROMPT=join "$app" --gtk-single-instance=false -e /bin/sh -c "echo \$\$ > $mark; sleep 120"
exit_code "$JOIN" 20
[ "$rc" = 0 ] && grep -q 'the window opened in the running build' "$JOIN_LOG"
hl_check "H10 Open Window forwards the window and the launch exits 0" $? "rc=$rc $(grep -m2 'handoff' "$JOIN_LOG" | tr '\n' ' ')"
hl_wait_for 20 test -s "$mark"
hl_check "H11 ... the launch's -e command runs in the running build" $?
more_windows() { [ "$(windows)" -gt "$w0" ] 2>/dev/null; }
hl_wait_for 10 more_windows
hl_check "H12 ... which now has one more window" $? "windows=$(windows) before=$w0"
alive "$APP"
hl_check "H13 ... and is still the app (pid $APP)" $?

# ---- 4. Switch: the running build quits, this launch takes over -------------
hl_launch SW env "${OTHER[@]}" GHOZTTY_HANDOFF_PROMPT=switch "$app" --gtk-single-instance=false
exit_code "$APP" 20
[ "$rc" = 0 ]
hl_check "H14 Switch: the running build quits, cleanly (exit 0, not a crash)" $? "rc=$rc $(crash_of "$APP_LOG")"
grep -q 'handoff-quit: quitting so the launch of 9.9.9-other' "$APP_LOG"
hl_check "H15 ... because the launch asked (its log names the launching build)" $? "$(grep -m1 'handoff' "$APP_LOG")"
sw_serving() { [ "$(vfield pid)" = "$SW" ]; }
hl_wait_for 30 sw_serving
hl_check "H16 ... and the launch is now the app serving the socket (pid $SW)" $? "serving pid=$(vfield pid)"
grep -q 'handoff: this launch is now the app (9.9.9-other' "$SW_LOG"
hl_check "H17 ... its log says it took over" $? "$(grep 'handoff' "$SW_LOG" | tr '\n' ' ')"
attached() { [ "$(pane_pid ph)" = "$listed" ]; }
hl_wait_for 20 attached && alive "$shell"
hl_check "H18 ... and re-attached 'ph' to the same session (pid $listed, shell $shell alive)" $? "listed pid now=$(pane_pid ph)"
b1=$(cat "$beat" 2>/dev/null); sleep 1; b2=$(cat "$beat" 2>/dev/null)
[ -n "$b1" ] && [ "$b1" != "$b2" ]
hl_check "H19 ... whose heartbeat never stopped" $?

# ---- 5. persistence off: the question says the terminals will close --------
kill -TERM "$SW" 2>/dev/null; hl_wait_for 10 gone "$SW"
hl_launch NP "$app" --gtk-single-instance=false --session-persistence=false
hl_wait_for 30 serving
rm -f "$dlg"
hl_launch ASK2 env "${OTHER[@]}" GHOZTTY_TEST_HANDOFF_DIALOG="$dlg" "$app" --gtk-single-instance=false
exit_code "$ASK2" 20
grep -q 'the terminals open in it will close' "$dlg" 2>/dev/null
hl_check "H20 against a build without persistence, Switch is priced: the terminals will close" $? "$(head -c 300 "$dlg" 2>/dev/null)"

hl_finish "$L"
