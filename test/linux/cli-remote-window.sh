#!/usr/bin/env bash
# cli-remote-window.sh - L8d-3 (T3597) acceptance for +new-remote-window
# against the GTK debug app and a loopback ghoztty-agent listening on TCP
# (the Linux half of win32's test/win32/ipc-remote.ps1). A remote window's
# panes are hosted by THAT agent, not the app and not the local agent; +list
# names the window's machine and link state; a split of a remote pane and
# `+new-window --from-focused` on a remote window land on the same machine, and
# so does a new TAB in a remote window, in the pressed pane's cwd (T3668);
# --command is forwarded into the agent OPEN, for the window and for a split;
# +close ends the remote session; and the refusals are win32's / the Mac's
# sentences, made before any dial. Section Y (T3670) does it again over a REAL
# relay dial: a local rendezvous relay built from relay/ (DEV_AUTH, the recipe
# of test/win32/ipc-relay.ps1), a device enrolled on it, and a ghoztty-agent in
# --relay mode - so the window's panes ride the relayed agent, +list names the
# machine by --name or by device id, a split and a new tab stay on it, and
# +close ends its sessions. It needs `go` (scripts/linux/setup-distro.sh
# installs it). Run it ONLY through the wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-remote-window.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop.
#
# NEGATIVE=1 dials a port nothing listens on for the main window, which must
# FAIL R1. NEGATIVE=relay dials a device the relay never enrolled for the relay
# window, which must FAIL Y5.
#
# Output: one PASS/FAIL line per check, then 'CLI REMOTE WINDOW: ALL PASS' or
# 'CLI REMOTE WINDOW: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI REMOTE WINDOW"

log=/tmp/cli-remote-window-build.log
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
is_ancestor() { # is_ancestor <ancestor> <pid>: 0 when <ancestor> is <pid> or above it.
    local want=$1 p=$2
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do
        [ "$p" = "$want" ] && return 0
        p=$(awk '/^PPid:/ { print $2 }' "/proc/$p/status" 2>/dev/null)
    done
    return 1
}
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

# The "remote" machine: a TCP-listening agent on loopback. hl_launch tracks
# it, so hl_stop reaps it and every pane it hosts.
port=$(free_port)
dead_port=$(free_port)
hl_launch RAGENT "$agent_bin" --listen "127.0.0.1:$port" --headless
hl_wait_for 20 listening "$port"
hl_check "S3 a ghoztty-agent listens on 127.0.0.1:$port" $? "$(tail -5 "$RAGENT_LOG" 2>/dev/null | tr '\n' ' ')"

# The app: local panes are plain exec panes, so any agent-hosted pane in this
# run is the TCP agent's. No relay credential anywhere (E3).
export SHELL=/bin/sh
export GHOSTTY_ACCOUNT_STORE="$HL_RUNTIME/no-account.dat"
export GHOSTTY_ACCOUNT_KEYRING=off
unset GHOSTTY_RELAY_TOKEN
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    --keybind=ctrl+shift+t=new_tab -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
f4=$?
hl_check "S4 the app serves its socket" $f4
[ $f4 = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

# win <mode> <target> [arg]: one +list read about the window named <target>.
#   machine / state - its `machine` / `connection.state` ("-" when absent)
#   pid / name      - the shell pid of the leaf named [arg] / the first leaf
#   count           - how many windows carry `machine`
#   local           - the target of the first window with no `machine`
win() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
mode, want = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
d = json.load(sys.stdin)["data"]
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
if mode == "count":
    print(sum(1 for w in d["windows"] if w.get("machine"))); sys.exit(0)
if mode == "machines":
    for w in d["windows"]:
        if w.get("machine"): print(w["machine"])
    sys.exit(0)
if mode == "local":
    print(next((w.get("target") or "" for w in d["windows"] if not w.get("machine")), "")); sys.exit(0)
if mode == "remote-pids":
    for w in d["windows"]:
        if w.get("machine"):
            for t in w["tabs"]:
                for l in leaves(t["splits"]): print(l.get("pid") or "")
    sys.exit(0)
for w in d["windows"]:
    if (w.get("target") or "") != want: continue
    if mode == "ntabs": print(len(w["tabs"])); sys.exit(0)
    if mode == "id": print(next(leaves(w["tabs"][0]["splits"])).get("id") or ""); sys.exit(0)
    if mode == "lastpid":
        if len(w["tabs"]) > 1: print(next(leaves(w["tabs"][-1]["splits"])).get("pid") or "")
        sys.exit(0)
    if mode == "machine": print(w.get("machine") or "-")
    if mode == "state": print((w.get("connection") or {}).get("state") or "-")
    for t in w["tabs"]:
        for l in leaves(t["splits"]):
            if mode == "pid" and (arg == "" or l.get("name") == arg): print(l.get("pid") or ""); sys.exit(0)
' "$@" 2>/dev/null
}
has_window() { cli +list --json 2>/dev/null | grep -q "\"target\":\"$1\""; }
remote_count_is() { [ "$(win count x)" = "$1" ]; }
pane_pid() { local p; p=$(win pid "$1" "${2:-}"); [ -n "$p" ] && [ "$p" != 0 ] && printf '%s' "$p"; }
reads() { cli +read --name="$1" 2>/dev/null | grep -q -- "$2"; }

# --- refusals, all before any dial ---------------------------------------------
refused() { # refused <label> <expect-substring> <args...>
    local label=$1 want=$2; shift 2
    local out rc
    out=$(cli +new-remote-window "$@" 2>&1); rc=$?
    [ $rc != 0 ] && printf '%s' "$out" | grep -qF -- "$want" && remote_count_is 0
    hl_check "$label" $? "rc=$rc out=$out windows=$(win count x)"
}
refused "E1 no --host is refused" "--host is required (or use --relay + --device) for +new-remote-window" --port="$port"
refused "E2 no --port is refused" "--port is required (or use --relay + --device) for +new-remote-window" --host=127.0.0.1
refused "E3 a relay with no credential is refused as not signed in" \
    "not signed in: sign in from the machine chooser (ctrl+shift+n), pass --token=, or set GHOSTTY_RELAY_TOKEN to open relay windows" \
    --relay=https://relay.invalid --device=box
refused "E4 a port nothing listens on fails to reach the agent" \
    "failed to reach 127.0.0.1:$dead_port: the agent is not running or not reachable" \
    --host=127.0.0.1 --port="$dead_port" --name=remdead
cli +list --json > /dev/null 2>&1
hl_check "E5 the app still answers after a failed dial" $?

# --- open a remote window --------------------------------------------------------
main_port=$port
[ "${NEGATIVE:-0}" = 1 ] && { main_port=$dead_port; echo "  NEGATIVE CONTROL: the main window dials a dead port - this run MUST fail"; }
out=$(cli +new-remote-window --host=127.0.0.1 --port="$main_port" --name=rem 2>&1); rc=$?
[ $rc = 0 ] && has_window rem
hl_check "R1 +new-remote-window --host --port --name=rem opens window rem" $? "rc=$rc out=$out"
[ "$(win machine rem)" = 127.0.0.1 ] && [ "$(win state rem)" = connected ]
hl_check "R2 +list names rem's machine 127.0.0.1 and its link connected" $? "machine=$(win machine rem) state=$(win state rem)"
lw=$(win local x)
[ -n "$lw" ] && [ "$(win machine "$lw")" = - ] && [ "$(win state "$lw")" = - ]
hl_check "R3 the local launch window has neither field" $? "local=$lw machine=$(win machine "$lw") state=$(win state "$lw")"
hl_wait_for 15 pane_pid rem > /dev/null
rpid=$(pane_pid rem)
[ -n "$rpid" ] && is_ancestor "$RAGENT" "$rpid" && ! is_ancestor "$APP" "$rpid"
hl_check "R4 rem's shell is the TCP agent's child, not the app's" $? "pane=$rpid agent=$RAGENT app=$APP"
cli +send-keys --target=rem 'echo remote-marker-$((6*7))' Enter > /dev/null 2>&1
hl_wait_for 10 reads rem 'remote-marker-42'
hl_check "R5 keys reach the remote shell and +read sees its output" $? "$(cli +read --name=rem 2>&1 | tail -3 | tr '\n' ' ')"

out=$(cli +new-remote-window --host=127.0.0.1 --port="$port" --name=remcmd \
    --command='echo remote-cmd-$((7*6)); exec sleep 120' 2>&1); rc=$?
[ $rc = 0 ] && hl_wait_for 10 reads remcmd 'remote-cmd-42'
hl_check "R6 --command runs on the remote machine (forwarded in the OPEN)" $? "rc=$rc out=$out $(cli +read --name=remcmd 2>&1 | tail -3 | tr '\n' ' ')"
cpid=$(pane_pid remcmd)
[ -n "$cpid" ] && is_ancestor "$RAGENT" "$cpid"
hl_check "R7 remcmd's pane is the TCP agent's too" $? "pane=$cpid agent=$RAGENT"

# --- a split of a remote pane stays on that machine -------------------------------
out=$(cli +split --target=rem --name=rs 2>&1); rc=$?
hl_wait_for 15 pane_pid rem rs > /dev/null
spid=$(pane_pid rem rs)
[ $rc = 0 ] && [ -n "$spid" ] && is_ancestor "$RAGENT" "$spid" && ! is_ancestor "$APP" "$spid"
hl_check "P1 +split of rem opens on the TCP agent" $? "rc=$rc out=$out split=$spid agent=$RAGENT"
out=$(cli +split --target=rem --name=rs2 --command='echo split-cmd-$((5*9))' 2>&1); rc=$?
split_reads() { cli +read --name=rs2 2>/dev/null | grep -q 'split-cmd-45'; }
[ $rc = 0 ] && hl_wait_for 10 split_reads
hl_check "P2 a remote split's --command runs on the remote machine" $? "rc=$rc out=$out $(cli +read --name=rs2 2>&1 | tail -3 | tr '\n' ' ')"
[ "$(win machine rem)" = 127.0.0.1 ]
hl_check "P3 rem still names its machine after the splits" $? "machine=$(win machine rem)"

# --- a new tab in a remote window opens on that machine (T3668) -------------------
# The new tab inherits the pressed pane's machine and its REMOTE cwd (win32
# addTab's T68 inheritance, the Mac's); a new tab in a local window stays local.
press() { hl_ipc press-key "--target=$1" "--key=$2" 2>&1; }
ntabs_is() { [ "$(win ntabs "$1")" = "$2" ]; }
last_pid() { local p; p=$(win lastpid "$1"); [ -n "$p" ] && [ "$p" != 0 ] && printf '%s' "$p"; }
tabdir=$(mktemp -d /tmp/remtab.XXXXXX)
rid=$(win id rem)
cli +send-keys --target="$rid" "cd $tabdir" Enter > /dev/null 2>&1
in_tabdir() { [ "$(readlink "/proc/$rpid/cwd" 2>/dev/null)" = "$tabdir" ]; }
hl_wait_for 10 in_tabdir
hl_check "N1 rem's first pane is in $tabdir" $? "id=$rid cwd=$(readlink "/proc/$rpid/cwd" 2>/dev/null)"
out=$(press "$rid" ctrl+shift+t)
hl_wait_for 10 ntabs_is rem 2
hl_check "N2 ctrl+shift+t in rem opens a second tab" $? "out=$out tabs=$(win ntabs rem)"
hl_wait_for 15 last_pid rem > /dev/null
tpid=$(last_pid rem)
[ -n "$tpid" ] && is_ancestor "$RAGENT" "$tpid" && ! is_ancestor "$APP" "$tpid"
hl_check "N3 the new tab's shell is the TCP agent's child, not the app's" $? "tab=$tpid agent=$RAGENT app=$APP"
tab_in_dir() { [ "$(readlink "/proc/$tpid/cwd" 2>/dev/null)" = "$tabdir" ]; }
hl_wait_for 5 tab_in_dir
hl_check "N4 the new tab starts in the pressed pane's remote cwd" $? "cwd=$(readlink "/proc/$tpid/cwd" 2>/dev/null) want=$tabdir"
[ "$(win machine rem)" = 127.0.0.1 ] && remote_count_is 2
hl_check "N5 rem still names its machine; no new remote window appeared" $? "machine=$(win machine rem) remote=$(win count x)"
lid=$(win id "$lw")
press "$lid" ctrl+shift+t > /dev/null
hl_wait_for 10 ntabs_is "$lw" 2
hl_wait_for 15 last_pid "$lw" > /dev/null
lpid=$(last_pid "$lw")
[ -n "$lpid" ] && is_ancestor "$APP" "$lpid" && ! is_ancestor "$RAGENT" "$lpid"
hl_check "N6 a new tab in the local window stays local" $? "tabs=$(win ntabs "$lw") pid=$lpid app=$APP agent=$RAGENT"

# --- --from-focused on a remote window re-dials its machine ------------------------
# Leave rem the only window, so it is the front one whatever the compositor
# says about activation.
cli +close --target="$lw" > /dev/null 2>&1
cli +close --target=remcmd > /dev/null 2>&1
only_rem() { [ "$(cli +list --json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["windows"]))')" = 1 ] && has_window rem; }
hl_wait_for 10 only_rem
hl_check "F1 only rem is left open" $? "$(win count x) remote of $(cli +list --json 2>/dev/null | grep -o '"target":"[^"]*"' | tr '\n' ' ')"
before=$(win remote-pids x | sort)
out=$(cli +new-window --from-focused 2>&1); rc=$?
hl_wait_for 15 remote_count_is 2
hl_check "F2 +new-window --from-focused on rem opens a second remote window" $? "rc=$rc out=$out remote=$(win count x)"
newpid=$(comm -13 <(printf '%s\n' "$before") <(win remote-pids x | sort) | grep -v '^$' | head -1)
[ -n "$newpid" ] && is_ancestor "$RAGENT" "$newpid"
hl_check "F3 its pane is the TCP agent's" $? "new=$newpid agent=$RAGENT"

# --- +close ends the remote session --------------------------------------------------
out=$(cli +close --target=rem 2>&1); rc=$?
gone() { ! alive "$rpid" && ! alive "$spid" && ! alive "$tpid"; }
hl_wait_for 10 gone
g=$?
[ $rc = 0 ] && [ $g = 0 ] && ! has_window rem
hl_check "C1 +close --target=rem closes the window and its remote shells end, its new tab's too" $? "rc=$rc out=$out rem=$rpid alive=$(alive "$rpid" && echo y) split=$spid alive=$(alive "$spid" && echo y) tab=$tpid alive=$(alive "$tpid" && echo y)"
alive "$RAGENT"
hl_check "C2 the remote agent itself keeps running" $?
cli +list --json > /dev/null 2>&1
hl_check "C3 the app still answers" $?
grep -q 'no pane rides it any more' "$APP_LOG"
hl_check "C4 the last pane off rem's link closed the connection" $? "$(grep -m3 'gtk_remote' "$APP_LOG" | tr '\n' ' ')"

# --- Y: a REAL relay dial end to end (T3670) ----------------------------------------
# test/win32/ipc-relay.ps1's world, in Linux: the relay from relay/ with
# DEV_AUTH, one device enrolled with the dev bearer, and an agent in --relay
# mode holding that device's token. Each setup step aborts the run on failure,
# so one broken precondition reports as one failure (the T1105 rule).
DEV_TOKEN=devtok-e2e
relay_bin="$HL_RUNTIME/ghoztty-relay-e2e"
command -v go > /dev/null
rc=$?
hl_check "Y0 go is on PATH (scripts/linux/setup-distro.sh installs it)" $rc "PATH=$PATH"
[ $rc = 0 ] || hl_finish "$L"
( cd relay && go build -o "$relay_bin" . ) > /tmp/cli-remote-window-relay-build.log 2>&1
rc=$?
hl_check "Y1 the relay builds from relay/" $rc "$(tail -5 /tmp/cli-remote-window-relay-build.log | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"
rport=$(free_port)
base="http://127.0.0.1:$rport"
hl_launch RELAY env LISTEN_ADDR="127.0.0.1:$rport" METRICS_ADDR=127.0.0.1:0 DEV_AUTH=true \
    DEV_CLIENT_TOKEN="$DEV_TOKEN" DEV_EMAIL=dev@example.com STATE_DIR="$HL_RUNTIME/relay-state" "$relay_bin"
healthy() { curl -fsS -o /dev/null --max-time 2 "$base/healthz"; }
hl_wait_for 30 healthy
rc=$?
hl_check "Y2 the relay is healthy on $base" $rc "$(tail -5 "$RELAY_LOG" 2>/dev/null | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"
enroll=$(curl -fsS --max-time 10 -X POST -H "Authorization: Bearer $DEV_TOKEN" \
    -H 'Content-Type: application/json' -d '{"name":"e2e-device"}' "$base/v1/client/devices" 2>&1)
dev_id=$(printf '%s' "$enroll" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null)
dev_tok=$(printf '%s' "$enroll" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' 2>/dev/null)
[ -n "$dev_id" ] && [ -n "$dev_tok" ]
rc=$?
hl_check "Y3 a device is enrolled (id + token)" $rc "answer=$enroll"
[ $rc = 0 ] || hl_finish "$L"
# Its own lineage and heartbeat, so it never meets another agent's guard or state.
hl_launch RLAGENT env GHOSTTY_DEVICE_TOKEN="$dev_tok" GHOZTTY_AGENT_INSTANCE="hlrelay$$" \
    GHOSTTY_AGENT_HEARTBEAT="$HL_RUNTIME/relay-agent.heartbeat" "$agent_bin" --relay="$base" --headless
online() {
    curl -fsS --max-time 2 -H "Authorization: Bearer $DEV_TOKEN" "$base/v1/client/devices" 2>/dev/null |
        python3 -c '
import json, sys
d = json.load(sys.stdin)
ds = d.get("devices", d) if isinstance(d, dict) else d
sys.exit(0 if any(x.get("id") == sys.argv[1] and x.get("online") for x in ds) else 1)' "$dev_id"
}
hl_wait_for 30 online
rc=$?
hl_check "Y4 the --relay agent is up and the relay reports the device online" $rc "alive=$(alive "$RLAGENT" && echo y) $(tail -5 "$RLAGENT_LOG" 2>/dev/null | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

relay_dev=$dev_id
[ "${NEGATIVE:-0}" = relay ] && { relay_dev=never-enrolled; echo "  NEGATIVE CONTROL: the relay window dials a device nobody enrolled - this run MUST fail"; }
out=$(cli +new-remote-window --relay="$base" --device="$relay_dev" --token="$DEV_TOKEN" --name=relwin 2>&1); rc=$?
[ $rc = 0 ] && has_window relwin
hl_check "Y5 +new-remote-window --relay --device --token --name=relwin opens window relwin" $? "rc=$rc out=$out"
[ "$(win machine relwin)" = relwin ] && [ "$(win state relwin)" = connected ]
hl_check "Y6 +list names relwin's machine by --name and its link connected" $? "machine=$(win machine relwin) state=$(win state relwin)"
hl_wait_for 15 pane_pid relwin > /dev/null
ypid=$(pane_pid relwin)
[ -n "$ypid" ] && is_ancestor "$RLAGENT" "$ypid" && ! is_ancestor "$APP" "$ypid" && ! is_ancestor "$RAGENT" "$ypid"
hl_check "Y7 relwin's shell is the relayed agent's child - not the app's, not the TCP agent's" $? "pane=$ypid relay-agent=$RLAGENT app=$APP tcp-agent=$RAGENT"
cli +send-keys --target=relwin 'echo relay-marker-$((8*8))' Enter > /dev/null 2>&1
hl_wait_for 10 reads relwin 'relay-marker-64'
hl_check "Y8 keys reach the relayed shell and +read sees its output" $? "$(cli +read --name=relwin 2>&1 | tail -3 | tr '\n' ' ')"

out=$(cli +new-remote-window --relay="$base" --device="$dev_id" --token="$DEV_TOKEN" 2>&1); rc=$?
has_device_window() { win machines x | grep -qx "$dev_id"; }
[ $rc = 0 ] && hl_wait_for 10 has_device_window
hl_check "Y9 a relay window opened with no --name is named by its device id" $? "rc=$rc out=$out machines=$(win machines x | tr '\n' ' ')"

out=$(cli +split --target=relwin --name=ys 2>&1); rc=$?
hl_wait_for 15 pane_pid relwin ys > /dev/null
yspid=$(pane_pid relwin ys)
[ $rc = 0 ] && [ -n "$yspid" ] && is_ancestor "$RLAGENT" "$yspid" && ! is_ancestor "$APP" "$yspid"
hl_check "Y10 +split of relwin opens on the relayed agent" $? "rc=$rc out=$out split=$yspid relay-agent=$RLAGENT"
yid=$(win id relwin)
out=$(press "$yid" ctrl+shift+t)
hl_wait_for 10 ntabs_is relwin 2
hl_wait_for 15 last_pid relwin > /dev/null
ytpid=$(last_pid relwin)
[ "$(win ntabs relwin)" = 2 ] && [ -n "$ytpid" ] && is_ancestor "$RLAGENT" "$ytpid" && ! is_ancestor "$APP" "$ytpid"
hl_check "Y11 a new tab in relwin opens on the relayed agent" $? "out=$out tabs=$(win ntabs relwin) tab=$ytpid relay-agent=$RLAGENT"
[ "$(win machine relwin)" = relwin ]
hl_check "Y12 relwin still names its machine after the split and the tab" $? "machine=$(win machine relwin)"

out=$(cli +close --target=relwin 2>&1); rc=$?
ygone() { ! alive "$ypid" && ! alive "$yspid" && ! alive "$ytpid"; }
hl_wait_for 10 ygone
g=$?
[ $rc = 0 ] && [ $g = 0 ] && ! has_window relwin
hl_check "Y13 +close --target=relwin ends its relayed sessions (pane, split and tab)" $? "rc=$rc out=$out pane=$ypid alive=$(alive "$ypid" && echo y) split=$yspid alive=$(alive "$yspid" && echo y) tab=$ytpid alive=$(alive "$ytpid" && echo y)"
alive "$RLAGENT" && alive "$RELAY"
hl_check "Y14 the relayed agent and the relay keep running" $? "agent=$(alive "$RLAGENT" && echo y) relay=$(alive "$RELAY" && echo y)"
cli +list --json > /dev/null 2>&1
hl_check "Y15 the app still answers" $?

hl_finish "$L"
