#!/usr/bin/env bash
# cli-rearrange.sh - L7d (T3368) acceptance for +rearrange against the GTK
# debug app. +rearrange --layout=<json> replaces a window's active-tab split
# layout with one whose every leaf names a pane already in it: panes MOVE (same
# shell, same id, same name), ratios land as given (percent, clamped 10-90), a
# pane the layout omits is closed with its shell (T128), focus stays on the
# focused pane when it survives and otherwise goes to the top-left one (T1371),
# and with no --target the CALLER's window is rearranged (T1079). Bad layouts
# are refused before anything moves. Run it ONLY through the wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-rearrange.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop.
#
# Output: one PASS/FAIL line per check, then 'CLI REARRANGE: ALL PASS' or
# 'CLI REARRANGE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI REARRANGE"

log=/tmp/cli-rearrange-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "R1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "R2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
cli_as() { local id=$1; shift; env -u GHOZTTY_IPC_SOCKET GHOZTTY_PANE_ID="$id" "$app" "$@"; }

cat > "$HL_RUNTIME/focus.py" <<'PY'
import json, socket, struct, sys
path = sys.argv[1]
args = ["--target=" + t for t in sys.argv[2:]]
body = json.dumps({"action": "focus", "arguments": args}).encode()
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(10)
s.connect(path)
s.sendall(struct.pack(">I", len(body)) + body)
def need(n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c: raise SystemExit("short read")
        b += c
    return b
n = struct.unpack(">I", need(4))[0]
print(need(n).decode())
PY
focus_raw() { python3 "$HL_RUNTIME/focus.py" "$sock" "$@" 2>&1; }

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
hl_check "R3 the app serves its socket" $?

# list_py <mode> <window> [arg]: read +list once.
#   shape   - the window's active-tab tree as H30(a,V50(b,c)); a leaf is its
#             name (an unnamed pane's name is its id), a split its direction
#             initial and ratio percent.
#   focused - the focused leaf's name.
#   id/pid  - the id / shell pid of the leaf named [arg].
#   names   - every leaf name in every window, one per line.
list_py() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
mode, want = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
d = json.load(sys.stdin)["data"]
def shape(n):
    if n["type"] == "split":
        return "%s%d(%s,%s)" % (n["direction"][0].upper(), round(n["ratio"] * 100),
                                shape(n["left"]), shape(n["right"]))
    return n["terminal"].get("name", "")
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
if mode == "names":
    for w in d["windows"]:
        for t in w["tabs"]:
            for l in leaves(t["splits"]): print(l.get("name", ""))
    sys.exit(0)
for w in d["windows"]:
    if (w.get("target") or "") != want: continue
    tab = next((t for t in w["tabs"] if t.get("selected")), w["tabs"][0])
    if mode == "shape": print(shape(tab["splits"]))
    for l in leaves(tab["splits"]):
        if mode == "focused" and l.get("focused"): print(l.get("name", ""))
        if mode == "id" and l.get("name") == arg: print(l["id"])
        if mode == "pid" and l.get("name") == arg: print(l.get("pid") or "")
' "$@" 2>/dev/null
}
shape_of() { list_py shape "$1"; }
shape_is() { [ "$(shape_of "$1")" = "$2" ]; }
focused_is() { [ "$(list_py focused "$1")" = "$2" ]; }
has_window() { cli +list --json 2>/dev/null | grep -q "\"target\":\"$1\""; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
dead() { ! alive "$1"; }
dump() { echo "rw=$(shape_of rw) rx=$(shape_of rx) focused=$(list_py focused rw)"; }

# rw: three panes, a (unnamed - addressed by id), b right of it, c below b.
cli +new-window --target=rw > /dev/null 2>&1
hl_wait_for 15 has_window rw
a=$(list_py shape rw)
cli +split --target=rw --name=b > /dev/null 2>&1
cli +split --pane=b --name=c --direction=down > /dev/null 2>&1
hl_wait_for 15 shape_is rw "H50($a,V50(b,c))"
hl_check "R4a window rw holds a, b and c as H50(a,V50(b,c))" $? "$(dump)"
focused_is rw "$a"
hl_check "R4b the focus is on a (splits without --focus leave it there)" $? "$(dump)"

# rx: a second window, so a pane from elsewhere can be named.
cli +new-window --target=rx > /dev/null 2>&1
hl_wait_for 15 has_window rx
cli +split --target=rx --name=x > /dev/null 2>&1
rx_has_x() { [ -n "$(list_py id rx x)" ]; }
hl_wait_for 15 rx_has_x
hl_check "R4c window rx holds a pane named x" $? "$(dump)"

pid_b=$(list_py pid rw b)
pid_c=$(list_py pid rw c)
alive "$pid_b" && alive "$pid_c"
hl_check "R4d +list reports live shell pids for b and c" $? "b=$pid_b c=$pid_c"

# --- refusals: nothing moves ---------------------------------------------------

before=$(shape_of rw)
refused() { # refused <label> <expect-regex> <cli args...>
    local label=$1 want=$2; shift 2
    local out rc
    out=$(cli +rearrange "$@" 2>&1); rc=$?
    sleep 0.3
    [ $rc != 0 ] && echo "$out" | grep -Eqi -- "$want" && shape_is rw "$before"
    hl_check "$label" $? "rc=$rc out=$out $(dump)"
}
refused "E1 no --layout is refused" "layout" --target=rw
refused "E2 a layout that is not JSON is refused" "json|layout" --target=rw '--layout={not json'
refused "E3 a pane named twice is refused" "duplicate" --target=rw \
    '--layout={"direction":"horizontal","left":{"pane":"b"},"right":{"pane":"b"}}'
refused "E4 a pane nothing holds is refused" "not found" --target=rw \
    '--layout={"direction":"horizontal","left":{"pane":"b"},"right":{"pane":"nobody"}}'
refused "E5 a pane from another window is refused" "not in the target window" --target=rw \
    '--layout={"direction":"horizontal","left":{"pane":"b"},"right":{"pane":"x"}}'
refused "E6 a bad direction is refused" "direction" --target=rw \
    '--layout={"direction":"diagonal","left":{"pane":"b"},"right":{"pane":"c"}}'
refused "E7 an unknown --target is refused" "not found" --target=no-such-window \
    '--layout={"pane":"b"}'

# --- the move ------------------------------------------------------------------

out=$(cli +rearrange --target=rw "--layout={\"direction\":\"vertical\",\"ratio\":30,\"left\":{\"pane\":\"c\"},\"right\":{\"direction\":\"horizontal\",\"ratio\":70,\"left\":{\"pane\":\"b\"},\"right\":{\"pane\":\"$a\"}}}" 2>&1); rc=$?
hl_wait_for 10 shape_is rw "V30(c,H70(b,$a))"
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ]
hl_check "M1 +rearrange rebuilds rw as V30(c,H70(b,a)) with the given ratios" $? "rc=$rc out=$out $(dump)"
[ "$(list_py pid rw b)" = "$pid_b" ] && [ "$(list_py pid rw c)" = "$pid_c" ] && alive "$pid_b" && alive "$pid_c"
hl_check "M2 b and c MOVED: same shells, still running" $? "b=$pid_b->$(list_py pid rw b) c=$pid_c->$(list_py pid rw c)"
focused_is rw "$a"
hl_check "M3 the focus stayed on a, which survived" $? "$(dump)"
cli +send-keys --target=b 'echo M4_$((40+2))' Enter > /dev/null 2>&1
read_b() { cli +read --target=b --lines=20 2>/dev/null | grep -q 'M4_42'; }
hl_wait_for 10 read_b
hl_check "M4 b still answers to its name and runs what it is sent" $? "$(cli +read --target=b --lines=6 2>&1 | tr '\n' '|' | head -c 300)"
shape_of rx | grep -Eq '^H50\([^,]+,x\)$'
hl_check "M5 window rx is untouched (still H50(<its pane>,x))" $? "$(dump)"

# --- an omitted pane closes, and the focus moves off it ------------------------

focus_raw c > /dev/null
hl_wait_for 10 focused_is rw c
hl_check "O1a focus --target=c puts the focus on c" $? "$(dump)"
out=$(cli +rearrange --target=rw "--layout={\"direction\":\"horizontal\",\"ratio\":95,\"left\":{\"pane\":\"b\"},\"right\":{\"pane\":\"$a\"}}" 2>&1); rc=$?
hl_wait_for 10 shape_is rw "H90(b,$a)"
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ]
hl_check "O1 a layout without c gives H90(b,a) (ratio 95 clamps to 90)" $? "rc=$rc out=$out $(dump)"
! list_py names rw | grep -qx c
hl_check "O2 c is gone from +list" $? "$(list_py names rw | tr '\n' ' ')"
hl_wait_for 10 dead "$pid_c"
hl_check "O3 c's shell ended with it" $? "pid_c=$pid_c"
hl_wait_for 10 focused_is rw b
hl_check "O4 the focus went to the top-left pane, b" $? "$(dump)"

# --- no --target: the caller's window ------------------------------------------

out=$(cli_as "$a" +rearrange "--layout={\"pane\":\"$a\"}" 2>&1); rc=$?
hl_wait_for 10 shape_is rw "$a"
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ] && has_window rx && [ "$(list_py id rx x)" != "" ]
hl_check "C1 run from a with no --target, a single-pane layout rearranges rw, not rx" $? "rc=$rc out=$out $(dump)"
hl_wait_for 10 dead "$pid_b"
hl_check "C2 b, which that layout left out, closed with its shell" $? "pid_b=$pid_b"

grep -q "panic\|reached unreachable" "$APP_LOG"
[ $? != 0 ]
hl_check "P1 the app logged no panic" $? "$(grep -m3 'panic\|unreachable' "$APP_LOG")"
grep -q "GLib-GObject-CRITICAL\|Gtk-CRITICAL" "$APP_LOG"
[ $? != 0 ]
hl_check "P2 the app logged no GTK/GObject critical" $? "$(grep -m3 'CRITICAL' "$APP_LOG")"

hl_finish "$L"
