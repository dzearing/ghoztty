#!/usr/bin/env bash
# cli-close-focus.sh - L7c (T3367) acceptance for +close and the `focus`
# action against the GTK debug app. +close closes a pane (and its window when
# it was the last one) or a whole window with no confirmation; it is
# idempotent (a target nothing answers to succeeds), refuses a name panes in
# several other windows hold (T2250), and refuses over a dialog unless
# --force (T2938). `focus` - the ghoztty:// scheme's one action, which has no
# CLI verb on any platform - focuses an existing pane or window and never
# creates one. Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-close-focus.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop.
#
# Output: one PASS/FAIL line per check, then 'CLI CLOSE FOCUS: ALL PASS' or
# 'CLI CLOSE FOCUS: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI CLOSE FOCUS"

log=/tmp/cli-close-focus-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "F1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "F2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
cli_as() { local id=$1; shift; env -u GHOZTTY_IPC_SOCKET GHOZTTY_PANE_ID="$id" "$app" "$@"; }

# focus_raw [target]: send the `focus` wire action straight to the socket, as
# the URL launcher does (there is no CLI verb to send it with). Prints the
# reply JSON.
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
# The window named 'dlg' opens with its close confirmation up (a debug-only
# seam: Wayland gives a test no input to press the close shortcut with).
export GHOZTTY_TEST_ASK_TO_CLOSE=dlg
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_ASK_TO_CLOSE
hl_wait_for 30 test -S "$sock"
hl_check "F3 the app serves its socket" $?

# summary: one line per window, 'target|focused|leaf-name:focused,...'
summary() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    leaves = [l for t in w["tabs"] for l in walk(t["splits"])]
    print("%s|%s|%s" % (w.get("target") or "", int(bool(w.get("focused"))),
        ",".join("%s:%d" % (l.get("name", ""), int(bool(l.get("focused")))) for l in leaves)))
' 2>/dev/null
}
id_of() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
want_w, want_p = sys.argv[1], sys.argv[2]
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if (w.get("target") or "") != want_w: continue
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if want_p == "*" or l.get("name") == want_p:
                print(l["id"]); sys.exit(0)
' "$1" "$2" 2>/dev/null
}
windows() { summary | wc -l; }
has_window() { summary | cut -d'|' -f1 | grep -qx "$1"; }
no_window() { ! has_window "$1"; }
leaves_in() { summary | awk -F'|' -v w="$1" '$1 == w { print $3 }' | tr ',' '\n' | grep -c .; }
leaves_are() { [ "$(leaves_in "$1")" = "$2" ]; }
# pane_focused <window> <pane-name>: 1 when +list marks that pane focused.
pane_focused() { summary | awk -F'|' -v w="$1" '$1 == w { print $3 }' | tr ',' '\n' | grep -qx "$2:1"; }
window_focused() { summary | grep -q "^$1|1|"; }
dump() { summary | tr '\n' ' '; }

have_window() { [ "$(windows)" -ge 1 ]; }
hl_wait_for 20 have_window
first=$(summary | head -1 | cut -d'|' -f1)
[ -n "$first" ]
hl_check "F4 +list names the startup window" $? "$(dump)"

# --- +close -----------------------------------------------------------------

out=$(cli +close 2>&1); rc=$?
[ $rc != 0 ]
hl_check "C1 +close with no --target fails" $? "rc=$rc out=$out"

out=$(cli +close --target=nothing-is-called-this 2>&1); rc=$?
[ $rc = 0 ] && [ "$(windows)" = 1 ]
hl_check "C2 +close of a name nothing holds succeeds and closes nothing (idempotent)" $? "rc=$rc out=$out $(dump)"

cli +split --name=side > /dev/null 2>&1
hl_wait_for 10 leaves_are "$first" 2
hl_check "C3a +split --name=side gives the window two panes" $? "$(dump)"
out=$(cli +close --target=side 2>&1); rc=$?
hl_wait_for 10 leaves_are "$first" 1
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ] && ! summary | grep -q 'side:'
hl_check "C3 +close --target=side closes that pane and leaves the window" $? "rc=$rc out=$out $(dump)"

out=$(cli +close --target=side 2>&1); rc=$?
[ $rc = 0 ] && leaves_are "$first" 1 && [ "$(windows)" = 1 ]
hl_check "C4 closing it again succeeds and closes nothing" $? "rc=$rc out=$out $(dump)"

out=$(cli +split 2>&1)
pid=$(echo "$out" | grep -Eo '[0-9A-Fa-f]{8}-[0-9A-Fa-f-]{27}' | head -1)
hl_wait_for 10 leaves_are "$first" 2
[ -n "$pid" ]
hl_check "C5a an unnamed +split reports its pane id" $? "out=$out"
out=$(cli +close --target="$pid" 2>&1); rc=$?
hl_wait_for 10 leaves_are "$first" 1
hl_check "C5 +close by pane id closes that pane" $? "rc=$rc out=$out $(dump)"

# T2250: a pane name in two windows is ambiguous from outside both.
cli +new-window --target=wa > /dev/null 2>&1
hl_wait_for 15 has_window wa
cli +split --target=wa --name=dup > /dev/null 2>&1
cli +new-window --target=wb > /dev/null 2>&1
hl_wait_for 15 has_window wb
cli +split --target=wb --name=dup > /dev/null 2>&1
both() { leaves_are wa 2 && leaves_are wb 2; }
hl_wait_for 15 both
hl_check "C6a windows wa and wb each hold a pane named dup" $? "$(dump)"
out=$(cli +close --target=dup 2>&1); rc=$?
sleep 0.5
[ $rc != 0 ] && echo "$out" | grep -q "wa" && echo "$out" | grep -q "wb" && both
hl_check "C6 +close --target=dup from outside both fails, names both windows, closes neither" $? "rc=$rc out=$out $(dump)"

wa_main=$(cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if w.get("target") != "wa": continue
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if l.get("name") != "dup": print(l["id"]); sys.exit(0)
' 2>/dev/null)
out=$(cli_as "$wa_main" +close --target=dup 2>&1); rc=$?
hl_wait_for 10 leaves_are wa 1
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ] && leaves_are wb 2
hl_check "C7 from inside wa, +close --target=dup closes wa's own and leaves wb's" $? "rc=$rc out=$out caller=$wa_main $(dump)"

cli +new-window --target=solo > /dev/null 2>&1
hl_wait_for 15 has_window solo
solo_pane=$(id_of solo '*')
out=$(cli +close --target="$solo_pane" 2>&1); rc=$?
hl_wait_for 10 no_window solo
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ]
hl_check "C8 closing a window's last pane closes the window" $? "rc=$rc pane=$solo_pane out=$out $(dump)"

out=$(cli +close --target=wb 2>&1); rc=$?
hl_wait_for 10 no_window wb
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ] && has_window wa && has_window "$first"
hl_check "C9 +close --target=<window> closes the window and all its panes, and only it" $? "rc=$rc out=$out $(dump)"

out=$(cli +close --target=wb 2>&1); rc=$?
[ $rc = 0 ]
hl_check "C10 closing the closed window again succeeds" $? "rc=$rc out=$out"

# T2938: a close confirmation up over the window.
cli +new-window --target=dlg -e sleep 600 > /dev/null 2>&1
hl_wait_for 15 has_window dlg
hl_check "D1a window dlg opens (with its close confirmation up)" $? "$(dump)"
out=$(cli +close --target=dlg 2>&1); rc=$?
sleep 0.5
[ $rc != 0 ] && echo "$out" | grep -q "waiting on a close confirmation" && has_window dlg
hl_check "D1 +close over a confirmation closes nothing and says why" $? "rc=$rc out=$out $(dump)"
out=$(cli +close --target=dlg --force 2>&1); rc=$?
hl_wait_for 10 no_window dlg
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ]
hl_check "D2 +close --force dismisses the confirmation and closes the window" $? "rc=$rc out=$out $(dump)"
grep -q "panic\|reached unreachable" "$APP_LOG"
[ $? != 0 ]
hl_check "D3 the app logged no panic" $? "$(grep -m3 'panic\|unreachable' "$APP_LOG")"

# --- focus ------------------------------------------------------------------

out=$(focus_raw)
echo "$out" | grep -q '"success":false' && echo "$out" | grep -q -- "--target is required for focus"
hl_check "G1 focus with no target fails and says --target is required" $? "out=$out"

n=$(windows)
out=$(focus_raw nothing-is-called-this)
echo "$out" | grep -q '"success":false' && echo "$out" | grep -q "not found" && [ "$(windows)" = "$n" ]
hl_check "G2 focus of a name nothing holds says not found and opens nothing" $? "out=$out $(dump)"

# Within a window: the pane focus moves to the target.
cli +split --target=wa --name=fa > /dev/null 2>&1
hl_wait_for 10 leaves_are wa 2
out=$(focus_raw fa)
echo "$out" | grep -q '"success":true'
hl_check "G3a focus --target=fa succeeds" $? "out=$out"
hl_wait_for 10 pane_focused wa fa
hl_check "G3 the focused pane is now fa" $? "$(dump)"
out=$(focus_raw "$wa_main")
hl_wait_for 10 pane_focused wa "$wa_main"
lrc=$?
f_off=1; pane_focused wa fa && f_off=0
[ $lrc = 0 ] && [ $f_off = 1 ]
hl_check "G4 focus by pane id moves the focus back off fa" $? "out=$out $(dump)"

# Across windows: the compositor decides whether a window is raised
# (xdg-activation); the reply is the same either way.
out=$(focus_raw "$first")
echo "$out" | grep -q '"success":true'
hl_check "G5 focus --target=<window> succeeds" $? "out=$out"
if hl_wait_for 10 window_focused "$first"; then
    echo "  note: the headless compositor granted the activation ($first is active)"
else
    echo "  note: the headless compositor did not activate $first: $(dump)"
fi

grep -q "panic\|reached unreachable" "$APP_LOG"
[ $? != 0 ]
hl_check "G6 the app logged no panic" $? "$(grep -m3 'panic\|unreachable' "$APP_LOG")"
kill -0 "$APP" 2>/dev/null
hl_check "G7 the app is still running" $?

hl_finish "$L"
