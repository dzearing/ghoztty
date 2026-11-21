#!/usr/bin/env bash
# gtk-smoke.sh - L1 (T3330) acceptance: the GTK debug build compiles, opens a
# window and runs a shell. Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\gtk-smoke.sh
#
# (-Repo clone, the default, builds the committed HEAD in ~/ghoztty-l; add
# -Repo mnt to build the live tree at /mnt speed.)
#
# The window opens in a PRIVATE headless Weston (its own XDG_RUNTIME_DIR and
# socket), never in WSLg, so nothing ever appears on - or takes focus from - the
# user's Windows desktop (go.md: NEVER PULL FOCUS FROM THE USER). glxinfo talks
# to WSLg's XWayland but maps no window.
#
# Prerequisite: scripts/linux/setup-distro.sh has run once.
# Output: one PASS/FAIL line per check, then 'GTK SMOKE: ALL PASS' or
# 'GTK SMOKE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
fails=0
check() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1${3:+ - $3}"; fails=$((fails+1)); fi; }

log=/tmp/gtk-smoke-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
check "S1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || { echo "GTK SMOKE: $fails FAILURE(S)"; exit 1; }

file zig-out/bin/ghoztty | grep -q 'ELF 64-bit.*x86-64'
check "S2 zig-out/bin/ghoztty is a Linux x86-64 ELF" $?

# Debug and release must never share an endpoint (T243/T350): the debug app id
# carries -debug, and that is what the build baked.
grep -aq 'com\.dzearing\.ghoztty-debug' zig-out/bin/ghoztty
check "S3 the debug build's application id is com.dzearing.ghoztty-debug" $?

# WSLg's GPU path: Mesa ships the d3d12 Gallium driver, but picks llvmpipe
# unless asked (measured 2026-11-21). Use the GPU when /dev/dxg exists.
gpu=""
if [ -e /dev/dxg ]; then export GALLIUM_DRIVER=d3d12; gpu=" (GALLIUM_DRIVER=d3d12)"; fi
echo "INFO glxinfo$gpu: $(DISPLAY=:0 glxinfo -B 2>/dev/null | grep 'OpenGL renderer string' | sed 's/.*: //')"

export XDG_RUNTIME_DIR=/tmp/gtk-smoke-xdg
rm -rf "$XDG_RUNTIME_DIR"; mkdir -m 0700 "$XDG_RUNTIME_DIR"
unset DISPLAY
weston --backend=headless --renderer=gl --socket=wayland-smoke --width=1280 --height=800 --idle-time=0 > /tmp/gtk-smoke-weston.log 2>&1 &
wpid=$!
for _ in $(seq 1 100); do [ -S "$XDG_RUNTIME_DIR/wayland-smoke" ] && break; sleep 0.1; done
[ -S "$XDG_RUNTIME_DIR/wayland-smoke" ]
check "S4 a private headless Weston is up" $? "$(tail -2 /tmp/gtk-smoke-weston.log)"

export WAYLAND_DISPLAY=wayland-smoke GDK_BACKEND=wayland
mark=/tmp/gtk-smoke-shell-ran
rm -f "$mark"
applog=/tmp/gtk-smoke-app.log
timeout 30 ./zig-out/bin/ghoztty --gtk-single-instance=false \
    -e /bin/sh -c "tty > $mark; sleep 60" > "$applog" 2>&1 &
apid=$!
for _ in $(seq 1 200); do [ -s "$mark" ] && break; sleep 0.1; done
[ -s "$mark" ] && grep -q '^/dev/pts/' "$mark"
check "S5 the window's shell ran on a pty" $? "mark=$(cat "$mark" 2>/dev/null)"
sleep 1
kill -0 $apid 2>/dev/null
check "S6 the app is still running after the shell started" $?
grep -q 'loaded OpenGL' "$applog"
check "S7 the renderer loaded OpenGL" $?
echo "INFO app renderer: $(grep -m1 'loaded OpenGL' "$applog" | sed 's/.*loaded //')"
! grep -qE '^(panic|thread [0-9]+ panic)|reached unreachable' "$applog"
check "S8 no panic in the app log" $?

kill $apid 2>/dev/null; wait $apid 2>/dev/null
kill $wpid 2>/dev/null; wait $wpid 2>/dev/null
rm -rf "$XDG_RUNTIME_DIR" "$mark"

if [ $fails = 0 ]; then echo "GTK SMOKE: ALL PASS"; exit 0; fi
echo "GTK SMOKE: $fails FAILURE(S)"; exit 1
