#!/usr/bin/env bash
# agent-upgrade.sh - T3600 (Linux L8f) acceptance: the GTK app adopts a newer
# bundled agent build without ever ending a live session for it, and a
# protocol-skewed agent gets the mandatory-update dialog (agent older) or the
# app-older notice (agent newer) - win32's T147/T125/T1056/T626 on Linux.
#
# An older agent cannot be built from one tree, so the two debug-only hooks
# win32's agent-upgrade.ps1 uses stand in for it: GHOZTTY_AGENT_BUNDLED_VERSION
# (the app believes it ships a newer build) and GHOZTTY_AGENT_PROTO_VERSION (a
# hand-started agent advertises another protocol). The skew dialog's click is
# scripted through GHOZTTY_TEST_AGENT_SKEW_ANSWER, the debug seam that also
# records the dialog (GHOZTTY_TEST_AGENT_SKEW_DIALOG).
#
# T3691 (U30-U48): the deferred case is visible - the main menu's
# "Background Update Ready…" row and the palette's "Install Background Process
# Update…" entry appear while it waits, read through the main-menu and
# command-palette seams; the opt-in dialog is scripted the same way
# (GHOZTTY_TEST_AGENT_UPDATE_DIALOG / _ANSWER).
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\agent-upgrade.sh
#
# Output: one PASS/FAIL line per check, then 'AGENT UPGRADE: ALL PASS' or
# 'AGENT UPGRADE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="AGENT UPGRADE"

log=/tmp/agent-upgrade-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "U1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
app=$(hl_ghoztty) || hl_finish "$L"
agent_bin="$(dirname "$app")/ghoztty-agent"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
export SHELL=/bin/sh
serving() { cli +list > /dev/null 2>&1; }
alive() { [ -n "$1" ] && [ "$1" != 0 ] && [ "$1" != None ] && kill -0 "$1" 2>/dev/null; }
is_ancestor() {
    local want=$1 p=$2
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do
        [ "$p" = "$want" ] && return 0
        p=$(awk '/^PPid:/ { print $2 }' "/proc/$p/status" 2>/dev/null)
    done
    return 1
}
leaf_field() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
want, field = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if l.get("name") == want: print(l.get(field)); sys.exit(0)
' "$1" "$2" 2>/dev/null
}
on_agent() { local p; p=$(leaf_field "$2" pid); alive "$p" && is_ancestor "$1" "$p"; }
logged() { grep -q -- "$2" "$1" 2>/dev/null; }
# Each phase is a fresh app: no restored windows from the last one.
stop_app() {
    kill -KILL "$1" 2>/dev/null; wait "$1" 2>/dev/null
    rm -f "${XDG_CONFIG_HOME:?}"/ghoztty/session-layout-debug*.json
}
STALE=20991231-test-newer
jget() { printf '%s' "$1" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); d=r.get("data",r); v=eval(sys.argv[1]); print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$2" 2>/dev/null; }
ROW='Background Update Ready…'
PAL='Install Background Process Update…'
# row_enabled <pane>: the main menu's update row's enabled state (true/false),
# or <no item>. The row is hidden-when action-disabled, so true = on screen.
row_enabled() { jget "$(hl_ipc main-menu --target="$1")" "next((i[\"enabled\"] for i in d[\"items\"] if i[\"label\"]==\"$ROW\"), \"<no item>\")"; }
row_action() { jget "$(hl_ipc main-menu --target="$1")" "next((i[\"action\"] for i in d[\"items\"] if i[\"label\"]==\"$ROW\"), \"<no item>\")"; }
# pal_lists <pane>: the palette, opened and searched, settles and shows the row.
pal_lists() {
    local o
    o=$(hl_ipc command-palette --target="$1" --op=open --query='background process')
    o=$(hl_ipc command-palette --target="$1")
    [ "$(jget "$o" 'd["pending"]')" = false ] && [ "$(jget "$o" "any(r[\"title\"]==\"$PAL\" for r in d[\"rows\"])")" = true ]
}
pal_settled_without() {
    local o
    o=$(hl_ipc command-palette --target="$1" --op=open --query='background process')
    o=$(hl_ipc command-palette --target="$1")
    [ "$(jget "$o" 'd["pending"]')" = false ] && [ "$(jget "$o" "any(r[\"title\"]==\"$PAL\" for r in d[\"rows\"])")" = false ]
}
udlg="$HL_RUNTIME/update-dialog.txt"; : > "$udlg"

# ---- 1. stale build, a live session: left strictly alone (T1056) ----------
hl_launch APP env GHOZTTY_AGENT_BUNDLED_VERSION=$STALE GHOZTTY_TEST_AGENT_UPDATE_DIALOG="$udlg" GHOZTTY_TEST_AGENT_UPDATE_ANSWER=later "$app" --gtk-single-instance=false --initial-window=false --quit-after-last-window-closed=false
hl_wait_for 30 serving
hl_check "U2 the app serves its socket" $?
cli +new-window --target=wu --name=pa --command="echo ready-pa" > /dev/null 2>&1
hl_wait_for 20 hl_agent_pid
agent1=$(hl_agent_pid)
hl_wait_for 20 on_agent "$agent1" pa
hl_check "U3 pa runs under agent $agent1" $? "pa=$(leaf_field pa pid)"
hl_wait_for 15 logged "$APP_LOG" 'agent upgrade check: stale with live sessions'
hl_check "U4 launch check: stale with a live session is deferred, not restarted" $? \
    "$(grep -m3 'agent upgrade' "$APP_LOG" | tr '\n' '|')"
grep -q "bundled agent build OVERRIDDEN to $STALE" "$APP_LOG"
hl_check "U5 the bundled stamp came from the debug hook" $?
sleep 1
[ "$(hl_agent_pid)" = "$agent1" ] && on_agent "$agent1" pa
hl_check "U6 the agent and pa's shell are untouched" $? "agent=$(hl_agent_pid) want=$agent1"
! grep -q 'local agent refreshed' "$APP_LOG"
hl_check "U7 no refresh happened while a session was live" $?

# ---- 1b. ...but the wait is visible, and Later keeps it (T3691) ------------
grep -q 'agent update affordance: shown (when_idle)' "$APP_LOG"
hl_check "U30 the deferral puts the waiting-update affordance up" $? "$(grep 'affordance' "$APP_LOG" | tr '\n' '|')"
a=$(row_action pa); e=$(row_enabled pa)
[ "$a" = app.install-agent-update ] && [ "$e" = true ]
hl_check "U31 the main menu shows '$ROW' (on app.install-agent-update, enabled)" $? "action=$a enabled=$e"
hl_wait_for 5 pal_lists pa
hl_check "U32 the command palette lists '$PAL'" $?
hl_ipc command-palette --target=pa --op=close > /dev/null
o=$(hl_ipc main-menu --target=pa "--activate=$ROW")
hl_wait_for 10 grep -q '^shown ' "$udlg"
hl_check "U33 choosing the row asks first" $? "activated=$(jget "$o" 'd["activated"]') dlg=$(cat "$udlg")"
grep -q '^shown Install the background process update now?|Later,Restart Now|.*nothing you have open is interrupted.*ends your 1 open terminal session .*Your windows stay open' "$udlg"
hl_check "U34 the dialog leads with 'waiting is free', Later first, names the 1 session it ends" $? "$(cat "$udlg")"
hl_wait_for 10 logged "$APP_LOG" 'agent update offer: user chose Later; the update keeps waiting'
hl_check "U35 Later is logged" $?
sleep 1
[ "$(hl_agent_pid)" = "$agent1" ] && on_agent "$agent1" pa && [ "$(row_enabled pa)" = true ]
hl_check "U36 after Later the agent and pa are untouched and the row stays" $? "agent=$(hl_agent_pid) want=$agent1 row=$(row_enabled pa)"

# ---- 2. the last window closes: idle, so the agent is refreshed ------------
cli +close --target=pa > /dev/null 2>&1
refreshed() { logged "$APP_LOG" 'local agent refreshed to bundled build'; }
hl_wait_for 20 refreshed
hl_check "U8 the last window closing refreshes the now-idle agent" $? \
    "$(grep 'agent upgrade\|agent restart\|refreshed' "$APP_LOG" | tail -5 | tr '\n' '|')"
grep -q 'agent upgrade check: stale and idle, refreshing now' "$APP_LOG"
hl_check "U9 the decision was logged as stale-and-idle before acting" $?
new_agent() { a=$(hl_agent_pid) && [ "$a" != "$agent1" ]; }
hl_wait_for 10 new_agent
agent2=$(hl_agent_pid)
hl_check "U10 a fresh agent replaced the old one" $? "agent $agent1 -> $agent2"
! kill -0 "$agent1" 2>/dev/null
hl_check "U11 the old agent process is gone" $?
cli +new-window --target=wu2 --name=pb --command="echo ready-pb" > /dev/null 2>&1
hl_wait_for 20 on_agent "$agent2" pb
hl_check "U12 a new pane rides the refreshed agent" $? "pb=$(leaf_field pb pid) agent=$agent2"
kill -0 "$APP" 2>/dev/null
hl_check "U13 the app stayed up" $?
grep -q 'agent update affordance: cleared' "$APP_LOG"
hl_check "U37 the refresh takes the waiting-update affordance down" $? "$(grep 'affordance' "$APP_LOG" | tr '\n' '|')"

# Capture the agent's exact launch so the skew phases can start one by hand.
mapfile -d '' agent_argv < "/proc/$agent2/cmdline"
agent_env=$(tr '\0' '\n' < "/proc/$agent2/environ" | grep '^GHOSTTY_AGENT_' | tr '\n' ' ')
stop_app "$APP"
hl_stop_agent

# ---- 3. current build: nothing to do (negative control) -------------------
hl_launch APP2 "$app" --gtk-single-instance=false --initial-window=false --quit-after-last-window-closed=false
hl_wait_for 30 serving
cli +new-window --target=wc --name=pc --command="echo ready-pc" > /dev/null 2>&1
hl_wait_for 15 logged "$APP2_LOG" 'agent upgrade check: no action, running agent is the bundled build'
hl_check "U14 an agent of the bundled build is left alone (current)" $? \
    "$(grep -m3 'agent upgrade\|bundled agent build' "$APP2_LOG" | tr '\n' '|')"
! grep -q 'refreshed\|agent restart' "$APP2_LOG"
hl_check "U15 ... and nothing was restarted" $?
e=$(row_enabled pc)
[ "$e" = false ]
hl_check "U38 with nothing waiting the update row is hidden (action disabled)" $? "enabled=$e"
hl_wait_for 5 pal_settled_without pc
hl_check "U39 ... and the palette does not list '$PAL'" $?
hl_ipc command-palette --target=pc --op=close > /dev/null
! grep -q 'agent update affordance' "$APP2_LOG"
hl_check "U40 ... and no affordance was ever shown" $?
stop_app "$APP2"
hl_stop_agent

# ---- 3b. stale with a live session, the user installs now (T3691) ----------
: > "$udlg"
hl_launch APP6 env GHOZTTY_AGENT_BUNDLED_VERSION=$STALE GHOZTTY_TEST_AGENT_UPDATE_DIALOG="$udlg" GHOZTTY_TEST_AGENT_UPDATE_ANSWER=restart "$app" --gtk-single-instance=false --initial-window=false --quit-after-last-window-closed=false
hl_wait_for 30 serving
cli +new-window --target=wi --name=pi --command="echo ready-pi" > /dev/null 2>&1
hl_wait_for 20 hl_agent_pid
agent6=$(hl_agent_pid)
hl_wait_for 20 on_agent "$agent6" pi
hl_wait_for 15 logged "$APP6_LOG" 'agent update affordance: shown'
hl_check "U41 a fresh launch over a stale agent with a live session shows the affordance" $? "$(grep -m3 'agent upgrade\|affordance' "$APP6_LOG" | tr '\n' '|')"
hl_wait_for 5 pal_lists pi
hl_check "U42 the palette lists '$PAL'" $?
o=$(hl_ipc command-palette --target=pi --op=run "--title=$PAL")
hl_wait_for 10 grep -q '^shown Install the background process update now?' "$udlg"
hl_check "U43 running the palette entry asks the same question" $? "ran=$(jget "$o" 'd["ran"]') dlg=$(cat "$udlg")"
hl_wait_for 15 logged "$APP6_LOG" 'local agent restarted onto the bundled build at the user'
hl_check "U44 Restart Now restarts the agent" $? "$(grep 'agent update\|agent upgrade\|recovery' "$APP6_LOG" | tail -6 | tr '\n' '|')"
hl_wait_for 10 sh -c "! kill -0 $agent6 2>/dev/null"
hl_check "U45 the stale agent process is gone" $?
agent7=$(hl_agent_pid)
hl_wait_for 20 on_agent "$agent7" pi
hl_check "U46 pi is rebuilt in place on the new agent (window kept)" $? "agent $agent6 -> $agent7 pi=$(leaf_field pi pid)"
e=$(row_enabled pi)
[ "$e" = false ] && logged "$APP6_LOG" 'agent update affordance: cleared'
hl_check "U47 the row is gone once the update is installed" $? "enabled=$e"
kill -0 "$APP6" 2>/dev/null
hl_check "U48 the app stayed up" $?
stop_app "$APP6"
hl_stop_agent

# start_agent <proto>: the agent, launched exactly as the app launches it,
# advertising protocol <proto>.
start_agent() {
    local a pf=
    for a in "${agent_argv[@]}"; do case "$a" in --port-file=*) pf=${a#--port-file=} ;; esac; done
    [ -n "$pf" ] && rm -f "$pf"
    # shellcheck disable=SC2086
    setsid env $agent_env GHOZTTY_AGENT_PROTO_VERSION="$1" "${agent_argv[@]}" \
        >> "$HL_RUNTIME/skew-agent.log" 2>&1 < /dev/null &
    hl_wait_for 10 hl_agent_pid
}

# ---- 4. skew, agent older, user says Later: nothing is touched ------------
start_agent 0
skew1=$(hl_agent_pid)
hl_check "U16 a hand-started agent advertising protocol 0 is up" $? "pid=$skew1 argv=${agent_argv[*]}"
dlg="$HL_RUNTIME/skew-dialog.txt"; : > "$dlg"
hl_launch APP3 env GHOZTTY_TEST_AGENT_SKEW_DIALOG="$dlg" GHOZTTY_TEST_AGENT_SKEW_ANSWER=later "$app" --gtk-single-instance=false --initial-window=false --quit-after-last-window-closed=false
hl_wait_for 30 serving
cli +new-window --target=ws --name=ps --command="echo ready-ps" > /dev/null 2>&1
hl_wait_for 15 grep -q '^shown ' "$dlg"
hl_check "U17 the mandatory-update dialog is shown for an older-protocol agent" $? "$(cat "$dlg")"
grep -q '^shown Restart the Ghoztty background terminal process?|Later,Restart Now|.*it speaks version 0, this app speaks' "$dlg"
hl_check "U18 the dialog names the act, Later first, and both versions" $? "$(cat "$dlg")"
hl_wait_for 10 logged "$APP3_LOG" 'the user chose Later'
hl_check "U19 Later is logged" $?
sleep 1
kill -0 "$skew1" 2>/dev/null && [ "$(hl_agent_pid)" = "$skew1" ]
hl_check "U20 after Later the skewed agent is untouched" $? "agent=$(hl_agent_pid) want=$skew1"
p=$(leaf_field ps pid)
alive "$p" && ! is_ancestor "$skew1" "$p"
hl_check "U21 the pane still opened, as a plain shell (no persistence)" $? "ps=$p"
stop_app "$APP3"

# ---- 5. skew, agent older, user says Restart: a working agent again -------
: > "$dlg"
hl_launch APP4 env GHOZTTY_TEST_AGENT_SKEW_DIALOG="$dlg" GHOZTTY_TEST_AGENT_SKEW_ANSWER=restart "$app" --gtk-single-instance=false --initial-window=false --quit-after-last-window-closed=false
hl_wait_for 30 serving
cli +new-window --target=wr --name=pr --command="echo ready-pr" > /dev/null 2>&1
hl_wait_for 15 grep -q '^shown ' "$dlg"
hl_check "U22 the dialog is shown again on the next launch" $?
hl_wait_for 15 logged "$APP4_LOG" 'restarted onto the bundled build after the protocol skew'
hl_check "U23 Restart replaces the skewed agent with the bundled build" $? \
    "$(grep 'agent upgrade\|agent restart\|recovery' "$APP4_LOG" | tail -6 | tr '\n' '|')"
hl_wait_for 10 sh -c "! kill -0 $skew1 2>/dev/null"
hl_check "U24 the skewed agent process is gone" $?
fresh=$(hl_agent_pid)
[ -n "$fresh" ] && [ "$fresh" != "$skew1" ]
hl_check "U25 a fresh agent is up" $? "agent=$fresh"
cli +new-window --target=wr2 --name=pr2 --command="echo ready-pr2" > /dev/null 2>&1
hl_wait_for 20 on_agent "$fresh" pr2
hl_check "U26 a new pane after the restart has session persistence again" $? "pr2=$(leaf_field pr2 pid) agent=$fresh"
stop_app "$APP4"
hl_stop_agent

# ---- 6. skew, agent NEWER: the app says it is out of date, never acts ------
start_agent 9999
skew2=$(hl_agent_pid)
: > "$dlg"
hl_launch APP5 env GHOZTTY_TEST_AGENT_SKEW_DIALOG="$dlg" GHOZTTY_TEST_AGENT_SKEW_ANSWER=restart "$app" --gtk-single-instance=false --initial-window=false --quit-after-last-window-closed=false
hl_wait_for 30 serving
cli +new-window --target=wn --name=pn --command="echo ready-pn" > /dev/null 2>&1
hl_wait_for 15 logged "$APP5_LOG" 'agent upgrade: app-older notice'
hl_check "U27 an agent on a NEWER protocol gets the app-older notice" $? \
    "$(grep -m3 'agent upgrade' "$APP5_LOG" | tr '\n' '|')"
sleep 1
[ ! -s "$dlg" ]
hl_check "U28 ... and no restart dialog, even with a scripted Restart waiting" $? "$(cat "$dlg")"
kill -0 "$skew2" 2>/dev/null && [ "$(hl_agent_pid)" = "$skew2" ]
hl_check "U29 the newer agent is never stopped (no downgrade)" $? "agent=$(hl_agent_pid) want=$skew2"
stop_app "$APP5"

hl_finish "$L"
