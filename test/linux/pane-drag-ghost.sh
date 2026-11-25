#!/usr/bin/env bash
# pane-drag-ghost.sh - L11b5 (T3617) acceptance for the card a pane drag
# carries under the pointer on the GTK debug app (Mac PaneDragGhost, win32
# pane_drag_ghost.zig).
#
# The headless harness has no seat, so no pointer drag can START here (that
# half is NOT RUN; the task says so). What it reads instead is the very card a
# drag-begin hands gtk_drag_source_set_icon: the `pane-drag --ghost` seam
# calls the same Surface.dragGhost the header's drag-begin calls, and reports
# the planned geometry, the texture the window's renderer produced, and pixels
# sampled from that texture.
#
#   G1-G2   build, harness, a window in rearrange mode (the header names the pane)
#   G3-G6   geometry: at most 220x150 in the pane's shape, a 10px shadow
#           margin, the texture at the device scale, the pointer holding the
#           middle of the title strip
#   G7-G11  pixels: a clear margin, a shadow under the card, the strip in its
#           planned tint, an opaque body, the title's ink in the strip
#   G12     the body is the pane's OWN content: the shell paints its screen
#           white and the card's body turns white with it
#   G13     a tinted pane's card is drawn in its tint, with dark ink
#   G14     --ghost-png writes a PNG of the card
#   G15     no GTK critical or warning
#
# Run it ONLY through the wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\pane-drag-ghost.sh
#
# NEGATIVE=1 never paints the screen white, and must FAIL G12 only (1
# failure): the body check cannot pass on a card that ignores the content.
# Output: one PASS/FAIL line per check, then 'PANE DRAG GHOST: ALL PASS' or
# 'PANE DRAG GHOST: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PANE DRAG GHOST"

log=/tmp/pane-drag-ghost-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "G1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "G1b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
hl_check "G1c the app serves its socket" $?

pd() { hl_ipc pane-drag "$@"; }
pf() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$2" 2>/dev/null; }
has_window() { cli +list --json 2>/dev/null | grep -q "\"target\":\"$1\""; }
id_of() { # id_of <window target>: the first pane's id
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
for w in json.load(sys.stdin)["data"]["windows"]:
    if (w.get("target") or "") != sys.argv[1]: continue
    n = w["tabs"][0]["splits"]
    while n["type"] == "split": n = n["left"]
    print(n["terminal"]["id"])
' "$1" 2>/dev/null
}

cli +new-window --target=gw --name=ghosted > /dev/null 2>&1
hl_wait_for 15 has_window gw
p=$(id_of gw)
hl_ipc press-key --target="$p" --key=ctrl+shift+period > /dev/null
mode_on() { [ "$(pf "$(pd --target="$p")" "d['mode']")" = True ]; }
hl_wait_for 5 mode_on
hl_check "G2 window gw is in rearrange mode, pane $p" $? "$(pd --target="$p")"

ghost_ok() { [ "$(pf "$(pd --target="$p" --ghost)" "d['ghost']['built']")" = True ]; }
hl_wait_for 10 ghost_ok
r=$(pd --target="$p" --ghost)
g() { pf "$r" "d['ghost']$1"; }
[ "$(g "['built']")" = True ] && [ "$(g "['card_w']")" -le 220 ] && [ "$(g "['card_h']")" -le 150 ] \
    && { [ "$(g "['card_w']")" = 220 ] || [ "$(g "['card_h']")" = 150 ]; }
hl_check "G3 a big pane's card is at most 220x150 and fills one of the two" $? "$r"
[ "$(g "['image_w']")" = $(( $(g "['card_w']") + 20 )) ] && [ "$(g "['image_h']")" = $(( $(g "['card_h']") + 20 )) ]
hl_check "G4 the image is the card plus a 10px shadow margin all round" $? "$r"
sc=$(g "['scale']")
[ "$(g "['texture_w']")" = $(( $(g "['image_w']") * sc )) ] && [ "$(g "['texture_h']")" = $(( $(g "['image_h']") * sc )) ]
hl_check "G5 the renderer produced the card's texture at the device scale ($sc)" $? "$r"
hx=$(g "['hot_x']"); hy=$(g "['hot_y']")
[ "$hx" = $(( $(g "['image_w']") / 2 )) ] && [ "$hy" -gt "$(g "['title_top']")" ] && [ "$hy" -lt "$(g "['title_bottom']")" ]
hl_check "G6 the pointer holds the card by the middle of its title strip ($hx,$hy)" $? "$r"

[ "$(g "['margin_px'][3]")" -lt 16 ]
hl_check "G7 the margin's corner is clear" $? "margin=$(g "['margin_px']")"
sa=$(g "['shadow_px'][3]")
[ "$sa" -gt 0 ] && [ "$sa" -lt 255 ]
hl_check "G8 a translucent shadow sits under the card" $? "shadow=$(g "['shadow_px']")"
pf "$r" "all(abs(a-b) <= 6 for a, b in zip(d['ghost']['strip_px'][:3], d['ghost']['strip_planned'])) and d['ghost']['strip_px'][3] == 255" | grep -q True
hl_check "G9 the title strip is drawn in its planned tint" $? "strip=$(g "['strip_px']") planned=$(g "['strip_planned']")"
[ "$(g "['body_px'][3]")" = 255 ]
hl_check "G10 the body is opaque" $? "body=$(g "['body_px']")"
[ "$(g "['title_ink_px']")" -gt 20 ] && [ -n "$(g "['title']")" ]
hl_check "G11 the strip carries the header's label in ink" $? "ink_px=$(g "['title_ink_px']") title=$(g "['title']")"

# The pane's own content: paint the whole screen white (erase with a white
# background), then the card's body - a scaled picture of that screen - must
# be white too, against the dark default background. Four backslashes: bash's
# double quotes halve them, then +send-keys turns `\\` into `\` (a bare `\0`
# is a NUL to it, which left the shell printing "^@33[107m").
if [ "${NEGATIVE:-0}" != 1 ]; then
    cli +send-keys --target="$p" "printf '\\\\033[107m\\\\033[2J'" Enter > /dev/null 2>&1
fi
body_white() {
    local v; v=$(pd --target="$p" --ghost)
    pf "$v" "min(d['ghost']['body_px'][:3]) >= 230 and max(d['ghost']['bg']) < 128" | grep -q True
}
hl_wait_for 10 body_white
hl_check "G12 the body is a picture of the pane: its white screen shows in the card" $? "$(pf "$(pd --target="$p" --ghost)" "(d['ghost']['body_px'], d['ghost']['bg'])")"

cli +new-window --target=tw --name=tinted --color='#d0e8ff' > /dev/null 2>&1
hl_wait_for 15 has_window tw
t=$(id_of tw)
tinted_ok() { [ "$(pf "$(pd --target="$t" --ghost)" "d['ghost']['bg']")" = "[208, 232, 255]" ]; }
hl_wait_for 10 tinted_ok
rt=$(pd --target="$t" --ghost)
pf "$rt" "d['ghost']['bg'] == [208, 232, 255] and all(s < b for s, b in zip(d['ghost']['strip_planned'], d['ghost']['bg'])) and abs(d['ghost']['strip_px'][0] - d['ghost']['strip_planned'][0]) <= 6" | grep -q True
hl_check "G13 a tinted pane's card is its tint, its strip shaded toward dark ink" $? "$(pf "$rt" "(d['ghost']['bg'], d['ghost']['strip_planned'], d['ghost']['strip_px'])")"

png=/tmp/pane-drag-ghost-$$.png
rm -f "$png"
rp=$(pd --target="$p" --ghost-png="$png")
[ "$(pf "$rp" "d['ghost']['png']")" = "$png" ] && [ -s "$png" ] && head -c 8 "$png" | od -An -tx1 | tr -d ' \n' | grep -q '^89504e470d0a1a0a$'
hl_check "G14 --ghost-png writes the card as a PNG" $? "$rp"
rm -f "$png"

[ -s "$APP_LOG" ] && ! grep -E -- '-(CRITICAL|WARNING) \*\*' "$APP_LOG" > /dev/null
hl_check "G15 the app logged no GTK critical or warning" $? "$(grep -E -m5 -- '-(CRITICAL|WARNING) \*\*' "$APP_LOG" | tr '\n' ' ')"

hl_finish "$L"
