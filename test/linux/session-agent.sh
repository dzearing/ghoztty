#!/usr/bin/env bash
# session-agent.sh - T3337 (Linux L8, first slice) acceptance: with
# session-persistence on (the default) the GTK app runs every new pane under
# the local ghoztty-agent, found or spawned over the Mac's 0600 Unix socket,
# so the pane outlives the app; a pane the USER closes ends its session; and
# session-persistence=false keeps the plain exec pty.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\session-agent.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), whose private
# XDG_CONFIG_HOME also holds the agent's state dir, so the agent this test
# spawns never meets the user's and is reaped by hl_stop.
#
# Output: one PASS/FAIL line per check, then 'SESSION AGENT: ALL PASS' or
# 'SESSION AGENT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="SESSION AGENT"

log=/tmp/session-agent-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"
[ -x "$PWD/zig-out/bin/ghoztty-agent" ]
hl_check "S2 the build installs ghoztty-agent beside ghoztty" $?

hl_start
hl_check "S3 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
state="$XDG_CONFIG_HOME/ghoztty/local-agent-debug"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
export SHELL=/bin/sh

# is_ancestor <ancestor> <pid>: 0 when <ancestor> is <pid> or above it.
is_ancestor() {
    local want=$1 p=$2
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do
        [ "$p" = "$want" ] && return 0
        p=$(awk '/^PPid:/ { print $2 }' "/proc/$p/status" 2>/dev/null)
    done
    return 1
}
advancing() { # advancing <file>: its content changes within 1.5 s
    local a b
    a=$(cat "$1" 2>/dev/null); sleep 1.5; b=$(cat "$1" 2>/dev/null)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]
}

# ---- 1. the first pane is agent-hosted and outlives a killed app ----------
beat1="$HL_RUNTIME/beat1"; pid1="$HL_RUNTIME/pid1"
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c \
    "echo \$\$ > $pid1; while :; do date +%s%N > $beat1; sleep 0.2; done"
hl_wait_for 30 test -s "$pid1"
hl_check "S4 the startup pane's command runs" $?
agent=$(hl_agent_pid)
[ -n "$agent" ]
hl_check "S5 the app spawned a ghoztty-agent under the harness config dir" $? "pid=${agent:-none} state=$state"
[ -S "$state/agent.sock" ] && [ "$(stat -c %a "$state/agent.sock" 2>/dev/null)" = 600 ]
hl_check "S6 the agent's socket is $state/agent.sock, mode 0600" $? "$(ls -l "$state" 2>/dev/null | tr '\n' ' ')"
shell1=$(cat "$pid1" 2>/dev/null)
[ -n "$agent" ] && [ -n "$shell1" ] && is_ancestor "$agent" "$shell1" && ! is_ancestor "$APP" "$shell1"
hl_check "S7 the pane's process descends from the agent, not the app" $? "shell=$shell1 agent=$agent app=$APP"
cli +sessions 2>&1 | grep -q 'alive'
hl_check "S8 +sessions reads the same agent and lists the live session" $? "$(cli +sessions 2>&1 | head -3 | tr '\n' ' ')"

kill -KILL "$APP" 2>/dev/null; wait "$APP" 2>/dev/null
advancing "$beat1"
hl_check "S9 the pane keeps running after the app is SIGKILLed" $?
kill -0 "$agent" 2>/dev/null
hl_check "S10 the agent is still up" $?

# ---- 2. a second app FINDS the running agent; a user close ends a session --
hl_launch APP2 "$app" --gtk-single-instance=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
hl_check "S11 a second app serves its socket" $?
again=$(hl_agent_pid)
[ "$again" = "$agent" ]
hl_check "S12 the second app dialed the SAME agent (no second spawn)" $? "first=$agent now=${again:-none}"
beat2="$HL_RUNTIME/beat2"; pid2="$HL_RUNTIME/pid2"
cli +new-window --target=closeme --command="echo \$\$ > $pid2; while :; do date +%s%N > $beat2; sleep 0.2; done" > /dev/null 2>&1
hl_wait_for 20 test -s "$pid2"
hl_check "S13 +new-window --command runs its command in an agent-hosted pane" $? \
    "shell=$(cat "$pid2" 2>/dev/null) agent=$agent"
shell2=$(cat "$pid2" 2>/dev/null)
[ -n "$shell2" ] && is_ancestor "$agent" "$shell2"
hl_check "S14 that pane descends from the agent" $?
cli +close --target=closeme > /dev/null 2>&1
hl_wait_for 10 sh -c "! kill -0 $shell2 2>/dev/null"
hl_check "S15 +close (a user close) ends the pane's process" $?
! advancing "$beat2"
hl_check "S16 the closed pane's output has stopped" $?
advancing "$beat1"
hl_check "S17 the orphaned first pane is untouched by the other close" $?

# ---- 3. session-persistence = false keeps the exec pty ------------------
kill -TERM "$APP2" 2>/dev/null; wait "$APP2" 2>/dev/null
hl_wait_for 10 sh -c "! test -S $sock"
pid3="$HL_RUNTIME/pid3"
hl_launch APP3 "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c \
    "echo \$\$ > $pid3; sleep 60"
hl_wait_for 30 test -s "$pid3"
shell3=$(cat "$pid3" 2>/dev/null)
[ -n "$shell3" ] && is_ancestor "$APP3" "$shell3" && ! is_ancestor "$agent" "$shell3"
hl_check "S18 session-persistence=false runs the pane under the app itself" $? "shell=$shell3 app=$APP3"

grep -E 'panic|reached unreachable' "$APP_LOG" "$APP2_LOG" "$APP3_LOG" > /dev/null 2>&1
[ $? != 0 ]
hl_check "S19 no app log carries a panic" $? "$(grep -h -m2 -E 'panic|unreachable' "$APP_LOG" "$APP2_LOG" "$APP3_LOG" 2>/dev/null | tr '\n' ' ')"

hl_finish "$L"
