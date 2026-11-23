#!/usr/bin/env bash
# gtk-smoke.sh - L1 (T3330) acceptance: the GTK debug build compiles, opens a
# window and runs a shell. Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\gtk-smoke.sh
#
# (-Repo clone, the default, builds the committed HEAD in ~/ghoztty-l; add
# -Repo mnt to build the live tree at /mnt speed.)
#
# The window opens in a PRIVATE headless Weston (test/linux/lib/headless.sh:
# its own XDG_RUNTIME_DIR and socket), never in WSLg, so nothing ever appears
# on - or takes focus from - the user's Windows desktop (go.md: NEVER PULL FOCUS FROM THE USER). glxinfo talks
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
# unless asked (measured 2026-11-21). Since T3350 the APP asks on its own, so
# nothing here exports GALLIUM_DRIVER: S9-S12 prove the app's default, and
# glxinfo just reports both renderers for the record.
unset GALLIUM_DRIVER MESA_LOADER_DRIVER_OVERRIDE LIBGL_ALWAYS_SOFTWARE
dxg=0; [ -e /dev/dxg ] && dxg=1
echo "INFO /dev/dxg present: $dxg"
echo "INFO glxinfo default: $(DISPLAY=:0 glxinfo -B 2>/dev/null | grep 'OpenGL renderer string' | sed 's/.*: //')"
[ $dxg = 1 ] && echo "INFO glxinfo GALLIUM_DRIVER=d3d12: $(DISPLAY=:0 GALLIUM_DRIVER=d3d12 glxinfo -B 2>/dev/null | grep 'OpenGL renderer string' | sed 's/.*: //')"

# The private headless compositor is the shared harness (T3333): it refuses to
# launch anything while the environment could still reach WSLg.
. "$PWD/test/linux/lib/headless.sh"
hl_start
check "S4 a private headless Weston is up" $? "$(tail -2 "${HL_WESTON_LOG:-/dev/null}" 2>/dev/null)"

app=$(hl_ghoztty) || app=./zig-out/bin/ghoztty
mark="$HL_RUNTIME/shell-ran"
hl_launch APP timeout 30 "$app" --gtk-single-instance=false -e /bin/sh -c "env > $mark.env; tty > $mark; sleep 60"
apid=$APP
applog=$APP_LOG
hl_wait_for 20 test -s "$mark"
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

# T3350: on WSL the app picks the GPU itself, and keeps that choice to itself.
if [ $dxg = 1 ]; then
    grep -q 'wslg: setting GALLIUM_DRIVER=d3d12' "$applog"
    check "S9 the app set GALLIUM_DRIVER=d3d12 on its own (/dev/dxg present, nothing exported)" $?
    r=$(grep -m1 'loaded OpenGL' "$applog" | sed 's/.*renderer=//')
    case "$r" in *D3D12*) true ;; *) false ;; esac
    check "S10 with no override exported, the app renders on the GPU (D3D12)" $? "renderer=$r"
    [ -s "$mark.env" ] && ! grep -q '^GALLIUM_DRIVER=' "$mark.env"
    check "S11 the window's shell did not inherit the app's GALLIUM_DRIVER" $? "$(grep '^GALLIUM_DRIVER=' "$mark.env" 2>/dev/null)"
else
    ! grep -q 'wslg: setting' "$applog"
    check "S9 without /dev/dxg the app leaves Mesa's driver choice alone" $?
fi

hl_stop

# T3350: a driver the user chose wins - here llvmpipe, which the app must keep
# (and leave in the shell's environment, since it was the user's). A FRESH
# harness: the window's shell runs under the ghoztty-agent the first app
# spawned, with that agent's environment, so a second app on the same harness
# would hand its shell to an agent that never saw the user's variable.
if [ $dxg = 1 ]; then
    hl_start
    check "S4b a second private headless Weston is up" $?
    umark="$HL_RUNTIME/user-shell-ran"
    hl_launch UAPP env GALLIUM_DRIVER=llvmpipe timeout 30 "$app" --gtk-single-instance=false -e /bin/sh -c "env > $umark.env; tty > $umark; sleep 60"
    hl_wait_for 20 test -s "$umark"
    hl_wait_for 10 grep -q 'loaded OpenGL' "$UAPP_LOG"
    r=$(grep -m1 'loaded OpenGL' "$UAPP_LOG" | sed 's/.*renderer=//')
    case "$r" in *llvmpipe*) true ;; *) false ;; esac && grep -q 'wslg: GPU driver left to the environment' "$UAPP_LOG"
    check "S12 a user's GALLIUM_DRIVER=llvmpipe wins over the app's default" $? "renderer=$r"
    grep -q '^GALLIUM_DRIVER=llvmpipe$' "$umark.env"
    check "S13 the user's GALLIUM_DRIVER still reaches the shell" $? "$(grep '^GALLIUM_DRIVER=' "$umark.env" 2>/dev/null || echo 'not in the shell env')"
    hl_stop
fi

if [ $fails = 0 ]; then echo "GTK SMOKE: ALL PASS"; exit 0; fi
echo "GTK SMOKE: $fails FAILURE(S)"; exit 1
