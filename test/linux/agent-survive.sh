#!/usr/bin/env bash
# agent-survive.sh - T3332 (Linux L3) acceptance: a ghoztty-agent started by
# hand on Linux serves a pane, and the pane keeps running after the client that
# opened it has gone away (the "GUI closing" half of session persistence; the
# Linux GUI attaching to the agent is L8, T3337).
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\agent-survive.sh
#
# It tests the committed HEAD in ~/ghoztty-l (-Repo clone, the default).
#
# What it does, all inside the distro, nothing on the user's desktop:
#   1. builds ghoztty-agent and remote-test-client (-Dapp-runtime=none)
#   2. starts the agent on an ephemeral loopback port with a private HOME and
#      XDG_RUNTIME_DIR, so it cannot meet any other agent's lock or socket
#   3. opens a session whose command writes a heartbeat file every 200 ms, holds
#      it 1 s, and exits the client (a detach - only CLOSE ends a session)
#   4. checks the heartbeat is still advancing 2 s after the client is gone
#      (the pane survived) and that the agent is still up
#   5. CLOSEs the session by id from a fresh client and checks the heartbeat
#      stops (the pane was the agent's, and CLOSE really ends it)
#
# Output: one 'CHECK <name> PASS|FAIL' line per check, then
# 'AGENT SURVIVE: ALL PASS' or 'AGENT SURVIVE: <n> FAILURE(S)'. Exit 0 only on
# ALL PASS.
set -u
fails=0
check() { # check <name> <cond-exit-code> [detail]
    if [ "$2" = 0 ]; then echo "CHECK $1 PASS${3:+ - $3}"; else echo "CHECK $1 FAIL${3:+ - $3}"; fails=$((fails+1)); fi
}
finish() {
    [ -n "${agent_pid:-}" ] && kill "$agent_pid" 2>/dev/null
    [ -n "${agent_pid:-}" ] && wait "$agent_pid" 2>/dev/null
    if [ $fails = 0 ]; then echo "AGENT SURVIVE: ALL PASS"; exit 0; fi
    echo "AGENT SURVIVE: $fails FAILURE(S)"; exit 1
}

work=$(mktemp -d /tmp/agent-survive.XXXXXX)
echo "AGENT SURVIVE at $(git rev-parse --short HEAD 2>/dev/null || echo '?') work=$work"

zig build agent remote-test-client -Dapp-runtime=none > "$work/build.log" 2>&1
rc=$?
check build $rc "zig build agent remote-test-client"
if [ $rc != 0 ]; then grep -m10 -E '(^|: )error: ' "$work/build.log" | sed 's/^/    /'; finish; fi
agent=$PWD/zig-out/bin/ghoztty-agent
client=$PWD/zig-out/bin/remote-test-client

mkdir -p "$work/home" "$work/run" && chmod 700 "$work/run"
HOME=$work/home XDG_RUNTIME_DIR=$work/run \
    "$agent" --listen=127.0.0.1:0 --port-file="$work/port.json" > "$work/agent.log" 2>&1 &
agent_pid=$!
port=
for _ in $(seq 1 100); do
    [ -s "$work/port.json" ] && port=$(sed -n 's/.*"port":\([0-9]*\).*/\1/p' "$work/port.json") && [ -n "$port" ] && break
    kill -0 "$agent_pid" 2>/dev/null || break
    sleep 0.1
done
[ -n "$port" ]; check agent-listening $? "pid=$agent_pid port=${port:-none}"
if [ -z "$port" ]; then tail -5 "$work/agent.log" | sed 's/^/    /'; finish; fi

beat=$work/beat
cmd="sh -c 'while :; do date +%s%N > $beat; sleep 0.2; done'"
sid=$("$client" 127.0.0.1 "$port" --open-command="$cmd" --hold=1 2> "$work/open.log" | head -1)
[ -n "$sid" ]; check session-opened $? "id=${sid:-none}"
if [ -z "$sid" ]; then sed 's/^/    /' "$work/open.log"; finish; fi
grep -q 'detaching (session survives)' "$work/open.log"; check client-detached $?

first=$(cat "$beat" 2>/dev/null)
sleep 2
second=$(cat "$beat" 2>/dev/null)
[ -n "$first" ] && [ -n "$second" ] && [ "$second" -gt "$first" ]
check pane-survives-client $? "heartbeat $first -> $second, 2 s after the client exited"
kill -0 "$agent_pid" 2>/dev/null; check agent-still-up $?

"$client" 127.0.0.1 "$port" --close-session="$sid" > /dev/null 2> "$work/close.log"
check close-session $? "$(tail -1 "$work/close.log")"
sleep 1
third=$(cat "$beat" 2>/dev/null)
sleep 1
fourth=$(cat "$beat" 2>/dev/null)
[ "$third" = "$fourth" ]; check pane-ends-on-close $? "heartbeat $third -> $fourth after CLOSE"

finish
