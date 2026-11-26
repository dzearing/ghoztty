#!/usr/bin/env bash
# wslg-display.sh - T3783 acceptance: a Linux app whose runtime dir has no
# Wayland socket (root under WSLg) reaches WSLg's compositor instead of falling
# back to an X11 window that d3d12 cannot draw to. Run it ONLY through the
# wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\wslg-display.sh
#
# It never touches the real WSLg: the debug build takes "WSLg's socket" from
# GHOZTTY_DEBUG_WSLG_SOCKET (src/apprt/gtk/wslg_display.zig), and here that is
# the harness's own private Weston. Every other harness test points it at a
# path that is never a socket, so no test can reach the user's desktop through
# the fallback (test/linux/lib/headless.sh).
#
#   W1-W2  control: no socket in the runtime dir and no "WSLg" socket - the app
#          cannot open a display (the bug's shape, minus the X11 the harness
#          forbids); proves W3 can fail.
#   W3-W7  the fix: same environment, "WSLg's" socket present - the app logs
#          the fallback, connects to it, runs its shell, logs no x11 shm error,
#          and the shell does not inherit the app's WAYLAND_DISPLAY override.
#   W8     the default user's shape (socket in the runtime dir) is left alone.
#
# Output: PASS/FAIL per check, then 'WSLG DISPLAY: ALL PASS' or
# 'WSLG DISPLAY: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init

app=$(hl_ghoztty) || { echo "WSLG DISPLAY: 1 FAILURE(S) (no Linux build; run zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell)"; exit 1; }
shell_cmd() { printf 'env > %s.env; tty > %s; sleep 60' "$1" "$1"; }

# ---- W1-W2: control ------------------------------------------------------------
hl_start
before=$(hl_weston_sockets)
cmark="$HL_RUNTIME/control"
hl_launch CAPP env -u WAYLAND_DISPLAY timeout 30 "$app" --gtk-single-instance=false -e /bin/sh -c "$(shell_cmd "$cmark")"
hl_wait_for 15 bash -c "! kill -0 $CAPP 2>/dev/null"
gone=$?
after=$(hl_weston_sockets)
[ $gone = 0 ] && [ ! -s "$cmark" ]
hl_check "W1 control: with no Wayland socket anywhere the app opens no window and exits" $? "exited=$([ $gone = 0 ] && echo yes || echo no) $(tail -1 "$CAPP_LOG" 2>/dev/null)"
[ "$after" -le "$before" ] && ! grep -q 'connecting to WSLg' "$CAPP_LOG"
hl_check "W2 control: nothing connected to the private Weston and no fallback was logged" $? "sockets $before -> $after"
hl_stop

# ---- W3-W7: the fix ----------------------------------------------------------------
hl_start
wslg="$HL_RUNTIME/$HL_SOCKET"
before=$(hl_weston_sockets)
mark="$HL_RUNTIME/fixed"
hl_launch APP env -u WAYLAND_DISPLAY GHOZTTY_DEBUG_WSLG_SOCKET="$wslg" timeout 30 "$app" --gtk-single-instance=false -e /bin/sh -c "$(shell_cmd "$mark")"
hl_wait_for 20 test -s "$mark"
grep -q "no Wayland socket at the runtime dir's wayland-0; connecting to WSLg's $wslg" "$APP_LOG"
hl_check "W3 the app logs that it fell back to WSLg's socket" $? "$(grep -m1 'wslg:.*Wayland' "$APP_LOG")"
after=$(hl_weston_sockets)
[ "$after" -gt "$before" ]
hl_check "W4 the app connected to that socket (its fds $before -> $after)" $?
[ -s "$mark" ] && grep -q '^/dev/pts/' "$mark"
hl_check "W5 the window's shell ran on a pty" $? "mark=$(cat "$mark" 2>/dev/null)"
! grep -qi 'x11 shm' "$APP_LOG" && ! grep -qE '^(panic|thread [0-9]+ panic)|reached unreachable' "$APP_LOG"
hl_check "W6 no x11 shm error and no panic in the app log" $? "shm=$(grep -ci 'x11 shm' "$APP_LOG")"
[ -s "$mark.env" ] && ! grep -q '^WAYLAND_DISPLAY=' "$mark.env"
hl_check "W7 the shell did not inherit the app's WAYLAND_DISPLAY override" $? "$(grep '^WAYLAND_DISPLAY=' "$mark.env" 2>/dev/null)"
hl_stop

# ---- W8: the default user's shape ------------------------------------------------------
hl_start
dmark="$HL_RUNTIME/default"
hl_launch DAPP env GHOZTTY_DEBUG_WSLG_SOCKET="$HL_RUNTIME/$HL_SOCKET" timeout 30 "$app" --gtk-single-instance=false -e /bin/sh -c "$(shell_cmd "$dmark")"
hl_wait_for 20 test -s "$dmark"
[ -s "$dmark" ] && ! grep -q 'connecting to WSLg' "$DAPP_LOG" && grep -q "^WAYLAND_DISPLAY=$HL_SOCKET\$" "$dmark.env"
hl_check "W8 a socket already in the runtime dir is used as-is, no fallback, and the shell keeps it" $? "$(grep -m1 'wslg:' "$DAPP_LOG")"

hl_finish "WSLG DISPLAY"
