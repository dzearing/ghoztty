#!/usr/bin/env bash
# cli-banner.sh - L10a (T3339) acceptance for the sticky pane banner and the
# activity state on the GTK debug app: +set-banner / OSC 7778 set and clear a
# card above the terminal (parsed by the shared banner markdown, drawn as GTK
# widgets), the terminal is laid out BELOW it (its rows shrink, and come back
# on a clear), +list --json reports `banner` and `state`, +set-state takes a
# pane or a whole window, and a viewer pane refuses both verbs with the
# shared sentence. T3561: the state shows in the window title (" (busy)",
# " (question)", pinned titles too) and on the tab (spinner, attention), and
# a right-click on a banner link offers the shared link menu (driven through
# the `pane-banner --link-menu/--menu-pick` debug seam, hand-offs recorded by
# GHOZTTY_TEST_VIEWER_LINKS). Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-banner.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), so no window ever
# reaches WSLg or the user's desktop. The card is read back through the debug
# build's GHOZTTY_TEST_BANNER_DUMP seam (PaneBanner.zig).
#
# Output: one PASS/FAIL line per check, then 'CLI BANNER: ALL PASS' or
# 'CLI BANNER: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI BANNER"

log=/tmp/cli-banner-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "F1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "F2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

fixture="$HL_RUNTIME/banner-fixture"
mkdir -p "$fixture/docs"
echo "# Doc" > "$fixture/docs/a.md"
dump="$HL_RUNTIME/banner-dump"
: > "$dump"

export SHELL=/bin/sh
export GHOZTTY_TEST_BANNER_DUMP="$dump"
# Every link hand-off is recorded there and the ones that would leave the
# app are not run (Viewer.linkSink), so the link menu checks stay in Weston.
links="$HL_RUNTIME/links"
: > "$links"
export GHOZTTY_TEST_VIEWER_LINKS="$links"
hl_launch APP "$app" --gtk-single-instance=false --working-directory="$fixture" -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_BANNER_DUMP GHOZTTY_TEST_VIEWER_LINKS
hl_wait_for 30 test -S "$sock"
f3=$?
hl_check "F3 the app serves its socket" $f3
[ $f3 = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

# leaf <field>: that field of the first terminal leaf of the first window, or
# '<absent>' when the leaf has no such field.
leaf() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
field = sys.argv[1]
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if l.get("type", "terminal") != "terminal": continue
            v = l.get(field)
            print("<absent>" if v is None else v); sys.exit(0)
' "$1" 2>/dev/null
}
have_pane() { [ -n "$(leaf id)" ] && [ "$(leaf id)" != "<absent>" ]; }
hl_wait_for 20 have_pane
pid=$(leaf id)
win=$(cli +list --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["windows"][0].get("target") or "")' 2>/dev/null)
[ -n "$pid" ] && [ -n "$win" ]
hl_check "F4 +list names the pane and its window" $? "pane=$pid window=$win"
[ -n "$pid" ] || hl_finish "$L"

read_has() { cli +read --name="$pid" --lines=200 2>/dev/null | grep -Eq "$1"; }
hl_wait_for 20 read_has '^hl\$ '
hl_check "F5 the shell is up" $?

# rows: the pane's terminal height in rows, as the shell sees it.
rows() {
    cli +send-keys --target="$pid" 'echo ROWS_$(stty size | cut -d" " -f1)_END' Enter > /dev/null 2>&1
    sleep 0.6
    cli +read --name="$pid" --lines=40 2>/dev/null | grep -Eo 'ROWS_[0-9]+_END' | tail -1 | grep -Eo '[0-9]+'
}
# last_block: the dump's most recent BANNER ... END block.
last_block() { awk '/^BANNER /{b=""} {b=b $0 "\n"} END{printf "%s", b}' "$dump"; }
dump_has() { last_block | grep -Fq -- "$1"; }
dump_shown() { last_block | head -1 | grep -q " shown$"; }
dump_cleared() { last_block | head -1 | grep -q " cleared$"; }

rows0=$(rows)
[ -n "$rows0" ]
hl_check "F6 the pane reports its rows before any banner" $? "rows=$rows0"

# osc <body>: the pane's shell prints ESC ] <body> BEL. Two layers of escape:
# bash's double quotes halve the backslashes, then +send-keys turns `\\` into
# one (its own `\0` would be a NUL), so the shell's printf sees `\033`/`\007`.
osc() { cli +send-keys --target="$pid" "printf '\\\\033]$1\\\\007'" Enter > /dev/null 2>&1; }

# /bin/sh reports no cwd on its own; say where it is, the way shell
# integration would (OSC 7), so ./ links have something to resolve against.
osc "7;file://$(hostname)$fixture"
sleep 0.5

# ---- argument handling (the shared verbs' sentences) ------------------------

out=$(cli +set-banner hello 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q -- "--target is required"
hl_check "A1 +set-banner with no --target fails with the shared sentence" $? "rc=$rc out=$out"

out=$(cli +set-state --target="$pid" 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q -- "--state is required"
hl_check "A2 +set-state with no --state fails" $? "rc=$rc out=$out"

out=$(cli +set-state --target="$pid" --state=sleepy 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "invalid state 'sleepy'"
hl_check "A3 +set-state with a bad state names it" $? "rc=$rc out=$out"

[ "$(leaf banner)" = "<absent>" ] && [ "$(leaf state)" = "idle" ]
hl_check "A4 a fresh pane lists no banner and state idle" $? "banner=$(leaf banner) state=$(leaf state)"

# ---- +set-banner draws a card and the terminal moves below it ---------------

text='## Build status\n**PR** _three_ __files__ `code` [view](https://example.com/pr/1)\n- [x] lint\n- [ ] tests\n1. first\n---\n| Job | State |\n|---|---:|\n| lint | ok |\nopen ./docs/a.md or ~/x.txt'
out=$(cli +set-banner --target="$pid" "$text" 2>&1); rc=$?
[ $rc = 0 ]
hl_check "B1 +set-banner --target=<pane> <markdown> exits 0" $? "rc=$rc out=$out"
hl_wait_for 10 dump_shown
hl_check "B2 the card is shown" $? "$(last_block | head -3 | tr '\n' '|')"

dump_has '  heading <span weight="bold" size="large">Build status</span>'
hl_check "B3 an ## heading draws bold and large" $? "$(last_block | tr '\n' '|' | head -c 600)"
dump_has '<b>PR</b> <i>three</i> <u>files</u> <tt>code</tt> <a href="https://example.com/pr/1"><u>view</u></a>'
hl_check "B4 inline styles and an explicit link become Pango markup" $? "$(last_block | grep -m1 '  text' )"
dump_has '  item [x]' && dump_has '  item [ ]' && dump_has '  item 1.' && dump_has '  content lint'
hl_check "B5 a list draws native checkboxes and its number marker in the gutter" $? "$(last_block | grep -E '  (item|content)' | tr '\n' '|')"
dump_has '  rule'
hl_check "B6 --- draws a separator" $?
dump_has '  table cols=2 rows=1 header=true' && dump_has '  th <span weight="bold">Job</span>' && dump_has '  td ok'
hl_check "B7 a pipe table draws a grid with a bold header" $? "$(last_block | grep -E '  (table|th|td)' | tr '\n' '|')"
dump_has "<a href=\"$fixture/docs/a.md\"><u>./docs/a.md</u></a>" && dump_has "<a href=\"$HOME/x.txt\"><u>~/x.txt</u></a>"
hl_check "B8 ./ and ~/ autolink against the pane's cwd and home, POSIX-joined" $? "$(last_block | grep -m1 'open' )"

got=$(leaf banner)
want=$(printf '%b' "$text")
[ "$got" = "$want" ]
hl_check "B9 +list --json reports the banner's source verbatim" $? "got=$(echo "$got" | head -c 120)"

# The resize reaches the pty a moment after the card lays out: poll.
rows_until() { local i r; for i in $(seq 1 15); do r=$(rows); if [ -n "$r" ] && eval "[ $r $1 $rows0 ]"; then echo "$r"; return 0; fi; done; echo "$r"; return 1; }
rows1=$(rows_until -lt)
[ -n "$rows1" ] && [ -n "$rows0" ] && [ "$rows1" -lt "$rows0" ]
hl_check "B10 the terminal is laid out below the card: fewer rows than before" $? "before=$rows0 after=$rows1"

# A window target sets its focused pane's banner.
out=$(cli +set-banner --target="$win" 'via window' 2>&1); rc=$?
hl_wait_for 10 dump_has '  text via window'
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ] && [ "$(leaf banner)" = "via window" ]
hl_check "B11 a window target sets its focused pane's banner" $? "rc=$rc out=$out banner=$(leaf banner)"

# ---- clearing --------------------------------------------------------------

out=$(cli +set-banner --target="$pid" --clear 2>&1); rc=$?
hl_wait_for 10 dump_cleared
lrc=$?
[ $rc = 0 ] && [ $lrc = 0 ] && [ "$(leaf banner)" = "<absent>" ]
hl_check "C1 --clear removes the card and the banner field" $? "rc=$rc out=$out banner=$(leaf banner)"

rows2=$(rows_until =)
[ -n "$rows2" ] && [ "$rows2" = "$rows0" ]
hl_check "C2 the terminal takes its rows back" $? "before=$rows0 cleared=$rows2"

out=$(cli +set-banner --target="$pid" --clear 2>&1); rc=$?
[ $rc = 0 ]
hl_check "C3 clearing again succeeds (idempotent)" $? "rc=$rc out=$out"

# ---- OSC 7778 from inside the pane -----------------------------------------

osc '7778;**from** osc'
hl_wait_for 10 dump_has '  text <b>from</b> osc'
lrc=$?
[ $lrc = 0 ] && [ "$(leaf banner)" = "**from** osc" ]
hl_check "O1 OSC 7778 from the pane sets its banner" $? "banner=$(leaf banner) $(last_block | tr '\n' '|' | head -c 200)"

osc '7778;'
hl_wait_for 10 dump_cleared
lrc=$?
[ $lrc = 0 ] && [ "$(leaf banner)" = "<absent>" ]
hl_check "O2 an empty OSC 7778 clears it" $? "banner=$(leaf banner)"

# ---- +set-state ------------------------------------------------------------

# wtitle: the first window's title as +list reports it (GtkWindow:title).
wtitle() { cli +list --json 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["windows"][0].get("title") or "")' 2>/dev/null; }
title0=$(wtitle)

out=$(cli +set-state --target="$pid" --state=busy 2>&1); rc=$?
[ $rc = 0 ] && [ "$(leaf state)" = "busy" ]
hl_check "S1 +set-state --state=busy on the pane lists state busy" $? "rc=$rc out=$out state=$(leaf state)"
t=$(wtitle)
[ -n "$title0" ] && [ "$t" = "$title0 (busy)" ]
hl_check "S1t the window title gains ' (busy)' (T3561)" $? "before='$title0' now='$t'"
grep -q 'activity: tab=0 state=busy loading=true' "$APP_LOG"
hl_check "S1m its tab shows the busy spinner (AdwTabPage:loading)" $? "$(grep -m2 'activity: tab' "$APP_LOG" | tr '\n' '|')"

out=$(cli +set-state --target="$win" --state=needs_input 2>&1); rc=$?
[ $rc = 0 ] && [ "$(leaf state)" = "needs_input" ]
hl_check "S2 a window target sets every terminal pane in it" $? "rc=$rc out=$out state=$(leaf state)"
t=$(wtitle)
[ "$t" = "$title0 (question)" ]
hl_check "S2t needs_input shows its human label, ' (question)', never the token" $? "now='$t'"
grep -q 'activity: tab=0 state=needs_input loading=false attention=true' "$APP_LOG"
hl_check "S2m its tab asks for attention" $? "$(grep 'activity: tab' "$APP_LOG" | tail -2 | tr '\n' '|')"

osc '7777;idle'
is_idle() { [ "$(leaf state)" = "idle" ]; }
hl_wait_for 10 is_idle
hl_check "S3 OSC 7777 from the pane sets its state" $? "state=$(leaf state)"
t=$(wtitle)
[ "$t" = "$title0" ]
hl_check "S3t idle drops the suffix" $? "now='$t'"

out=$(cli +rename --target="$win" --title=pinned 2>&1)
cli +set-state --target="$pid" --state=busy > /dev/null 2>&1
t=$(wtitle)
[ "$t" = "pinned (busy)" ]
hl_check "S4t a pinned title carries the suffix too (Mac computeTitle)" $? "rename=$out now='$t'"
cli +set-state --target="$pid" --state=idle > /dev/null 2>&1
cli +rename --target="$win" --title= > /dev/null 2>&1
t=$(wtitle)
[ "$t" = "$title0" ]
hl_check "S5t unpinned and idle, the title is the tab's again" $? "now='$t'"

# ---- the banner link menu (T3561) -------------------------------------------
# A right-click on a link pops banner_link's menu; under the sink the menu is
# recorded and a row is run by `pane-banner --menu-pick`.

sink_has() { grep -Fxq -- "$1" "$links"; }
cli +set-banner --target="$pid" "[w](https://example.com/) [f]($fixture/docs/a.md) [g](ghoztty://focus/$pid)" > /dev/null 2>&1
hl_ipc pane-banner --target="$pid" --link-menu=https://example.com/ > /dev/null
sink_has "menu web https://example.com/ rows=open_browser|side_pane,new_window|copy"
hl_check "M1 a web link's menu: browser | side pane, new window | copy link" $? "$(tail -3 "$links" | tr '\n' '|')"
hl_ipc pane-banner --target="$pid" --link-menu="$fixture/docs/a.md" > /dev/null
sink_has "menu file $fixture/docs/a.md rows=reveal|side_pane,new_window|open_default_app|copy"
hl_check "M2 a file link's menu: reveal | side pane, new window | default app | copy path" $? "$(tail -3 "$links" | tr '\n' '|')"
hl_ipc pane-banner --target="$pid" --menu-pick=copy > /dev/null
sink_has "copy $fixture/docs/a.md"
hl_check "M3 Copy Path copies the file's path" $? "$(tail -3 "$links" | tr '\n' '|')"
hl_ipc pane-banner --target="$pid" --menu-pick=side_pane > /dev/null
sink_has "split $fixture/docs/a.md"
hl_check "M4 Open in Side Pane splits a viewer beside the pane" $? "$(tail -3 "$links" | tr '\n' '|')"
hl_ipc pane-banner --target="$pid" --link-menu="ghoztty://focus/$pid" > /dev/null
sink_has "menu command ghoztty://focus/$pid rows=focus|copy"
hl_check "M5 a ghoztty:// link's menu: focus | copy link" $? "$(tail -3 "$links" | tr '\n' '|')"
hl_ipc pane-banner --target="$pid" --link-menu=https://example.com/ > /dev/null
hl_ipc pane-banner --target="$pid" --menu-pick=open_browser > /dev/null
sink_has "browser https://example.com/"
hl_check "M6 Open in Default Browser hands the link to the browser (recorded, never run)" $? "$(tail -3 "$links" | tr '\n' '|')"
out=$(hl_ipc pane-banner --target="$pid" --menu-pick=nope)
echo "$out" | grep -q "no menu row 'nope'"
hl_check "M7 an unknown row is refused by name" $? "$out"
# Close what M4 opened so the viewer checks below see one viewer.
for v in $(cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if l.get("type") == "viewer": print(l["id"])
'); do cli +close --target="$v" > /dev/null 2>&1; done
cli +set-banner --target="$pid" --clear > /dev/null 2>&1

# ---- a viewer pane has neither ---------------------------------------------

cli +split --target="$pid" --name=view --view="$fixture/docs/a.md" > /dev/null 2>&1
has_view() { cli +list --json 2>/dev/null | grep -Eq '"name": ?"view"'; }
hl_wait_for 20 has_view
out=$(cli +set-banner --target=view hi 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "view is a viewer pane, not a terminal"
hl_check "V1 +set-banner on a viewer pane refuses with the shared sentence" $? "rc=$rc out=$out"
out=$(cli +set-state --target=view --state=busy 2>&1); rc=$?
[ $rc != 0 ] && echo "$out" | grep -q "view is a viewer pane, not a terminal"
hl_check "V2 +set-state on a viewer pane refuses too" $? "rc=$rc out=$out"
cli +list --json 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if l.get("type") == "viewer" and ("state" in l or "banner" in l): sys.exit(1)
'
hl_check "V3 a viewer leaf lists neither state nor banner" $?

hl_finish "$L"
