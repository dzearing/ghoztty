#!/usr/bin/env bash
# viewer-toc.sh - L9i (T3418) acceptance: the markdown viewer's table of
# contents on GTK.
#
# docs/reference/viewer-panes.md "Table of contents", on Linux:
# - a markdown document with two or more headings gets a CONTENTS card
#   listing them, nested by level relative to its shallowest heading and
#   capped at three steps; one heading (or a code file) gets no card;
# - the scroll spy: the section at the top of the pane is the selected row,
#   and the end of the document selects the last heading;
# - a row click scrolls the page to that heading and PINS the selection
#   through the smooth scroll; the reader's next gesture hands it back;
# - a wide pane (>= 720 px) puts the card in a left gutter the page
#   reserves (margin + card); dragging its edge resizes card and gutter
#   together and the width is saved as the shared preference;
# - a narrow pane turns it into an overlay: the nav bar's first item is a
#   contents button, the overlay starts closed, the button opens it, a row
#   click dismisses it, nothing is reserved, and the edge does not drag;
# - the switch follows the pane's width live, both ways;
# - a live reload that drops to one heading retracts the card and the gutter,
#   and one that brings them back restores both;
# - nothing panics.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-toc.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh); the pane is driven
# and read back through the debug build's GHOZTTY_TEST_VIEWER_STEPS seam
# (src/apprt/gtk/Viewer.zig; `toc` / `toc-rows` / `toc-row` / `toc-drag` /
# `resize` read and drive ViewerTOC), and the page through `probe`.
#
# Output: one PASS/FAIL line per check, then 'VIEWER TOC: ALL PASS' or
# 'VIEWER TOC: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER TOC"

log=/tmp/viewer-toc-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "C1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start 1600 1000
hl_check "C2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
# The width preference lands under the harness, never in the distro's ~.
export XDG_STATE_HOME="$HL_RUNTIME/state"
pref="$XDG_STATE_HOME/ghoztty/viewer_sidepanel_width-debug"

# ---- fixtures --------------------------------------------------------------
fx="$HL_RUNTIME/fx"
mkdir -p "$fx"
filler() { for i in $(seq 1 "$1"); do printf 'Paragraph %s of filler text, long enough to take a line.\n\n' "$i"; done; }
write_doc() {
    {
        printf '# Guide\n\nintro\n\n'; filler 30
        printf '## Install\n\n'; filler 30
        printf '### From source\n\n'; filler 30
        printf '## Usage\n\n'; filler 30
        printf '### Flags\n\n'; filler 20
        printf '#### Deep heading\n\n'; filler 10
        printf '##### Deeper still\n\n'; filler 10
        printf '## A very long heading that has to wrap onto a second line in the card and then stop at two lines\n\n'; filler 30
        printf '## End\n\nthe end\n'
    } > "$fx/doc.md.tmp"
    mv "$fx/doc.md.tmp" "$fx/doc.md"
}
write_doc
printf 'const x = 1;\n' > "$fx/code.zig"

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }

H="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');return h?h.textContent:'NOH1'})()"
PAD="'pad=' + (document.body.style.paddingLeft || 'none')"
TOP="'top=' + Math.round(document.getElementById('usage').getBoundingClientRect().top)"
TOEND="(window.scrollTo(0, document.documentElement.scrollHeight), 'end')"
# The reader's own gesture, then a jump to the top: the pin must let go.
RELEASE="(window.dispatchEvent(new WheelEvent('wheel')), window.scrollTo(0, 0), 'released')"

# ---- the steps the pane runs once it has rendered --------------------------
steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
resize 1200x800
sleep 1200
toc
toc-rows
probe $PAD
probe $TOEND
sleep 900
toc
toc-row usage
sleep 1500
toc
probe $TOP
probe $RELEASE
sleep 900
toc
toc-drag 60
sleep 400
toc
probe $PAD
resize 600x800
sleep 1200
toc
probe $PAD
toc-drag 80
click contents
sleep 500
toc
toc-row flags
sleep 1500
toc
click contents
sleep 400
resize 1200x800
sleep 1200
toc
probe $PAD
mark one-heading
sleep 3000
toc
probe $PAD
mark restored
sleep 3000
toc
probe $PAD
key <Control>l
type $fx/code.zig
activate
wait
sleep 900
toc
EOF

dump="$HL_RUNTIME/viewer-dump"
export SHELL=/bin/sh
export GHOZTTY_TEST_VIEWER_DUMP="$dump"
export GHOZTTY_TEST_VIEWER_PROBE="$H"
export GHOZTTY_TEST_VIEWER_STEPS="$steps"
export GHOZTTY_TEST_VIEWER_STEPS_OUT="$out"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_VIEWER_DUMP GHOZTTY_TEST_VIEWER_PROBE GHOZTTY_TEST_VIEWER_STEPS GHOZTTY_TEST_VIEWER_STEPS_OUT
hl_wait_for 30 test -S "$sock"
hl_check "C3 the app serves its socket" $?

o=$(cli +new-window --view=doc.md --name=doc 2>&1)
hl_check "C4 +new-window --view=doc.md opens a viewer" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK Guide" ]
hl_check "C5 the pane renders its file" $? "dump: $(cat "$dump" 2>/dev/null)"

# The driving script's half of the sync points: a live reload down to one
# heading, then back.
hl_wait_for 120 grep -q '^mark one-heading' "$out"
printf '# Only one\n\ntext\n' > "$fx/doc.md.tmp" && mv "$fx/doc.md.tmp" "$fx/doc.md"
hl_wait_for 60 grep -q '^mark restored' "$out"
write_doc
hl_wait_for 120 grep -q '^done' "$out"
hl_check "C6 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

nth() { grep "^$1 " "$out" | sed -n "${2}p"; }
tc() { nth toc "$1"; }
pr() { nth probe "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

s=$(tc 1)
has "$s" "mode=gutter " && has "$s" "card=true " && has "$s" "button=false " && has "$s" "rows=9 " && has "$s" "selected=guide "
hl_check "C7 a wide pane lists the nine headings in a gutter card, the first one selected" $? "$s"

r=$(nth toc-rows 1)
[ "$r" = "toc-rows guide:0|install:1|from-source:2|usage:1|flags:2|deep-heading:3|deeper-still:3|a-very-long-heading-that-has-to-wrap-onto-a-second-line-in-the-card-and-then-stop-at-two-lines:1|end:1" ]
hl_check "C8 rows nest by level from the shallowest heading, capped at three steps" $? "$r"

has "$s" "cardw=240 " && has "$s" "gutter=252 " && [ "$(pr 1)" = "probe OK pad=252px" ]
hl_check "C9 the page reserves margin + card (12 + 240) as its own padding" $? "$s / $(pr 1)"

w=$(echo "$s" | sed -n 's/.* shownw=\([0-9]*\) .*/\1/p')
[ -n "$w" ] && [ "$w" -ge 238 ] && [ "$w" -le 242 ]
hl_check "C10 a long heading wraps inside the card instead of widening it" $? "shownw=$w"

s=$(tc 2)
has "$s" "active=end " && has "$s" "selected=end "
hl_check "C11 the scroll spy follows the page: its end selects the last heading" $? "$s"

s=$(tc 3)
t=$(pr 3 | sed -n 's/.*top=\(-\?[0-9]*\).*/\1/p')
has "$s" "active=usage " && has "$s" "selected=usage " && [ -n "$t" ] && [ "$t" -ge 0 ] && [ "$t" -le 40 ]
hl_check "C12 a row click scrolls its heading to the top and the selection stays on it" $? "$s / $(pr 3)"
grep -q 'viewer toc click id=usage' "$APP_LOG"
hl_check "C13 the click is logged" $?

s=$(tc 4)
has "$s" "active=guide " && has "$s" "selected=guide "
hl_check "C14 the reader's own gesture releases the pin back to the scroll spy" $? "$s"

s=$(tc 5)
has "$s" "width=300 " && has "$s" "cardw=300 " && has "$s" "gutter=312 " && [ "$(pr 5)" = "probe OK pad=312px" ]
hl_check "C15 dragging the edge 60 px widens the card and the page's gutter together" $? "$s / $(pr 5)"
[ "$(cat "$pref" 2>/dev/null)" = "300" ]
hl_check "C16 the width is saved as the shared preference" $? "pref: $(cat "$pref" 2>/dev/null)"

s=$(tc 6)
has "$s" "mode=compact " && has "$s" "open=false " && has "$s" "card=false " && has "$s" "button=true " && has "$s" "gutter=0 " && [ "$(pr 6)" = "probe OK pad=none" ]
hl_check "C17 a narrow pane: the overlay starts closed, the bar shows the contents button, nothing is reserved" $? "$s / $(pr 6)"

s=$(tc 7)
has "$s" "open=true " && has "$s" "card=true " && has "$s" "width=300 " && has "$s" "gutter=0 "
hl_check "C18 the button opens the overlay; the edge does not drag it" $? "$s"

s=$(tc 8)
has "$s" "open=false " && has "$s" "card=false " && has "$s" "active=flags "
hl_check "C19 a row click in the overlay scrolls there and dismisses it" $? "$s"

s=$(tc 9)
has "$s" "mode=gutter " && has "$s" "card=true " && has "$s" "button=false " && has "$s" "gutter=312 " && [ "$(pr 7)" = "probe OK pad=312px" ]
hl_check "C20 widening the pane again puts the card back in its gutter at the saved width" $? "$s / $(pr 7)"

s=$(tc 10)
has "$s" "mode=hidden " && has "$s" "rows=0 " && has "$s" "card=false " && has "$s" "button=false " && [ "$(pr 8)" = "probe OK pad=none" ]
hl_check "C21 a live reload down to one heading retracts the card and the gutter" $? "$s / $(pr 8)"

s=$(tc 11)
has "$s" "mode=gutter " && has "$s" "rows=9 " && [ "$(pr 9)" = "probe OK pad=312px" ]
hl_check "C22 a reload that brings the headings back restores card and gutter" $? "$s / $(pr 9)"

s=$(tc 12)
has "$s" "mode=hidden " && has "$s" "rows=0 " && has "$s" "button=false "
hl_check "C23 a code file has no contents" $? "$s"

grep -q 'viewer toc layout=compact' "$APP_LOG" && grep -q 'viewer toc layout=gutter' "$APP_LOG"
hl_check "C24 each layout switch is logged" $?

! grep -q -i 'panic\|segmentation fault\|reached unreachable' "$APP_LOG"
hl_check "C25 nothing panicked" $? "$(grep -m2 -i 'panic' "$APP_LOG")"

hl_finish "$L"
