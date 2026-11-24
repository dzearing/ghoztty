#!/usr/bin/env bash
# session-restore.sh - T3397 (Linux L8b) acceptance: the GTK app keeps a
# session-layout manifest, and a relaunch rebuilds its windows, tabs and splits
# with each pane RE-ATTACHED to the session the agent kept - the same process,
# the same pane id, the same name and split ratio. A real quit (SIGTERM, what a
# logout sends) detaches rather than ends; a pane whose session died while the
# app was down comes back as a fresh shell; a window the user closed never
# comes back; a second instance neither restores nor writes.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\session-restore.sh
#
# Everything runs inside the private headless Weston (test/linux/lib/headless.sh),
# whose private XDG_CONFIG_HOME holds the agent's state dir and the manifest.
#
# Output: one PASS/FAIL line per check, then 'SESSION RESTORE: ALL PASS' or
# 'SESSION RESTORE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="SESSION RESTORE"

log=/tmp/session-restore-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "R1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
manifest="$XDG_CONFIG_HOME/ghoztty/session-layout-debug.json"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
export SHELL=/bin/sh
serving() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" +list > /dev/null 2>&1; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
is_ancestor() {
    local want=$1 p=$2
    while [ -n "$p" ] && [ "$p" != 0 ] && [ "$p" != 1 ]; do
        [ "$p" = "$want" ] && return 0
        p=$(awk '/^PPid:/ { print $2 }' "/proc/$p/status" 2>/dev/null)
    done
    return 1
}

# shape: one line per window, sorted - "target|tab0;tab1" where a tab is its
# split tree with each leaf as name:pane-id:pid and each split as
# (direction ratio left right). Ratios to 2 places.
shape() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def node(n):
    if n["type"] == "split":
        return "(%s %.2f %s %s)" % (n["direction"], n["ratio"], node(n["left"]), node(n["right"]))
    t = n["terminal"]
    return "%s:%s:%s" % (t.get("name") or "-", t.get("id"), t.get("pid") or 0)
out = []
for w in d["windows"]:
    out.append("%s|%s" % (w.get("target") or "-", ";".join(node(t["splits"]) for t in w["tabs"])))
print("\n".join(sorted(out)))
' 2>/dev/null
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
# manifest_q <python expr>: evaluate against the manifest, with `m` the file
# (None when absent) and `leaves` every leaf in it. The expression travels in
# argv, so it can use double quotes inside the shell's single quotes.
manifest_q() {
    python3 -c '
import json, sys
try: m = json.load(open(sys.argv[1]))
except Exception: m = None
leaves = [n["leaf"] for w in (m or {}).get("windows", []) for t in w["tabs"] for n in t["nodes"] if "leaf" in n]
print(eval(sys.argv[2]))
' "$manifest" "$1" 2>/dev/null
}
# live_leaves: how many +list panes report a session pid.
live_leaves() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
print(sum(1 for w in d["windows"] for t in w["tabs"] for l in walk(t["splits"]) if (l.get("pid") or 0) > 0))
' 2>/dev/null
}

# ---- 1. a running app keeps the manifest ----------------------------------
hl_launch APP "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_check "R2 the app serves its socket (launched with no command)" $?
pA="$HL_RUNTIME/pA"; pB="$HL_RUNTIME/pB"; pC="$HL_RUNTIME/pC"
cli +new-window --target=wa --name=pa --command="echo ready-pa; echo \$\$ > $pA; exec sleep 100000" > /dev/null 2>&1
hl_wait_for 20 test -s "$pA"
cli +split --pane=pa --name=pb --direction=right --percent=30 --command="echo ready-pb; echo \$\$ > $pB; exec sleep 100000" > /dev/null 2>&1
cli +split --pane=pb --name=pc --direction=down --command="echo ready-pc; echo \$\$ > $pC; exec sleep 100000" > /dev/null 2>&1
hl_wait_for 20 sh -c "test -s $pB && test -s $pC"
hl_check "R3 three named agent-hosted panes run in window wa" $? "pA=$(cat "$pA" 2>/dev/null) pB=$(cat "$pB" 2>/dev/null) pC=$(cat "$pC" 2>/dev/null)"
sids_ok() { [ "$(manifest_q 'sum(1 for l in leaves if l.get("session_id"))')" = 4 ]; }
hl_wait_for 10 sids_ok
hl_check "R4 the manifest records every pane with its session id within seconds" $? "$(manifest_q '[l.get("session_id") for l in leaves]')"
four_live() { [ "$(live_leaves)" = 4 ]; }
hl_wait_for 10 four_live
# T3560: pa and pb carry banners (pb's session dies later); pc has none.
banA='## pa goal\n- [x] **restore** the `banner`\n| job | state |\n|---|---:|\n| lint | ok |'
banB='pb status line'
cli +set-banner --target=pa "$banA" > /dev/null 2>&1
cli +set-banner --target=pb "$banB" > /dev/null 2>&1
banners_recorded() { [ "$(manifest_q 'sorted((l.get("ipc_name"), l.get("banner")) for l in leaves if l.get("banner"))')" = "$(python3 -c 'import sys; print(sorted([("pa", sys.argv[1]), ("pb", sys.argv[2])]))' "$banA" "$banB")" ]; }
hl_wait_for 10 banners_recorded
hl_check "RB1 the manifest records pa's and pb's banners as their markdown source, and none for pc" $? "$(manifest_q '[(l.get("ipc_name"), l.get("banner")) for l in leaves]')"
before=$(shape)
wins_before=$(printf '%s\n' "$before" | grep -c .)
listA=$(leaf_field pa pid); listB0=$(leaf_field pb pid); listC=$(leaf_field pc pid)

# ---- 2. a crash: relaunch re-attaches the same processes ------------------
kill -KILL "$APP" 2>/dev/null; wait "$APP" 2>/dev/null
alive "$(cat "$pA")" && alive "$(cat "$pB")" && alive "$(cat "$pC")"
hl_check "R5 every pane's process outlives the SIGKILLed app" $?
hl_launch APP2 "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_wait_for 15 four_live
after=$(shape)
[ -n "$before" ] && [ "$after" = "$before" ]
hl_check "R6 the relaunch rebuilds every window, split, ratio, name and pane id, on the SAME pids" $? "
before: $before
after:  $after"
wins_after=$(printf '%s\n' "$after" | grep -c .)
[ "$wins_after" = "$wins_before" ] && [ "$wins_after" = 2 ]
hl_check "R7 no extra window beside the restored ones" $? "before=$wins_before after=$wins_after"
[ -n "$listA" ] && [ "$listA" != 0 ] && [ "$(leaf_field pa pid)" = "$listA" ] && alive "$(cat "$pA")"
hl_check "R8 pane pa is the very process it was (re-attached, not re-run)" $? "list=$(leaf_field pa pid) before=$listA"
read_pa() { cli +read --name=pa --lines=50 2>/dev/null | grep -q 'ready-pa'; }
hl_wait_for 10 read_pa
hl_check "R8b pa's restored screen still shows what it printed before the crash" $? "$(cli +read --name=pa --lines=8 2>&1 | tr '\n' '|' | head -c 300)"
grep -q 'session layout: restored 2 of 2 window(s), 4 pane(s) re-attached' "$APP2_LOG"
hl_check "R9 the app logs that it re-attached all four panes" $? "$(grep -m1 'session layout: restored' "$APP2_LOG")"
[ "$(leaf_field pa banner)" = "$banA" ] && [ "$(leaf_field pb banner)" = "$banB" ] && [ "$(leaf_field pc banner)" = None ]
hl_check "RB2 the relaunch puts pa's and pb's banners back, and pc stays bannerless" $? "pa=$(leaf_field pa banner) pb=$(leaf_field pb banner) pc=$(leaf_field pc banner)"

# ---- 3. a real quit detaches and snapshots --------------------------------
kill -TERM "$APP2" 2>/dev/null
hl_wait_for 15 sh -c "! kill -0 $APP2 2>/dev/null"
hl_check "R10 SIGTERM quits the app" $?
alive "$(cat "$pA")" && alive "$(cat "$pB")" && cli +sessions 2>/dev/null | grep -q alive
hl_check "R11 the quit detached: every session is still alive" $? "$(cli +sessions 2>&1 | head -5 | tr '\n' '|')"
[ "$(manifest_q 'len(leaves)')" = 4 ]
hl_check "R12 the quit left the manifest with all four panes" $? "$(manifest_q 'len(leaves)')"
[ "$(manifest_q 'sum(1 for l in leaves if l.get("screen_snapshot") and l.get("screen_snapshot_offset"))')" = 4 ]
hl_check "R13 the quit's write carries every pane's screen snapshot" $? "$(manifest_q '[bool(l.get("screen_snapshot")) for l in leaves]')"

# ---- 3b. a window's size and a tab's pinned title (T3549) -----------------
# The manifest records each window's size; restoring replays a recorded size
# and re-pins a recorded tab title. Neither has a CLI verb on GTK, so the test
# writes them into the manifest while the app is down (as a resize and a
# "Change Tab Title" before the quit would have) and then watches the relaunch.
[ "$(manifest_q 'all((w.get("frame") or {}).get("w", 0) > 0 and (w.get("frame") or {}).get("h", 0) > 0 for w in m["windows"])')" = True ]
hl_check "R13b the manifest records every window's size" $? "$(manifest_q '[w.get("frame") for w in m["windows"]]')"
w0=$(manifest_q '[w["frame"]["w"] for w in m["windows"] if w.get("ipc_name") == "wa"][0]')
case "$w0" in ''|*[!0-9]*) w0=0 ;; esac
if [ "$w0" -ge 950 ]; then want_w=700; else want_w=$((w0 + 250)); fi
want_h=460
python3 -c '
import json, sys
p, w, h = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
m = json.load(open(p))
for win in m["windows"]:
    if win.get("ipc_name") == "wa":
        win["frame"] = {"x": 0, "y": 0, "w": w, "h": h}
        win["tabs"][0]["title"] = "pinned-tab"
json.dump(m, open(p, "w"))
' "$manifest" "$want_w" "$want_h"

# ---- 4. a session that died while the app was down comes back fresh --------
oldB=$(cat "$pB"); idB=$(manifest_q '[l["pane_id"] for l in leaves if l.get("ipc_name") == "pb"][0]')
kill -KILL "$oldB" 2>/dev/null
hl_wait_for 10 sh -c "! kill -0 $oldB 2>/dev/null"
hl_launch APP3 "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_wait_for 15 four_live
listB=$(leaf_field pb pid)
[ -n "$listB" ] && [ "$listB" != 0 ] && [ "$listB" != "$listB0" ] && alive "$listB" && [ -n "$idB" ] && [ "$(leaf_field pb id)" = "$idB" ]
hl_check "R14 pb, whose session died, is back as a FRESH shell under its own pane id" $? "old=$listB0 new=$listB id=$(leaf_field pb id) want=$idB"
[ "$(leaf_field pc pid)" = "$listC" ] && [ "$(leaf_field pa pid)" = "$listA" ]
hl_check "R15 the panes whose sessions lived are re-attached beside it" $? "pc=$(leaf_field pc pid)/$listC pa=$(leaf_field pa pid)/$listA"
sleep 1
[ "$(leaf_field pb banner)" = "$banB" ]
hl_check "RB3 pb's fresh shell keeps pb's own banner; the session-gone notice did not take its slot" $? "pb=$(leaf_field pb banner)"
shot="$HL_RUNTIME/wa-window.png"
wa_size() { hl_screenshot wa "$shot" --window > /dev/null 2>&1 && hl_png_stats "$shot" | awk '{ sub("w=","",$1); sub("h=","",$2); print $1, $2 }'; }
size_ok() {
    set -- $(wa_size)
    [ -n "${1:-}" ] && [ $(( $1 > want_w ? $1 - want_w : want_w - $1 )) -le 40 ] && [ $(( $2 > want_h ? $2 - want_h : want_h - $2 )) -le 40 ]
}
hl_wait_for 10 size_ok
hl_check "R15b window wa comes back at its recorded size (${want_w}x${want_h}, was ${w0} wide)" $? "rendered: $(wa_size)"
tab_title() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
for w in json.load(sys.stdin)["data"]["windows"]:
    if w.get("target") == "wa": print(w["tabs"][0]["title"])
' 2>/dev/null
}
[ "$(tab_title)" = pinned-tab ]
hl_check "R15c wa's tab keeps its pinned title through the relaunch" $? "title=$(tab_title)"
recaptured() { [ "$(manifest_q '[(w["frame"]["w"], w["tabs"][0].get("title")) for w in m["windows"] if w.get("ipc_name") == "wa"][0]')" = "($want_w, 'pinned-tab')" ]; }
hl_wait_for 5 recaptured
hl_check "R15d the running app records the restored size and title again" $? "$(manifest_q '[(w.get("frame"), w["tabs"][0].get("title")) for w in m["windows"] if w.get("ipc_name") == "wa"]')"

# ---- 5. a second instance neither restores nor writes -----------------------
m_before=$(md5sum "$manifest" 2>/dev/null)
hl_launch APP4 "$app" --gtk-single-instance=false
sleep 4
! grep -q 'session layout: restored' "$APP4_LOG" && [ "$(shape | grep -c .)" = 2 ]
hl_check "R16 a second instance does not restore the first one's windows" $? "$(grep -m1 'session layout' "$APP4_LOG")"
kill -TERM "$APP4" 2>/dev/null; hl_wait_for 10 sh -c "! kill -0 $APP4 2>/dev/null"
sleep 1.5
[ "$(md5sum "$manifest" 2>/dev/null)" = "$m_before" ] || [ "$(manifest_q 'len(leaves)')" = 4 ]
hl_check "R17 the second instance's quit did not overwrite the manifest" $? "$(manifest_q 'len(leaves)')"

# ---- 5b. the agent died too (a reboot): sessions come back relaunched -------
# session-relaunch = restore (the default): a plain shell in the session's
# recorded directory, under the same pane id, in the same place.
kill -TERM "$APP3" 2>/dev/null; hl_wait_for 15 sh -c "! kill -0 $APP3 2>/dev/null"
old_agent=$(hl_agent_pid)
old_tree=$( [ -n "$old_agent" ] && hl_tree "$old_agent" )
idA=$(manifest_q '[l["pane_id"] for l in leaves if l.get("ipc_name") == "pa"][0]')
kill -KILL "$old_agent" 2>/dev/null
for p in $old_tree; do kill -KILL "$p" 2>/dev/null; done
hl_wait_for 10 sh -c "! kill -0 $old_agent 2>/dev/null"
hl_launch APP6 "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_wait_for 20 four_live
new_agent=$(hl_agent_pid)
relA=$(leaf_field pa pid)
[ -n "$new_agent" ] && [ "$new_agent" != "$old_agent" ] && [ -n "$relA" ] && [ "$relA" != 0 ] && [ "$relA" != "$listA" ] \
    && alive "$relA" && is_ancestor "$new_agent" "$relA" && [ "$(leaf_field pa id)" = "$idA" ]
hl_check "R17b after an agent restart pa comes back as a relaunched shell under the new agent, same pane id" $? \
    "agent $old_agent->$new_agent pid $listA->$relA id=$(leaf_field pa id) want=$idA"
[ "$(shape | grep -c .)" = 2 ] && [ "$(live_leaves)" = 4 ]
hl_check "R17c every window and pane is back after the agent restart" $? "$(shape | tr '\n' '|')"
read_pa_any() { cli +read --name=pa --lines=60 2>/dev/null | grep -Eq 'ready-pa'; }
hl_wait_for 10 read_pa_any
hl_check "R17d the relaunched pa replays the history it had" $? "$(cli +read --name=pa --lines=10 2>&1 | tr '\n' '|' | head -c 400)"
# T3560: the notice fires on this path (pc, bannerless, shows it), and pa's
# own banner keeps the slot.
notice_c() { leaf_field pc banner | grep -q 'Session interrupted'; }
hl_wait_for 5 notice_c
hl_check "RB4 bannerless pc's slot carries the session-interrupted notice after the agent restart" $? "pc=$(leaf_field pc banner)"
[ "$(leaf_field pa banner)" = "$banA" ]
hl_check "RB5 the relaunched pa keeps its own banner instead of the notice" $? "pa=$(leaf_field pa banner)"

# ---- 6. what the user closes stays closed ----------------------------------
cli +close --target=wa > /dev/null 2>&1
hl_wait_for 10 sh -c "! kill -0 $relA 2>/dev/null"
hl_check "R18 closing window wa ends its panes' processes" $?
hl_wait_for 5 sh -c "[ \"\$(python3 -c \"
import json
m=json.load(open('$manifest'))
print(sum(1 for w in m['windows'] for t in w['tabs'] for n in t['nodes'] if 'leaf' in n))\" 2>/dev/null)\" = 1 ]"
hl_check "R19 the manifest drops the closed window within seconds" $? "$(manifest_q 'len(leaves)')"
for t in $(cli +list --json 2>/dev/null | python3 -c 'import json,sys; [print(w.get("target") or w["id"]) for w in json.load(sys.stdin)["data"]["windows"]]' 2>/dev/null); do
    cli +close --target="$t" > /dev/null 2>&1
done
hl_wait_for 15 sh -c "! kill -0 $APP6 2>/dev/null"
hl_check "R20 closing the last window quits the app" $?
[ ! -e "$manifest" ] || [ "$(manifest_q 'len(leaves)')" = 0 ]
hl_check "R21 an app the user emptied leaves nothing to restore" $? "$(manifest_q 'len(leaves)')"
hl_launch APP5 "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_wait_for 10 sh -c "[ \"\$(env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID '$app' +list --json 2>/dev/null | grep -o '\"type\":\"leaf\"' | wc -l)\" = 1 ]"
hl_check "R22 the next launch opens one fresh window with one pane" $? "$(shape | tr '\n' '|')"

grep -E 'panic|reached unreachable' "$APP_LOG" "$APP2_LOG" "$APP3_LOG" "$APP4_LOG" "$APP5_LOG" "$APP6_LOG" > /dev/null 2>&1
[ $? != 0 ]
hl_check "R23 no app log carries a panic" $? "$(grep -h -m2 -E 'panic|unreachable' "$APP_LOG" "$APP2_LOG" "$APP3_LOG" "$APP4_LOG" "$APP5_LOG" "$APP6_LOG" 2>/dev/null | tr '\n' ' ')"

hl_finish "$L"
