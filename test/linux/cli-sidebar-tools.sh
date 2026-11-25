#!/usr/bin/env bash
# cli-sidebar-tools.sh - L10d (T3606) acceptance for a pane sidebar row's
# hover buttons on the GTK debug app (docs/reference/pane-sidebar.md "Rows
# and tiles", "Adding from the sidebar", "Closing from the sidebar"):
#
#   - a panel row of this window offers - (stash) or the restore, then x;
#     another window's pane row the x alone; a rail tile nothing;
#   - the buttons show only while the pointer is over the row;
#   - - stashes the pane, the restore brings it back focused, and the last
#     pane on screen is never stashed;
#   - a pane's x closes it with no confirmation, even with a program
#     running, and a window's last pane closes the window;
#   - a window row's + splits that window's focused pane (a new pane), its x
#     closes the window; a project header's + opens `<project>: new` in the
#     group, its x every window of the group; the panel header's + a new
#     window.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-sidebar-tools.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop. The harness has no pointer: the debug
# build's `pane-sidebar` IPC seam (IpcHandlers.zig) moves the pointer onto a
# row (`--hover`, the motion controller's enter) and clicks a button
# (`--click=tool:<button>:<row id>`, `--click=add`).
#
# NEGATIVE=1 never hovers the row, which must FAIL B2 (the harness can see
# buttons that stay hidden).
#
# Output: one PASS/FAIL line per check, then 'CLI SIDEBAR TOOLS: ALL PASS' or
# 'CLI SIDEBAR TOOLS: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI SIDEBAR TOOLS"

log=/tmp/cli-sidebar-tools-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "B0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "B0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

fixture="$HL_RUNTIME/sidebar-tools-fixture"
mkdir -p "$fixture/proj"
export SHELL=/bin/sh
export HOME="$fixture"

rm -f "$sock"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    --macos-pane-sidebar=expanded \
    --working-directory="$fixture/proj" -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
b0c=$?
hl_check "B0c the app serves its socket" $b0c
[ $b0c = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

# sb <target> [seam args...]: the seam's report for that target's window.
sb() { local t=$1; shift; hl_ipc pane-sidebar "--target=$t" "$@" 2>/dev/null; }
# field <target> <python expr over s (the sidebar), r (its rows), p (its
# pane rows), row(id) and head(label[, kind])> [seam args...]
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
print(eval(sys.argv[1]))
' "$e" 2>/dev/null
}
is() { [ "$(field "$1" "$2")" = "$3" ]; }
# lst <python expr over W (windows by target), T (every window's title) and
# panes(target)> - read from +list.
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
T = [w.get("title") or "" for w in d["windows"]]
def panes(t):
    w = W.get(t)
    if not w: return []
    tab = next((x for x in w["tabs"] if x.get("selected")), w["tabs"][0])
    return list(leaves(tab["splits"]))
def ids(t): return [l["id"] for l in panes(t)]
def focused(t): return next((l["id"] for l in panes(t) if l.get("focused")), "")
print(eval(sys.argv[1]))
' "$1" 2>/dev/null
}
lst_is() { [ "$(lst "$1")" = "$2" ]; }

# ---- 1. this window's rows: their buttons, shown on hover ------------------
cli +new-window --target=wa --title=wa > /dev/null 2>&1
hl_wait_for 15 is wa 's["mode"]' expanded
# A first launch lists every window; this part is the per-window list.
[ "$(field wa 's["all_windows"]')" = True ] && sb wa --click=scope > /dev/null
hl_wait_for 10 is wa '(s["all_windows"], len(p))' "(False, 1)"
hl_check "B1 the panel lists this window's one pane" $? "$(sb wa)"
cli +split --target=wa --name=b > /dev/null 2>&1
hl_wait_for 10 lst_is 'len(ids("wa"))' 2
ids=$(lst '" ".join(ids("wa"))'); a=${ids% *}; b=${ids#* }
hl_wait_for 10 is wa '[x["tools"] for x in p]' "[['stash', 'close'], ['stash', 'close']]"
is wa '(row("'"$a"'")["tools_shown"], row("'"$b"'")["tools_shown"], s["add_shown"])' "(False, False, True)"
hl_check "B1b each of this window's rows offers - then x, hidden until hovered; the header shows its +" $? "$(sb wa)"

hover=$a
[ "${NEGATIVE:-0}" = 1 ] && hover=nobody
field wa 'None' "--hover=$hover" > /dev/null
is wa '(row("'"$a"'")["hovered"], row("'"$a"'")["tools_shown"], row("'"$b"'")["tools_shown"])' "(True, True, False)"
hl_check "B2 the pointer over a row shows its buttons and no other row's" $? "$(sb wa)"
field wa 'None' "--hover=$b" > /dev/null
is wa '(row("'"$a"'")["tools_shown"], row("'"$b"'")["tools_shown"])' "(False, True)"
hl_check "B3 moving to another row moves the buttons with it" $? "$(sb wa)"
field wa 'None' "--hover=" > /dev/null
is wa 'any(x["tools_shown"] for x in p)' False
hl_check "B4 the pointer leaving the list hides them" $? "$(sb wa)"

# ---- 2. stash and restore ----------------------------------------------------
sb wa "--click=tool:stash:$b" > /dev/null
hl_wait_for 10 is wa '(row("'"$b"'")["stashed"], row("'"$b"'")["tools"])' "(True, ['restore', 'close'])"
hl_check "B5 - stashes the pane; its row then offers the restore" $? "$(sb wa)"
sb wa "--click=tool:stash:$a" > /dev/null
is wa 'row("'"$a"'")["stashed"]' False
hl_check "B6 the last pane on screen is not stashed" $? "$(sb wa)"
grep -q "pane sidebar stash refused pane=$a" "$APP_LOG"
hl_check "B6b and the refusal is logged" $?
sb wa "--click=tool:restore:$b" > /dev/null
hl_wait_for 10 is wa 'row("'"$b"'")["stashed"]' False
hl_check "B7 the restore brings it back" $? "$(sb wa)"
hl_wait_for 10 lst_is 'focused("wa")' "$b"
hl_check "B8 focused, as a click on its row would" $? "focused=$(lst 'focused("wa")') want=$b"

# ---- 3. a pane's x closes it, asking nothing --------------------------------
cli +send-keys --target="$b" 'sleep 300' Enter > /dev/null 2>&1
dlg=$(hl_ipc close-dialog "--target=$b" --op=pane 2>&1)
case "$dlg" in *'"open":true'*) ctl=0 ;; *) ctl=1 ;; esac
hl_check "B9 control: with a program running, the pane's keyboard close asks first" $ctl "$dlg"
# Answered Cancel until it is gone, so B11 reads only what the sidebar's x
# put up (nothing). An answer that lands in the main-loop turn that presented
# the dialog leaves it on the window's dialog stack (the seam's own note), so
# each try answers again.
cancel_gone() { case "$(hl_ipc close-dialog "--target=$1" --answer=cancel 2>&1)" in *'"open":false'*) true ;; *) false ;; esac; }
hl_wait_for 10 cancel_gone "$b"
hl_check "B9b the control's dialog is answered Cancel and goes" $?
hl_wait_for 10 lst_is 'len(ids("wa"))' 2
sb wa "--click=tool:close:$b" > /dev/null
hl_wait_for 10 lst_is 'ids("wa")' "['$a']"
hl_check "B10 the row's x closes that pane, program running and all" $? "$(lst 'ids("wa")')"
dlg=$(hl_ipc close-dialog "--target=$a" 2>&1)
case "$dlg" in *'"open":false'*) nd=0 ;; *) nd=1 ;; esac
hl_check "B11 with no confirmation up" $nd "$dlg"
hl_wait_for 10 is wa '[x["pane"] for x in p]' "['$a']"
hl_check "B12 and its row is gone from the list" $? "$(sb wa)"

# ---- 4. all windows: another window's rows, the headers' + and x ------------
cli +new-window --target=wb --title=wb > /dev/null 2>&1
hl_wait_for 15 lst_is '"wb" in W' True
sb wa --click=scope > /dev/null
hl_wait_for 10 is wa '(s["all_windows"], head("wb")["tools"], head("wa")["tools"])' "(True, ['add', 'close'], ['add', 'close'])"
hl_check "B13 in all windows every window row offers + then x" $? "$(sb wa)"
kb=$(field wa 'head("wb")["pane"]')
field wa 'None' "--hover=$kb" > /dev/null
is wa '(head("wb")["tools_shown"], head("wa")["tools_shown"])' "(True, False)"
hl_check "B14 shown on its hover" $? "$(sb wa)"

pb=$(lst 'ids("wb")[0]')
sb wa "--click=tool:add:$kb" > /dev/null
hl_wait_for 10 lst_is 'len(ids("wb"))' 2
hl_check "B15 a window row's + adds a pane to that window" $? "$(lst 'ids("wb")')"
lst_is 'W["wb"]["tabs"][0]["splits"]["type"] == "split" and focused("wb") != "'"$pb"'"' True
hl_check "B16 split off its focused pane, the new pane focused (a manual surface)" $? "$(lst 'panes("wb")')"
grep -q 'pane sidebar add pane dir=right' "$APP_LOG"
hl_check "B16b in the default direction, right, with no split made by hand yet" $?

# Another window's pane, under its unfolded row: the x alone.
[ "$(field wa 'head("wb")["folded"]')" = True ] && sb wa "--click=fold:$kb" > /dev/null
pb2=$(lst 'ids("wb")[1]')
hl_wait_for 10 is wa 'row("'"$pb2"'")["tools"]' "['close']"
hl_check "B17 another window's pane row offers the x alone" $? "$(sb wa)"
sb wa "--click=tool:close:$pb2" > /dev/null
hl_wait_for 10 lst_is 'ids("wb")' "['$pb']"
hl_check "B18 which closes that pane in its own window" $? "$(lst 'ids("wb")')"

sb wa "--click=tool:close:$kb" > /dev/null
hl_wait_for 10 lst_is '"wb" in W' False
hl_check "B19 a window row's x closes that window" $? "$(lst 'list(W)')"
lst_is '"wa" in W' True
hl_check "B20 and only that one" $? "$(lst 'list(W)')"

# ---- 5. a project's + and x; the panel header's + ---------------------------
cli +new-window --target=p1 --title="grp: one" > /dev/null 2>&1
cli +new-window --target=p2 --title="grp: two" > /dev/null 2>&1
hl_wait_for 15 is wa 'head("grp", "project")["tools"]' "['add', 'close']"
hl_check "B21 a project header offers + then x" $? "$(sb wa)"
sb wa "--click=tool:add:project:grp" > /dev/null
hl_wait_for 15 lst_is '"grp: new" in T' True
hl_check "B22 its + opens a window titled into the group, <project>: new" $? "$(lst 'T')"
sb wa "--click=tool:add:project:grp" > /dev/null
hl_wait_for 15 lst_is '"grp: new-2" in T' True
hl_check "B23 again: the first free name, new-2" $? "$(lst 'T')"
hl_wait_for 10 is wa 'head("grp", "project")["count"]' 4
sb wa "--click=tool:close:project:grp" > /dev/null
hl_wait_for 15 lst_is 'sorted(t for t in T if t.startswith("grp"))' "[]"
hl_check "B24 its x closes every window of the group" $? "$(lst 'T')"
lst_is '"wa" in W' True
hl_check "B25 and none outside it" $? "$(lst 'list(W)')"

n0=$(lst 'len(W)')
sb wa --click=add > /dev/null
hl_wait_for 15 lst_is 'len(W)' $((n0 + 1))
hl_check "B26 the panel header's + opens a new window" $? "before=$n0 now=$(lst 'len(W)')"

# ---- 6. the rail has no row buttons ------------------------------------------
sb wa --click=toggle > /dev/null
hl_wait_for 10 is wa '(s["mode"], s["add_shown"], all(len(x["tools"]) == 0 for x in r))' "('mini', False, True)"
hl_check "B27 in the rail no row offers a button, and the header's + is gone" $? "$(sb wa)"

grep -q 'pane sidebar close pane' "$APP_LOG"
hl_check "B28 each close is logged with what it closed" $?

hl_finish "$L"
