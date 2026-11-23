#!/usr/bin/env bash
# cli-handoff-quit.sh - T3595 (Linux L8d-1, split from T3399) acceptance: the
# GTK app serves `handoff-quit`, the request a launch of ANOTHER build sends
# when the user answers "Switch" (win32's T1070). It is refused without a
# launch identity and for the same build; for a different build the reply
# comes back first and then the app quits the ordinary way - the layout is
# saved and the agent-hosted pane DETACHES, so the build that takes over
# re-attaches the same shell. `+version` advertises the verb and whether a
# quit keeps the terminals (session persistence).
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-handoff-quit.sh
#
# Everything runs inside the private headless Weston (test/linux/lib/headless.sh).
# Output: one PASS/FAIL line per check, then 'CLI HANDOFF QUIT: ALL PASS' or
# 'CLI HANDOFF QUIT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI HANDOFF QUIT"

log=/tmp/cli-handoff-quit-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "Q1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
app=$(hl_ghoztty) || hl_finish "$L"
manifest="$XDG_CONFIG_HOME/ghoztty/session-layout-debug.json"
export SHELL=/bin/sh
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
serving() { cli +list > /dev/null 2>&1; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

# handoff <json-or-empty>: send `handoff-quit` with that `handoff` object (none
# when empty), print the reply. The CLI has no verb for it - only a launch
# sends it - so this speaks the wire directly, like hl_ipc.
handoff() {
    python3 -I - "$(hl_socket)" "$1" <<'PY'
import json, socket, struct, sys
path, ident = sys.argv[1], sys.argv[2]
req = {"action": "handoff-quit"}
if ident: req["handoff"] = json.loads(ident)
body = json.dumps(req).encode()
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(15); s.connect(path)
    s.sendall(struct.pack(">I", len(body)) + body)
    def take(n):
        out = b""
        while len(out) < n:
            c = s.recv(n - len(out))
            if not c: raise EOFError("short read")
            out += c
        return out
    n = struct.unpack(">I", take(4))[0]
    print(take(n).decode())
except Exception as e:
    sys.stderr.write("handoff: %s\n" % e); sys.exit(1)
PY
}
# vfield <field>: one field of the +version reply's data.
vfield() {
    hl_ipc version 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
v = d.get(sys.argv[1])
print(json.dumps(v) if isinstance(v, bool) else v)' "$1" 2>/dev/null
}
# pane_pid <name>: the pid +list reports for the pane named <name>.
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

# ---- 1. +version advertises the verb ---------------------------------------
hl_launch APP "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_check "Q2 the app serves its socket" $?
beat="$HL_RUNTIME/beat"; spid="$HL_RUNTIME/spid"
cli +new-window --target=wh --name=ph --command="echo \$\$ > $spid; while :; do date +%s%N > $beat; sleep 0.2; done" > /dev/null 2>&1
hl_wait_for 20 test -s "$spid"
shell=$(cat "$spid" 2>/dev/null)
# The pid +list reports is the session's own process, which the agent spawned
# (the heartbeat shell descends from it); Q16 compares the relaunch against it.
listed=$(pane_pid ph)
alive "$shell" && alive "$listed"
hl_check "Q3 an agent-hosted pane 'ph' runs a heartbeat shell" $? "pid=$shell listed=$listed"

hq=$(vfield handoff_quit); sp=$(vfield session_persistence)
[ "$hq" = true ]
hl_check "Q4 +version says handoff_quit: true" $? "handoff_quit=$hq"
[ "$sp" = true ]
hl_check "Q5 +version says session_persistence: true (the default)" $? "session_persistence=$sp"
ver=$(vfield version); commit=$(vfield commit)
[ -n "$ver" ] && [ -n "$commit" ]
hl_check "Q6 +version names this build (version + commit)" $? "version=$ver commit=$commit"

# ---- 2. refusals: no launch identity, the same build -----------------------
r=$(handoff "")
printf '%s' "$r" | grep -q '"success":false' && printf '%s' "$r" | grep -q 'only sent by a launch of another build'
hl_check "Q7 no handoff identity is refused ('only sent by a launch of another build')" $? "$r"
same=$(python3 -c 'import json,sys; print(json.dumps({"version": sys.argv[1], "commit": sys.argv[2], "exe": "/elsewhere/ghoztty"}))' "$ver" "$commit")
r=$(handoff "$same")
printf '%s' "$r" | grep -q '"success":false' && printf '%s' "$r" | grep -q 'the launch is the build already running'
hl_check "Q8 the same build (same commit, other path) is refused" $? "$r"
sleep 1
alive "$APP" && serving
hl_check "Q9 after both refusals the app is still up and serving" $?

# ---- 3. another build: reply first, then a real quit that detaches ---------
other='{"version":"9.9.9-other","commit":"0000000","exe":"/opt/other/ghoztty"}'
r=$(handoff "$other")
printf '%s' "$r" | grep -q '"success":true'
hl_check "Q10 another build's handoff-quit is answered success before the app goes" $? "$r"
hl_wait_for 10 sh -c "! kill -0 $APP 2>/dev/null"
hl_check "Q11 the app exits on its own within 10 s" $?
grep -q 'handoff-quit: quitting so the launch of 9.9.9-other (/opt/other/ghoztty) can take over (persistence=true)' "$APP_LOG"
hl_check "Q12 the app logged why it quit, naming the launching build" $? "$(grep -m2 'handoff' "$APP_LOG" | tr '\n' ' ')"
b1=$(cat "$beat" 2>/dev/null); sleep 1; b2=$(cat "$beat" 2>/dev/null)
alive "$shell" && [ -n "$b1" ] && [ "$b1" != "$b2" ]
hl_check "Q13 the pane's shell outlived the quit (detached, heartbeat still advancing)" $? "pid=$shell b1=$b1 b2=$b2"
python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
names = [n["leaf"].get("ipc_name") for w in m["windows"] for t in w["tabs"] for n in t["nodes"] if "leaf" in n]
sys.exit(0 if "ph" in names else 1)' "$manifest" 2>/dev/null
hl_check "Q14 the quit saved the layout (pane 'ph' is in the manifest)" $?

# ---- 4. the build that takes over re-attaches the same shell ----------------
hl_launch APP2 "$app" --gtk-single-instance=false
hl_wait_for 30 serving
hl_check "Q15 the next launch serves the socket" $?
attached() { [ "$(pane_pid ph)" = "$listed" ]; }
hl_wait_for 20 attached && alive "$shell"
hl_check "Q16 the relaunch re-attached 'ph' to the same session (pid $listed, heartbeat shell $shell alive)" $? "listed pid now=$(pane_pid ph)"

# ---- 5. persistence off: the version reply says a quit closes terminals ----
kill -TERM "$APP2" 2>/dev/null
hl_wait_for 10 sh -c "! kill -0 $APP2 2>/dev/null"
hl_launch APP3 "$app" --gtk-single-instance=false --session-persistence=false
hl_wait_for 30 serving
sp=$(vfield session_persistence)
[ "$sp" = false ]
hl_check "Q17 with session-persistence = false, +version says session_persistence: false" $? "session_persistence=$sp"

hl_finish "$L"
