#!/usr/bin/env bash
# agent-recover.sh - T3400 (Linux L8e) acceptance: when the local agent dies
# under a RUNNING GTK app, the app rebuilds its terminal panes in place on a
# fresh agent - same window, same split, same pane ids and names - instead of
# leaving them frozen until a relaunch. A viewer pane is never touched, the
# rebuilt panes are drivable, a pane opened afterwards rides the new agent,
# and a second agent death (raced against a new pane) recovers too. A pane's
# banner rides across the rebuild and keeps the session-interrupted notice out
# of its slot; a bannerless pane shows the notice (T3560). That notice is long
# and pb's column narrow, so A13 is also the check that a banner too tall for
# its pane cannot stop the rebuilt pane's shell from starting.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\agent-recover.sh
#
# Everything runs inside the private headless Weston (test/linux/lib/headless.sh).
#
# Output: one PASS/FAIL line per check, then 'AGENT RECOVER: ALL PASS' or
# 'AGENT RECOVER: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="AGENT RECOVER"

log=/tmp/agent-recover-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "A1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
app=$(hl_ghoztty) || hl_finish "$L"
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
# leaf_field <name> <field>: one +list field of the pane named <name>.
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
# shape: the window's split tree, leaves as name:id, ratios to 2 places.
shape() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def node(n):
    if n["type"] == "split":
        return "(%s %.2f %s %s)" % (n["direction"], n["ratio"], node(n["left"]), node(n["right"]))
    t = n["terminal"]
    return "%s:%s" % (t.get("name") or "-", t.get("id"))
print("|".join(";".join(node(t["splits"]) for t in w["tabs"]) for w in d["windows"]))
' 2>/dev/null
}
# on_agent <agent> <name>...: every named pane has a live pid under <agent>.
on_agent() {
    local a=$1 n p; shift
    for n in "$@"; do
        p=$(leaf_field "$n" pid)
        alive "$p" && is_ancestor "$a" "$p" || return 1
    done
    return 0
}
kill_agent_tree() {
    local a=$1 t p
    t=$(hl_tree "$a")
    kill -KILL "$a" 2>/dev/null
    for p in $t; do kill -KILL "$p" 2>/dev/null; done
}

# ---- 1. a running app with agent-hosted panes and a viewer -----------------
hl_launch APP "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_check "A2 the app serves its socket" $?
doc="$HL_RUNTIME/doc.md"; printf '# Recover\n\nviewer body\n' > "$doc"
mkdir -p "$HL_RUNTIME/wd-a" "$HL_RUNTIME/wd-b"
cli +new-window --target=wr --name=pa --working-directory="$HL_RUNTIME/wd-a" --command="echo ready-pa" > /dev/null 2>&1
cli +split --pane=pa --name=pb --direction=right --percent=30 --working-directory="$HL_RUNTIME/wd-b" --command="echo ready-pb" > /dev/null 2>&1
cli +split --pane=pb --name=pv --direction=down --view="$doc" > /dev/null 2>&1
hl_wait_for 20 hl_agent_pid
agent1=$(hl_agent_pid)
hl_wait_for 20 on_agent "$agent1" pa pb
hl_check "A3 two terminal panes run under agent $agent1, beside a viewer" $? \
    "pa=$(leaf_field pa pid) pb=$(leaf_field pb pid) pv=$(leaf_field pv type)"
before=$(shape)
pidA1=$(leaf_field pa pid); pidB1=$(leaf_field pb pid)
idV=$(leaf_field pv id)
# T3560: pa carries a banner across the rebuild; pb has none, so its slot is
# free for the session-interrupted notice.
banA='## pa goal\n- [x] survive the agent'
cli +set-banner --target=pa "$banA" > /dev/null 2>&1
banA_nl=$(printf '%b' "$banA")   # +set-banner stores each \n as a newline
hl_wait_for 5 sh -c "[ \"\$(env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID '$app' +list --json 2>/dev/null | grep -c 'survive the agent')\" -ge 1 ]"

# ---- 2. the agent dies: the panes come back in place on a new agent --------
kill_agent_tree "$agent1"
hl_wait_for 10 sh -c "! kill -0 $agent1 2>/dev/null"
new_agent() { a=$(hl_agent_pid) && [ "$a" != "$agent1" ]; }
recovered() { grep -q 'agent recovery: rebuilt [1-9]' "$APP_LOG"; }
hl_wait_for 30 recovered
hl_check "A4 the app logs an in-place rebuild after the agent dies" $? \
    "$(grep -m3 'agent recovery' "$APP_LOG" | tr '\n' '|')"
hl_wait_for 10 new_agent
agent2=$(hl_agent_pid)
hl_check "A5 a fresh agent was spawned" $? "agent $agent1 -> $agent2"
hl_wait_for 20 on_agent "$agent2" pa pb
pidA2=$(leaf_field pa pid); pidB2=$(leaf_field pb pid)
[ "$pidA2" != "$pidA1" ] && [ "$pidB2" != "$pidB1" ]
hl_check "A6 pa and pb run again, as new shells under the new agent" $? "pa $pidA1->$pidA2 pb $pidB1->$pidB2"
[ "$(shape)" = "$before" ]
hl_check "A7 same window, split, ratios, names and pane ids as before" $? "before=$before after=$(shape)"
[ "$(leaf_field pv id)" = "$idV" ] && [ "$(leaf_field pv type)" = viewer ]
hl_check "A8 the viewer pane was left alone (same id, still a viewer)" $? "pv id=$(leaf_field pv id) want=$idV"
wdA=$(readlink "/proc/$pidA2/cwd" 2>/dev/null)
[ "$wdA" = "$HL_RUNTIME/wd-a" ]
hl_check "A9 the rebuilt pa shell starts in pa's directory" $? "cwd=$wdA"
! grep -q 'gave up' "$APP_LOG"
hl_check "A10 no give-up line" $?
# T3560: the rebuilt pa keeps its own banner - the notice did not take its
# slot - while bannerless pb's slot carries the notice.
banner_kept() { [ "$(leaf_field pa banner)" = "$banA_nl" ]; }
hl_wait_for 5 banner_kept
sleep 1
banner_kept
hl_check "A10b the rebuilt pa keeps its own banner, not the session-interrupted notice" $? "banner=$(leaf_field pa banner)"
notice_b() { leaf_field pb banner | grep -q 'Session interrupted'; }
hl_wait_for 5 notice_b
hl_check "A10c bannerless pb's slot carries the session-interrupted notice" $? "banner=$(leaf_field pb banner)"

# ---- 3. the rebuilt panes work ---------------------------------------------
cli +send-keys --target=pa 'echo A11_$((40+2))' Enter > /dev/null 2>&1
read_pa() { cli +read --name=pa --lines=40 2>/dev/null | grep -q 'A11_42'; }
hl_wait_for 10 read_pa
hl_check "A11 +send-keys / +read drive the rebuilt pa" $? "$(cli +read --name=pa --lines=8 2>&1 | tr '\n' '|' | head -c 300)"

# ---- 4. a pane opened afterwards rides the new agent -----------------------
cli +split --pane=pa --name=pc --direction=down --command="echo ready-pc" > /dev/null 2>&1
hl_wait_for 20 on_agent "$agent2" pc
hl_check "A12 a new pane after recovery runs under the new agent" $? "pc=$(leaf_field pc pid) agent=$agent2"

# ---- 5. a second death, raced against a new pane ---------------------------
# Whichever notices first - the link watch or the new pane's request - the end
# state is the same: every terminal pane on a third agent.
kill_agent_tree "$agent2"
cli +split --pane=pb --name=pd --direction=down --command="echo ready-pd" > /dev/null 2>&1
third_agent() { a=$(hl_agent_pid) && [ "$a" != "$agent2" ] && [ "$a" != "$agent1" ]; }
hl_wait_for 20 third_agent
agent3=$(hl_agent_pid)
hl_wait_for 30 on_agent "$agent3" pa pb pc pd
hl_check "A13 after a second death every pane (and the raced new one) runs under agent $agent3" $? \
    "pa=$(leaf_field pa pid) pb=$(leaf_field pb pid) pc=$(leaf_field pc pid) pd=$(leaf_field pd pid)"
[ "$(leaf_field pv id)" = "$idV" ]
hl_check "A14 the viewer is still the same pane" $?
kill -0 "$APP" 2>/dev/null
hl_check "A15 the app stayed up throughout" $?

# ---- 6. a user close still ENDS the session (spare is recovery-only) -------
pidC=$(leaf_field pc pid)
cli +close --target=pc > /dev/null 2>&1
hl_wait_for 10 sh -c "! kill -0 $pidC 2>/dev/null"
hl_check "A16 closing a rebuilt-era pane still ends its shell" $? "pc pid $pidC"

hl_finish "$L"
