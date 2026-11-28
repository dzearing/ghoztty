#!/usr/bin/env bash
# cli-sidebar-pane-drop.sh - T3756 acceptance: the GTK pane sidebar takes PANE
# drags (a rearrange header, the grab handle or a strip - so another window's
# pane too), not only its own rows (docs/reference/pane-sidebar.md "Drag to
# reorder"; Mac `PaneDropResolver.sidebarHit` -> `.sidebarOrder` / `.stash`,
# win32 `commitListDrop` / `commitStashDrop`):
#
#   - this window's own pane let go on the list takes that place in the list
#     only (the grid does not move), and let go in the tray it is stashed;
#   - held over the tray, the tray lights; over the list it does not;
#   - ANOTHER window's pane let go on the list arrives on this grid's right
#     edge (the same shell) and takes the place it was let go at in the list;
#     let go in the tray it arrives stashed there, and its old window keeps
#     its other panes;
#   - in the all-windows list a pane let go among another window's rows joins
#     that window, as its row would (T3699).
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-sidebar-pane-drop.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh). The harness has no
# pointer, so no drag can START here (NOT RUN, T3847): the debug build's
# `pane-sidebar` seam holds (`--pane-hover=<pane>:<y>`) and lets go
# (`--pane-drop=<pane>:<y>`) a pane drag at a y of the list through the list's
# pane drop target's own calls (PaneSidebar.hoverPaneAt / dropPaneAt).
#
# NEGATIVE=1 lets the first pane go over its own place, which must FAIL P2,
# P2b and the places read off that order later - P6b, P6c, P6e, P7c - and
# nothing else (6 failures, measured 2026-11-27): the harness can tell a drop
# that moved nothing.
#
# Output: one PASS/FAIL line per check, then 'CLI SIDEBAR PANE DROP: ALL PASS'
# or 'CLI SIDEBAR PANE DROP: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI SIDEBAR PANE DROP"

log=/tmp/cli-sidebar-pane-drop-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "P0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "P0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

fixture="$HL_RUNTIME/sidebar-pane-drop-fixture"
mkdir -p "$fixture/proj"
export SHELL=/bin/sh
export HOME="$fixture"

rm -f "$sock"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    --macos-pane-sidebar=expanded \
    --working-directory="$fixture/proj" -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
p0c=$?
hl_check "P0c the app serves its socket" $p0c
[ $p0c = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

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
# lst <python expr over W (windows by target) and ids/pids/focused/stashed(target)>
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
def pid(t, i): return next((l.get("pid") for l in panes(t) if l["id"] == i), None)
def focused(t): return next((l["id"] for l in panes(t) if l.get("focused")), "")
def stashed(t): return sorted(l["id"] for l in panes(t) if l.get("stashed"))
print(eval(sys.argv[1]))
' "$1" 2>/dev/null
}
lst_is() { [ "$(lst "$1")" = "$2" ]; }
laid() {
    local t=$1; shift
    local want="[$(printf "'%s', " "$@" | sed 's/, $//')]"
    [ "$(field "$t" 'all(row(i).get("top", -1) >= 0 and row(i).get("height", 0) > 0 for i in '"$want"')' --layout)" = True ]
}
ylow() { field "$1" 'row("'"$2"'")["top"] + row("'"$2"'")["height"] - 2' --layout; }
yhigh() { field "$1" 'row("'"$2"'")["top"] + 2' --layout; }
ymid() { field "$1" 'row("'"$2"'")["top"] + row("'"$2"'")["height"] // 2' --layout; }
# pdrop <sidebar target> <pane> <y>: the pane drag let go there; prints
# (target, outcome, index).
pdrop() { field "$1" '(d.get("drop") or {}).get("target"), (d.get("drop") or {}).get("outcome"), (d.get("drop") or {}).get("index")' "--pane-drop=$2:$3"; }
# lit <sidebar target> <pane> <y>: held there, is the tray head lit?
lit() { field "$1" 'row("tray").get("lit")' "--pane-hover=$2:$3"; }
srt() { python3 -I -c 'import sys; print(sorted(sys.argv[1:]))' "$@"; }

# ---- 1. two windows: wa (a b c), wb (f e g) -----------------------------------
cli +new-window --target=wa --title=wa > /dev/null 2>&1
hl_wait_for 15 is wa 's["mode"]' expanded
[ "$(field wa 's["all_windows"]')" = True ] && sb wa --click=scope > /dev/null
hl_wait_for 10 is wa '(s["all_windows"], len(p))' "(False, 1)"
cli +split --target=wa --name=b > /dev/null 2>&1
hl_wait_for 10 lst_is 'len(ids("wa"))' 2
cli +split --target=wa --name=c > /dev/null 2>&1
hl_wait_for 10 lst_is 'len(ids("wa"))' 3
read -r a b c <<< "$(lst '" ".join(ids("wa"))')"
cli +new-window --target=wb --title=wb > /dev/null 2>&1
hl_wait_for 15 lst_is '"wb" in W' True
cli +split --target=wb --name=e > /dev/null 2>&1
hl_wait_for 10 lst_is 'len(ids("wb"))' 2
cli +split --target=wb --name=g > /dev/null 2>&1
hl_wait_for 10 lst_is 'len(ids("wb"))' 3
read -r f e g <<< "$(lst '" ".join(ids("wb"))')"
hl_wait_for 10 is wa '[x["pane"] for x in p]' "['$a', '$b', '$c']"
hl_check "P1 wa lists its own three panes, in tree order" $? "$(field wa '[x["pane"] for x in p]')"
hl_wait_for 10 laid wa "$a" "$b" "$c" tray
hl_check "P1b the rows and the tray's well are laid out" $? "$(sb wa --layout)"

# ---- 2. this window's own pane, on its list ----------------------------------
y=$(ylow wa "$c")
[ "${NEGATIVE:-0}" = 1 ] && y=$(yhigh wa "$a")
res=$(pdrop wa "$a" "$y")
hl_wait_for 10 is wa '[x["pane"] for x in p]' "['$b', '$c', '$a']"
hl_check "P2 its own pane let go low on the last row takes the last place in the list" $? "drop=$res list=$(field wa '[x["pane"] for x in p]')"
[ "$res" = "('sidebar_order', 'moved', 2)" ]
hl_check "P2b the drop says sidebar_order, moved, index 2" $? "drop=$res"
lst_is 'ids("wa")' "['$a', '$b', '$c']"
hl_check "P3 the grid does not move" $? "$(lst 'ids("wa")')"
grep -q "pane sidebar pane drop pane=$a .*plan=row" "$APP_LOG"
hl_check "P3b the pane drop is logged as its row's drop" $? "$(grep 'pane sidebar pane drop' "$APP_LOG" | tail -2)"

# ---- 3. held over the tray it lights; let go there it stashes ----------------
hl_wait_for 10 laid wa "$a" "$b" "$c" tray
yt=$(ymid wa tray)
[ "$(lit wa "$c" "$yt")" = True ]
hl_check "P4 a pane drag held over the tray's well lights it" $? "y=$yt $(sb wa "--pane-hover=$c:$yt")"
[ "$(lit wa "$c" "$(ymid wa "$b")")" = False ]
hl_check "P4b moved over the list the light goes off" $? "$(sb wa --layout)"
lit wa "$c" "$yt" > /dev/null
[ "$(field wa 'row("tray").get("lit")' --pane-leave)" = False ]
hl_check "P4c leaving the list puts it out" $?
res=$(pdrop wa "$c" "$yt")
hl_wait_for 10 lst_is 'stashed("wa")' "['$c']"
hl_check "P5 let go in the tray, its own pane is stashed" $? "drop=$res stashed=$(lst 'stashed("wa")')"
[ "$res" = "('stash', 'moved', 0)" ]
hl_check "P5b the drop says stash, moved, index 0" $? "drop=$res"

# ---- 4. another window's pane arrives: on the list, then in the tray ----------
fpid=$(lst 'pid("wb", "'"$f"'")')
hl_wait_for 10 laid wa "$a" "$b" "$c" tray
y=$(yhigh wa "$b")
res=$(pdrop wa "$f" "$y")
hl_wait_for 10 lst_is '(ids("wa"), ids("wb"))' "(['$a', '$b', '$c', '$f'], ['$e', '$g'])"
hl_check "P6 another window's pane let go on the list arrives on this grid's right edge" $? "drop=$res $(lst '(ids("wa"), ids("wb"))')"
[ "$res" = "('sidebar_order', 'moved', 0)" ]
hl_check "P6b the drop says sidebar_order, moved, index 0" $? "drop=$res"
hl_wait_for 10 is wa '[x["pane"] for x in p]' "['$f', '$b', '$a', '$c']"
hl_check "P6c and takes the place it was let go at: first in the list, the stash after" $? "list=$(field wa '[x["pane"] for x in p]')"
lst_is '(pid("wa", "'"$f"'"), stashed("wa"))' "($fpid, ['$c'])"
hl_check "P6d the same shell, on screen" $? "was=$fpid $(lst '(pid("wa", "'"$f"'"), stashed("wa"))')"
grep -q "pane sidebar pane arrived pane=$f into=list index=0 placed=true" "$APP_LOG"
hl_check "P6e the arrival is logged" $? "$(grep 'pane sidebar pane arrived' "$APP_LOG" | tail -2)"

epid=$(lst 'pid("wb", "'"$e"'")')
hl_wait_for 10 laid wa "$a" "$b" "$c" "$f" tray
y=$(ylow wa "$c")
res=$(pdrop wa "$e" "$y")
hl_wait_for 10 lst_is 'stashed("wa")' "$(srt "$c" "$e")"
hl_check "P7 another window's pane let go in the tray arrives stashed" $? "drop=$res stashed=$(lst 'stashed("wa")')"
[ "$res" = "('stash', 'moved', 1)" ]
hl_check "P7b below c, as let go: stash, moved, index 1" $? "drop=$res"
hl_wait_for 10 is wa '[x["pane"] for x in p]' "['$f', '$b', '$a', '$c', '$e']"
hl_check "P7c the tray lists it under c" $? "list=$(field wa '[x["pane"] for x in p]')"
lst_is '(pid("wa", "'"$e"'"), ids("wb"))' "($epid, ['$g'])"
hl_check "P7d the same shell, and its old window keeps its other pane" $? "was=$epid $(lst '(pid("wa", "'"$e"'"), ids("wb"))')"

# ---- 5. all windows: over another window's rows it joins that window ---------
sb wa --click=scope > /dev/null
hl_wait_for 10 is wa 's["all_windows"]' True
ka=$(field wa 'head("wa")["pane"]')
kb=$(field wa 'head("wb")["pane"]')
[ "$(field wa 'head("wa")["folded"]')" = True ] && sb wa "--click=fold:$ka" > /dev/null
[ "$(field wa 'head("wb")["folded"]')" = True ] && sb wa "--click=fold:$kb" > /dev/null
hl_wait_for 10 laid wa "$a" "$b" "$g"
res=$(pdrop wa "$b" "$(ymid wa "$g")")
hl_wait_for 10 lst_is 'ids("wb")' "['$g', '$b']"
hl_check "P8 in all windows a pane let go among another window's rows joins it" $? "drop=$res $(lst '(ids("wa"), ids("wb"))')"
[ "$(echo "$res" | cut -d, -f1-2)" = "('join_window', 'moved'" ]
hl_check "P8b the drop says join_window, moved" $? "drop=$res"

hl_finish "$L"
