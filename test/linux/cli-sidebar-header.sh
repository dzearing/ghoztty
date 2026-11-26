#!/usr/bin/env bash
# cli-sidebar-header.sh - L10e (T3695) acceptance for the pane sidebar's own
# window header and the rail's + on the GTK debug app
# (docs/reference/pane-sidebar.md "Rows and tiles": a window always holds its
# panes; "Adding from the sidebar"):
#
#   - this window's list starts with its header - the window's name, its
#     count, a fold chevron, + and x on hover - with its panes one level in;
#     the panel's caption is "Panes";
#   - the header folds the panes away in this list only, and folded it is
#     drawn selected (its focused pane is inside the fold);
#   - its + adds a pane to this window, its x closes the window;
#   - a `<project>: <name>` window's list has the group's header above its
#     own (labeled by worktree), counting the whole group; a folded group is
#     its header alone;
#   - the rail starts with a +: a new pane in this window's list, a new
#     window in all windows.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-sidebar-header.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop. The harness has no pointer: the debug
# build's `pane-sidebar` IPC seam (IpcHandlers.zig) folds (`--click=fold:`),
# clicks a button (`--click=tool:<button>:<row id>`) and a row
# (`--click=rail-add`).
#
# NEGATIVE=1 never folds the header, which must FAIL H4 (the harness can see
# a header that did not fold).
#
# Output: one PASS/FAIL line per check, then 'CLI SIDEBAR HEADER: ALL PASS' or
# 'CLI SIDEBAR HEADER: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI SIDEBAR HEADER"

log=/tmp/cli-sidebar-header-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "H0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "H0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

fixture="$HL_RUNTIME/sidebar-header-fixture"
mkdir -p "$fixture/proj"
export SHELL=/bin/sh
export HOME="$fixture"

rm -f "$sock"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false \
    --macos-pane-sidebar=expanded \
    --working-directory="$fixture/proj" -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
h0c=$?
hl_check "H0c the app serves its socket" $h0c
[ $h0c = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

# sb <target> [seam args...]: the seam's report for that target's window.
sb() { local t=$1; shift; hl_ipc pane-sidebar "--target=$t" "$@" 2>/dev/null; }
# field <target> <python expr over s (the sidebar), r (its rows), p (its
# pane rows), k (its rows' kinds) and head(label[, kind])>
field() {
    local t=$1 e=$2; shift 2
    sb "$t" "$@" | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
s = d.get("sidebar") or {}
r = s.get("rows") or []
p = [x for x in r if x["kind"] in ("terminal", "viewer")]
k = [x["kind"] for x in r]
def head(label, kind="window"):
    return next((x for x in r if x["label"] == label and x["kind"] == kind), {})
print(eval(sys.argv[1]))
' "$e" 2>/dev/null
}
is() { [ "$(field "$1" "$2")" = "$3" ]; }
# lst <python expr over W (windows by target), T (every window's title) and
# ids(target)> - read from +list.
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
def ids(t):
    w = W.get(t)
    if not w: return []
    tab = next((x for x in w["tabs"] if x.get("selected")), w["tabs"][0])
    return [l["id"] for l in leaves(tab["splits"])]
print(eval(sys.argv[1]))
' "$1" 2>/dev/null
}
lst_is() { [ "$(lst "$1")" = "$2" ]; }

# ---- 1. this window's header over its panes ---------------------------------
cli +new-window --target=wa --title=wa > /dev/null 2>&1
hl_wait_for 15 is wa 's["mode"]' expanded
# A first launch lists every window; this suite is the per-window list.
[ "$(field wa 's["all_windows"]')" = True ] && sb wa --click=scope > /dev/null
hl_wait_for 10 is wa '(s["all_windows"], k)' "(False, ['window', 'terminal'])"
hl_check "H1 this window's list is its header, then its pane" $? "$(sb wa)"
is wa '(r[0]["label"], r[0]["count"], r[0]["folded"], r[0]["selection"], s["title"])' "('wa', 1, False, 'none', 'Panes')"
hl_check "H2 the header is the window's name and count, open and unselected; the caption says Panes" $? "$(sb wa)"
is wa '(r[0]["tools"], r[0]["tools_shown"], r[0]["depth"], p[0]["depth"], p[0]["selected"])' "(['add', 'close'], False, 0, 1, True)"
hl_check "H3 it offers + and x on hover; its pane sits one level in, selected" $? "$(sb wa)"
ka=$(field wa 'r[0]["pane"]')

# ---- 2. the fold is this list's own ------------------------------------------
[ "${NEGATIVE:-0}" = 1 ] || sb wa "--click=fold:$ka" > /dev/null
hl_wait_for 10 is wa '(k, r[0]["folded"], r[0]["selection"], r[0]["selected"])' "(['window'], True, 'accent', True)"
hl_check "H4 the chevron folds the panes away, and the folded header carries the selection" $? "$(sb wa)"
sb wa "--click=fold:$ka" > /dev/null
hl_wait_for 10 is wa '(k, r[0]["folded"])' "(['window', 'terminal'], False)"
hl_check "H5 and unfolds them again" $? "$(sb wa)"

# ---- 3. its + and x ----------------------------------------------------------
sb wa "--click=tool:add:$ka" > /dev/null
hl_wait_for 10 lst_is 'len(ids("wa"))' 2
hl_check "H6 the header's + adds a pane to this window" $? "$(lst 'ids("wa")')"
hl_wait_for 10 is wa '(k, r[0]["count"])' "(['window', 'terminal', 'terminal'], 2)"
hl_check "H7 listed under the header, which counts it" $? "$(sb wa)"
grep -q 'pane sidebar add pane dir=right from=row' "$APP_LOG"
hl_check "H7b split the way the user last split by hand (right, by default)" $?

cli +new-window --target=wc --title=wc > /dev/null 2>&1
hl_wait_for 15 is wc 'r[0]["label"] if r else ""' wc
kc=$(field wc 'r[0]["pane"]')
sb wc "--click=tool:close:$kc" > /dev/null
hl_wait_for 10 lst_is '"wc" in W' False
hl_check "H8 the header's x closes this window" $? "$(lst 'list(W)')"
lst_is '"wa" in W' True
hl_check "H8b and no other" $? "$(lst 'list(W)')"

# ---- 4. a grouped window: its group's header above its own ------------------
cli +new-window --target=p1 --title="grp: one" > /dev/null 2>&1
cli +new-window --target=p2 --title="grp: two" > /dev/null 2>&1
hl_wait_for 15 is p1 '(k, r[0]["label"], r[0]["count"], r[1]["label"])' "(['project', 'window', 'terminal'], 'grp', 2, 'one')"
hl_check "H9 a project window's list has the group's header (counting the group) over its own, labeled by worktree" $? "$(sb p1)"
is p1 '(r[1]["depth"], r[2]["depth"])' "(1, 2)"
hl_check "H9b each a level in under the one above" $? "$(sb p1)"
sb p1 "--click=fold:project:grp" > /dev/null
hl_wait_for 10 is p1 '(k, r[0]["folded"])' "(['project'], True)"
hl_check "H10 a folded group is its header alone" $? "$(sb p1)"
sb p1 "--click=fold:project:grp" > /dev/null
hl_wait_for 10 is p1 'k' "['project', 'window', 'terminal']"
hl_check "H10b unfolded, the window is back" $? "$(sb p1)"

# ---- 5. the rail's + ---------------------------------------------------------
sb wa --click=toggle > /dev/null
hl_wait_for 10 is wa '(s["mode"], k, r[0]["tooltip"], r[0]["label_shown"])' "('mini', ['rail_add', 'terminal', 'terminal'], 'New pane', False)"
hl_check "H11 the rail starts with a + where the header was, then a tile per pane" $? "$(sb wa)"
sb wa --click=rail-add > /dev/null
hl_wait_for 10 lst_is 'len(ids("wa"))' 3
hl_check "H12 in Panes the rail's + adds a pane to this window" $? "$(lst 'ids("wa")')"
grep -q 'pane sidebar add pane dir=right from=rail' "$APP_LOG"
hl_check "H12b logged from the rail" $?

sb wa --click=scope > /dev/null
n0=$(lst 'len(W)')
hl_wait_for 10 is wa '(s["all_windows"], k[0], r[0]["tooltip"], k.count("tile"))' "(True, 'rail_add', 'New window', $n0)"
hl_check "H13 in all windows the rail's + heads the window tiles" $? "$(sb wa) windows=$n0"
sb wa --click=rail-add > /dev/null
hl_wait_for 15 lst_is 'len(W)' $((n0 + 1))
hl_check "H14 there it opens a new window" $? "before=$n0 now=$(lst 'len(W)')"
grep -q 'pane sidebar add window (rail)' "$APP_LOG"
hl_check "H14b logged from the rail" $?

hl_finish "$L"
