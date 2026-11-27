#!/usr/bin/env bash
# cli-seat.sh - T3713: the checks the headless Weston could never answer for
# want of a wl_seat, run on the seat compositor (hl_start_seat, headless sway)
# with a keyboard held on the seat (hl_seat_keyboard):
#
#   - window activation: a +new-window --focus is ACTIVATED (GTK's is-active
#     follows keyboard focus, which a seat with no keyboard never gives), and
#     a --focus on an existing, older window raises it too;
#   - real keys: text typed through the seat's keyboard (wtype) lands in the
#     focused pane - not the debug press-key seam, the real wl_keyboard path;
#   - a popover stays open: the sidebar's window menu is still up a moment
#     after it pops (Weston headless closes it at once, for want of a grab).
#
# Not here: a real pointer drag. The seat has no pointer device, and wtype
# only makes keyboards - T3847 tracks a held virtual pointer.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-seat.sh
#
# Everything runs inside the private headless sway (test/linux/lib/headless.sh),
# so no window ever reaches WSLg or the user's desktop.
#
# NEGATIVE=1 never takes the keyboard, and must fail S6, S7 and S8: the
# activation checks, and the typing (each wtype call brings its own
# short-lived keyboard, but with no raise the text lands in another window).
#
# Output: one PASS/FAIL line per check, then 'CLI SEAT: ALL PASS' or
# 'CLI SEAT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI SEAT"

log=/tmp/cli-seat-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start_seat
hl_check "S2 a private headless sway (a seat) is up" $?
[ "${HL_COMPOSITOR:-}" = sway ] || hl_finish "$L"
# Tabbed, so every window keeps the output's full size and the sidebar stays
# expanded (tiled side by side, six windows leave each too narrow for it).
swaymsg 'workspace_layout tabbed' > /dev/null 2>&1
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

fixture="$HL_RUNTIME/seat-fixture"
mkdir -p "$fixture/proj"
export SHELL=/bin/sh
export HOME="$fixture"

rm -f "$sock"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    --macos-pane-sidebar=expanded \
    --working-directory="$fixture/proj" -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
s3=$?
hl_check "S3 the app serves its socket" $s3
[ $s3 = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }
swaymsg 'layout tabbed' > /dev/null 2>&1

windows() { cli +list --json 2>/dev/null | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)["data"]["windows"]))' 2>/dev/null; }
# pane_of <window-target>: that window's first pane id.
pane_of() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if (w.get("target") or "") != sys.argv[1]: continue
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            print(l["id"]); sys.exit(0)
' "$1" 2>/dev/null
}
nact() { grep -a -c 'focus: the compositor activated the window' "$APP_LOG"; }
ndec() { grep -a -c 'focus: the compositor declined to activate the window' "$APP_LOG"; }
# new_window <target> [--focus]: open it and wait until +list has it.
new_window() {
    local n; n=$(windows)
    cli +new-window "--target=$1" "--title=$1" ${2:-} > /dev/null 2>&1
    more() { [ "$(windows)" -gt "$n" ]; }
    hl_wait_for 10 more
}

# ---- 1. the control: a seat with no keyboard ----------------------------------
# sway focuses each new window itself, but no wl_keyboard.enter ever arrives,
# so GTK never calls the window active and the app logs a decline.
hl_seat_has_keyboard
[ $? != 0 ]
hl_check "S4 the bare seat has no keyboard" $? "$(swaymsg -t get_seats 2>&1 | tr -d ' \n' | head -c 200)"
d0=$(ndec)
new_window s0 --focus
more_dec() { [ "$(ndec)" -gt "$d0" ]; }
hl_wait_for 5 more_dec
hl_check "S5 control: with no keyboard, +new-window --focus is declined" $? "declined=$d0->$(ndec) activated=$(nact)"

# ---- 2. a held keyboard: activation ------------------------------------------
if [ "${NEGATIVE:-0}" = 1 ]; then echo "NEGATIVE=1: no keyboard is taken"; else hl_seat_keyboard; fi
a0=$(nact)
new_window k1 --focus
more_act() { [ "$(nact)" -gt "$a0" ]; }
hl_wait_for 5 more_act
hl_check "S6 with a keyboard on the seat, +new-window --focus is activated" $? "activated=$a0->$(nact) declined=$(ndec) seat=$(swaymsg -t get_seats 2>&1 | tr -d ' \n' | head -c 160)"
# The older window: --focus on a target that exists raises it (sway's
# focus_on_window_activation is `focus` under hl_start_seat).
# Let k1's own map and activation settle first: a raise sent while sway is
# still focusing the window it just mapped is lost (measured: declined).
sleep 2
a0=$(nact)
cli +new-window --target=s0 --focus > /dev/null 2>&1
hl_wait_for 5 more_act
hl_check "S7 --focus on an existing, older window activates it" $? "activated=$a0->$(nact) declined=$(ndec)"

# ---- 3. real keys reach the focused pane -------------------------------------
p0=$(pane_of s0)
mark="seat-keys-$$"
wtype "echo $mark-ok" > /dev/null 2>&1
wtype -k Return > /dev/null 2>&1
typed() { cli +read --name="$p0" --lines=40 2>/dev/null | grep -q "^$mark-ok"; }
hl_wait_for 5 typed
hl_check "S8 text typed through the seat's keyboard runs in the focused pane" $? "pane=$p0 read=$(cli +read --name="$p0" --lines=6 2>&1 | tr '\n' '|' | head -c 240)"

# ---- 4. a popover stays open --------------------------------------------------
sb() { local t=$1; shift; hl_ipc pane-sidebar "--target=$t" "$@" 2>/dev/null; }
field() {
    local t=$1 e=$2; shift 2
    sb "$t" "$@" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
s = d.get("sidebar") or {}
r = s.get("rows") or []
m = s.get("menu") or {}
def head(label):
    return next((x for x in r if x["label"] == label and x["kind"] == "window"), {})
print(eval(sys.argv[1]))
' "$e" 2>/dev/null
}
[ "$(field s0 's.get("all_windows")')" = True ] || sb s0 --click=scope > /dev/null
allw() { [ "$(field s0 '(s.get("all_windows"), bool(head("k1")))')" = "(True, True)" ]; }
hl_wait_for 10 allw
row=$(field s0 'head("k1").get("pane", "")')
[ -n "$row" ] && [ "$(field s0 'm.get("popped")' "--menu=$row")" = True ]
hl_check "S9 the sidebar's window menu pops" $? "row=$row $(sb s0 | head -c 300)"
sleep 1.5
[ "$(field s0 '(m.get("row"), m.get("popped"))')" = "('$row', True)" ]
hl_check "S10 ...and is still open 1.5s later (a seat grants the popover its grab)" $? "$(field s0 'm')"

# Nothing above crashed the app.
kill -0 "$APP" 2>/dev/null
hl_check "S11 the app is still running" $?
! grep -Eq 'panic|reached unreachable' "$APP_LOG"
hl_check "S12 no panic in the app's log" $? "$(grep -Em3 'panic|unreachable' "$APP_LOG" | tr '\n' ' ')"

hl_finish "$L"
