#!/usr/bin/env bash
# window-workspace-layout.sh - T3650 acceptance for single-window mode's
# parked layout on the GTK debug app (docs/reference/window-modes.md "Size";
# Linux L11k3; Mac prepareParkedContent / windowDidResize /
# layoutParkedContent; win32 T3193).
#
# With `macos-window-mode = single`, a PARKED workspace is laid out at the
# shared window's size:
# - 0.3s after a resize of the window settles, so its terminal's grid is
#   already the new one while it is parked (the shell saw the resize) and a
#   switch to it never changes that grid;
# - at once on a tree change (a +split into it while parked), so its old
#   pane takes its half right away and keeps it when shown.
# A terminal MADE while parked starts on first show (T3786), so the new
# pane's grid is only read after the show.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-workspace-layout.sh
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -Step 'NEGATIVE=1 bash test/linux/window-workspace-layout.sh'
#
# NEGATIVE=1 runs the same steps in `separate` mode, where nothing is parked
# and a resize of one window never reaches another: it must FAIL from Y1 on.
#
# Oracles: the debug-only `workspaces` seam (`grids`: each pane's
# "<cols>x<rows>", null before its terminal started), the `window-size` seam
# to resize the toplevel the way an edge drag would, and the app's log line
# `workspace: parked window=<w> laid out at <W>x<H> ... why=<resize|tree>`.
# Output: one PASS/FAIL line per check, then 'WINDOW WORKSPACE LAYOUT: ALL
# PASS' or 'WINDOW WORKSPACE LAYOUT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="WINDOW WORKSPACE LAYOUT"
NEGATIVE=${NEGATIVE:-0}

log=/tmp/window-workspace-layout-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "Y0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "Y0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
mode=single
[ "$NEGATIVE" = 1 ] && mode=separate
{
    echo 'window-width = 90'
    echo 'window-height = 24'
    echo 'quit-after-last-window-closed = false'
    echo 'confirm-close-surface = false'
    echo "macos-window-mode = $mode"
} > "$cfg_dir/config.ghostty"
export SHELL=/bin/sh

# ws <python expression over d (the seam's data), row (by window name)>
ws() {
    local expr="$1"; shift
    hl_ipc workspaces "$@" 2>&1 > "$XDG_RUNTIME_DIR/ws-last"
    python3 -I -c '
import json, sys
try:
    r = json.load(open(sys.argv[2]))
except Exception as e:
    print("unparsable:", e); sys.exit(1)
d = r.get("data") or {}
row = {o.get("window"): o for o in d.get("order") or []}
try:
    print(eval(sys.argv[1]))
except Exception as e:
    print("error:", e)
' "$expr" "$XDG_RUNTIME_DIR/ws-last"
}
wsis() { local want="$1"; shift; [ "$(ws "$@")" = "$want" ]; }
last() { cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null; }
# The grid of pane <i> of workspace <w> ("<cols>x<rows>" or None).
grid() { ws "(row.get('$1') or {}).get('grids', [None]*9)[$2]"; }
started() { local g; g=$(grid "$1" "$2"); [ -n "$g" ] && [ "$g" != None ] && [ "${g#error}" = "$g" ]; }
# The first pane id of the window called <target>.
pane_of() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if (w.get("target") or "") == sys.argv[1]:
        tab = next((t for t in w["tabs"] if t.get("selected")), w["tabs"][0])
        print(next(leaves(tab["splits"]))["id"]); break
' "$1" 2>/dev/null
}
log_lines() { wc -l < "$APP_LOG"; }
log_after() { tail -n +"$(( $1 + 1 ))" "$APP_LOG"; }
log_has() { log_after "$1" | grep -q "$2"; }
grid_is() { [ "$(grid "$1" "$2")" = "$3" ]; }
grid_not() { [ "$(grid "$1" "$2")" != "$3" ]; }

hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "Y0c the app serves its socket" $?
hl_wait_for 10 wsis True 'd["toplevel_mapped"] or d["mode"] == "separate"'
first=$(ws 'd["toplevel"]')
[ "$NEGATIVE" = 1 ] && first=$(cli +list --json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"]["windows"][0].get("target") or "")')
echo "first window: $first"
pa=$(pane_of "$first")

# two opens ON SHOW (so its terminal starts), then first is put back on show:
# two is parked with a running terminal.
cli +new-window --target=two --title=two --focus > /dev/null 2>&1
hl_wait_for 10 started two 0
pb=$(pane_of two)
hl_ipc workspaces "--show=$pa" > /dev/null 2>&1
hl_wait_for 10 wsis "('$first', True)" 'd["active"], row["two"]["parked"]'
hl_check "Y1 two is parked behind $first with a started terminal" $? "$(last)"
hl_wait_for 10 started "$first" 0
g_first=$(grid "$first" 0); g_two=$(grid two 0)
[ "$g_first" = "$g_two" ]
hl_check "Y2 parked two's grid ($g_two) is the shared window's ($g_first)" $?

# ---- 1. a settled resize reaches the parked workspace ---------------------
mark=$(log_lines)
hl_ipc window-size "--target=$pa" --size=1180x720 > /dev/null 2>&1
hl_wait_for 10 grid_not "$first" 0 "$g_first"
g_first2=$(grid "$first" 0)
[ "$g_first2" != "$g_first" ]
hl_check "Y3 the resize changed the window's grid ($g_first -> $g_first2)" $?
hl_wait_for 5 log_has "$mark" "parked window=two laid out .* why=resize"
hl_check "Y4 0.3s after it settled, parked two was laid out (why=resize)" $? "$(log_after "$mark" | grep 'parked window' | tail -2 | tr '\n' ' ')"
hl_wait_for 5 grid_is two 0 "$g_first2"
g_two2=$(grid two 0)
[ "$g_two2" = "$g_first2" ] && wsis True 'row["two"]["parked"]'
hl_check "Y5 still parked, two's grid is already the new one ($g_two2)" $? "$(last)"

hl_ipc workspaces "--show=$pb" > /dev/null 2>&1
hl_wait_for 10 wsis two 'd["active"]'
sleep 1
g_two3=$(grid two 0)
[ "$g_two3" = "$g_two2" ]
hl_check "Y6 shown, two's grid did not change ($g_two2 -> $g_two3)" $? "$(last)"

# ---- 2. a tree change lays the parked workspace out at once ----------------
hl_ipc workspaces "--show=$pa" > /dev/null 2>&1
hl_wait_for 10 wsis "('$first', True)" 'd["active"], row["two"]["parked"]'
hl_check "Y7 $first is on show again, two parked" $? "$(last)"
mark=$(log_lines)
cli +split --pane="$pb" --name=two-b --direction=right > /dev/null 2>&1
hl_wait_for 10 wsis "(2, True)" 'row["two"]["panes"], row["two"]["parked"]'
hl_check "Y8 the split landed in parked two (2 panes, still parked)" $? "$(last)"
hl_wait_for 5 log_has "$mark" "parked window=two laid out .* why=tree"
hl_check "Y9 the tree change laid parked two out at once (why=tree)" $? "$(log_after "$mark" | grep 'parked window' | tail -2 | tr '\n' ' ')"
cols() { printf '%s' "$1" | cut -dx -f1; }
g_half=$(grid two 0)
c_full=$(cols "$g_two3"); c_half=$(cols "$g_half")
[ -n "$c_half" ] && [ "$c_half" != None ] && [ "$c_half" -lt "$c_full" ] 2>/dev/null && [ "$c_half" -gt $(( c_full / 3 )) ] 2>/dev/null
hl_check "Y10 parked, two's first pane took its half at once ($g_two3 -> $g_half)" $?

hl_ipc workspaces "--show=$pb" > /dev/null 2>&1
hl_wait_for 10 wsis two 'd["active"]'
hl_wait_for 10 started two 1
sleep 1
g_half2=$(grid two 0)
[ "$g_half2" = "$g_half" ]
hl_check "Y11 shown, two's first pane kept its grid ($g_half -> $g_half2)" $? "$(last)"
started two 1
hl_check "Y12 the pane made while parked started on show ($(grid two 1); T3786 starts it sooner)" $?

hl_finish "$L"
