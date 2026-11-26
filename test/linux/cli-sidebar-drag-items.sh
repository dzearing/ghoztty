#!/usr/bin/env bash
# cli-sidebar-drag-items.sh - L10f2 (T3697) acceptance for dragging window
# rows and project headers to reorder the GTK all-windows list
# (docs/reference/pane-sidebar.md "Reordering windows and groups"):
#
#   - a project header moves among the top level, never above the lone
#     windows; the list only moves, no window does;
#   - picking one up folds every group (or every window) to its row, and
#     letting go puts the folds back;
#   - a window row let go inside a group joins it (retitled `<group>: <name>`),
#     let go up among the lone windows leaves its group (just `<name>`), and
#     let go among its own group's windows only reorders;
#   - Remove from Group keeps the list's place (win32 `keepWindowPlace`);
#   - the Ungrouped header and this window's own list do not drag;
#   - the order is stored beside the sidebar's flags, and a relaunch keeps the
#     groups' order (the windows' own keys are tab addresses: T3700).
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-sidebar-drag-items.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop. The harness has no seat, so no pointer
# drag can START here (NOT RUN, as in cli-sidebar-drag.sh): the debug build's
# `pane-sidebar` seam picks a row up (`--lift`, the drag's begin), reads the
# rows as laid out (`--layout`) and lets go at a y of the list
# (`--drag=<row id>:<y>`) through the live drop's own code
# (PaneSidebar.liftItem / dropItemAt / endLift).
#
# NEGATIVE=1 lets the group go over its own place, which must FAIL I3 and I3c
# (the drop moved nothing, so the stored order still has proj first).
#
# Output: one PASS/FAIL line per check, then 'CLI SIDEBAR DRAG ITEMS: ALL
# PASS' or '... <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI SIDEBAR DRAG ITEMS"

log=/tmp/cli-sidebar-drag-items-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "I0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "I0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
order_file="$XDG_CONFIG_HOME/ghoztty/pane-sidebar-order-debug"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

fixture="$HL_RUNTIME/sidebar-drag-items-fixture"
mkdir -p "$fixture/proj"
export SHELL=/bin/sh
export HOME="$fixture"

launch() {
    rm -f "$sock"
    hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
        --macos-pane-sidebar=expanded \
        --working-directory="$fixture/proj" -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
    hl_wait_for 30 test -S "$sock"
}
launch
i0c=$?
hl_check "I0c the app serves its socket" $i0c
[ $i0c = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

sb() { local t=$1; shift; hl_ipc pane-sidebar "--target=$t" "$@" 2>/dev/null; }
# field <target> <python expr over d (the reply), s (the sidebar), r (its
# rows), H (its header rows), heads() (their labels), id(label[, kind]),
# row(id) and under(label) (the group a window row is listed in)> [args...]
field() {
    local t=$1 e=$2; shift 2
    sb "$t" "$@" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
s = d.get("sidebar") or {}
r = s.get("rows") or []
H = [x for x in r if x["kind"] in ("window", "project", "ungrouped")]
def heads(): return [x["label"] for x in H]
def id(label, kind="window"):
    return next((x["pane"] for x in H if x["label"] == label and x["kind"] == kind), "")
def row(i): return next((x for x in r if x["pane"] == i), {})
def under(label):
    g = None
    for x in H:
        if x["kind"] == "project": g = x["label"]
        if x["kind"] == "ungrouped": g = None
        if x["kind"] == "window" and x["label"] == label: return g
    return "?"
def projects(): return [x["label"] for x in H if x["kind"] == "project"]
def folded(kind): return [x["folded"] for x in H if x["kind"] == kind]
print(eval(sys.argv[1]))
' "$e" 2>/dev/null
}
is() { [ "$(field "$1" "$2")" = "$3" ]; }
isl() { [ "$(field "$1" "$2" --layout)" = "$3" ]; }
# titles: every window's title, sorted, from +list.
titles() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
print(sorted(w.get("title") or "" for w in d["windows"]))
' 2>/dev/null
}
# every header row has a place on screen (read with --layout, no redraw).
laid() { isl "$1" 'all(x.get("top", -1) >= 0 and x.get("height", 0) > 0 for x in H)' True; }
ylow() { field "$1" 'row("'"$2"'")["top"] + row("'"$2"'")["height"] - 2' --layout; }
yhigh() { field "$1" 'row("'"$2"'")["top"] + 2' --layout; }
lift() { sb "$1" "--lift=$2"; }
drop() { field "$1" 'd.get("index", d.get("error"))' "--drag=$2:$3"; }

# ---- 0. two groups and two lone windows, in the all-windows list ------------
cli +new-window --target=wl --title=alpha > /dev/null 2>&1
cli +new-window --target=wx --title="proj: x" > /dev/null 2>&1
cli +new-window --target=wy --title="proj: y" > /dev/null 2>&1
cli +new-window --target=wz --title="zed: z" > /dev/null 2>&1
hl_wait_for 15 is wl 's["mode"]' expanded
[ "$(field wl 's["all_windows"]')" = False ] && sb wl --click=scope > /dev/null
hl_wait_for 10 is wl 'projects()' "['proj', 'zed']"
hl_check "I1 groups list by name: proj, then zed" $? "$(field wl 'heads()')"
is wl '[(x["kind"], x["draggable"]) for x in H if x["kind"] != "window"]' "[('ungrouped', False), ('project', True), ('project', True)]"
hl_check "I1b project headers drag, the Ungrouped header does not" $? "$(field wl 'H')"
is wl 'all(x["draggable"] for x in H if x["kind"] == "window")' True
hl_check "I1c every window row drags" $?
pz=$(field wl 'id("zed", "project")')
pp=$(field wl 'id("proj", "project")')
kl=$(field wl 'id("alpha")')
kx=$(field wl 'id("x")')
ky=$(field wl 'id("y")')
titles0=$(titles)

# ---- 1. a group dragged above the other -------------------------------------
out=$(lift wl "$pz")
case "$out" in *'"success":true'*) ok=0 ;; *) ok=1 ;; esac
hl_check "I2 a project header lifts" $ok "$out"
hl_wait_for 10 isl wl 'folded("project")' "[True, True]"
hl_check "I2b lifting it folds every group to its header" $? "$(field wl 'H' --layout)"
hl_wait_for 10 laid wl
y=$(yhigh wl "$pp")
[ "${NEGATIVE:-0}" = 1 ] && y=$(ylow wl "$pz")
idx=$(drop wl "$pz" "$y")
hl_wait_for 10 is wl 'projects()' "['zed', 'proj']"
hl_check "I3 let go high on proj's header, zed lists first" $? "index=$idx y=$y $(field wl 'heads()')"
hl_wait_for 10 is wl 'folded("project")' "[False, False]"
hl_check "I3b letting go puts the folds back" $? "$(field wl 'H')"
grep -q '^project:zed$' "$order_file" 2>/dev/null && [ "$(grep -n '^project:zed$' "$order_file" | cut -d: -f1)" -lt "$(grep -n '^project:proj$' "$order_file" | cut -d: -f1)" ]
hl_check "I3c the order is stored beside the flags, zed before proj" $? "$(cat "$order_file" 2>/dev/null | tr '\n' ' ')"
[ "$(titles)" = "$titles0" ]
hl_check "I3d no window was renamed" $? "$(titles)"
grep -q "pane sidebar item drop id=$pz" "$APP_LOG"
hl_check "I3e the drop is logged" $?
lift wl "$pz" > /dev/null
hl_wait_for 10 laid wl
idx=$(drop wl "$pz" 0)
hl_wait_for 10 is wl '[x["kind"] for x in H].index("project") > max(i for i, x in enumerate(H) if x["kind"] == "window" and under(x["label"]) is None) and projects()[0] == "zed"' True
hl_check "I4 held at the very top a group still stops below the lone windows" $? "index=$idx $(field wl 'heads()')"

# ---- 2. a window into a group, out of one, within one -----------------------
# x open, so letting go has a fold to put back.
sb wl "--click=fold:$kx" > /dev/null
hl_wait_for 10 is wl 'row("'"$kx"'")["folded"]' False
out=$(lift wl "$kl")
hl_wait_for 10 isl wl 'all(folded("window"))' True
hl_check "I5 lifting a window folds every window to its row" $? "$(field wl 'H' --layout)"
hl_wait_for 10 laid wl
y=$(ylow wl "$kx")
idx=$(drop wl "$kl" "$y")
hl_wait_for 10 is wl 'under("alpha")' proj
hl_check "I6 a lone window let go under proj's x joins proj" $? "index=$idx $(field wl 'heads()')"
hl_wait_for 10 is wl '[x for x in heads() if x in ("x", "alpha", "y")]' "['x', 'alpha', 'y']"
hl_check "I6b where it was let go: after x" $? "$(field wl 'heads()')"
titles | grep -q "'proj: alpha'"
hl_check "I6c it is retitled proj: alpha" $? "$(titles)"
hl_wait_for 10 is wl 'row("'"$kx"'")["folded"]' False
hl_check "I6d the window folds come back when it is let go: x is open again" $? "$(field wl 'H')"

lift wl "$ky" > /dev/null
hl_wait_for 10 laid wl
idx=$(drop wl "$ky" 0)
hl_wait_for 10 is wl 'under("y")' None
hl_check "I7 proj's y let go at the top leaves its group" $? "index=$idx $(field wl 'heads()')"
titles | grep -q "'y'"
hl_check "I7b retitled just y" $? "$(titles)"
hl_wait_for 10 is wl 'heads()[:2]' "['Ungrouped', 'y']"
hl_check "I7c first of the lone windows, where it was let go" $? "$(field wl 'heads()')"

kl=$(field wl 'id("alpha")')
lift wl "$kl" > /dev/null
hl_wait_for 10 laid wl
y=$(yhigh wl "$kx")
idx=$(drop wl "$kl" "$y")
hl_wait_for 10 is wl '[x for x in heads() if x in ("x", "alpha")]' "['alpha', 'x']"
hl_check "I8 within its own group it only reorders" $? "index=$idx $(field wl 'heads()')"
titles | grep -q "'proj: alpha'"
hl_check "I8b and keeps its title" $? "$(titles)"

# ---- 3. a group move from the menu keeps the list's place -------------------
kx=$(field wl 'id("x")')
sb wl "--menu=$kx" --menu-pick=remove > /dev/null
hl_wait_for 10 is wl 'under("x")' None
hl_check "I9 Remove from Group takes x out of proj" $? "$(field wl 'heads()')"
lone=$(field wl '[x["label"] for x in H if x["kind"] == "window" and under(x["label"]) is None]')
hl_wait_for 10 is wl '[x["label"] for x in H if x["kind"] == "window" and under(x["label"]) is None][0]' y
hl_check "I9b the lone windows keep their places: y still first" $? "lone=$lone"
grep -q 'cause=group move' "$APP_LOG"
hl_check "I9c the move wrote the list as shown into the order" $?

# ---- 4. what does not drag ---------------------------------------------------
out=$(sb wl --lift=ungrouped)
case "$out" in *'did not lift'*) ok=0 ;; *) ok=1 ;; esac
hl_check "I10 the Ungrouped header does not lift" $ok "$out"
sb wl --click=scope > /dev/null
hl_wait_for 10 is wl 's["all_windows"]' False
is wl '[x["draggable"] for x in H]' "[False]"
hl_check "I10b this window's own list: its header does not drag" $? "$(field wl 'H')"
out=$(sb wl "--lift=$(field wl 'H[0]["pane"]')")
case "$out" in *'did not lift'*) ok=0 ;; *) ok=1 ;; esac
hl_check "I10c and refuses a lift" $ok "$out"

# ---- 5. a relaunch keeps the groups' order -----------------------------------
kill "$APP" 2> /dev/null
hl_wait_for 10 sh -c "! kill -0 $APP 2>/dev/null"
launch
hl_check "I11a the app comes back" $?
cli +new-window --target=wp --title="proj: x" > /dev/null 2>&1
cli +new-window --target=wq --title="zed: z" > /dev/null 2>&1
hl_wait_for 15 is wp 's["mode"]' expanded
[ "$(field wp 's["all_windows"]')" = False ] && sb wp --click=scope > /dev/null
hl_wait_for 10 is wp 'projects()' "['zed', 'proj']"
hl_check "I11 relaunched, zed still lists before proj" $? "$(field wp 'heads()')"
grep -q 'pane sidebar window order loaded' "$APP_LOG"
hl_check "I11b the stored order was read at launch" $?

hl_finish "$L"
