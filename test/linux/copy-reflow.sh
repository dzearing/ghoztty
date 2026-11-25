#!/usr/bin/env bash
# copy-reflow.sh - L11c (T3565) acceptance for docs/reference/copy-reflow.md on
# the GTK debug app: text copied out of a TUI that hard-wrapped and re-indented
# its own rows (Claude Code, Ink / wrap-ansi) comes back as clean prose on every
# GTK copy path - Ctrl+Shift+C, select-all, and copy-on-select from a mouse
# drag into the PRIMARY selection - and a URL the TUI broke across rows is ONE
# link: hover lights it from either row, a click opens the whole URL, and Copy
# URL copies it whole. The cleanup itself is the shared core
# (src/terminal/hard_wrap.zig); this proves the GTK paths reach it. Run it ONLY
# through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\copy-reflow.sh
#
# Input the headless harness does not have comes through debug-only seams:
# keys through `press-key`, the pointer through `pane-mouse` (a motion, press
# and release at a cell's centre, with modifiers). The clipboard is read back
# through `read-clipboard`, from the GdkClipboard the copy filled - AND, since
# T3620, from OUTSIDE the app: this run uses hl_start_seat (a headless sway,
# which has the wl_seat the default Weston lacks), so `wl-paste` - another
# Wayland client - must be offered the same clean text (P1-P5). A link click
# is recorded, never opened, through GHOZTTY_TEST_VIEWER_LINKS (`open <url>`).
#
# Output: one PASS/FAIL line per check, then 'COPY REFLOW: ALL PASS' or
# 'COPY REFLOW: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
LABEL="COPY REFLOW"

log=/tmp/copy-reflow-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "R1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$LABEL"

hl_start_seat
hl_check "R2 a private headless compositor WITH a seat (sway) is up" $? "$(tail -2 "${HL_WESTON_LOG:-/dev/null}" 2>/dev/null | tr '\n' ' ')"
[ -n "${HL_SOCKET:-}" ] && [ -S "$HL_RUNTIME/$HL_SOCKET" ] || hl_finish "$LABEL"
app=$(hl_ghoztty) || hl_finish "$LABEL"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

fx="$HL_RUNTIME/fx"
mkdir -p "$fx"
links="$HL_RUNTIME/links.txt"
: > "$links"
export GHOZTTY_TEST_VIEWER_LINKS="$links"
# copy-on-select is the Linux default; said explicitly so a changed default
# cannot quietly turn the PRIMARY checks into checks of nothing. Copy URL has
# no default chord, so the test binds one.
hl_launch APP "$app" --gtk-single-instance=false --copy-on-select=true \
    --keybind=ctrl+shift+u=copy_url_to_clipboard \
    -e python3 -I "$PWD/test/linux/lib/copy_reflow_fixture.py" "$fx"
unset GHOZTTY_TEST_VIEWER_LINKS
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "R3 the app serves its socket" $?

have_pane() { [ -n "$(hl_first_pane "$app")" ]; }
hl_wait_for 20 have_pane
pane=$(hl_first_pane "$app")
[ -n "$pane" ]
hl_check "R4 +list names the pane" $? "id=$pane"
[ -n "$pane" ] || hl_finish "$LABEL"

# Let the window settle to its final size before the fixture measures it.
sleep 1
touch "$fx/go"
hl_wait_for 20 test -s "$fx/layout.json"
hl_check "R5 the fixture drew its rows and wrote layout.json" $? "$(cat "$fx/layout.json" 2>/dev/null | head -c 160)"
[ -s "$fx/layout.json" ] || hl_finish "$LABEL"
sleep 0.5

L() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); v=d
for k in sys.argv[2].split("."): v=v[k]
print(v)' "$fx/layout.json" "$1"; }
cols=$(L cols); prose_row=$(L prose.row); prose_n=$(L prose.count); prose_last=$(L prose.last_len)
url_row=$(L url.row); url_n=$(L url.count); url_lead=$(L url.lead); url=$(L url.url)
code_row=$(L code.row)
printf '%s' "$(L prose.text)" > "$fx/prose.txt"
printf '%s' "$url" > "$fx/url.txt"

# The fixture genuinely wrapped: the paragraph and the URL each span several
# rows on screen. Without this every check below could pass on text that was
# never broken in the first place.
[ "$prose_n" -ge 3 ] && [ "$url_n" -ge 2 ]
hl_check "R6 the paragraph and the URL are each hard-wrapped across rows" $? "cols=$cols prose_rows=$prose_n url_rows=$url_n"

# contains <file> <needle-file>: the file holds the needle verbatim.
contains() { python3 -I -c 'import sys; h=open(sys.argv[1],encoding="utf-8").read(); n=open(sys.argv[2],encoding="utf-8").read(); sys.exit(0 if n in h else 1)' "$1" "$2"; }
# clean <file>: the copy is clean prose - the paragraph whole on one line, the
# URL whole, the code's two lines kept apart with their relative indentation.
clean() {
    python3 -I - "$1" "$fx/prose.txt" "$fx/url.txt" <<'PY'
import sys
got = open(sys.argv[1], encoding="utf-8").read()
prose = open(sys.argv[2], encoding="utf-8").read()
url = open(sys.argv[3], encoding="utf-8").read()
why = []
if prose not in got: why.append("prose not whole")
if url not in got: why.append("url not whole")
if "def answer():\n    return 42" not in got: why.append("code lost its break or indent")
if "\n  " + prose.split()[3] in got: why.append("re-indented continuation kept")
print("; ".join(why) or "clean")
sys.exit(1 if why else 0)
PY
}

# readclip <file> [--primary]: the pane's clipboard (or PRIMARY) into <file>.
readclip() {
    local f=$1; shift
    rm -f "$f" "$f.err"
    hl_ipc read-clipboard "--target=$pane" "--out=$f" "$@" > /dev/null || return 1
    hl_wait_for 10 sh -c '[ -e "$1" ] || [ -e "$1.err" ]' _ "$f"
    [ -e "$f" ]
}

# outside <file> [--primary]: what ANOTHER Wayland client is offered - wl-paste,
# through wlr-data-control, so it needs no focus of its own. Exact bytes.
outside() {
    local f=$1; shift
    rm -f "$f" "$f.err"
    hl_assert_isolated
    timeout 10 wl-paste --no-newline "$@" > "$f" 2> "$f.err"
}

# ---- negative control: what +read returns is the screen as laid out --------
cli +read --name="$pane" --lines=200 > "$fx/read.txt" 2>&1
r=$(clean "$fx/read.txt")
[ "$r" != clean ] && grep -q "deliberately long paragraph" "$fx/read.txt" && grep -q "def answer" "$fx/read.txt"
hl_check "R7 control: +read (never reflowed) shows the text but NOT as clean prose, so the checks can fail" $? "$r"
grep -q "^  " "$fx/read.txt"
hl_check "R8 control: +read still shows the TUI's re-indented continuation rows" $? "$(head -3 "$fx/read.txt" | cat -A | head -c 300)"

# ---- select-all: PRIMARY by copy-on-select, then Ctrl+Shift+C -----------------
hl_ipc press-key "--target=$pane" --key=ctrl+shift+a > /dev/null
readclip "$fx/sel-all-primary.txt" --primary
hl_check "R9 select-all fills PRIMARY (copy-on-select)" $? "$(cat "$fx/sel-all-primary.txt.err" 2>/dev/null)"
r=$(clean "$fx/sel-all-primary.txt")
hl_check "R10 ...and PRIMARY holds clean prose" $? "$r"

# ---- outside the app (T3620) ---------------------------------------------------
# Control first: until the app has been given one key serial, wlroots refuses
# its set_selection ("serial 0 was never given to client"), so the PRIMARY it
# just filled stays app-local. That is what proves P3-P5 can fail - and why
# hl_key_serial exists.
outside "$fx/out-primary0.txt" --primary
! cmp -s "$fx/out-primary0.txt" "$fx/sel-all-primary.txt"
hl_check "P1 control: with no key serial yet, wl-paste is NOT offered the app's PRIMARY" $? "$(head -c 120 "$fx/out-primary0.txt.err" 2>/dev/null)"
hl_key_serial
hl_check "P2 one Shift_L key event reaches the window (wtype, a virtual keyboard)" $?
sleep 0.3

hl_ipc press-key "--target=$pane" --key=ctrl+shift+c > /dev/null
readclip "$fx/sel-all-clip.txt"
hl_check "R11 Ctrl+Shift+C fills the clipboard" $? "$(cat "$fx/sel-all-clip.txt.err" 2>/dev/null)"
r=$(clean "$fx/sel-all-clip.txt")
hl_check "R12 ...and the clipboard holds clean prose" $? "$r"
outside "$fx/out-clip.txt"
cmp -s "$fx/out-clip.txt" "$fx/sel-all-clip.txt" && [ "$(clean "$fx/out-clip.txt")" = clean ]
hl_check "P3 another app's paste (wl-paste) gets the SAME clean prose Ctrl+Shift+C copied" $? "$(head -c 120 "$fx/out-clip.txt.err" 2>/dev/null)"
python3 -I -c 'import sys; t=open(sys.argv[1],encoding="utf-8").read(); sys.exit(0 if "⏺ " in t else 1)' "$fx/sel-all-clip.txt"
hl_check "R13 the gutter glyph hangs in the margin and survives the dedent" $?

# ---- a mouse drag over the paragraph alone: copy-on-select on release --------
last=$((prose_row + prose_n - 1))
hl_ipc pane-mouse "--target=$pane" "--cell=0,$prose_row" --button=press > /dev/null
hl_ipc pane-mouse "--target=$pane" "--cell=$prose_last,$last" > /dev/null
hl_ipc pane-mouse "--target=$pane" "--cell=$prose_last,$last" --button=release > /dev/null
readclip "$fx/drag-primary.txt" --primary
hl_check "R14 a drag over the paragraph fills PRIMARY on release" $? "$(cat "$fx/drag-primary.txt.err" 2>/dev/null)"
python3 -I -c '
import sys
t = open(sys.argv[1], encoding="utf-8").read()
p = open(sys.argv[2], encoding="utf-8").read()
sys.exit(0 if t.rstrip("\n") == "⏺ " + p else 1)' "$fx/drag-primary.txt" "$fx/prose.txt"
hl_check "R15 ...and it is the paragraph as one line, gutter and all, nothing else" $? "$(python3 -I -c 'import sys; print(repr(open(sys.argv[1],encoding="utf-8").read()[-100:]))' "$fx/drag-primary.txt" 2>/dev/null)"
outside "$fx/out-drag-primary.txt" --primary
cmp -s "$fx/out-drag-primary.txt" "$fx/drag-primary.txt"
hl_check "P4 another app's middle-click paste (wl-paste --primary) gets the dragged paragraph as one line" $? "$(head -c 120 "$fx/out-drag-primary.txt.err" 2>/dev/null)"

# ---- the URL broken across rows is one link -----------------------------------
# A cell well inside each half: the first row (after the lead-in) and the last.
c1=$((url_lead + 5)); r1=$url_row
c2=4; r2=$((url_row + url_n - 1))
over() { hl_ipc pane-mouse "--target=$pane" "--cell=$1,$2" --mods=ctrl | grep -q '"over_link":true'; }
over "$c1" "$r1"
hl_check "R16 Ctrl-hover on the URL's first row lights a link" $?
over "$c2" "$r2"
hl_check "R17 Ctrl-hover on its LAST row (past the seam) lights the same link" $?
! over 4 "$code_row"
hl_check "R18 control: Ctrl-hover on the code row lights nothing" $?
! over 0 "$((url_row + 1))"
hl_check "R19 the continuation's skipped margin is not part of the link" $?

over "$c2" "$r2"
hl_ipc pane-mouse "--target=$pane" "--cell=$c2,$r2" --mods=ctrl --button=click > /dev/null
hl_wait_for 5 grep -q '^open ' "$links"
got=$(grep -m1 '^open ' "$links" | cut -d' ' -f2-)
[ "$got" = "$url" ]
hl_check "R20 Ctrl+click on the last row opens the WHOLE URL (recorded, not opened)" $? "got=${got:-nothing}"

hl_ipc pane-mouse "--target=$pane" "--cell=$c1,$r1" --mods=ctrl > /dev/null
hl_ipc press-key "--target=$pane" --key=ctrl+shift+u > /dev/null
readclip "$fx/copy-url.txt"
[ "$(cat "$fx/copy-url.txt" 2>/dev/null)" = "$url" ]
hl_check "R21 Copy URL over the first row copies the whole URL" $? "$(head -c 160 "$fx/copy-url.txt" 2>/dev/null)"
outside "$fx/out-url.txt"
[ "$(cat "$fx/out-url.txt" 2>/dev/null)" = "$url" ]
hl_check "P5 another app's paste gets the WHOLE URL Copy URL copied" $? "$(head -c 160 "$fx/out-url.txt.err" 2>/dev/null)"

grep -q 'leave the app\|refused to hand' "$APP_LOG"
[ $? != 0 ]
hl_check "R22 nothing tried to leave the app for the desktop" $?

hl_finish "$LABEL"
