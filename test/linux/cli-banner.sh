#!/usr/bin/env bash
# cli-banner.sh - L10a (T3339) acceptance for the sticky pane banner and the
# activity state on the GTK debug app: +set-banner / OSC 7778 set and clear a
# card above the terminal (parsed by the shared banner markdown, drawn as GTK
# widgets), the terminal is laid out BELOW it (its rows shrink, and come back
# on a clear), +list --json reports `banner` and `state`, +set-state takes a
# pane or a whole window, and a viewer pane refuses both verbs with the
# shared sentence. Run it ONLY through the wrapper, from this box:
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
cd "$fixture"
hl_launch APP "$app" --gtk-single-instance=false --working-directory="$fixture" -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
cd - > /dev/null
unset GHOZTTY_TEST_BANNER_DUMP
hl_wait_for 30 test -S "$sock"
hl_check "F3 the app serves its socket" $?

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
dump_has '<b>PR</b> <i>three</i> <u>files</u> <tt>code</tt> <a href="https://example.com/pr/1">view</a>'
hl_check "B4 inline styles and an explicit link become Pango markup" $? "$(last_block | grep -m1 '  text' )"
dump_has '  item [x]' && dump_has '  item [ ]' && dump_has '  item 1.' && dump_has '  content lint'
hl_check "B5 a list draws native checkboxes and its number marker in the gutter" $? "$(last_block | grep -E '  (item|content)' | tr '\n' '|')"
dump_has '  rule'
hl_check "B6 --- draws a separator" $?
dump_has '  table cols=2 rows=1 header=true' && dump_has '  th <span weight="bold">Job</span>' && dump_has '  td ok'
hl_check "B7 a pipe table draws a grid with a bold header" $? "$(last_block | grep -E '  (table|th|td)' | tr '\n' '|')"
dump_has "<a href=\"$fixture/docs/a.md\">./docs/a.md</a>" && dump_has "<a href=\"$HOME/x.txt\">~/x.txt</a>"
hl_check "B8 ./ and ~/ autolink against the pane's cwd and home, POSIX-joined" $? "$(last_block | grep -m1 'open' )"

got=$(leaf banner)
want=$(printf '%b' "$text")
[ "$got" = "$want" ]
hl_check "B9 +list --json reports the banner's source verbatim" $? "got=$(echo "$got" | head -c 120)"

rows1=$(rows)
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

rows2=$(rows)
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

out=$(cli +set-state --target="$pid" --state=busy 2>&1); rc=$?
[ $rc = 0 ] && [ "$(leaf state)" = "busy" ]
hl_check "S1 +set-state --state=busy on the pane lists state busy" $? "rc=$rc out=$out state=$(leaf state)"

out=$(cli +set-state --target="$win" --state=needs_input 2>&1); rc=$?
[ $rc = 0 ] && [ "$(leaf state)" = "needs_input" ]
hl_check "S2 a window target sets every terminal pane in it" $? "rc=$rc out=$out state=$(leaf state)"

osc '7777;idle'
is_idle() { [ "$(leaf state)" = "idle" ]; }
hl_wait_for 10 is_idle
hl_check "S3 OSC 7777 from the pane sets its state" $? "state=$(leaf state)"

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
