#!/usr/bin/env bash
# pane-drop-preview.sh - L11b5b (T3708) acceptance for the live drop preview
# a pane drag shows on the GTK debug app (Mac PaneDropFeedbackView, win32
# drop_highlight.zig), and the tab button a drag dwells on, lit.
#
# The headless harness has no seat, so no pointer drag can START here (that
# half is NOT RUN; the task says so). The `pane-drag --hover-on/--hover-at`
# seam calls SplitTree.hoverAt - the very call the split area's drop target
# makes on every drag motion - and reports the preview it put up: what was
# planned, the CSS classes the widget wears, and the widget as laid out.
#
#   V1-V2   build, harness, window pv holding H(a,V(b,c)) in rearrange mode
#   V3      nothing is previewed before the drag moves anywhere
#   V4-V6   over b's bottom: the lower half of b, seamed on its top edge,
#           and the widget is laid out exactly there
#   V7      over b's centre: the swap box, inside b and centred on it, with
#           the glyph
#   V8      over b's left half: a quiet spot (a | b already) - nothing
#   V9      by the window's right edge: the right half of the whole area
#   V10     on the b/c divider: the landing area, seamed top and bottom
#   V11     the drag leaving the area takes the preview down
#   V12     a release where the preview said split-down splits down, and
#           the preview is gone after it
#   V13     the preview is drawn: a pixel inside it is tinted toward the
#           accent against the same pixel with no preview
#   V14-V16 the tab bar: resting on another tab's button lights that button,
#           leaving the bar darkens it, and the dwell firing opens the tab
#           and darkens it
#   V17     no GTK critical or warning
#
# Run it ONLY through the wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\pane-drop-preview.sh
#
# NEGATIVE=1 hovers with the pointer one pane over (a's own area instead of
# b's): a pane over itself has no preview, so V4-V7, V10 and V13 must FAIL
# (6 failures). Output: one PASS/FAIL line per check, then
# 'PANE DROP PREVIEW: ALL PASS' or 'PANE DROP PREVIEW: <n> FAILURE(S)'.
# Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PANE DROP PREVIEW"

log=/tmp/pane-drop-preview-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "V1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "V1b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
hl_wait_for 30 test -S "$sock"
hl_check "V1c the app serves its socket" $?

list_py() {
    cli +list --json 2>/dev/null | python3 -c '
import json, sys
mode, want = sys.argv[1], sys.argv[2]
arg = sys.argv[3] if len(sys.argv) > 3 else ""
d = json.load(sys.stdin)["data"]
def shape(n):
    if n["type"] == "split":
        return "%s(%s,%s)" % (n["direction"][0].upper(), shape(n["left"]), shape(n["right"]))
    return n["terminal"].get("name", "")
def leaves(n):
    if n["type"] == "split":
        yield from leaves(n["left"]); yield from leaves(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if (w.get("target") or "") != want: continue
    tab = next((t for t in w["tabs"] if t.get("selected")), w["tabs"][0])
    if mode == "shape": print(shape(tab["splits"]))
    for l in leaves(tab["splits"]):
        if mode == "id" and l.get("name") == arg: print(l["id"])
' "$@" 2>/dev/null
}
shape_of() { list_py shape pv; }
shape_is() { [ "$(shape_of)" = "$1" ]; }
has_window() { cli +list --json 2>/dev/null | grep -q "\"target\":\"$1\""; }

pd() { hl_ipc pane-drag "$@"; }
pf() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$2" 2>/dev/null; }
rect_of() { pf "$(pd --target="$a")" "' '.join(str(v) for v in [h['rect'] for h in d['headers'] if h['pane'] == '$1'][0])"; }

cli +new-window --target=pv > /dev/null 2>&1
hl_wait_for 15 has_window pv
a=$(shape_of)
cli +split --target=pv --name=b > /dev/null 2>&1
cli +split --pane=b --name=c --direction=down > /dev/null 2>&1
hl_wait_for 15 shape_is "H($a,V(b,c))"
b=$(list_py id pv b); c=$(list_py id pv c)
hl_ipc press-key --target="$a" --key=ctrl+shift+period > /dev/null
mode_on() { [ "$(pf "$(pd --target="$a")" "d['mode']")" = True ]; }
hl_wait_for 5 mode_on
rects_up() { [ -n "$(rect_of "$b")" ] && [ -n "$(rect_of "$a")" ]; }
hl_wait_for 5 rects_up
hl_check "V2 window pv holds H(a,V(b,c)) in rearrange mode, every pane laid out" $? "shape=$(shape_of) $(pd --target="$a")"

# The pane the pointer is over: b, or under NEGATIVE=1 the dragged pane itself.
over="$b"
[ "${NEGATIVE:-0}" = 1 ] && over="$a"

r=$(pd --target="$a")
[ "$(pf "$r" "d['preview']['shown']")" = False ]
hl_check "V3 nothing is previewed before the drag moves anywhere" $? "$r"

read -r bl bt br bb <<< "$(rect_of "$b")"
read -r al at ar ab <<< "$(rect_of "$a")"
read -r cl ct cr cb <<< "$(rect_of "$c")"

# V4-V6: over b's bottom quarter.
r=$(pd --target="$a" --hover-on="$over" --hx=0.5 --hy=0.9)
want_top=$(( bb - (bb - bt) / 2 ))
[ "$(pf "$r" "d['preview']['shown']")" = True ] && [ "$(pf "$r" "d['preview']['kind']")" = split ] \
    && [ "$(pf "$r" "d['preview']['rect']")" = "[$bl, $want_top, $br, $bb]" ]
hl_check "V4 over b's bottom the preview is b's lower half [$bl, $want_top, $br, $bb]" $? "$r"
[ "$(pf "$r" "d['preview']['seam']")" = seam-top ] && [ "$(pf "$r" "sorted(d['preview']['classes'])")" = "['pane-drop-fill', 'seam-top']" ] \
    && [ "$(pf "$r" "d['preview']['glyph']")" = False ]
hl_check "V5 it is a fill seamed on its top edge, where the new divider runs, with no glyph" $? "$r"
laid_out() { [ "$(pf "$(pd --target="$a")" "d['preview']['widget']")" = "[$bl, $want_top, $br, $bb]" ]; }
hl_wait_for 5 laid_out
hl_check "V6 the preview widget is laid out on exactly that rect" $? "$(pd --target="$a")"

# The pixel check (V13) shoots now, with the split-down preview up, then
# again with none.
shot_on="$HL_RUNTIME/preview-on.png"; shot_off="$HL_RUNTIME/preview-off.png"
hl_screenshot "$b" "$shot_on" --window > /dev/null

# V7: over b's centre.
r=$(pd --target="$a" --hover-on="$over" --hx=0.5 --hy=0.5)
ok=1
if [ "$(pf "$r" "d['preview']['kind']")" = swap ] && [ "$(pf "$r" "d['preview']['glyph']")" = True ] \
    && [ "$(pf "$r" "'pane-drop-swap' in d['preview']['classes']")" = True ]; then
    read -r sl st sr sb <<< "$(pf "$r" "' '.join(str(v) for v in d['preview']['rect'])")"
    cx=$(( (bl + br) / 2 )); cy=$(( (bt + bb) / 2 ))
    [ "$sl" -gt "$bl" ] && [ "$sr" -lt "$br" ] && [ "$st" -gt "$bt" ] && [ "$sb" -lt "$bb" ] \
        && [ $(( (sl + sr) / 2 - cx )) -ge -1 ] && [ $(( (sl + sr) / 2 - cx )) -le 1 ] \
        && [ $(( (st + sb) / 2 - cy )) -ge -1 ] && [ $(( (st + sb) / 2 - cy )) -le 1 ] && ok=0
fi
hl_check "V7 over b's centre: the swap box, inside b and centred on it, with the glyph" $ok "$r"

# V8: b's left half puts a back where it is.
r=$(pd --target="$a" --hover-on="$b" --hx=0.08 --hy=0.5)
[ "$(pf "$r" "d['preview']['shown']")" = False ]
hl_check "V8 over b's left half (a | b already) nothing is previewed" $? "$r"

# V9: by the window's right edge, the right half of the whole area.
area_w=$br; area_h=$cb
r=$(pd --target="$a" --hover-at="$(( area_w - 4 )),$(( area_h / 2 ))")
[ "$(pf "$r" "d['preview']['kind']")" = top_level ] && [ "$(pf "$r" "d['preview']['seam']")" = seam-left ] \
    && [ "$(pf "$r" "d['preview']['rect']")" = "[$(( area_w - area_w / 2 )), 0, $area_w, $area_h]" ]
hl_check "V9 by the window's right edge: the right half of the area, seamed on its left" $? "$r"

# V10: on the b/c divider.
dy=$(( (bb + ct) / 2 ))
r=$(pd --target="$a" --hover-at="$(( (bl + br) / 2 )),$dy")
[ "${NEGATIVE:-0}" = 1 ] && r=$(pd --target="$a" --hover-on="$a" --hx=0.5 --hy=0.5)
[ "$(pf "$r" "d['preview']['kind']")" = insert ] && [ "$(pf "$r" "d['preview']['seam']")" = seams-ends ]
hl_check "V10 on the b/c divider: the landing area, seamed top and bottom" $? "$r"

# V11: the drag leaves.
r=$(pd --target="$a" --hover-end)
[ "$(pf "$r" "d['preview']['shown']")" = False ]
hl_check "V11 the drag leaving the split area takes the preview down" $? "$r"
hl_screenshot "$b" "$shot_off" --window > /dev/null

# V13: a pixel well inside the split-down preview (lower half of b, clear of
# its seam), with the preview and without. The window shot is in device
# pixels from the window's origin; the split area starts at the stage's
# offset, so sample relative to b's own capture origin.
cap=$(hl_screenshot "$b" "$HL_RUNTIME/b.png")
read -r ox oy cw ch <<< "$(pf "$cap" "' '.join(str(d[k]) for k in ('x', 'y', 'client_width', 'client_height'))")"
wx=$(( ${ox:-0} + ${cw:-0} / 2 )); wy=$(( ${oy:-0} + ${ch:-0} - (bb - bt) / 8 ))
on_px=$(hl_png_pixel "$shot_on" "$wx" "$wy"); off_px=$(hl_png_pixel "$shot_off" "$wx" "$wy")
python3 -c '
import sys
on = [int(v) for v in sys.argv[1].split()]; off = [int(v) for v in sys.argv[2].split()]
# Tinted: it moved, and toward blue (the accent) more than toward red.
moved = sum(abs(a - b) for a, b in zip(on, off))
sys.exit(0 if moved >= 20 and (on[2] - off[2]) > (on[0] - off[0]) else 1)
' "$on_px" "$off_px" 2>/dev/null
hl_check "V13 the preview is drawn: at ($wx,$wy) with it ($on_px) vs without ($off_px)" $?

# V12: a release where the preview said split-down splits down, preview gone.
pd --target="$a" --hover-on="$b" --hx=0.5 --hy=0.9 > /dev/null
r=$(pd --target="$a" --drop-on="$b" --fx=0.5 --fy=0.9)
hl_wait_for 5 shape_is "V(V(b,$a),c)"
[ "$(pf "$r" "d['drop']['target']")" = split ] && [ "$(pf "$r" "d['drop']['side']")" = down ] \
    && [ "$(pf "$r" "d['drop']['outcome']")" = moved ] && [ "$(pf "$r" "d['preview']['shown']")" = False ] \
    && shape_is "V(V(b,$a),c)"
hl_check "V12 the release there splits b downward, and the preview is gone after it" $? "shape=$(shape_of) $r"

# V14-V16: the tab bar. c into a tab of its own, so the window has two.
r=$(pd --target="$c" --drop-tab=1)
two_tabs() { [ "$(pf "$(pd --target="$a")" "d['tab_count']")" = 2 ]; }
hl_wait_for 5 two_tabs
r=$(pd --target="$a" --hover-tab=0)
[ "$(pf "$r" "d['selected_tab']")" = 1 ] && [ "$(pf "$r" "d['dwell_tab']")" = 0 ] && [ "$(pf "$r" "d['dwell_lit']")" = 0 ]
hl_check "V14 resting on the other tab's button lights that button while the clock runs" $? "$r"
r=$(pd --target="$a" --hover-leave)
[ "$(pf "$r" "d['dwell_lit']")" = None ] && [ "$(pf "$r" "d['dwell_tab']")" = None ]
hl_check "V15 leaving the bar darkens it" $? "$r"
pd --target="$a" --hover-tab=0 > /dev/null
opened() { [ "$(pf "$(pd --target="$a")" "d['selected_tab']")" = 0 ]; }
hl_wait_for 5 opened
r=$(pd --target="$a")
[ "$(pf "$r" "d['selected_tab']")" = 0 ] && [ "$(pf "$r" "d['dwell_lit']")" = None ]
hl_check "V16 when the dwell fires the tab opens and its button goes dark" $? "$r"

! grep -E 'Gtk-CRITICAL|Gtk-WARNING|GLib-CRITICAL|GLib-GObject-CRITICAL' "$APP_LOG" | grep -v 'GtkRevealer' > /dev/null
hl_check "V17 no GTK critical or warning in the app log" $? "$(grep -E 'CRITICAL|WARNING' "$APP_LOG" | head -3)"

hl_finish "$L"
