#!/usr/bin/env bash
# cli-sidebar-drag.sh - L10f (T3607) acceptance for dragging a pane row to
# reorder the GTK pane sidebar (docs/reference/pane-sidebar.md "Drag to
# reorder"):
#
#   - a pane row let go level with another row lands there, in its window's
#     list only: the grid, the focus and the shells do not move;
#   - the order is the sidebar's own, read against the tree at every draw: a
#     new split lands beside the pane it came from, a closed pane drops out;
#   - it is one order per window, the same in the per-window list and under
#     that window in the all-windows list, and a drag in either changes both;
#   - a stashed pane's row does not drag, and a row lands among its own
#     window's rows whatever it is let go over.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-sidebar-drag.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop. The harness has no seat, so no pointer
# drag can START here (that half is NOT RUN, as in cli-pane-drag.sh): the
# debug build's `pane-sidebar` seam reads each row's place as laid out
# (`--layout`) and lets a row go at a y of the list (`--drag=<row id>:<y>`)
# through the live drop's own code (PaneSidebar.dropRowAt).
#
# NEGATIVE=1 lets the first row go over its own place, which must FAIL D2,
# D2b and D4b and nothing else (3 failures, measured 2026-11-24): the harness
# can tell a drag that moved nothing.
#
# Output: one PASS/FAIL line per check, then 'CLI SIDEBAR DRAG: ALL PASS' or
# 'CLI SIDEBAR DRAG: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI SIDEBAR DRAG"

log=/tmp/cli-sidebar-drag-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "D0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "D0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

fixture="$HL_RUNTIME/sidebar-drag-fixture"
mkdir -p "$fixture/proj"
export SHELL=/bin/sh
export HOME="$fixture"

rm -f "$sock"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    --macos-pane-sidebar=expanded \
    --working-directory="$fixture/proj" -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
d0c=$?
hl_check "D0c the app serves its socket" $d0c
[ $d0c = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

# sb <target> [seam args...]: the seam's reply for that target's window.
sb() { local t=$1; shift; hl_ipc pane-sidebar "--target=$t" "$@" 2>/dev/null; }
# field <target> <python expr over d (the reply), s (the sidebar), r (its
# rows), p (its pane rows), row(id), head(label[, kind]) and order(ids)>
# [seam args...]
field() {
    local t=$1 e=$2; shift 2
    sb "$t" "$@" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
s = d.get("sidebar") or {}
r = s.get("rows") or []
p = [x for x in r if x["kind"] in ("terminal", "viewer")]
def row(i):
    return next((x for x in r if x["pane"] == i), {})
def head(label, kind="window"):
    return next((x for x in r if x["label"] == label and x["kind"] == kind), {})
def order(ids):
    return [x["pane"] for x in p if x["pane"] in ids]
print(eval(sys.argv[1]))
' "$e" 2>/dev/null
}
is() { [ "$(field "$1" "$2")" = "$3" ]; }
# lst <python expr over W (windows by target) and ids(target)/focused(target)
# /pids(target)> - read from +list.
lst() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
W = {(w.get("target") or ""): w for w in d["windows"]}
def panes(t):
    w = W.get(t)
    if not w: return []
    tab = next((x for x in w["tabs"] if x.get("selected")), w["tabs"][0])
    return list(leaves(tab["splits"]))
def ids(t): return [l["id"] for l in panes(t)]
def pids(t): return [l.get("pid") for l in panes(t)]
def focused(t): return next((l["id"] for l in panes(t) if l.get("focused")), "")
print(eval(sys.argv[1]))
' "$1" 2>/dev/null
}
lst_is() { [ "$(lst "$1")" = "$2" ]; }
# laid <target> <ids...>: every one of those rows has a place on screen.
# Read with --layout: any other read redraws, and new rows have no place
# until the next frame.
laid() {
    local t=$1; shift
    local want="[$(printf "'%s', " "$@" | sed 's/, $//')]"
    [ "$(field "$t" 'all(row(i).get("top", -1) >= 0 and row(i).get("height", 0) > 0 for i in '"$want"')' --layout)" = True ]
}
# ylow <target> <id>: a y just above the bottom of that row (below its middle).
ylow() { field "$1" 'row("'"$2"'")["top"] + row("'"$2"'")["height"] - 2' --layout; }
# yhigh <target> <id>: a y just under the top of that row (above its middle).
yhigh() { field "$1" 'row("'"$2"'")["top"] + 2' --layout; }
# drop <target> <id> <y>: the row let go there; prints the landing index.
drop() { field "$1" 'd.get("index", d.get("error"))' "--drag=$2:$3"; }

# ---- 1. three panes, listed in tree order ------------------------------------
cli +new-window --target=wa --title=wa > /dev/null 2>&1
hl_wait_for 15 is wa 's["mode"]' expanded
[ "$(field wa 's["all_windows"]')" = True ] && sb wa --click=scope > /dev/null
hl_wait_for 10 is wa '(s["all_windows"], len(p))' "(False, 1)"
cli +split --target=wa --name=b > /dev/null 2>&1
hl_wait_for 10 lst_is 'len(ids("wa"))' 2
cli +split --target=wa --name=c > /dev/null 2>&1
hl_wait_for 10 lst_is 'len(ids("wa"))' 3
read -r a b c <<< "$(lst '" ".join(ids("wa"))')"
shape0=$(cli +list --json 2>/dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin)["data"]; w=[x for x in d["windows"] if x.get("target")=="wa"][0]; print(json.dumps(w["tabs"][0]["splits"], sort_keys=True))' | sed 's/"ratio": [0-9.e-]*//g')
pids0=$(lst 'pids("wa")')
focus0=$(lst 'focused("wa")')
hl_wait_for 10 is wa 'order(["'"$a"'", "'"$b"'", "'"$c"'"])' "['$a', '$b', '$c']"
hl_check "D1 the list starts in tree order" $? "$(field wa '[x["pane"] for x in p]') tree=$a $b $c"
is wa '[x["draggable"] for x in p]' "[True, True, True]"
hl_check "D1b every pane on screen drags" $? "$(sb wa)"
hl_wait_for 10 laid wa "$a" "$b" "$c"
hl_check "D1c the seam reads each row's place as laid out" $? "$(sb wa --layout)"

# ---- 2. a drag moves the row in the list, nothing else ----------------------
y=$(ylow wa "$c")
[ "${NEGATIVE:-0}" = 1 ] && y=$(yhigh wa "$a")
idx=$(drop wa "$a" "$y")
hl_wait_for 10 is wa 'order(["'"$a"'", "'"$b"'", "'"$c"'"])' "['$b', '$c', '$a']"
hl_check "D2 the first row let go low on the last lands last" $? "index=$idx y=$y list=$(field wa '[x["pane"] for x in p]')"
[ "$idx" = 2 ]
hl_check "D2b the drop reports where it landed (index 2 of the list without it)" $? "index=$idx"
lst_is 'ids("wa")' "['$a', '$b', '$c']"
hl_check "D3 the grid does not move: the tree is in its old order" $? "$(lst 'ids("wa")')"
shape1=$(cli +list --json 2>/dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin)["data"]; w=[x for x in d["windows"] if x.get("target")=="wa"][0]; print(json.dumps(w["tabs"][0]["splits"], sort_keys=True))' | sed 's/"ratio": [0-9.e-]*//g')
[ -n "$shape0" ] && [ "$shape0" = "$shape1" ]
hl_check "D3b the same splits, the same panes in them" $?
[ "$(lst 'pids("wa")')" = "$pids0" ] && [ "$(lst 'focused("wa")')" = "$focus0" ]
hl_check "D4 the same shells, and the focus stays where it was" $? "pids=$(lst 'pids("wa")') was=$pids0 focus=$(lst 'focused("wa")') was=$focus0"
grep -q "pane sidebar reorder pane=$a index=2" "$APP_LOG"
hl_check "D4b the reorder is logged" $?

hl_wait_for 10 laid wa "$a" "$b" "$c"
y=$(yhigh wa "$c")
idx=$(drop wa "$a" "$y")
hl_wait_for 10 is wa 'order(["'"$a"'", "'"$b"'", "'"$c"'"])' "['$b', '$a', '$c']"
hl_check "D5 let go high on a middle row, it lands before that row" $? "index=$idx list=$(field wa '[x["pane"] for x in p]')"

# ---- 3. the order meets the tree: a split, a close -------------------------
cli +split --target="$b" --name=d > /dev/null 2>&1
hl_wait_for 10 lst_is 'len(ids("wa"))' 4
dd=$(lst '[i for i in ids("wa") if i not in ("'"$a"'", "'"$b"'", "'"$c"'")][0]')
# +split splits the window's focused pane: the new pane's tree neighbour
# before it is the pane it came from.
parent=$(lst 'ids("wa")[ids("wa").index("'"$dd"'") - 1]')
want=$(case "$parent" in "$b") echo "['$b', '$dd', '$a', '$c']" ;; "$a") echo "['$b', '$a', '$dd', '$c']" ;; *) echo "parent?" ;; esac)
hl_wait_for 10 is wa '[x["pane"] for x in p]' "$want"
hl_check "D6 a split lands in the list right after the pane it came from" $? "list=$(field wa '[x["pane"] for x in p]') tree=$(lst 'ids("wa")') parent=$parent"
cli +close --target="$dd" > /dev/null 2>&1
hl_wait_for 10 lst_is 'len(ids("wa"))' 3
hl_wait_for 10 is wa '[x["pane"] for x in p]' "['$b', '$a', '$c']"
hl_check "D7 a closed pane drops out, the rest keep their order" $? "list=$(field wa '[x["pane"] for x in p]')"

# ---- 4. all windows: the same order, and a drag there ---------------------
cli +new-window --target=wb --title=wb > /dev/null 2>&1
hl_wait_for 15 lst_is '"wb" in W' True
cli +split --target=wb --name=e > /dev/null 2>&1
hl_wait_for 10 lst_is 'len(ids("wb"))' 2
read -r f e <<< "$(lst '" ".join(ids("wb"))')"
sb wa --click=scope > /dev/null
hl_wait_for 10 is wa 's["all_windows"]' True
ka=$(field wa 'head("wa")["pane"]')
kb=$(field wa 'head("wb")["pane"]')
[ "$(field wa 'head("wa")["folded"]')" = True ] && sb wa "--click=fold:$ka" > /dev/null
[ "$(field wa 'head("wb")["folded"]')" = True ] && sb wa "--click=fold:$kb" > /dev/null
hl_wait_for 10 is wa 'order(["'"$a"'", "'"$b"'", "'"$c"'"])' "['$b', '$a', '$c']"
hl_check "D8 under its row in the all-windows list a window keeps its own order" $? "$(field wa '[x["pane"] for x in p]')"

hl_wait_for 10 laid wa "$a" "$b" "$c" "$f" "$e"
y=$(yhigh wa "$b")
idx=$(drop wa "$c" "$y")
hl_wait_for 10 is wa 'order(["'"$a"'", "'"$b"'", "'"$c"'"])' "['$c', '$b', '$a']"
hl_check "D9 a drag in the all-windows list reorders that window's panes" $? "index=$idx list=$(field wa '[x["pane"] for x in p]')"
is wa 'order(["'"$f"'", "'"$e"'"])' "['$f', '$e']"
hl_check "D9b and no other window's" $? "$(field wa '[x["pane"] for x in p]')"
is wb 'order(["'"$a"'", "'"$b"'", "'"$c"'"])' "['$c', '$b', '$a']"
hl_check "D9c every window's list shows it" $? "$(field wb '[x["pane"] for x in p]')"

# Let go over the other window's rows, it stays in its own window's list.
hl_wait_for 10 laid wa "$a" "$b" "$c" "$f" "$e"
y=$(ylow wa "$e")
idx=$(drop wa "$c" "$y")
hl_wait_for 10 is wa 'order(["'"$a"'", "'"$b"'", "'"$c"'"])' "['$b', '$a', '$c']"
hl_check "D10 let go below another window's rows it lands last in its own" $? "index=$idx list=$(field wa '[x["pane"] for x in p]')"
lst_is '(ids("wa"), ids("wb"))' "(['$a', '$b', '$c'], ['$f', '$e'])"
hl_check "D10b and no pane changes window" $? "$(lst '(ids("wa"), ids("wb"))')"

sb wa --click=scope > /dev/null
hl_wait_for 10 is wa '(s["all_windows"], [x["pane"] for x in p])' "(False, ['$b', '$a', '$c'])"
hl_check "D11 back in the per-window list, the drag made there holds" $? "$(field wa '[x["pane"] for x in p]')"

# ---- 5. a stashed pane's row does not drag ---------------------------------
sb wa "--click=tool:stash:$a" > /dev/null
hl_wait_for 10 is wa '(row("'"$a"'")["stashed"], row("'"$a"'")["draggable"])' "(True, False)"
hl_check "D12 a stashed pane's row is not draggable" $? "$(sb wa)"
hl_wait_for 10 laid wa "$a" "$b" "$c"
out=$(sb wa "--drag=$a:0")
case "$out" in *'did not drop'*) ok=0 ;; *) ok=1 ;; esac
hl_check "D13 and letting it go is refused" $ok "$out"
is wa '[x["pane"] for x in p]' "['$b', '$a', '$c']"
hl_check "D13b the list is unchanged" $? "$(field wa '[x["pane"] for x in p]')"

hl_finish "$L"
