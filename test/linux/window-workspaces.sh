#!/usr/bin/env bash
# window-workspaces.sh - T3648 acceptance for single-window mode's foundation
# on the GTK debug app (docs/reference/window-modes.md "The rule" and "The
# hand-off"; Linux L11k1; win32 T3181/T3191/T3192): with
# `macos-window-mode = single` the person sees ONE toplevel. Every later
# window is a workspace of it that keeps its own Window; only its content
# moves into the toplevel on show and out (held, unmapped) when parked.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\window-workspaces.sh
#
# The oracle is the debug-only `workspaces` seam (IpcHandlers.workspacesSeam):
# which workspace's content root IS the toplevel's content, who is on show,
# who is parked/held/seen, whose own GtkWindow is mapped, and whether every
# pane resolves to its own workspace through the owner-of lookup.
# The last launch (K9) is the negative control: the same steps with the key
# unset must make no workspaces and map the second window itself.
# Output: one PASS/FAIL line per check, then 'WINDOW WORKSPACES: ALL PASS' or
# 'WINDOW WORKSPACES: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="WINDOW WORKSPACES"

log=/tmp/window-workspaces-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "K0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "K0b a private headless Weston is up" $?
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
        echo 'confirm-close-surface = false'
        [ -n "$1" ] && echo "macos-window-mode = $1"
    } > "$cfg"
}
export SHELL=/bin/sh

# ws <python expression over d (the seam's data)> [seam args...]: prints it.
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
print(eval(sys.argv[1]))
' "$expr"
}
# wsis <expected> <expr> [seam args...]: exit 0 when the expression prints it.
wsis() { local want="$1"; shift; [ "$(ws "$@")" = "$want" ]; }
stop_app() {
    kill -TERM "$1" 2>/dev/null
    hl_wait_for 5 sh -c "! kill -0 $1 2>/dev/null" || kill -KILL "$1" 2>/dev/null
    hl_wait_for 10 sh -c "! kill -0 $1 2>/dev/null"
}

# ---- 1. the first window loads the shared toplevel -------------------------
write_cfg single
hl_launch APP "$app" --gtk-single-instance=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "K0c the app serves its socket" $?
hl_wait_for 10 wsis True 'd["toplevel_mapped"]'
first=$(ws 'd["toplevel"]')
wsis "('single', 1, True)" 'd["mode"], len(d["order"]), d["toplevel"] == d["active"] == d["content"]'
hl_check "K1 the first window loads the toplevel: one workspace, on show, its content in it ($first)" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"
grep -q "workspace: window=.* loads the shared window" "$APP_LOG"
hl_check "K1b ...and logs it" $? "$(grep 'workspace:' "$APP_LOG" | head -3)"

# ---- 2. a programmatic open stays parked, out of every window --------------
o=$(cli +new-window --target=two 2>&1); rc=$?
hl_check "K2a +new-window --target=two succeeds" $rc "$o"
hl_wait_for 10 wsis 2 'len(d["order"])'
wsis "('$first', '$first', True, True, False, False)" \
    'd["active"], d["content"], row["two"]["parked"], row["two"]["held"], row["two"]["seen"], row["two"]["mapped"]'
hl_check "K2 two opens parked: held out of every window, unseen, its own window never mapped; $first keeps the toplevel" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"
wsis "('$first', 'two')" 'tuple(o["window"] for o in d["order"])'
hl_check "K2b the order is on show first, then the parked one" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"
wsis True 'all(o["owner_ok"] for o in d["order"]) and row["two"]["panes"] == 1'
hl_check "K2c every pane resolves to its own workspace, parked included (owner-of)" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"

# ---- 3. the hand-off: no new window, the content moves ---------------------
wsis True 'd["shown"]' --show=two
hl_check "K3a --show=two is accepted" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"
wsis "('$first', 'two', 'two', True, False, True, True, True, False)" \
    'd["toplevel"], d["active"], d["content"], d["toplevel_mapped"], row["two"]["parked"], row["two"]["seen"], row["'$first'"]["parked"], row["'$first'"]["held"], row["'$first'"]["seen"]'
hl_check "K3 two is on show IN $first's toplevel; $first is parked, held and unseen" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"
wsis "False" 'row["two"]["mapped"]'
hl_check "K3b two's own GtkWindow is still never mapped (one window)" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"
grep -q "workspace: show window=two (from " "$APP_LOG"
hl_check "K3c the hand-off is logged" $? "$(grep 'workspace:' "$APP_LOG" | tail -3)"
wsis True 'all(o["owner_ok"] for o in d["order"])'
hl_check "K3d after the hand-off every pane still resolves to its own workspace" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"

# Its terminal runs inside the borrowed toplevel: keys reach its shell.
mark="$XDG_RUNTIME_DIR/two-ran"
for _ in $(seq 1 20); do
    K4_OUT=$(cli +send-keys --target=two "touch $mark
" 2>&1)
    sleep 0.5
    test -e "$mark" && break
done
test -e "$mark"
hl_check "K4 two's shell runs and takes keys while on show in the shared toplevel" $? "$K4_OUT"

# ---- 4. a split addressed to the parked workspace lands in it --------------
o=$(cli +split --target="$first" --direction=right 2>&1); rc=$?
hl_check "K5a +split into the parked $first succeeds" $rc "$o"
hl_wait_for 10 wsis 2 'row["'$first'"]["panes"]'
wsis "(2, 1, 'two', True)" 'row["'$first'"]["panes"], row["two"]["panes"], d["content"], all(o["owner_ok"] for o in d["order"])'
hl_check "K5 the split lands in $first (parked), not in two which is on show" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"

# ---- 5. switching back -----------------------------------------------------
wsis "('$first', '$first', True, True, True)" 'd["active"], d["content"], row["two"]["parked"], row["two"]["held"], row["'$first'"]["seen"]' --show="$first"
hl_check "K6 showing $first again puts its content back in its own toplevel and parks two" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"

# ---- 6. closes keep every workspace whole (the experience is T3652) --------
o=$(cli +close --target=two --force 2>&1); rc=$?
hl_check "K7a +close --force on the parked two succeeds" $rc "$o"
hl_wait_for 10 wsis 1 'len(d["order"])'
wsis "('$first', '$first')" 'd["active"], d["content"]'
hl_check "K7 a parked workspace closes in place; $first is untouched" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"
alive "$APP"; hl_check "K7b the app is alive" $?

o=$(cli +new-window --target=three --focus 2>&1); rc=$?
hl_check "K8a +new-window --target=three --focus succeeds" $rc "$o"
hl_wait_for 10 wsis "('three', 'three')" 'd["active"], d["content"]'
hl_check "K8 a --focus open goes on show in the toplevel at once" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"
o=$(cli +close --target=three --force 2>&1); rc=$?
hl_wait_for 10 wsis "(1, '$first', '$first', True)" 'len(d["order"]), d["active"], d["content"], d["toplevel_mapped"]'
hl_check "K8b closing the workspace on show hands the toplevel back with $first's content" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"
alive "$APP"; hl_check "K8c the app is alive" $?

o=$(cli +new-window --target=four --focus 2>&1)
hl_wait_for 10 wsis "four" 'd["content"]'
# $first holds two panes (K5): close them by its name until it is gone.
for _ in 1 2 3; do
    wsis True "'$first' in row" || break
    cli +close --target="$first" --force >/dev/null 2>&1
    sleep 0.5
done
hl_wait_for 10 wsis "(1, 'four', 'four', 'four', True)" 'len(d["order"]), d["toplevel"], d["active"], d["content"], d["toplevel_mapped"]'
hl_check "K8d the toplevel's own workspace closing hands four a window of its own, whole" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"
alive "$APP"; hl_check "K8e the app is alive" $?

grep 'workspace:' "$APP_LOG" | tail -12
stop_app "$APP"

# ---- 7. negative control: separate mode makes no workspaces ----------------
write_cfg ''
rm -f "$(hl_socket)"
hl_launch APP2 "$app" --gtk-single-instance=false
hl_wait_for 30 test -S "$(hl_socket)"
cli +new-window --target=two >/dev/null 2>&1
sleep 1
wsis "('separate', 0, None)" 'd["mode"], len(d["order"]), d["toplevel"]'
hl_check "K9 the same app with the key unset makes no workspaces" $? "$(cat "$XDG_RUNTIME_DIR/ws-last" 2>/dev/null)"
stop_app "$APP2"

hl_finish "$L"
