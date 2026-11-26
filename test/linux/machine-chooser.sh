#!/usr/bin/env bash
# machine-chooser.sh - T3674 (Linux L11a-2) acceptance for the GTK machine
# chooser, against a REAL relay: the local rendezvous relay built from relay/
# (DEV_AUTH, the recipe of cli-remote-window.sh section Y), one device enrolled
# on it, and a ghoztty-agent in --relay mode holding that device's token. The
# app has session persistence on, so Local's roster is the local agent's.
#
# What it proves, all through the DEBUG-ONLY `machine-chooser` seam (Wayland
# gives the harness no pointer; every op clicks the chooser's own buttons):
#   K   Ctrl+Shift+N is the chord (the window's own key classifier); Ctrl+N
#       and Ctrl+Alt+Shift+N are not.
#   M   the list: Local first, then the relay's device, online, with the
#       detail, tooltips and Host Settings... where Mac has them; Local's
#       roster lists the app's own pane as Show.
#   N   New Window on the device opens a window whose pane descends from the
#       --relay agent.
#   R   that window Disconnected (T3563), the chooser lists its session as
#       Resume, and Resume opens a window ATTACHED to the SAME far shell.
#   S   the session is then Show, and Show focuses it - no second attach.
#   E   End on a detached session ends its far shell and drops the row.
#   L   a local session left behind by a killed app is Resume, and Resume
#       re-attaches that same local shell.
#
# Run it ONLY through the wrapper (it builds the committed HEAD in the clone):
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\machine-chooser.sh
#
# Everything runs inside the private headless Weston (test/linux/lib/headless.sh).
# NEGATIVE=1 presses New Window where the test means Resume, which must FAIL R4.
# Output: one PASS/FAIL line per check, then 'MACHINE CHOOSER: ALL PASS' or
# 'MACHINE CHOOSER: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="MACHINE CHOOSER"

log=/tmp/machine-chooser-build.log
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
is_ancestor() { # is_ancestor <ancestor> <pid>: 0 when <ancestor> is <pid> or above it.
    local want=$1 p=$2
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do
        [ "$p" = "$want" ] && return 0
        p=$(awk '/^PPid:/ { print $2 }' "/proc/$p/status" 2>/dev/null)
    done
    return 1
}
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
dead() { ! alive "$1"; }

# --- the relay world (each setup step aborts the run on failure: T1105) ---------
DEV_TOKEN=devtok-chooser
relay_bin="$HL_RUNTIME/ghoztty-relay-chooser"
command -v go > /dev/null
rc=$?
hl_check "S3 go is on PATH (scripts/linux/setup-distro.sh installs it)" $rc "PATH=$PATH"
[ $rc = 0 ] || hl_finish "$L"
( cd relay && go build -o "$relay_bin" . ) > /tmp/machine-chooser-relay-build.log 2>&1
rc=$?
hl_check "S4 the relay builds from relay/" $rc "$(tail -5 /tmp/machine-chooser-relay-build.log | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"
rport=$(free_port)
base="http://127.0.0.1:$rport"
hl_launch RELAY env LISTEN_ADDR="127.0.0.1:$rport" METRICS_ADDR=127.0.0.1:0 DEV_AUTH=true \
    DEV_CLIENT_TOKEN="$DEV_TOKEN" DEV_EMAIL=dev@example.com STATE_DIR="$HL_RUNTIME/relay-state" "$relay_bin"
healthy() { curl -fsS -o /dev/null --max-time 2 "$base/healthz" 2>/dev/null; }
hl_wait_for 30 healthy
rc=$?
hl_check "S5 the relay is healthy on $base" $rc "$(tail -5 "$RELAY_LOG" 2>/dev/null | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"
enroll=$(curl -fsS --max-time 10 -X POST -H "Authorization: Bearer $DEV_TOKEN" \
    -H 'Content-Type: application/json' -d '{"name":"chooser-box"}' "$base/v1/client/devices" 2>&1)
dev_id=$(printf '%s' "$enroll" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null)
dev_tok=$(printf '%s' "$enroll" | python3 -c 'import json,sys; print(json.load(sys.stdin)["token"])' 2>/dev/null)
[ -n "$dev_id" ] && [ -n "$dev_tok" ]
rc=$?
hl_check "S6 a device is enrolled (id + token)" $rc "answer=$enroll"
[ $rc = 0 ] || hl_finish "$L"
hl_launch RLAGENT env GHOSTTY_DEVICE_TOKEN="$dev_tok" GHOZTTY_AGENT_INSTANCE="hlchooser$$" \
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
hl_check "S7 the --relay agent is up and the relay reports the device online" $rc "$(tail -5 "$RLAGENT_LOG" 2>/dev/null | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

# --- the app: signed in by the environment, every store private -------------------
export SHELL=/bin/sh
export GHOSTTY_ACCOUNT_STORE="$HL_RUNTIME/no-account.dat"
export GHOSTTY_ACCOUNT_KEYRING=off
export GHOSTTY_RELAY_TOKEN="$DEV_TOKEN"
export GHOSTTY_RELAY_BASE="$base"
export GHOSTTY_HOST_DEFAULTS="$HL_RUNTIME/host-defaults.json"
export XDG_CACHE_HOME="$HL_RUNTIME/cache"
lpid="$HL_RUNTIME/local-pid"
printf '#!/bin/sh\necho $$ > %s\nPS1="hl$ " exec /bin/sh -i\n' "$lpid" > "$HL_RUNTIME/local.sh"
chmod +x "$HL_RUNTIME/local.sh"
hl_launch APP "$app" --gtk-single-instance=false -e "$HL_RUNTIME/local.sh"
hl_wait_for 30 test -S "$sock"
f=$?
hl_check "S8 the app serves its socket" $f
[ $f = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }
hl_wait_for 20 test -s "$lpid"
local1=$(cat "$lpid" 2>/dev/null)

# mc [op args]: the seam's reply. q <json> <python expr over d>: one value.
mc() { hl_ipc machine-chooser "$@" 2>&1; }
q() { printf '%s' "$1" | python3 -c '
import json, sys
try: d = json.load(sys.stdin).get("data", {})
except Exception: d = {}
try: v = eval(sys.argv[1])
except Exception: v = ""
print("" if v is None else (str(v).lower() if isinstance(v, bool) else v))' "$2" 2>/dev/null; }
# remote_windows: one line per window with a machine: "<target> <first pid>".
remote_windows() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
for w in json.load(sys.stdin)["data"]["windows"]:
    if w.get("machine"):
        pids = [str(l.get("pid") or "") for t in w["tabs"] for l in leaves(t["splits"])]
        print(w.get("target") or "", pids[0] if pids else "")' 2>/dev/null
}
nremote_is() { [ "$(remote_windows | grep -c .)" = "$1" ]; }
# remote_pid_shown: every remote window's first pane reports its shell pid.
remote_pid_shown() { [ -n "$(remote_windows | head -1)" ] && ! remote_windows | awk '{ if ($2 == "") bad = 1 } END { exit !bad }'; }
roster_loaded() { [ "$(q "$(mc)" 'd.get("roster_state")')" = loaded ]; }
device_online() { [ "$(q "$(mc)" '[m["presence"] for m in d["machines"] if m["id"]=="'"$dev_id"'"][0]')" = online ]; }
# sessions_n <n>: the selected machine's roster shows <n> sessions.
sessions_n() { local s; s=$(mc); [ "$(q "$s" 'd.get("roster_state")')" = loaded ] && [ "$(q "$s" 'len(d["sessions"])')" = "$1" ]; }
pid_listed() { [ "$(q "$(mc)" '[x["pid"] for x in d["sessions"] if x["pid"]=='"$1"'][0]')" = "$1" ]; }
# A LOCAL session's pid is the top of its process tree (the agent's wrapper),
# so a local shell is matched by ancestry. local_sid <json> <shell pid>: the
# id of the roster row whose session holds that shell.
local_sid() {
    local id pid
    while read -r id pid; do
        [ -n "$pid" ] && is_ancestor "$pid" "$2" && { printf '%s' "$id"; return 0; }
    done <<EOF
$(q "$1" '"\n".join(x["id"] + " " + str(x["pid"]) for x in d["sessions"])')
EOF
    return 1
}
local_listed() { local_sid "$(mc)" "$1" > /dev/null; }
# sfield <json> <session id> <field>: one field of that roster row.
sfield() { q "$1" '[x["'"$3"'"] for x in d["sessions"] if x["id"]=="'"$2"'"][0]'; }

# --- K: the chord ---------------------------------------------------------------
out=$(mc --op=chord --key=ctrl+n)
[ "$(q "$out" 'd["did"]')" = false ] && [ "$(q "$out" 'd["open"]')" = false ]
hl_check "K1 Ctrl+N is not the chooser chord" $? "out=$out"
out=$(mc --op=chord --key=ctrl+alt+shift+n)
[ "$(q "$out" 'd["did"]')" = false ] && [ "$(q "$out" 'd["open"]')" = false ]
hl_check "K2 an extra Alt is not the chord either" $? "out=$out"
out=$(mc --op=chord --key=ctrl+shift+n)
[ "$(q "$out" 'd["did"]')" = true ] && [ "$(q "$out" 'd["open"]')" = true ]
hl_check "K3 Ctrl+Shift+N opens the chooser" $? "out=$out"

# --- M: the list and the detail ------------------------------------------------------
out=$(mc)
[ "$(q "$out" 'd["machines"][0]["id"]')" = local ] && [ "$(q "$out" 'd["machines"][0]["title"]')" = Local ] &&
    [ "$(q "$out" 'd["selected"]')" = local ] && [ "$(q "$out" 'd["detail_title"]')" = "This Computer" ] &&
    [ "$(q "$out" 'd["new_window_tooltip"]')" = "Open a new window on This Computer" ] &&
    [ "$(q "$out" 'd["host_settings"]')" = false ]
hl_check "M1 Local is first and selected: This Computer, its New Window tooltip, no Host Settings" $? "out=$out"
[ "$(q "$out" 'd["account"]')" != "Not signed in" ] && [ -n "$(q "$out" 'd["account"]')" ]
hl_check "M2 the account line reads signed in" $? "account=$(q "$out" 'd["account"]')"
hl_wait_for 15 device_online
out=$(mc)
[ "$(q "$out" '[m["title"] for m in d["machines"] if m["id"]=="'"$dev_id"'"][0]')" = chooser-box ]
hl_check "M3 the relay's device is listed by name and online" $? "out=$out"
hl_wait_for 15 roster_loaded
hl_wait_for 10 local_listed "$local1"
out=$(mc)
lsid0=$(local_sid "$out" "$local1")
[ -n "$lsid0" ] && [ "$(sfield "$out" "$lsid0" action)" = Show ] &&
    [ "$(sfield "$out" "$lsid0" action_tooltip)" = "Bring this session's window to the front" ] &&
    [ "$(sfield "$out" "$lsid0" end_tooltip)" = "End this session (terminates its process)" ]
hl_check "M4 Local's roster lists the app's own pane as Show, with Mac's tooltips" $? "local=$local1 sid=$lsid0 out=$out"

out=$(mc --op=select --value="$dev_id")
hl_wait_for 15 roster_loaded
out=$(mc)
[ "$(q "$out" 'd["selected"]')" = "$dev_id" ] && [ "$(q "$out" 'd["detail_title"]')" = chooser-box ] &&
    q "$out" 'd["detail_subtitle"]' | grep -q Online &&
    [ "$(q "$out" 'd["host_settings"]')" = true ] &&
    [ "$(q "$out" 'd["new_window_tooltip"]')" = "Open a new window on chooser-box" ] &&
    [ "$(q "$out" 'd["placeholder"]')" = "No active sessions" ]
hl_check "M5 selecting the device: its name, Online, Host Settings..., and No active sessions" $? "out=$out"

# --- N: New Window on the device ----------------------------------------------------
out=$(mc --op=new-window)
hl_wait_for 20 nremote_is 1
hl_wait_for 15 remote_pid_shown
read -r rwin rp1 <<EOF
$(remote_windows | head -1)
EOF
[ "$(q "$out" 'd["open"]')" = false ] && q "$out" 'd["last"]' | grep -q "^new-window $dev_id" &&
    [ -n "$rp1" ] && is_ancestor "$RLAGENT" "$rp1"
hl_check "N1 New Window closes the chooser and opens a window on the relayed agent" $? "out=$out win=$rwin pid=$rp1"

# --- O: the other two ways in: the window menu and Settings ---------------------------
pane1=$(hl_first_pane "$app")
o=$(hl_ipc main-menu --target="$pane1" '--activate=New Remote Window…' 2>&1)
sleep 0.5
[ "$(q "$o" 'd["activated"]')" = true ] && [ "$(q "$(mc)" 'd["open"]')" = true ]
hl_check "O1 the window menu's New Remote Window… opens the chooser" $? "reply=$(printf '%s' "$o" | head -c 300)"
mc --op=close > /dev/null
hl_ipc settings --op=action > /dev/null 2>&1
hl_ipc settings --op=state --page=remote > /dev/null 2>&1
o=$(hl_ipc settings --op=new_remote_window 2>&1)
sleep 0.5
[ "$(q "$(mc)" 'd["open"]')" = true ]
hl_check "O2 Settings > Remote Machines' New Remote Window… opens the chooser" $? "reply=$(printf '%s' "$o" | head -c 300)"
mc --op=close > /dev/null

# --- R: Disconnect it, then Resume it from the chooser -------------------------------
dialog() { local t=$1; shift; hl_ipc close-dialog "--target=$t" "$@" 2>&1; }
dialog "$rwin" --op=window > /dev/null
out=$(dialog "$rwin" --answer=disconnect)
hl_wait_for 10 nremote_is 0
gone=$?
sleep 2
[ $gone = 0 ] && alive "$rp1"
hl_check "R1 Disconnect closes the window and its far shell keeps running" $? "out=$out pid=$rp1"

mc --op=open > /dev/null
mc --op=select --value="$dev_id" > /dev/null
hl_wait_for 20 pid_listed "$rp1"
out=$(mc)
sid=$(q "$out" '[x["id"] for x in d["sessions"] if x["pid"]=='"$rp1"'][0]')
[ -n "$sid" ] && [ "$(q "$out" '[x["action"] for x in d["sessions"] if x["pid"]=='"$rp1"'][0]')" = Resume ] &&
    [ "$(q "$out" '[x["action_tooltip"] for x in d["sessions"] if x["pid"]=='"$rp1"'][0]')" = "Resume this session in a new window" ]
hl_check "R2 the chooser lists the disconnected session as Resume" $? "sid=$sid out=$out"
q "$out" 'd["detail_subtitle"]' | grep -q '^1 session'
hl_check "R3 the detail counts it: 1 session" $? "subtitle=$(q "$out" 'd["detail_subtitle"]')"

if [ "${NEGATIVE:-0}" = 1 ]; then
    echo "  NEGATIVE CONTROL: pressing New Window where Resume is meant - this run MUST fail R4"
    out=$(mc --op=new-window)
else
    out=$(mc --op=resume --value="$sid")
fi
hl_wait_for 20 nremote_is 1
hl_wait_for 15 remote_pid_shown
read -r rwin2 rp2 <<EOF
$(remote_windows | head -1)
EOF
[ "$(q "$out" 'd["open"]')" = false ] && [ "$rp2" = "$rp1" ]
hl_check "R4 Resume closes the chooser and attaches the SAME far shell in a new window" $? "out=$out pid=$rp2 want=$rp1"
cli +send-keys --target="$rwin2" 'echo resumed-$((6*7))' Enter > /dev/null 2>&1
hl_wait_for 10 sh -c "env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID '$app' +read --name='$rwin2' 2>/dev/null | grep -q resumed-42"
hl_check "R5 keys reach the resumed shell and its output reads back" $? "$(cli +read --name="$rwin2" 2>&1 | tail -3 | tr '\n' ' ')"

# --- S: now it is open here, so it is Show -------------------------------------------
mc --op=open > /dev/null
mc --op=select --value="$dev_id" > /dev/null
hl_wait_for 20 pid_listed "$rp1"
out=$(mc)
[ "$(q "$out" '[x["action"] for x in d["sessions"] if x["pid"]=='"$rp1"'][0]')" = Show ] &&
    [ "$(q "$out" '[x["open_locally"] for x in d["sessions"] if x["pid"]=='"$rp1"'][0]')" = true ]
hl_check "S9 a session open in one of our windows is Show" $? "out=$out"
out=$(mc --op=resume --value="$sid")
sleep 1
[ "$(q "$out" 'd["open"]')" = false ] && q "$out" 'd["last"]' | grep -q "^show $sid" && nremote_is 1
hl_check "S10 Show focuses it and closes the chooser - no second attach" $? "out=$out windows=$(remote_windows | tr '\n' ';')"

# --- E: End a detached session -------------------------------------------------------
mc --op=open > /dev/null
mc --op=select --value="$dev_id" > /dev/null
hl_wait_for 15 roster_loaded
mc --op=new-window > /dev/null
hl_wait_for 20 nremote_is 2
hl_wait_for 15 remote_pid_shown
read -r ewin ep <<EOF
$(remote_windows | grep -v "^$rwin2 " | head -1)
EOF
dialog "$ewin" --op=window > /dev/null
dialog "$ewin" --answer=disconnect > /dev/null
hl_wait_for 10 nremote_is 1
sleep 2
mc --op=open > /dev/null
mc --op=select --value="$dev_id" > /dev/null
hl_wait_for 20 pid_listed "$ep"
out=$(mc)
esid=$(q "$out" '[x["id"] for x in d["sessions"] if x["pid"]=='"$ep"'][0]')
[ -n "$ep" ] && alive "$ep" && [ -n "$esid" ]
hl_check "E1 a second session, disconnected, is listed with its shell running" $? "pid=$ep sid=$esid"
out=$(mc --op=end --value="$esid")
hl_wait_for 10 dead "$ep"
d1=$?
hl_wait_for 15 sessions_n 1
d2=$?
out=$(mc)
[ $d1 = 0 ] && [ $d2 = 0 ] && q "$out" 'd["last"]' | grep -q "^end $esid" && [ "$(q "$out" 'd["open"]')" = true ]
hl_check "E2 End ends its far shell, drops the row, and the chooser stays open" $? "pid=$ep dead=$d1 rows=$d2 out=$out"
alive "$rp1"
hl_check "E3 the other session's shell is untouched" $?
mc --op=close > /dev/null

# --- L: a local session a killed app left behind -------------------------------------
kill -KILL "$APP" 2>/dev/null; wait "$APP" 2>/dev/null
rm -f "$XDG_CONFIG_HOME"/ghoztty/session-layout-debug*.json "$sock"
sleep 1
alive "$local1"
hl_check "L1 the local shell outlives the SIGKILLed app" $? "pid=$local1"
printf '#!/bin/sh\nPS1="hl2$ " exec /bin/sh -i\n' > "$HL_RUNTIME/local2.sh"
chmod +x "$HL_RUNTIME/local2.sh"
hl_launch APP2 "$app" --gtk-single-instance=false -e "$HL_RUNTIME/local2.sh"
hl_wait_for 30 sh -c "env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID '$app' +list > /dev/null 2>&1"
hl_check "L2 a second app serves its socket" $? "$(tail -20 "$APP2_LOG" 2>/dev/null | tr '\n' ' ')"
# A pane of this app holds the local shell: some pane's pid is it or above it.
local_has() {
    local p
    for p in $(cli +list --json 2>/dev/null | grep -o '"pid":[0-9]*' | cut -d: -f2); do
        [ "$p" != 0 ] && is_ancestor "$p" "$local1" && return 0
    done
    return 1
}
! local_has
hl_check "L3a no pane of the new app holds the orphaned shell yet" $?
mc --op=open > /dev/null
hl_wait_for 20 local_listed "$local1"
out=$(mc)
lsid=$(local_sid "$out" "$local1")
[ -n "$lsid" ] && [ "$(sfield "$out" "$lsid" action)" = Resume ] && [ "$(sfield "$out" "$lsid" attached)" = false ]
hl_check "L3 Local lists the orphaned session as Resume" $? "sid=$lsid out=$out"
mc --op=resume --value="$lsid" > /dev/null
hl_wait_for 20 local_has
hl_check "L4 Resume re-attaches that same local shell in a new window" $? "pid=$local1 $(cli +list --json 2>/dev/null | head -c 400)"
alive "$local1"
hl_check "L5 the re-attached local shell is still the same live process" $? "pid=$local1"

hl_finish "$L"
