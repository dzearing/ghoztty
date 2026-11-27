#!/usr/bin/env bash
# pane-grab-handle.sh - L11b5c (T3709) acceptance for the hover grab handle
# at a pane's top edge on the GTK debug app (Mac PaneGrabHandle, win32
# pane_grab_handle.zig): with rearrange mode OFF, the pointer in a pane's top
# band reveals a grip that drags the pane the way the rearrange header does.
#
# The headless harness has no seat, so no pointer can move and no drag can
# START here (the real pointer drag is NOT RUN; the task says so). The
# `pane-drag --grab-at/--grab-leave` seam calls PaneGrabHandle.pointerAt /
# pointerLeft - the very calls the pane's motion controller makes - and
# `--grab-begin/--grab-end` run what the handle's drag source runs at
# drag-begin and drag-end (PaneDrag.Source.begin/end).
#
#   G1-G2   build, harness, window gh holding H(a,b), mode off
#   G3      no handle anywhere before the pointer is over a pane
#   G4      pointer in b's middle (below the band): no handle
#   G5      pointer in b's top band, off the grip: hinted, the hit box
#           80x24 centred on b's top edge, the band the top fifth (>= 24)
#   G6      the handle widget is laid out exactly on the planned hit box
#   G7      pointer on the grip: engaged
#   G8      the grip is drawn: a pixel at the capsule's centre differs from
#           the same pixel with the handle hidden
#   G9      the pointer leaving the pane hides it
#   G10     rearrange mode on: no handle, even in the band; off again, it
#           comes back on the next motion
#   G11     a drag from b's handle: b engaged and dragging, and a's handle
#           stays down under it (another drag is in flight)
#   G12     that drag's drop on a's lower half splits a downward, and the
#           drag ending hides the handle
#   G13     a drag from the handle let go over nothing pops b out into a new
#           window, as a header drag does
#   G14     a fullscreen window holding one pane shows no handle
#   G15     no GTK critical
#
# Run it ONLY through the wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\pane-grab-handle.sh
#
# NEGATIVE=1 puts the band pointer 30px further down (below the band): G5,
# G6, G7 and G8 must FAIL (4 failures). Output: one PASS/FAIL line per check,
# then 'PANE GRAB HANDLE: ALL PASS' or 'PANE GRAB HANDLE: <n> FAILURE(S)'.
# Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PANE GRAB HANDLE"

log=/tmp/pane-grab-handle-build.log
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
shape_of() { list_py shape gh; }
shape_is() { [ "$(shape_of)" = "$1" ]; }
has_window() { cli +list --json 2>/dev/null | grep -q "\"target\":\"$1\""; }

pd() { hl_ipc pane-drag "$@"; }
pf() { printf '%s' "$1" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(eval(sys.argv[1]))' "$2" 2>/dev/null; }
# The grab report of pane $2 in reply $1.
gf() { pf "$1" "[h['grab'] for h in d['headers'] if h['pane'] == '$2'][0]$3"; }

cli +new-window --target=gh > /dev/null 2>&1
hl_wait_for 15 has_window gh
a=$(shape_of)
cli +split --target=gh --name=b > /dev/null 2>&1
hl_wait_for 15 shape_is "H($a,b)"
b=$(list_py id gh b)
r=$(pd --target="$b")
laid() { [ "$(gf "$(pd --target="$b")" "$b" "['planned']")" != None ]; }
hl_wait_for 5 laid
r=$(pd --target="$b")
[ "$(pf "$r" "d['mode']")" = False ] && shape_is "H($a,b)" && [ "$(gf "$r" "$b" "['planned']")" != None ]
hl_check "G2 window gh holds H(a,b) with rearrange mode off, b big enough for a handle" $? "shape=$(shape_of) $r"

[ "$(gf "$r" "$a" "['state']")" = hidden ] && [ "$(gf "$r" "$b" "['state']")" = hidden ] \
    && [ "$(gf "$r" "$b" "['shown']")" = False ]
hl_check "G3 no handle on any pane before the pointer is over one" $? "$r"

pw=$(gf "$r" "$b" "['band'][2]")
# The pane's height: b's drawn rect.
ph=$(pf "$r" "[h['rect'][3] - h['rect'][1] for h in d['headers'] if h['pane'] == '$b'][0]")

r=$(pd --target="$b" --grab-at="$(( pw / 2 )),$(( ph / 2 ))")
[ "$(gf "$r" "$b" "['state']")" = hidden ] && [ "$(gf "$r" "$b" "['shown']")" = False ]
hl_check "G4 the pointer in b's middle, below the band: no handle" $? "$r"

band_h=$(( (ph * 2 + 5) / 10 )); [ "$band_h" -lt 24 ] && band_h=24
hit_l=$(( (pw - 80) / 2 ))
py=5; [ "${NEGATIVE:-0}" = 1 ] && py=$(( band_h + 30 ))
r=$(pd --target="$b" --grab-at="10,$py")
[ "$(gf "$r" "$b" "['state']")" = hinted ] && [ "$(gf "$r" "$b" "['shown']")" = True ] \
    && [ "$(gf "$r" "$b" "['planned']")" = "[$hit_l, 0, $(( hit_l + 80 )), 24]" ] \
    && [ "$(gf "$r" "$b" "['band']")" = "[0, 0, $pw, $band_h]" ]
hl_check "G5 in b's top band, off the grip: hinted; hit box [$hit_l, 0, $(( hit_l + 80 )), 24], band [0, 0, $pw, $band_h]" $? "$r"

laid_out() { [ "$(gf "$(pd --target="$b")" "$b" "['widget']")" = "[$hit_l, 0, $(( hit_l + 80 )), 24]" ]; }
hl_wait_for 5 laid_out
hl_check "G6 the handle widget is laid out exactly on the planned hit box" $? "$(pd --target="$b")"

gy=12; [ "${NEGATIVE:-0}" = 1 ] && gy=$(( band_h + 30 ))
r=$(pd --target="$b" --grab-at="$(( pw / 2 )),$gy")
[ "$(gf "$r" "$b" "['state']")" = engaged ] && [ "$(gf "$r" "$b" "['shown']")" = True ]
hl_check "G7 the pointer on the grip: engaged" $? "$r"

# G8: the capsule's centre with the handle engaged, then hidden. The window
# shot is in device pixels from the window's origin; b's own capture names
# where b starts in it.
shot_on="$HL_RUNTIME/grab-on.png"; shot_off="$HL_RUNTIME/grab-off.png"
sleep 0.3
hl_screenshot "$b" "$shot_on" --window > /dev/null

# G9: the pointer leaves.
r=$(pd --target="$b" --grab-leave)
[ "$(gf "$r" "$b" "['state']")" = hidden ] && [ "$(gf "$r" "$b" "['shown']")" = False ]
hl_check "G9 the pointer leaving the pane hides the handle" $? "$r"
sleep 0.3
hl_screenshot "$b" "$shot_off" --window > /dev/null
cap=$(hl_screenshot "$b" "$HL_RUNTIME/b.png")
read -r ox oy sc <<< "$(pf "$cap" "' '.join(str(d['data'].get(k, 1)) for k in ('x', 'y', 'scale'))")"
sc=${sc:-1}; case "$sc" in ''|*[!0-9]*) sc=1 ;; esac
wx=$(( ${ox:-0} + pw * sc / 2 )); wy=$(( ${oy:-0} + 12 * sc ))
on_px=$(hl_png_pixel "$shot_on" "$wx" "$wy"); off_px=$(hl_png_pixel "$shot_off" "$wx" "$wy")
python3 -c '
import sys
on = [int(v) for v in sys.argv[1].split()]; off = [int(v) for v in sys.argv[2].split()]
sys.exit(0 if sum(abs(a - b) for a, b in zip(on, off)) >= 20 else 1)
' "$on_px" "$off_px" 2>/dev/null
hl_check "G8 the grip is drawn: at ($wx,$wy) engaged ($on_px) vs hidden ($off_px)" $?

# G10: rearrange mode owns the top edge.
hl_ipc press-key --target="$a" --key=ctrl+shift+period > /dev/null
mode_is() { [ "$(pf "$(pd --target="$b")" "d['mode']")" = "$1" ]; }
hl_wait_for 5 mode_is True
r_on=$(pd --target="$b" --grab-at="10,5")
hl_ipc press-key --target="$a" --key=ctrl+shift+period > /dev/null
hl_wait_for 5 mode_is False
r_off=$(pd --target="$b" --grab-at="10,5")
[ "$(gf "$r_on" "$b" "['state']")" = hidden ] && [ "$(gf "$r_off" "$b" "['state']")" = hinted ]
hl_check "G10 rearrange mode on: no handle in the band; off again: hinted on the next motion" $? "on=$r_on off=$r_off"

# G11: a drag from b's handle.
pd --target="$b" --grab-at="$(( pw / 2 )),12" > /dev/null
pd --target="$b" --grab-begin > /dev/null
r=$(pd --target="$a" --grab-at="10,5")
[ "$(gf "$r" "$b" "['state']")" = engaged ] && [ "$(gf "$r" "$b" "['dragging']")" = True ] \
    && [ "$(gf "$r" "$a" "['state']")" = hidden ]
hl_check "G11 a drag from b's handle: b engaged and dragging, a's handle stays down under it" $? "$r"

# G12: the drag's drop on a's lower half, then the drag ending.
r=$(pd --target="$b" --drop-on="$a" --fx=0.5 --fy=0.9)
hl_wait_for 5 shape_is "V($a,b)"
d_ok=0; { [ "$(pf "$r" "d['drop']['side']")" = down ] && [ "$(pf "$r" "d['drop']['outcome']")" = moved ]; } || d_ok=1
r=$(pd --target="$b" --grab-end)
[ $d_ok = 0 ] && shape_is "V($a,b)" && [ "$(gf "$r" "$b" "['dragging']")" = False ] \
    && [ "$(gf "$r" "$b" "['state']")" = hidden ]
hl_check "G12 its drop on a's lower half splits a downward; the drag ending hides the handle" $? "shape=$(shape_of) $r"

# G13: a drag from the handle let go over nothing.
wins=$(pf "$(pd --target="$b")" "d['window_count']")
r=$(pd --target="$b" --release-nowhere --via-grab)
[ "$(pf "$r" "d['drop']['target']")" = new_window ] && [ "$(pf "$r" "d['drop']['outcome']")" = moved ] \
    && [ "$(pf "$r" "d['window_count']")" = $(( ${wins:-0} + 1 )) ] && ! shape_is "V($a,b)"
hl_check "G13 a handle drag let go over nothing pops b out of gh into a new window ($wins -> $(( ${wins:-0} + 1 )) windows)" $? "shape=$(shape_of) $r"

# G14: b is now its window's only pane. Fullscreen that window.
r=$(pd --target="$b" --grab-at="10,5")
before=$(gf "$r" "$b" "['state']")
hl_ipc press-key --target="$b" --key=ctrl+enter > /dev/null
sleep 1
r=$(pd --target="$b" --grab-at="10,5")
[ "$before" = hinted ] && [ "$(gf "$r" "$b" "['state']")" = hidden ]
hl_check "G14 a fullscreen window holding one pane shows no handle (hinted before: $before)" $? "$r"

# G15: nothing critical.
! grep -E 'CRITICAL' "$APP_LOG" > /dev/null
hl_check "G15 no critical in the app log" $? "$(grep -E 'CRITICAL' "$APP_LOG" | head -3)"

hl_finish "$L"
