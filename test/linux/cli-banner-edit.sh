#!/usr/bin/env bash
# cli-banner-edit.sh - L10b (T3559) acceptance for the pane banner's collapse
# and its Set Pane Banner editor on the GTK debug app (docs/reference/
# banners.md): a click on a multi-line card, or on its chevron, folds it to
# its title row and back (the terminal gets its rows back, once), a one-line
# card does not fold, a new text keeps the fold and a clear resets it; and
# Ctrl+Shift+B opens the editor filled with the banner, where Return is the
# text box's (a newline), Ctrl+Return saves, Escape cancels and a blank text
# clears. Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-banner-edit.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh). Wayland gives the
# harness no pointer or keyboard, so clicks and editor keys go through the
# debug build's `pane-banner` seam and the chord through `press-key`, which
# feeds the configured binding table like a real key. `NEGATIVE=1` presses
# Ctrl+R instead of Ctrl+Shift+B, and E1 must fail.
#
# Output: one PASS/FAIL line per check, then 'CLI BANNER EDIT: ALL PASS' or
# 'CLI BANNER EDIT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI BANNER EDIT"

log=/tmp/cli-banner-edit-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "F1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "F2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

dump="$HL_RUNTIME/banner-dump"
: > "$dump"
export SHELL=/bin/sh
export GHOZTTY_TEST_BANNER_DUMP="$dump"
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_BANNER_DUMP
hl_wait_for 30 test -S "$sock"
f3=$?
hl_check "F3 the app serves its socket" $f3
[ $f3 = 0 ] || { echo "--- app log tail:"; tail -40 "$APP_LOG"; hl_finish "$L"; }

pane_id() { hl_first_pane "$app"; }
have_pane() { [ -n "$(pane_id)" ]; }
hl_wait_for 20 have_pane
pid=$(pane_id)
[ -n "$pid" ]
hl_check "F4 +list names the pane" $? "pane=$pid"
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
# rows_until <op> <n>: poll until the rows compare <op> n; prints the last.
rows_until() { local i r; for i in $(seq 1 15); do r=$(rows); if [ -n "$r" ] && eval "[ $r $1 $2 ]"; then echo "$r"; return 0; fi; done; echo "$r"; return 1; }

# seam [args...]: one pane-banner request for this pane; prints the reply.
seam() { hl_ipc pane-banner --target="$pid" "$@"; }
# field <json> <path>: a dotted path of the reply, Python's repr of it.
field() { printf '%s' "$1" | python3 -I -c '
import json, sys
v = json.loads(sys.stdin.read())
for k in sys.argv[1].split("."): v = v.get(k) if isinstance(v, dict) else None
print({True: "true", False: "false", None: "null"}.get(v, v) if not isinstance(v, str) else v)
' "$2"; }
state() { field "$(seam)" "$1"; }
last_block() { awk '/^BANNER /{b=""} {b=b $0 "\n"} END{printf "%s", b}' "$dump"; }
dump_has() { last_block | grep -Fq -- "$1"; }
banner_is() { [ "$(state banner.text)" = "$1" ]; }
editor_closed() { [ "$(state editor.open)" = "false" ]; }

rows0=$(rows)
[ -n "$rows0" ]
hl_check "F6 the pane reports its rows before any banner" $? "rows=$rows0"

# ---- a one-line card has nothing to fold ------------------------------------

cli +set-banner --target="$pid" 'just a title' > /dev/null 2>&1
hl_wait_for 10 dump_has '  state fixed'
hl_check "C1 a one-line banner is drawn not collapsible" $? "$(last_block | head -3 | tr '\n' '|')"
r=$(seam --click=card)
[ "$(field "$r" banner.collapsible)" = "false" ] && [ "$(field "$r" banner.collapsed)" = "false" ]
hl_check "C2 a click on a one-line card does not fold it" $? "$r"

# ---- a multi-line card folds to its title row and back ----------------------

text='## Build status\nthe body line\n- [x] lint\n- [ ] tests\n| Job | State |\n|---|---|\n| lint | ok |'
cli +set-banner --target="$pid" "$text" > /dev/null 2>&1
hl_wait_for 10 dump_has '  state expanded'
r=$(seam)
[ "$(field "$r" banner.collapsible)" = "true" ] && [ "$(field "$r" banner.collapsed)" = "false" ] && dump_has '  content tests'
hl_check "C3 a multi-line banner is drawn expanded, every block in it" $? "$r"
rows_open=$(rows_until -lt "$rows0")
hl_check "C4 the expanded card takes rows from the terminal" $? "before=$rows0 expanded=$rows_open"

r=$(seam --click=card)
[ "$(field "$r" banner.collapsed)" = "true" ] && dump_has '  state collapsed'
hl_check "C5 a click on the card folds it" $? "$r"
dump_has '  heading <span weight="bold" size="large">Build status</span>' && ! dump_has 'the body line' && ! dump_has '  content tests' && ! dump_has '  table'
hl_check "C6 folded, the card draws only its title row" $? "$(last_block | tr '\n' '|')"
rows_shut=$(rows_until -gt "$rows_open")
hl_check "C7 folded, the terminal gets rows back" $? "expanded=$rows_open folded=$rows_shut"

r=$(seam --click=card)
[ "$(field "$r" banner.collapsed)" = "false" ] && dump_has '  content tests'
hl_check "C8 a second click unfolds it, every block back" $? "$r"
rows_back=$(rows_until = "$rows_open")
hl_check "C9 unfolded, the terminal is back to the expanded rows" $? "expanded=$rows_open now=$rows_back"

r=$(seam --click=chevron)
[ "$(field "$r" banner.collapsed)" = "true" ]
hl_check "C10 the chevron folds it too" $? "$r"
r=$(seam --click=chevron)
[ "$(field "$r" banner.collapsed)" = "false" ]
hl_check "C11 ... and unfolds it" $? "$r"

seam --click=card > /dev/null
cli +set-banner --target="$pid" '## Second\nanother body' > /dev/null 2>&1
hl_wait_for 10 dump_has 'Second'
r=$(seam)
[ "$(field "$r" banner.collapsed)" = "true" ] && dump_has '  state collapsed' && ! dump_has 'another body'
hl_check "C12 a new multi-line text keeps the fold" $? "$r"

cli +set-banner --target="$pid" --clear > /dev/null 2>&1
cli +set-banner --target="$pid" '## Third\nthird body' > /dev/null 2>&1
hl_wait_for 10 dump_has 'third body'
r=$(seam)
[ "$(field "$r" banner.collapsed)" = "false" ]
hl_check "C13 a cleared banner comes back expanded" $? "$r"

grep -q 'banner: collapse pane=.* via=chevron' "$APP_LOG"
hl_check "C14 the app log names each fold and what did it" $?

# ---- the Set Pane Banner editor ---------------------------------------------

chord=ctrl+shift+b
[ "${NEGATIVE:-0}" = 1 ] && chord=ctrl+r
r=$(hl_ipc press-key --target="$pid" --key=$chord)
open_now() { [ "$(state editor.open)" = "true" ]; }
hl_wait_for 5 open_now
ok=$?
r2=$(seam)
[ $ok = 0 ] && [ "$(field "$r2" editor.pane)" = "$pid" ]
hl_check "E1 Ctrl+Shift+B opens the banner editor for the pane" $? "press=$r editor=$r2"
[ "$(field "$r2" editor.text)" = "$(printf '## Third\nthird body')" ]
hl_check "E2 the editor opens with the pane's banner in it" $? "$r2"

r=$(seam --editor-key=return)
[ "$(field "$r" key_effect)" = "pass" ] && [ "$(field "$r" editor.open)" = "true" ]
hl_check "E3 Return is left to the text box (a newline), the editor stays" $? "$r"

hl_ipc press-key --target="$pid" --key=ctrl+shift+b > /dev/null
r=$(seam)
[ "$(field "$r" editor.open)" = "true" ] && [ $(grep -c 'banner editor: open pane=' "$APP_LOG") = 1 ] && grep -q 'banner editor: already open' "$APP_LOG"
hl_check "E4 asking again while it is open keeps the one editor" $? "$r"

new=$(printf '## Edited\n\nline two  \n')
r=$(seam --editor-text="$new" --editor-key=ctrl+return)
[ "$(field "$r" key_effect)" = "save" ]
hl_check "E5 Ctrl+Return saves" $? "$r"
hl_wait_for 5 editor_closed
hl_check "E6 ... and the editor closes" $?
want=$(printf '## Edited\n\nline two')
banner_is "$want"
hl_check "E7 the saved text is the banner, trimmed" $? "banner=$(state banner.text)"
hl_wait_for 10 dump_has 'line two'
hl_check "E8 the card redraws with it" $? "$(last_block | head -4 | tr '\n' '|')"

hl_ipc press-key --target="$pid" --key=ctrl+shift+b > /dev/null
hl_wait_for 5 open_now
r=$(seam --editor-text='not this' --editor-key=escape)
[ "$(field "$r" key_effect)" = "cancel" ]
hl_check "E9 Escape cancels" $? "$r"
hl_wait_for 5 editor_closed && banner_is "$want"
hl_check "E10 ... the editor closes and the banner is unchanged" $? "banner=$(state banner.text)"

hl_ipc press-key --target="$pid" --key=ctrl+shift+b > /dev/null
hl_wait_for 5 open_now
seam --editor-text='   ' --editor-key=ctrl+return > /dev/null
hl_wait_for 5 editor_closed
r=$(seam)
[ "$(field "$r" banner.shown)" = "false" ] && [ "$(field "$r" banner.text)" = "null" ]
hl_check "E11 saving a blank editor clears the banner" $? "$r"
grep -q 'banner editor: saved pane=.* len=0' "$APP_LOG" && grep -q 'banner editor: cancelled' "$APP_LOG"
hl_check "E12 the app log names each save and cancel" $?

hl_finish "$L"
