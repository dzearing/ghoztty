#!/usr/bin/env bash
# window-workspace-fade.sh - T3651 acceptance for single-window mode's shade
# crossfade on the GTK debug app (docs/reference/window-modes.md "The
# hand-off" step 4; Linux L11k4; Mac deskEntrance/PaneDeskFade, win32 T3183).
#
# With `macos-window-mode = single`, elevated style:
# - the one toplevel draws the desk of the workspace ON SHOW, not its own;
# - a switch between two different gradients crossfades: the old desk drawn
#   over the new one and eased out over 0.35s - a frame from the middle of
#   it is the blend of the two at what is left of the old;
# - no fade between two workspaces with the same gradient, and none in the
#   flat style (no desk).
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-workspace-fade.sh
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'NEGATIVE=1 bash test/linux/window-workspace-fade.sh'
#
# NEGATIVE=1 runs the same steps in `separate` mode, where nothing is put on
# show and nothing fades: it must FAIL from F1 on.
#
# The debug build stretches the fade's clock with
# GHOZTTY_DEBUG_DESK_FADE_STRETCH (20 here: 7s), so frames from its middle can
# be captured; the curve and the 0.35s are the unit tests' (desk_fade.zig).
# Oracles: the debug-only `workspaces` seam (`desk`: the seed the toplevel
# last drew, the fade's state and counters; each row's `desk_seed`) and
# window captures from the app's own render (capture-pane --window).
# Output: one PASS/FAIL line per check, then 'WINDOW WORKSPACE FADE: ALL PASS'
# or 'WINDOW WORKSPACE FADE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="WINDOW WORKSPACE FADE"
NEGATIVE=${NEGATIVE:-0}

log=/tmp/window-workspace-fade-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "F0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "F0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }
alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
mode=single
[ "$NEGATIVE" = 1 ] && mode=separate
write_cfg() {
    {
        echo 'window-width = 90'
        echo 'window-height = 24'
        echo 'quit-after-last-window-closed = false'
        echo 'confirm-close-surface = false'
        echo "macos-window-mode = $mode"
        echo 'background = #203040'
        echo 'macos-window-gradient = ocean'
        echo 'macos-pane-glass = false'
        echo "macos-pane-style = $1"
    } > "$cfg_dir/config.ghostty"
}
write_cfg elevated
export SHELL=/bin/sh
export GHOZTTY_DEBUG_DESK_FADE_STRETCH=20

# ws <python expression over d (the seam's data), row (by window name), k
# (d["desk"] or {})>
WS_LAST=""
ws() {
    local expr="$1"; shift
    WS_LAST=$(hl_ipc workspaces "$@" 2>&1)
    printf '%s' "$WS_LAST" > "$XDG_RUNTIME_DIR/ws-last"
    printf '%s' "$WS_LAST" | python3 -I -c '
import json, sys
try:
    r = json.load(sys.stdin)
except Exception as e:
    print("unparsable:", e); sys.exit(1)
d = r.get("data") or {}
row = {o.get("window"): o for o in d.get("order") or []}
k = d.get("desk") or {}
try:
    print(eval(sys.argv[1]))
except Exception as e:
    print("err:", e)
' "$expr"
}
wsis() { local want="$1"; shift; [ "$(ws "$@")" = "$want" ]; }
last() { cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null; }

shot="$HL_RUNTIME/fade.png"
# probe <toplevel>: 'r g b r g b' at two points of the header bar's top rows,
# where nothing but the desk is drawn, from a capture of the whole toplevel.
probe() {
    hl_screenshot "$1" "$shot" --window > /dev/null 2>&1 || { echo off; return; }
    local w
    w=$(hl_png_stats "$shot" | sed -n 's/^w=\([0-9]*\).*/\1/p')
    [ -n "$w" ] || { echo off; return; }
    hl_png_pixel "$shot" $(( w / 4 )) 3 $(( w * 3 / 5 )) 3 | tr '\n' ' '
}
# between <k1> <k2> <old 6> <new 6> <mid 6>: every channel of mid is
# new + (old - new) * k/255 for some k in [k2, k1], within 6.
between() {
    python3 -I -c '
import sys
k1, k2 = int(sys.argv[1]), int(sys.argv[2])
v = [int(x) for x in sys.argv[3:21]]
old, new, mid = v[0:6], v[6:12], v[12:18]
for o, n, m in zip(old, new, mid):
    lo = n + (o - n) * min(k1, k2) / 255.0
    hi = n + (o - n) * max(k1, k2) / 255.0
    if not (min(lo, hi) - 6 <= m <= max(lo, hi) + 6): sys.exit(1)
' "$@"
}
# apart <6> <6>: the two probes differ by at least 24 summed over a point.
apart() {
    python3 -I -c '
import sys
v = [int(x) for x in sys.argv[1:13]]
a, b = v[0:6], v[6:12]
sys.exit(0 if max(sum(abs(a[i+j]-b[i+j]) for j in range(3)) for i in (0, 3)) >= 24 else 1)
' "$@"
}

# tinted <6>: both probes are a colour, not the stock header grey (r == g == b)
# that shows where no desk is drawn.
tinted() {
    python3 -I -c '
import sys
v = [int(x) for x in sys.argv[1:7]]
sys.exit(0 if all(max(v[i:i+3]) - min(v[i:i+3]) >= 8 for i in (0, 3)) else 1)
' "$@"
}

hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "F0c the app serves its socket" $?
hl_wait_for 10 wsis True 'd["toplevel_mapped"] or d["mode"] == "separate"'
first=$(ws 'd["toplevel"]')
[ "$NEGATIVE" = 1 ] && first=$(cli +list --json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"]["windows"][0].get("target") or "")')
echo "first window: $first"

# rnd has a gradient of its own; oc is on the shared ocean, like first.
cli +new-window --target=rnd --title=rnd --color=random > /dev/null 2>&1
cli +new-window --target=oc --title=oc > /dev/null 2>&1
hl_wait_for 10 wsis 3 'len(d["order"])'
rnd_seed=$(ws 'row["rnd"]["desk_seed"]')
wsis "('$first', True, True, 0, 0, True)" 'd["active"], row["rnd"]["parked"], row["oc"]["parked"], row["'$first'"]["desk_seed"], row["oc"]["desk_seed"], row["rnd"]["desk_seed"] != 0'
hl_check "F1 rnd (a gradient of its own) and oc (the ocean) open parked behind $first (the ocean)" $? "$(last)"

sleep 1
hl_wait_for 5 wsis "(True, 0, False)" 'k.get("drawn"), k.get("drawn_seed"), k.get("fade_on")'
hl_check "F2 the toplevel draws $first's desk (the ocean), no fade running" $? "$(last)"
old=$(probe "$first")
# shellcheck disable=SC2086
tinted $old
hl_check "F2b control: the header's top rows show the ocean desk" $? "probe=$old"

# ---- 1. a switch to another gradient crossfades ---------------------------
started0=$(ws 'k.get("fades_started", 0)')
wsis "(True, True, 0, $((started0 + 1)))" 'd["shown"], k.get("fade_on"), k.get("fade_from_seed"), k.get("fades_started")' --show=rnd
hl_check "F3 putting rnd on show starts a fade from the ocean (seed 0)" $? "$(last)"
grep -q "workspace shade fade from=0 to=$rnd_seed" "$APP_LOG"
hl_check "F3b ...logged with both gradients" $? "$(grep 'workspace shade' "$APP_LOG" | tail -3)"
hl_wait_for 5 wsis "$rnd_seed" 'k.get("drawn_seed")'
hl_check "F4 the toplevel now draws rnd's desk under the fade (the workspace on show's, not its own)" $? "$(last)"

sleep 2.5
k1=$(ws 'k.get("fade_keep", -1)')
mid=$(probe "$first")
k2=$(ws 'k.get("fade_keep", -1)')
fon=$(ws 'k.get("fade_on")')
echo "mid-fade probe: $mid (keep $k1 -> $k2)"
[ "$fon" = True ] && [ "$k1" -gt 0 ] && [ "$k1" -lt 255 ] && [ "$k2" -gt 0 ] && [ "$k2" -le "$k1" ]
hl_check "F5 mid-fade: what is left of the old desk is between none and all, and falling" $? "keep=$k1->$k2 on=$fon"

hl_wait_for 15 wsis False 'k.get("fade_on")'
hl_check "F6 the fade ends by itself (7s stretched)" $? "$(last)"
frames=$(ws 'k.get("fade_frames", 0)')
[ "$frames" -ge 10 ]
hl_check "F6b ...over many drawn frames, each with the old desk laid on ($frames)" $? "$(last)"
grep -q "workspace shade fade done frames=" "$APP_LOG"
hl_check "F6c ...logged done" $? "$(grep 'workspace shade' "$APP_LOG" | tail -3)"
new=$(probe "$first")
echo "rnd probe: $new"
# shellcheck disable=SC2086
apart $old $new && tinted $new
hl_check "F7 after the fade the desk is rnd's own gradient: not the ocean, and not the stock grey of no desk at all" $? "ocean=$old rnd=$new"
# shellcheck disable=SC2086
between "$k1" "$k2" $old $new $mid && apart $old $mid && apart $new $mid
hl_check "F8 the mid-fade frame is the old desk over the new at what was left of it (neither one alone)" $? "ocean=$old mid=$mid rnd=$new keep=$k1->$k2"

# ---- 2. same gradient, no fade --------------------------------------------
wsis "(True, True)" 'd["shown"], k.get("fade_on")' --show="$first"
hl_check "F9 back to $first (rnd -> ocean): a fade again" $? "$(last)"
hl_wait_for 15 wsis False 'k.get("fade_on")'
started1=$(ws 'k.get("fades_started", 0)')
wsis "(True, False, $started1, 0)" 'd["shown"], k.get("fade_on"), k.get("fades_started"), d["active"] and row[d["active"]]["desk_seed"]' --show=oc
hl_check "F10 $first -> oc, both the ocean: no fade (Mac: leavingShade != deskVariant)" $? "$(last)"
grep -q "workspace shade swap (no fade) from=0 to=0 elevated=true" "$APP_LOG"
hl_check "F10b ...logged as a swap" $? "$(grep 'workspace shade' "$APP_LOG" | tail -3)"

# ---- 3. the flat style has no desk ----------------------------------------
write_cfg flat
cli +reload --config > /dev/null 2>&1
sleep 1
wsis "(True, False, $started1)" 'd["shown"], k.get("fade_on"), k.get("fades_started")' --show=rnd
hl_check "F11 flat style: oc -> rnd swaps with no fade" $? "$(last)"
grep -q "workspace shade swap (no fade) from=0 to=$rnd_seed elevated=false" "$APP_LOG"
hl_check "F11b ...logged elevated=false" $? "$(grep 'workspace shade' "$APP_LOG" | tail -3)"

alive "$APP"; hl_check "F12 the app is alive" $?
grep -E "shade|workspace: show" "$APP_LOG" | tail -20
hl_finish "$L"
