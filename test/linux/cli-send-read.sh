#!/usr/bin/env bash
# cli-send-read.sh - L7 (T3336) acceptance for +send-keys and +read against
# the GTK debug app: typed text and keys reach the pane's pty with the Mac's
# framing (text runs as a bracketed paste when the program asked for one, key
# runs bare), and +read returns what the pane shows, tailed by --lines. Run it
# ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-send-read.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop.
#
# Output: one PASS/FAIL line per check, then 'CLI SEND READ: ALL PASS' or
# 'CLI SEND READ: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init

log=/tmp/cli-send-read-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "K1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "CLI SEND READ"

hl_start
hl_check "K2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "CLI SEND READ"

# The CLI, run from OUTSIDE any pane: it derives the app's socket from the
# harness's private $XDG_RUNTIME_DIR.
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

# An interactive POSIX shell in the one pane, with a prompt we can find.
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
hl_check "K3 the app serves its socket" $?

pane_id() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"].get("id", "")
for w in d["windows"]:
    for t in w["tabs"]:
        for i in walk(t["splits"]):
            if i: print(i); sys.exit(0)
' 2>/dev/null
}
have_pane() { [ -n "$(pane_id)" ]; }
hl_wait_for 20 have_pane
pid=$(pane_id)
[ -n "$pid" ]
hl_check "K4 +list names the pane's id" $? "id=$pid"
[ -n "$pid" ] || hl_finish "CLI SEND READ"

# read_has <regex>: the pane's +read text has a line matching it.
read_has() { cli +read --name="$pid" --lines=200 2>/dev/null | grep -Eq "$1"; }

hl_wait_for 20 read_has '^hl\$ '
hl_check "K5 +read shows the shell's prompt" $? "$(cli +read --name="$pid" --lines=5 2>&1 | tr '\n' '|' | head -c 200)"

# Text then a key, the shape an agent uses: the shell runs it.
out=$(cli +send-keys --target="$pid" 'echo K6_$((40+2))' Enter 2>&1)
hl_check "K6a +send-keys text Enter exits 0" $? "$out"
hl_wait_for 10 read_has '^K6_42$'
hl_check "K6 the shell ran the sent command (its output K6_42 is on screen)" $? "$(cli +read --name="$pid" --lines=6 2>&1 | tr '\n' '|' | head -c 300)"

# A trailing \n in the text is a keypress, and an interior one is content
# (docs/claude/cli.md): the shell, which never asked for bracketed paste,
# runs both lines.
cli +send-keys --target="$pid" 'echo K7_A\necho K7_B\n' > /dev/null 2>&1
k7_both() { read_has '^K7_A$' && read_has '^K7_B$'; }
hl_wait_for 10 k7_both
hl_check "K7 a two-line send runs both lines in an unbracketed shell" $? "$(cli +read --name="$pid" --lines=8 2>&1 | tr '\n' '|' | head -c 300)"

# A bare key: C-c abandons a half-typed line.
cli +send-keys --target="$pid" 'echo K8_NEVER' > /dev/null 2>&1
cli +send-keys --target="$pid" C-c > /dev/null 2>&1
cli +send-keys --target="$pid" 'echo K8_AFTER' Enter > /dev/null 2>&1
hl_wait_for 10 read_has '^K8_AFTER$'
r=$?
read_has '^K8_NEVER$'; never=$?
[ $r = 0 ] && [ $never != 0 ]
hl_check "K8 C-c is delivered as a key: the abandoned line never ran" $? "after=$r never_ran=$([ $never = 0 ] && echo yes || echo no)"

# --lines tails: 3 lines of 'seq 1 30' end in 30, and do not reach 27.
cli +send-keys --target="$pid" 'seq 1 30; echo K9_DONE' Enter > /dev/null 2>&1
hl_wait_for 10 read_has '^K9_DONE$'
tail3=$(cli +read --name="$pid" --lines=4 2>/dev/null)
echo "$tail3" | grep -q '^30$' && ! echo "$tail3" | grep -q '^27$'
hl_check "K9 +read --lines=4 returns only the tail" $? "$(echo "$tail3" | tr '\n' '|')"

# On the wire: a program that enables bracketed paste gets the text framed
# and the Enter bare after the closing fencepost - the property that makes
# '"msg" Enter' submit in a TUI composer (T428).
raw="$HL_RUNTIME/raw.py"
hexout="$HL_RUNTIME/raw.hex"
cat > "$raw" <<'PY'
import os, sys, termios, tty, time
out = sys.argv[1]
fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
sys.stdout.write("\x1b[?2004hRAW_READY\r\n"); sys.stdout.flush()
buf = b""
deadline = time.time() + 15
try:
    while time.time() < deadline and not buf.endswith(b"\r"):
        os.set_blocking(fd, False)
        try:
            chunk = os.read(fd, 4096)
            if chunk: buf += chunk
        except BlockingIOError:
            time.sleep(0.02)
finally:
    os.set_blocking(fd, True)
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    sys.stdout.write("\x1b[?2004l"); sys.stdout.flush()
open(out, "w").write(buf.hex())
PY
cli +send-keys --target="$pid" "python3 $raw $hexout" Enter > /dev/null 2>&1
hl_wait_for 15 read_has 'RAW_READY'
hl_check "K10 the bracketed-paste probe is running" $?
cli +send-keys --target="$pid" 'hello' Enter > /dev/null 2>&1
hl_wait_for 15 test -s "$hexout"
want=$(printf '\033[200~hello\033[201~\r' | od -An -tx1 | tr -d ' \n')
got=$(cat "$hexout" 2>/dev/null)
[ "$got" = "$want" ]
hl_check "K11 '\"hello\" Enter' arrives as ESC[200~hello ESC[201~ CR, byte for byte" $? "got=$got want=$want"

# Refusals name the problem and fail.
out=$(cli +send-keys --target=no-such-pane 'x' 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "target 'no-such-pane' not found"
hl_check "K12 +send-keys to an unknown target fails and says so" $? "rc=$rc $out"
out=$(cli +read --name=no-such-pane 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "pane 'no-such-pane' not found"
hl_check "K13 +read of an unknown pane fails and says so" $? "rc=$rc $out"

# From inside the pane, $GHOZTTY_PANE_ID is a valid +read target.
cli +send-keys --target="$pid" "'$app' +read --name=\"\$GHOZTTY_PANE_ID\" --lines=1 > /dev/null && echo K14_OK" Enter > /dev/null 2>&1
hl_wait_for 10 read_has '^K14_OK$'
hl_check "K14 a pane reads itself through \$GHOZTTY_PANE_ID" $? "$(cli +read --name="$pid" --lines=4 2>&1 | tr '\n' '|' | head -c 300)"

if grep -qE '^(panic|thread [0-9]+ panic)|reached unreachable' "$APP_LOG"; then
    grep -m5 -E 'panic|unreachable' "$APP_LOG"
    hl_check "K15 no panic in the app log" 1
else
    hl_check "K15 no panic in the app log" 0
fi

hl_finish "CLI SEND READ"
