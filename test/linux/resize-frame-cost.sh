#!/usr/bin/env bash
# resize-frame-cost.sh - T3792 measurement: what a live window-edge drag costs
# the GTK app per frame, on WSLg's d3d12 GL inside the private headless Weston
# (test/linux/lib/headless.sh renders Weston on d3d12; the app picks the GPU
# itself). The user reported the real-screen drag as "slow" and "weird"; this
# is the half of that question a lane can ask without the user's display.
#
# A shell sits at its prompt (the case the user hit: the grid reflows on every
# step, docs/reference/terminal-resize.md), the window edge is dragged in
# $STEPS steps through the debug-only window-size seam, and the pane-seen
# seam's `draw` block (src/apprt/gtk/draw_stats.zig) reports what the drag
# cost: draws and their mean/worst time, the core's resize work per configure,
# and the gap between frames while resizes were arriving.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\resize-frame-cost.sh
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'OPT=ReleaseSafe bash test/linux/resize-frame-cost.sh'
#
# OPT picks the build (Debug, default, or ReleaseSafe - an optimized build
# that keeps the debug seams and the debug endpoints; ReleaseFast compiles the
# seams out). A non-Debug build goes to its own prefix, never zig-out.
# NEGATIVE=1 sets GHOZTTY_TEST_DRAW_DELAY_MS=40 in the app, which sleeps in
# every draw, and must FAIL F4 alone: the budget can tell a slow frame.
# Output: the numbers, one PASS/FAIL line per check, then
# 'RESIZE FRAME COST: ALL PASS' or '... <n> FAILURE(S)'.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="RESIZE FRAME COST"
OPT=${OPT:-Debug}
STEPS=${STEPS:-40}; DX=${DX:-6}
# Budget for the worst draw during the drag. 16ms is one 60 Hz frame; a
# draw over it is a dropped frame on its own.
BUDGET_US=${BUDGET_US:-16000}

log=/tmp/resize-frame-cost-build-$OPT.log
if [ "$OPT" = Debug ]; then
    zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
    rc=$?; root=$PWD/zig-out
else
    root=/tmp/ghoztty-rfc-$OPT
    zig build -Dapp-runtime=gtk -Doptimize="$OPT" -fno-sys=gtk4-layer-shell --prefix "$root" > "$log" 2>&1
    rc=$?
fi
hl_check "F0 zig build -Dapp-runtime=gtk -Doptimize=$OPT exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "F0b a private headless Weston is up" $?
app="$root/bin/ghoztty"
case "$(file -b "$app" 2>/dev/null)" in ELF*) ;; *) echo "not a Linux ELF: $app"; hl_finish "$L" ;; esac

cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
printf 'window-width = 150\nwindow-height = 30\n' > "$cfg_dir/config.ghostty"
hl_home=$(mktemp -d /tmp/resize-frame-cost-home.XXXXXX)
printf 'PS1="$ "\n' > "$hl_home/.bashrc"

delay=""
[ "${NEGATIVE:-0}" = 1 ] && delay="GHOZTTY_TEST_DRAW_DELAY_MS=40"
hl_launch APP env $delay HOME="$hl_home" SHELL=/bin/bash "$app" --gtk-single-instance=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "F0c the app serves its socket" $?

first=$(hl_first_pane "$app")
ws() { hl_ipc window-size "--target=$first" "$@"; }
jget() { python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(eval(sys.argv[1]))' "$1" 2>/dev/null; }
seen() { hl_ipc pane-seen "--target=$first" "$@"; }
dstat() { printf '%s' "$1" | jget "[p for p in r['data']['panes'] if p['pane']=='$first'][0]['draw']$2"; }

# Let the first frames land, then start a fresh measurement.
for _ in $(seq 1 200); do seen | grep -q '"draw"' && break; sleep 0.1; done
sleep 1
w0=$(ws | jget 'r.get("width",0)'); h0=$(ws | jget 'r.get("height",0)')
seen --reset-draw > /dev/null

t0=$(date +%s%N)
for i in $(seq 1 "$STEPS"); do ws "--size=$((w0 - i * DX))x$h0" > /dev/null; done
t1=$(date +%s%N)
# Release: wait until no resize has arrived for 300ms, then read.
prev=-1
for _ in $(seq 1 50); do
    n=$(dstat "$(seen)" "['resizes']['count']"); [ "$n" = "$prev" ] && break; prev=$n; sleep 0.3
done
r=$(seen)
drag_ms=$(( (t1 - t0) / 1000000 ))
draws=$(dstat "$r" "['draws']['count']"); dmean=$(dstat "$r" "['draws']['mean_us']"); dmax=$(dstat "$r" "['draws']['max_us']")
rs=$(dstat "$r" "['resizes']['count']"); rmean=$(dstat "$r" "['resizes']['mean_us']"); rmax=$(dstat "$r" "['resizes']['max_us']")
gaps=$(dstat "$r" "['resize_gaps']['count']"); gmean=$(dstat "$r" "['resize_gaps']['mean_us']"); gmax=$(dstat "$r" "['resize_gaps']['max_us']")
echo "MEASURE opt=$OPT steps=$STEPS drag_ms=$drag_ms draws=$draws draw_mean_us=$dmean draw_max_us=$dmax resizes=$rs resize_mean_us=$rmean resize_max_us=$rmax gaps=$gaps gap_mean_us=$gmean gap_max_us=$gmax"
[ -n "$draws" ] || echo "  reply: $(printf '%s' "$r" | head -c 600) first=$first"
grep -m3 'renderer\|GL_RENDERER\|OpenGL' "$APP_LOG" | sed 's/^/  log: /'

[ "${rs:-0}" -ge $((STEPS / 2)) ] 2>/dev/null
hl_check "F1 the drag reached the terminal as resizes ($rs for $STEPS steps)" $?
[ "${draws:-0}" -ge "${rs:-1}" ] 2>/dev/null
hl_check "F2 every resize got a frame ($draws draws for $rs resizes)" $?
[ "${rmax:-999999}" -lt "$BUDGET_US" ] 2>/dev/null
hl_check "F3 the core's resize work stays inside a frame (worst ${rmax}us, budget ${BUDGET_US}us)" $?
[ "${dmax:-999999}" -lt "$BUDGET_US" ] 2>/dev/null
hl_check "F4 no draw during the drag overruns a frame (worst ${dmax}us, mean ${dmean}us, budget ${BUDGET_US}us)" $?

# F5: the person's real-screen reader (open.ps1 -DrawStats) reads this same
# block - proven here against the harness app (Debug builds only: it names
# ~/ghoztty-l/zig-out, open.ps1's build).
if [ "$OPT" = Debug ]; then
    ds_out=$(bash scripts/linux/draw-stats.sh 2>&1)
    printf '%s\n' "$ds_out" | grep -q '^DRAW STATS read (1 pane(s))' &&
        printf '%s\n' "$ds_out" | grep -q '^DRAW STATS pane=.* draws n=[1-9]'
    hl_check "F5 scripts/linux/draw-stats.sh reads the open app's draw block" $? "$(printf '%s' "$ds_out" | tr '\n' '|')"
fi

rm -rf "$hl_home"
hl_finish "$L"
