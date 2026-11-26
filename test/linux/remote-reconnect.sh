#!/usr/bin/env bash
# remote-reconnect.sh - L11a-3 (T3675) acceptance for the GTK remote connection
# pill and the reconnect ladder, against the GTK debug app and a loopback
# ghoztty-agent listening on TCP. win32's halves: test/win32/remote-pill.ps1 and
# remote-reconnect-fresh.ps1; Mac reference: docs/reference/remote-machines.md.
#
# The app dials the agent THROUGH a small TCP relay this script owns
# (python3, 127.0.0.1:<relay> -> 127.0.0.1:<agent>). Killing the relay cuts the
# link while the agent and its shells live on - the network drop the ladder
# exists for - and starting it again on the same port is the machine coming
# back. The oracle for "the same shell came back" is the remote shell's pid.
#
#   P1  a remote window's pill names the machine (green dot, not a button
#       action); a local window has no pill
#   P2  the relay dies: the pill turns amber and counts attempts, +list says
#       reconnecting
#   P3  the relay is back: the panes re-ATTACH their sessions in place - same
#       shell pids, still drivable - and the pill reads the name again
#   P4  the relay stays down past the fast ladder (~30 s): the pill is the red
#       Reconnect button, +list says disconnected and self_healable; a click
#       dials at once (a manual attempt, no backoff) and the same shells return
#   P5  the agent is restarted underneath (its sessions are gone): the
#       automatic ladder goes terminal (self_healable false); a click brings the
#       same two-pane layout back with fresh shells, names kept
#
# The pill is read and clicked through the DEBUG-ONLY `remote-pill` seam
# (`src/apprt/gtk/ipc_remote_pill.zig`): Wayland gives the headless harness no
# pointer. A click emits the button's own `clicked`.
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\remote-reconnect.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston, so no window reaches WSLg or the user's desktop.
#
# NEGATIVE=1 never restarts the relay in P3, so the panes cannot come back and
# P3 must FAIL.
#
# Output: one PASS/FAIL line per check, then 'REMOTE RECONNECT: ALL PASS' or
# 'REMOTE RECONNECT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="REMOTE RECONNECT"

log=/tmp/remote-reconnect-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "S2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
agent_bin="$(dirname "$app")/ghoztty-agent"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
free_port() { python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])'; }
listening() { python3 -c 'import socket,sys; s=socket.create_connection(("127.0.0.1",int(sys.argv[1])),1)' "$1" 2>/dev/null; }
not_listening() { ! listening "$1"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

aport=$(free_port)
rport=$(free_port)
hl_launch RAGENT "$agent_bin" --listen "127.0.0.1:$aport" --headless
hl_wait_for 20 listening "$aport"
hl_check "S3 a ghoztty-agent listens on 127.0.0.1:$aport" $? "$(tail -5 "$RAGENT_LOG" 2>/dev/null | tr '\n' ' ')"

# The relay: every accepted connection is piped both ways to the agent. A
# SIGKILL closes every socket it holds, which the app reads as the link dying.
relay_py="$HL_RUNTIME/relay.py"
cat > "$relay_py" <<'PY'
import socket, sys, threading
lport, aport = int(sys.argv[1]), int(sys.argv[2])
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", lport))
srv.listen(16)
def pipe(a, b):
    try:
        while True:
            d = a.recv(65536)
            if not d: break
            b.sendall(d)
    except OSError:
        pass
    for s in (a, b):
        try: s.shutdown(socket.SHUT_RDWR)
        except OSError: pass
while True:
    c, _ = srv.accept()
    try:
        u = socket.create_connection(("127.0.0.1", aport))
    except OSError:
        c.close(); continue
    for x, y in ((c, u), (u, c)):
        threading.Thread(target=pipe, args=(x, y), daemon=True).start()
PY
RELAY=""
relay_up() {
    hl_launch RELAY python3 -I "$relay_py" "$rport" "$aport"
    hl_wait_for 10 listening "$rport"
}
relay_down() {
    [ -n "$RELAY" ] && kill -9 "$RELAY" 2>/dev/null
    RELAY=""
    hl_wait_for 10 not_listening "$rport"
}
relay_up
hl_check "S4 the TCP relay listens on 127.0.0.1:$rport" $?

# Local panes are plain exec panes (no session persistence), so every
# agent-hosted pane in this run is the TCP agent's.
export SHELL=/bin/sh
export GHOSTTY_ACCOUNT_STORE="$HL_RUNTIME/no-account.dat"
export GHOSTTY_ACCOUNT_KEYRING=off
unset GHOSTTY_RELAY_TOKEN
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
s5=$?
hl_check "S5 the app serves its socket" $s5
[ $s5 = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

# pane_pid <window> [pane name]: a leaf's shell pid from +list.
pane_pid() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
want, arg = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "")
d = json.load(sys.stdin)["data"]
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if (w.get("target") or "") != want: continue
    for t in w["tabs"]:
        for l in leaves(t["splits"]):
            if arg == "" or l.get("name") == arg:
                p = l.get("pid") or 0
                if p: print(p); sys.exit(0)
sys.exit(1)
' "$@" 2>/dev/null
}
# leaf_count <window>: how many panes the window holds.
leaf_count() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def n(x): return n(x["left"]) + n(x["right"]) if x["type"] == "split" else 1
for w in d["windows"]:
    if (w.get("target") or "") == sys.argv[1]: print(sum(n(t["splits"]) for t in w["tabs"]))
' "$1" 2>/dev/null
}
# conn <window> <key>: one field of the window's +list connection object.
conn() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
for w in d["windows"]:
    if (w.get("target") or "") != sys.argv[1]: continue
    v = (w.get("connection") or {}).get(sys.argv[2])
    print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))
' "$1" "$2" 2>/dev/null
}
pill() { hl_ipc remote-pill "--target=$1" "${2:---op=state}" 2>&1; }
field() { printf '%s' "$1" | python3 -c '
import json, sys
v = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))' "$2" 2>/dev/null; }
pill_is() { # pill_is <window> <field> <value>
    [ "$(field "$(pill "$1")" "$2")" = "$3" ]
}
pill_status_has() { field "$(pill "$1")" status | grep -q -- "$2"; }
reads() { cli +read --name="$1" 2>/dev/null | grep -q -- "$2"; }

# --- P1: a remote window names its machine; a local one has no pill ----------
cli +new-remote-window --host=127.0.0.1 --port="$rport" --name=rr > /dev/null 2>&1
hl_wait_for 15 pane_pid rr > /dev/null
p_a=$(pane_pid rr)
cli +split --target=rr --name=rr-b > /dev/null 2>&1
hl_wait_for 15 pane_pid rr rr-b > /dev/null
p_b=$(pane_pid rr rr-b)
[ -n "$p_a" ] && [ -n "$p_b" ] && alive "$p_a" && alive "$p_b"
hl_check "P1a a remote window rr with two panes opens through the relay" $? "a=$p_a b=$p_b"

out=$(pill rr)
[ "$(field "$out" visible)" = true ] && [ "$(field "$out" name)" = 127.0.0.1 ] &&
    [ "$(field "$out" status)" = "" ] && [ "$(field "$out" mark)" = dot ] &&
    [ "$(field "$out" dot_class)" = success ] && [ "$(field "$out" action)" = false ] &&
    [ "$(field "$out" tooltip)" = "Connected to 127.0.0.1" ] &&
    [ "$(field "$out" connection.state)" = connected ]
hl_check "P1b rr's pill names 127.0.0.1 with a green dot and says Connected" $? "out=$out"

cli +new-window --name=loc > /dev/null 2>&1
hl_wait_for 15 pane_pid loc > /dev/null
out=$(pill loc)
[ "$(field "$out" visible)" = false ] && [ "$(conn loc state)" = "" ]
hl_check "P1c a local window has no pill and no +list connection" $? "out=$out"

# --- P2: the link drops ------------------------------------------------------
relay_down
reconnecting() { pill_status_has rr "Reconnecting" && pill_is rr dot_class warning; }
hl_wait_for 15 reconnecting
r2=$?
out=$(pill rr)
st=$(conn rr state)
[ $r2 = 0 ] && [ "$st" = reconnecting ] && [ -n "$(conn rr attempt)" ] && alive "$p_a"
hl_check "P2 the relay dies: the pill is amber, counts 'Reconnecting... n/5', +list says reconnecting" $? "out=$out list=$st"

# --- P3: the link comes back; the same shells re-attach in place -------------
[ "${NEGATIVE:-}" = 1 ] || relay_up
back() { pill_is rr status "" && pill_is rr dot_class success && [ "$(conn rr state)" = connected ]; }
hl_wait_for 30 back
r3=$?
pa3=$(pane_pid rr)
pb3=$(pane_pid rr rr-b)
[ $r3 = 0 ] && [ "$pa3" = "$p_a" ] && [ "$pb3" = "$p_b" ] && [ "$(leaf_count rr)" = 2 ]
hl_check "P3a the relay is back: rr reconnects and both panes keep their shells (pids $p_a, $p_b)" $? \
    "r=$r3 a=$pa3 b=$pb3 leaves=$(leaf_count rr) pill=$(pill rr)"
grep -q "remote reconnect: 127.0.0.1 is back on a fresh transport (2 pane(s) re-attached, 0 opened fresh)" "$APP_LOG"
hl_check "P3b the app logs a re-attach of both panes" $? "$(grep 'remote reconnect' "$APP_LOG" | tail -4 | tr '\n' ' ')"
cli +send-keys --target=rr-b 'echo back-$((6*7))' Enter > /dev/null 2>&1
hl_wait_for 10 reads rr-b back-42
hl_check "P3c the re-attached pane rr-b is drivable" $? "$(cli +read --name=rr-b 2>&1 | tail -3 | tr '\n' ' ')"
[ "${NEGATIVE:-}" = 1 ] && hl_finish "$L"

# --- P4: down past the fast ladder; a click reconnects at once ---------------
relay_down
exhausted() { pill_is rr action true && [ "$(conn rr state)" = disconnected ]; }
hl_wait_for 75 exhausted
r4=$?
out=$(pill rr)
[ $r4 = 0 ] && [ "$(field "$out" status)" = " — Reconnect" ] && [ "$(field "$out" mark)" = refresh ] &&
    [ "$(conn rr self_healable)" = true ] &&
    [ "$(field "$out" tooltip)" = "Connection to 127.0.0.1 lost — click to reconnect" ]
hl_check "P4a past the fast ladder the pill is the red 'Reconnect' button; +list says self_healable" $? "out=$out"

relay_up
mark=$(wc -l < "$APP_LOG")
out=$(pill rr --op=click)
hl_wait_for 10 back
r4b=$?
[ $r4b = 0 ] && [ "$(field "$out" last_click)" = reconnect ] &&
    tail -n +"$mark" "$APP_LOG" | grep -q "attempt 1/5 in 0ms (manual)" &&
    [ "$(pane_pid rr)" = "$p_a" ] && [ "$(pane_pid rr rr-b)" = "$p_b" ]
hl_check "P4b a click dials at once (no backoff) and the same shells come back" $? \
    "r=$r4b out=$out a=$(pane_pid rr) $(tail -n +"$mark" "$APP_LOG" | grep 'remote reconnect' | tr '\n' ' ')"

# --- P5: the agent restarts (sessions gone); terminal, then a fresh layout ---
kill -9 "$RAGENT" 2>/dev/null
hl_wait_for 10 not_listening "$aport"
hl_launch RAGENT "$agent_bin" --listen "127.0.0.1:$aport" --headless
hl_wait_for 20 listening "$aport"
terminal() { pill_is rr action true && [ "$(conn rr self_healable)" = false ]; }
hl_wait_for 30 terminal
r5=$?
[ $r5 = 0 ] && grep -q "is terminal after attempt .* (session_gone)" "$APP_LOG"
hl_check "P5a the agent restarted without its sessions: the automatic ladder goes terminal" $? \
    "out=$(pill rr) $(grep 'remote reconnect' "$APP_LOG" | tail -3 | tr '\n' ' ')"

out=$(pill rr --op=click)
fresh() {
    local a b
    a=$(pane_pid rr) && b=$(pane_pid rr rr-b) || return 1
    [ "$a" != "$p_a" ] && [ "$b" != "$p_b" ] && alive "$a" && alive "$b" && back
}
hl_wait_for 20 fresh
r5b=$?
[ $r5b = 0 ] && [ "$(leaf_count rr)" = 2 ] &&
    grep -q "is back on a fresh transport (0 pane(s) re-attached, 2 opened fresh)" "$APP_LOG"
hl_check "P5b a click brings rr's two panes back with fresh shells, names kept" $? \
    "r=$r5b a=$(pane_pid rr) b=$(pane_pid rr rr-b) leaves=$(leaf_count rr) $(grep 'remote reconnect' "$APP_LOG" | tail -2 | tr '\n' ' ')"
cli +send-keys --target=rr-b 'echo fresh-$((6*7))' Enter > /dev/null 2>&1
hl_wait_for 10 reads rr-b fresh-42
hl_check "P5c the fresh pane rr-b is drivable" $? "$(cli +read --name=rr-b 2>&1 | tail -3 | tr '\n' ' ')"

hl_finish "$L"
