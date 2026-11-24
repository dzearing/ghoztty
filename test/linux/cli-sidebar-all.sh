#!/usr/bin/env bash
# cli-sidebar-all.sh - L10c (T3558) acceptance for the pane sidebar's
# all-windows list on the GTK debug app (docs/reference/pane-sidebar.md "All
# windows"): a first launch opens in it; every window (tab) is a row, folded,
# with its pane count; lone windows first under an Ungrouped header beside a
# `<project>: <worktree>` group, labeled by worktree in Finder order; the
# folds are one state for every window; the search keeps every term's panes,
# unfolds, is shared, Return goes to the first hit and Escape clears it; a
# pane row in another window focuses it there; the rail is one tile per
# window; the scope button switches back to this window's panes and the
# choice is kept across a relaunch; a closed window leaves every list. Run it
# ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-sidebar-all.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs in the
# private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop. The sidebar is read and clicked through
# the debug build's `pane-sidebar` IPC seam (IpcHandlers.zig) - the harness
# has no pointer and no keyboard.
#
# NEGATIVE=1 searches for a term no pane has, which must FAIL A12.
#
# Output: one PASS/FAIL line per check, then 'CLI SIDEBAR ALL: ALL PASS' or
# 'CLI SIDEBAR ALL: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI SIDEBAR ALL"

log=/tmp/cli-sidebar-all-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "A1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "A2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
prefs="$XDG_CONFIG_HOME/ghoztty/pane-sidebar-debug"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

fixture="$HL_RUNTIME/sidebar-all-fixture"
mkdir -p "$fixture/proj"
export SHELL=/bin/sh
export HOME="$fixture"

launch() {
    local var=$1; shift
    rm -f "$sock"
    hl_launch "$var" "$app" --gtk-single-instance=false --session-persistence=false \
        --working-directory="$fixture/proj" "$@" -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
    hl_wait_for 30 test -S "$sock"
}
stop() { kill -TERM "$1" 2>/dev/null; hl_wait_for 10 sh -c "! kill -0 $1 2>/dev/null"; }

# sb <target> [seam args...]: the seam's report for that target's window.
sb() { local t=$1; shift; hl_ipc pane-sidebar "--target=$t" "$@" 2>/dev/null; }
# field <target> <python expr over s (the sidebar), r (its rows), h (its
# header rows), p (its pane rows)>
field() {
    sb "$1" | python3 -c '
import json, sys
d = json.loads(sys.stdin.read() or "{}")
s = d.get("sidebar") or {}
r = s.get("rows") or []
h = [x for x in r if x["kind"] in ("window", "project", "ungrouped", "tile")]
p = [x for x in r if x["kind"] in ("terminal", "viewer")]
def row(label, kind="window"):
    return next((x for x in r if x["label"] == label and x["kind"] == kind), {})
print(eval(sys.argv[1]))
' "$2" 2>/dev/null
}
is() { [ "$(field "$1" "$2")" = "$3" ]; }
pane_of() { # the first pane id of the window called <target>
    cli +list --json 2>/dev/null | python3 -c '
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
        print(" ".join(l["id"] for l in leaves(tab["splits"])))
' "$1" 2>/dev/null
}
focused() { # the focused pane id in the window called <target>
    cli +list --json 2>/dev/null | python3 -c '
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
        print(next((l["id"] for l in leaves(tab["splits"]) if l.get("focused")), ""))
' "$1" 2>/dev/null
}
focused_is() { [ "$(focused "$1")" = "$2" ]; }

# ---- 1. a first launch lists every window, folded --------------------------
launch APP --macos-pane-sidebar=expanded
a3=$?
hl_check "A3 the app serves its socket" $a3
[ $a3 = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }
cli +new-window --target=wa --title=alpha > /dev/null 2>&1
cli +new-window --target=wb --title="proj: wt-10" > /dev/null 2>&1
cli +new-window --target=wc --title="proj: wt-2" > /dev/null 2>&1
hl_wait_for 15 is wa 's["window_count"]' 4
hl_check "A4 a first launch lists all windows: the launch window and three more" $? "$(sb wa)"
is wa '(s["all_windows"], s["title"], s["search_shown"], s["scope_button_shown"])' "(True, 'All Windows', True, True)"
hl_check "A5 the panel says All Windows, with the search field and the scope button" $? "$(sb wa)"
is wa '[x["kind"] for x in r]' "['ungrouped', 'window', 'window', 'project', 'window', 'window']"
hl_check "A6 lone windows first under Ungrouped, then the project group; every window folded (no pane rows)" $? "$(field wa '[(x["kind"], x["label"]) for x in r]')"
is wa '([x["label"] for x in r][3:], row("proj", "project")["count"], row("Ungrouped", "ungrouped")["count"])' "(['proj', 'wt-2', 'wt-10'], 2, 2)"
hl_check "A7 the group is labeled by project, its windows by worktree in Finder order (2 before 10), with counts" $? "$(field wa '[(x["label"], x["count"]) for x in r]')"
is wa '(row("alpha")["folded"], row("alpha")["count"], row("alpha")["selection"], row("wt-2")["selection"])' "(True, 1, 'accent', 'none')"
hl_check "A8 this window's folded row is the accent; every row counts its panes" $? "$(field wa 'row("alpha")')"

# ---- 2. the folds are one state for every window ---------------------------
alpha_id=$(field wa 'row("alpha")["pane"]')
a_pane=$(pane_of wa)
sb wa "--click=fold:$alpha_id" > /dev/null
hl_wait_for 10 is wa 'r[r.index(row("alpha")) + 1]["kind"]' terminal
hl_check "A9 unfolding a window lists its panes under it" $? "$(field wa '[(x["kind"], x["label"]) for x in r]')"
is wa '(row("alpha")["selection"], p[0]["pane"], p[0]["selected"], p[0]["depth"] > row("alpha")["depth"])' "('unemphasized', '$a_pane', True, True)"
hl_check "A10 open, its row is unemphasized and its focused pane's row (a level in) has the selection" $? "$(field wa 'r[:4]')"
is wb '(row("alpha")["folded"], len(p))' "(False, 1)"
hl_check "A11 the unfold shows in another window's list too (absolute, shared folds)" $? "$(field wb '[(x["kind"], x["label"], x["folded"]) for x in r]')"
sb wa "--click=project:proj" > /dev/null
hl_wait_for 10 is wb '([x["kind"] for x in h], row("proj", "project")["folded"])' "(['ungrouped', 'window', 'window', 'project'], True)"
hl_check "A11b clicking a project header folds its windows away, in every list" $? "$(field wb '[(x["kind"], x["label"]) for x in r]')"
sb wa "--click=project:proj" > /dev/null
hl_wait_for 10 is wa 'row("proj", "project")["folded"]' False

# ---- 3. the search ---------------------------------------------------------
cli +split --target=wc --name=needle > /dev/null 2>&1
two_panes() { [ "$(pane_of wc | wc -w)" -ge 2 ]; }
hl_wait_for 10 two_panes
cli +set-banner --target=needle '## Needle Task' > /dev/null 2>&1
needle_pane=$(pane_of wc | awk '{print $2}')
term=needle
[ "${NEGATIVE:-0}" = 1 ] && term=zzqx-nothing
sb wa "--search=$term" > /dev/null
hl_wait_for 10 is wa '([(x["kind"], x["label"]) for x in r], s["search"])' "([('project', 'proj'), ('window', 'wt-2'), ('terminal', 'Needle Task')], 'needle')"
hl_check "A12 a search keeps only the matching pane (by its banner) and its window, unfolded" $? "$(field wa '([(x["kind"], x["label"]) for x in r], s["search"])')"
is wb '(s["search"], s["search_field"], len(p))' "('needle', 'needle', 1)"
hl_check "A13 the search is every window's: another window's field and list show it" $? "$(field wb '(s["search"], s["search_field"], [x["label"] for x in r])')"
sb wa "--search=NEEDLE proj" > /dev/null
hl_wait_for 10 is wa 'len(p)' 1
hl_check "A14 every term must match, in any field (the window's name too), ignoring case" $? "$(field wa '[x["label"] for x in r]')"
sb wa "--search=needle zzqx" > /dev/null
hl_wait_for 10 is wa 'len(r)' 0
hl_check "A15 a term no pane has lists nothing" $? "$(field wa '[x["label"] for x in r]')"
sb wa "--search=needle" > /dev/null
sb wa "--search-key=enter" > /dev/null
hl_wait_for 10 focused_is wc "$needle_pane"
hl_check "A16 Return goes to the first hit: that pane is focused in its own window" $? "focused=$(focused wc) want=$needle_pane"
sb wa "--search-key=escape" > /dev/null
hl_wait_for 10 is wa '(s["search"], s["search_field"], row("alpha")["folded"], len(h))' "('', '', False, 6)"
hl_check "A17 Escape clears the search, and the folds are back as they were" $? "$(field wa '(s["search"], [(x["label"], x["folded"]) for x in h])')"

# ---- 4. rows of other windows ----------------------------------------------
wb_id=$(field wa 'row("wt-10")["pane"]')
b_pane=$(pane_of wb)
sb wa "--click=fold:$wb_id" > /dev/null
hl_wait_for 10 is wa "any(x['pane'] == '$b_pane' for x in p)" True
sb wa "--click=$b_pane" > /dev/null
hl_wait_for 10 grep -q "pane sidebar row clicked pane=$b_pane other_window=true" "$APP_LOG"
hl_check "A18 clicking another window's pane row focuses it there (its window is raised)" $? "$(grep 'pane sidebar row clicked' "$APP_LOG" | tail -2)"
focused_is wb "$b_pane"
hl_check "A18b and that pane is its window's focused pane" $? "focused=$(focused wb) want=$b_pane"
sb wa "--click=$wb_id" > /dev/null
hl_wait_for 10 grep -q "pane sidebar window clicked key=${wb_id#window:}" "$APP_LOG"
hl_check "A19 clicking a window's row raises that window" $? "$(grep 'pane sidebar window clicked' "$APP_LOG" | tail -2)"

# ---- 5. the rail: one tile per window --------------------------------------
sb wa --click=toggle > /dev/null
hl_wait_for 10 is wa '(s["mode"], [x["kind"] for x in r], s["search_shown"], s["scope_button_shown"])' "('mini', ['tile', 'tile', 'tile', 'tile'], False, False)"
hl_check "A20 collapsed, all windows is one tile per window; no field, no scope button" $? "$(field wa '(s["mode"], [x["kind"] for x in r])')"
is wa '([x["tooltip"] for x in r if x["selected"]], [x["tooltip"] for x in r][-2:])' "(['alpha'], ['proj: wt-2', 'proj: wt-10'])"
hl_check "A21 a tile's tooltip is its window's full name; this window's tile is selected; the list's order" $? "$(field wa '[(x["tooltip"], x["selected"]) for x in r]')"
sb wa --click=toggle > /dev/null

# ---- 6. back to this window; kept across a relaunch ------------------------
sb wa --click=scope > /dev/null
hl_wait_for 10 is wa '(s["all_windows"], [x["kind"] for x in r], s["title"], s["search_shown"])' "(False, ['terminal'], 'alpha', False)"
hl_check "A22 the scope button switches every window back to its own panes" $? "$(field wa '(s["all_windows"], [x["kind"] for x in r], s["title"])')"
is wb 's["all_windows"]' False
hl_check "A23 for every window at once" $? "$(sb wb)"
hl_wait_for 5 grep -q ' 0$' "$prefs"
hl_check "A24 the choice is written to the flags file" $? "$(cat "$prefs" 2>/dev/null)"
sb wa --click=scope > /dev/null
hl_wait_for 10 is wa '[x["folded"] for x in h if x["kind"] == "window"]' "[True, True, True, True]"
hl_check "A25 back on, every window is folded again (the scope forgot the folds)" $? "$(field wa '[(x["label"], x["folded"]) for x in h]')"

# ---- 7. a closed window leaves every list ----------------------------------
cli +close --target=wc > /dev/null 2>&1
hl_wait_for 10 is wa '(s["window_count"], row("proj", "project")["count"], row("wt-2")) ' "(3, 1, {})"
hl_check "A26 a closed window leaves the other windows' lists" $? "$(field wa '[(x["label"], x["count"]) for x in h]')"

sb wa --click=scope > /dev/null
stop "$APP"
launch APP2
cli +new-window --target=wd > /dev/null 2>&1
hl_wait_for 15 is wd '(s["all_windows"], s["mode"])' "(False, 'expanded')"
hl_check "A27 a relaunch keeps the scope the user left (this window)" $? "$(sb wd) file=$(cat "$prefs" 2>/dev/null)"
stop "$APP2"

hl_finish "$L"
