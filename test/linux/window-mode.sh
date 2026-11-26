#!/usr/bin/env bash
# window-mode.sh - T3573 acceptance for single-window mode's launch latch on
# the GTK debug app (docs/reference/window-modes.md, Linux L11k; win32
# T3180/T3212): `macos-window-mode` is read ONCE, when the app starts. A
# reload whose file now says the other mode does not move it (and says so),
# and with `quit-after-last-window-closed = false` the first window opened
# while none is open is the next launch and reads the mode again.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-mode.sh
#
# The second launch (W6) is the negative control: the same app with the key
# unset must latch `separate`, so W1's `single` is the file talking and not a
# constant.
# Output: one PASS/FAIL line per check, then 'WINDOW MODE: ALL PASS' or
# 'WINDOW MODE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="WINDOW MODE"

log=/tmp/window-mode-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "W0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "W0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
cfg="$cfg_dir/config.ghostty"
write_cfg() {
    {
        echo 'window-width = 90'
        echo 'window-height = 24'
        echo 'quit-after-last-window-closed = false'
        [ -n "$1" ] && echo "macos-window-mode = $1"
    } > "$cfg"
}

export SHELL=/bin/sh

# ---- 1. the file's mode is latched at launch -------------------------------
write_cfg single
hl_launch APP "$app" --gtk-single-instance=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "W0c the app serves its socket" $?
grep -q 'window mode: single (latched at launch)' "$APP_LOG"
hl_check "W1 a config saying single latches single at launch" $? "$(grep -m2 'window mode' "$APP_LOG")"

# ---- 2. a reload that now says separate does not move it -------------------
write_cfg separate
o=$(cli +reload --config 2>&1); rc=$?
hl_check "W2 +reload --config succeeds" $rc "$o"
hl_wait_for 10 grep -q 'window mode: single in force; the config now says separate' "$APP_LOG"
hl_check "W3 the reload keeps single in force and names the next launch" $? "$(grep 'window mode' "$APP_LOG" | tail -3)"
! grep -q 'window mode: single -> separate' "$APP_LOG"
hl_check "W3b ...and nothing re-latched while the window is open" $?

# ---- 3. no window open: the next window is the next launch -----------------
p1=$(hl_first_pane "$app")
o=$(cli +close --target="$p1" --force 2>&1); rc=$?
hl_check "W4a +close --force on the only pane succeeds" $rc "$o"
hl_wait_for 10 sh -c "! $app +list --json 2>/dev/null | grep -q '\"pane\"'"
sleep 0.5
alive "$APP"
hl_check "W4b the app stays resident with no window (quit-after-last-window-closed = false)" $?
o=$(cli +new-window --target=again 2>&1); rc=$?
hl_check "W4c +new-window opens a window with none open" $rc "$o"
hl_wait_for 10 grep -q 'window mode: single -> separate (re-read with no window open)' "$APP_LOG"
hl_check "W5 that first window re-reads the mode: single -> separate" $? "$(grep 'window mode' "$APP_LOG" | tail -3)"

# A second window while one is open never re-latches.
write_cfg single
cli +reload --config > /dev/null 2>&1
cli +new-window --target=second > /dev/null 2>&1
sleep 1
[ "$(grep -c -- '-> ' <(grep 'window mode' "$APP_LOG"))" = 1 ]
hl_check "W5b a window opened beside an open one does not re-latch" $? "$(grep 'window mode' "$APP_LOG" | tail -4)"

# T3656: SIGTERM (a logout, `systemctl stop`) quits the app whatever
# quit-after-last-window-closed says - here it is false and two windows are
# open. It once logged "quitting" and stayed up for good; the KILL after a
# failed check only keeps hl_stop from waiting on a stuck app.
kill -TERM "$APP" 2>/dev/null
hl_wait_for 10 sh -c "! kill -0 $APP 2>/dev/null"
hl_check "W5c SIGTERM quits the resident app (quit-after-last-window-closed = false) within 10s" $? "$(grep -E 'SIGTERM|runloop' "$APP_LOG" | tail -3)"
grep -q 'received SIGTERM, quitting' "$APP_LOG"
hl_check "W5d ...and it is the SIGTERM handler that quit it" $?
kill -KILL "$APP" 2>/dev/null
hl_wait_for 10 sh -c "! kill -0 $APP 2>/dev/null"

# ---- 4. negative control: the key unset latches separate -------------------
write_cfg ''
rm -f "$(hl_socket)"
hl_launch APP2 "$app" --gtk-single-instance=false
hl_wait_for 30 test -S "$(hl_socket)"
grep -q 'window mode: separate (latched at launch)' "$APP2_LOG"
hl_check "W6 the same app with the key unset latches separate" $? "$(grep -m2 'window mode' "$APP2_LOG")"

hl_finish "$L"
