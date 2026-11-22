#!/usr/bin/env bash
# ipc-server.sh - L6 (T3335) acceptance: the GTK debug app serves the CLI's
# Unix socket, at the derivation the CLI resolves, mode 0600, baked into
# every pane, and a CLI run inside a pane answers from THAT app and never
# from another one. Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\ipc-server.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop.
#
# Output: one PASS/FAIL line per check, then 'IPC SERVER: ALL PASS' or
# 'IPC SERVER: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init

log=/tmp/ipc-server-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "I1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "IPC SERVER"

hl_start
hl_check "I2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "IPC SERVER"
uid=$(id -u)
sock="$XDG_RUNTIME_DIR/ghostty-debug-$uid.sock"
release_sock="$XDG_RUNTIME_DIR/ghostty-$uid.sock"

# A DECOY: a socket that records every connection and answers like an app.
# It stands for "some other instance" - the app is launched with it as an
# inherited $GHOZTTY_IPC_SOCKET (the launched-from-another-pane case) and it
# also sits at the RELEASE name, so a CLI that dialled either would show here.
decoy="$HL_RUNTIME/decoy.sock"
decoy_hits="$HL_RUNTIME/decoy-hits"
cat > "$HL_RUNTIME/decoy.py" <<'PY'
import os, socket, struct, sys
paths, hits = sys.argv[1:-1], sys.argv[-1]
socks = []
for p in paths:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.bind(p); s.listen(8); socks.append(s)
import select
while True:
    r, _, _ = select.select(socks, [], [])
    for s in r:
        c, _ = s.accept()
        with open(hits, "a") as f: f.write("hit\n")
        body = b'{"success":true,"data":{"windows":[],"build":{"version":"decoy","commit":"","mode":"","runtime":"","update_check":false,"exe":"decoy","exe_modified":"","pid":1}}}'
        try:
            c.recv(65536); c.sendall(struct.pack(">I", len(body)) + body)
        except OSError: pass
        c.close()
PY
: > "$decoy_hits"
hl_launch DECOY python3 "$HL_RUNTIME/decoy.py" "$decoy" "$release_sock" "$decoy_hits"
hl_wait_for 10 test -S "$decoy"

# The pane's own script: record the env it was baked with, its tty, and what
# the CLI answers from inside the pane.
pane="$HL_RUNTIME/pane"
mkdir -p "$pane"
cat > "$HL_RUNTIME/pane.sh" <<EOF
printf '%s' "\$GHOZTTY_IPC_SOCKET" > "$pane/socket"
printf '%s' "\$GHOZTTY_PANE_ID" > "$pane/id"
tty > "$pane/tty"
"$app" +list --json > "$pane/list.json" 2> "$pane/list.err"
echo \$? > "$pane/list.rc"
"$app" +list --tty="\$(tty)" > "$pane/bytty" 2>&1
"$app" +reload > "$pane/unserved.out" 2>&1
echo \$? > "$pane/unserved.rc"
echo done > "$pane/done"
sleep 120
EOF

GHOZTTY_IPC_SOCKET="$decoy" hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh "$HL_RUNTIME/pane.sh"
apid=$APP
hl_wait_for 30 test -s "$pane/done"
hl_check "I3 the pane's script ran to the end" $? "$(ls "$pane" | tr '\n' ' ')"

# The socket: at the derivation, a socket, 0600, owned by us.
test -S "$sock"
hl_check "I4 the app serves \$XDG_RUNTIME_DIR/ghostty-debug-<uid>.sock" $? "$(ls -la "$XDG_RUNTIME_DIR" | grep ghostty | tr '\n' ' ')"
mode=$(stat -c %a "$sock" 2>/dev/null)
[ "$mode" = 600 ]
hl_check "I5 the socket is mode 0600" $? "mode=$mode"
grep -q "IPC: listening on $sock" "$APP_LOG"
hl_check "I6 the app logs the path it listens on" $?

# Baked env: this app's socket (not the inherited decoy) and a UUID pane id.
[ "$(cat "$pane/socket")" = "$sock" ]
hl_check "I7 the pane is baked with THIS app's socket, not the inherited one" $? "baked=$(cat "$pane/socket")"
grep -Eq '^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}$' "$pane/id"
hl_check "I8 the pane is baked with a UUID \$GHOZTTY_PANE_ID" $? "id=$(cat "$pane/id")"

# +list from inside the pane answers from THIS app.
[ "$(cat "$pane/list.rc")" = 0 ]
hl_check "I9 +list --json inside the pane exits 0" $? "$(head -c 300 "$pane/list.err")"
listed=$(python3 - "$pane/list.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["data"]
leaves = []
def walk(n):
    if n["type"] == "split": walk(n["left"]); walk(n["right"])
    else: leaves.append(n["terminal"])
for w in d["windows"]:
    for t in w["tabs"]: walk(t["splits"])
print(d.get("build", {}).get("pid", 0), len(d["windows"]), " ".join(l.get("id", "") for l in leaves), " ".join(l.get("tty", "") for l in leaves))
PY
)
set -- $listed
[ "${1:-0}" = "$apid" ]
hl_check "I10 the answer's build.pid is the app's own pid" $? "pid=${1:-?} app=$apid"
[ "${2:-0}" = 1 ]
hl_check "I11 it lists the one window" $? "windows=${2:-?}"
case " ${3:-} " in *" $(cat "$pane/id") "*) r=0 ;; *) r=1 ;; esac
hl_check "I12 the pane's \$GHOZTTY_PANE_ID is a listed leaf id" $r "ids=${3:-}"
case " ${4:-} " in *" $(cat "$pane/tty") "*) r=0 ;; *) r=1 ;; esac
hl_check "I13 the pane's tty is listed" $r "ttys=${4:-} pane=$(cat "$pane/tty")"
[ "$(cat "$pane/bytty")" = "$(cat "$pane/id")" ]
hl_check "I14 +list --tty=\$(tty) names the pane" $? "got=$(cat "$pane/bytty")"
[ ! -s "$decoy_hits" ]
hl_check "I15 nothing ever dialled the decoy (inherited or release socket)" $? "hits=$(wc -l < "$decoy_hits")"
# Positive control: a CLI that IS pointed at the decoy reaches it and gets its
# answer, so I15's silence means something.
ctl=$(GHOZTTY_IPC_SOCKET="$decoy" "$app" +list --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["build"]["pid"])' 2>/dev/null)
[ "$ctl" = 1 ] && [ -s "$decoy_hits" ]
hl_check "I15c control: a CLI aimed at the decoy does reach it" $? "pid=$ctl hits=$(wc -l < "$decoy_hits")"

# A verb not served yet says so, naming the task, and fails.
[ "$(cat "$pane/unserved.rc")" != 0 ] && grep -q 'not served by the Linux app yet (T3369)' "$pane/unserved.out"
hl_check "I16 +reload answers 'not served by the Linux app yet (T3369)'" $? "$(head -c 200 "$pane/unserved.out")"

# Outside any pane, the CLI derives the same path from the same environment.
out=$(env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" +version 2>&1)
echo "$out" | grep -Eq "pid[^0-9]*$apid"
hl_check "I17 +version outside the pane reaches the same app" $? "$(echo "$out" | grep -A12 'Running Instance' | tr '\n' ' ' | head -c 300)"

# A second instance must not steal a LIVE socket.
hl_launch APP2 "$app" --gtk-single-instance=false -e /bin/sh -c 'sleep 60'
hl_wait_for 20 grep -q 'another instance already serves' "$APP2_LOG"
hl_check "I18 a second app leaves the live socket alone and says so" $? "$(grep -m2 'IPC' "$APP2_LOG" | tr '\n' ' ')"
out=$(env -u GHOZTTY_IPC_SOCKET "$app" +list --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["build"]["pid"])' 2>/dev/null)
[ "$out" = "$apid" ]
hl_check "I19 the first app still answers" $? "pid=$out"
kill "$APP2" 2>/dev/null

# A stale socket (its app killed outright) is replaced by the next app.
kill -9 "$apid" 2>/dev/null
sleep 1
test -S "$sock"
hl_check "I20 SIGKILL leaves a stale socket behind (the case to recover)" $?
hl_launch APP3 "$app" --gtk-single-instance=false -e /bin/sh -c 'sleep 60'
hl_wait_for 20 grep -q "IPC: listening on $sock" "$APP3_LOG"
hl_check "I21 the next app replaces the stale socket and serves" $? "$(grep -m2 'IPC' "$APP3_LOG" | tr '\n' ' ')"
out=$(env -u GHOZTTY_IPC_SOCKET "$app" +list --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["build"]["pid"])' 2>/dev/null)
[ "$out" = "$APP3" ]
hl_check "I22 the CLI now reaches the new app" $? "pid=$out app=$APP3"

for l in "$APP_LOG" "$APP3_LOG"; do
    if grep -qE '^(panic|thread [0-9]+ panic)|reached unreachable' "$l"; then
        grep -m5 -E 'panic|unreachable' "$l"; hl_check "I23 no panic in $(basename "$l")" 1
    fi
done
hl_check "I23 no panic in the app logs" 0

hl_finish "IPC SERVER"
