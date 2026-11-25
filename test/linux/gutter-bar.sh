#!/usr/bin/env bash
# gutter-bar.sh - T3626 acceptance for the stacked-panes gutter bar and a
# gutter's double-click on the GTK debug app (docs/reference/stacked-panes.md
# "The gutter bar", "Double-clicking a grip"; Linux L11e-3):
#
#   - every divider and grip shows a 4px accent bar down the middle of its
#     gutter: half strength under the pointer, full while dragged, one at a
#     time, gone when the pointer leaves;
#   - the bar stays in the gutter: drawn where the layout leaves it, and when
#     a drag folds a pane away it moves to the gutter that took its place;
#   - the window's own render shows the accent there while a drag is held;
#   - a double-click on a divider evens out the panes across it in its
#     direction only, and one on a grip between two cards evens out the run
#     on show; the grip where a run meets its strips has none.
#
# Geometry and the bar come from the debug-only `pane-stack` seam (its
# --hover/--leave/--press/--drag/--release run the real controllers' code -
# the headless harness has no seat), pixels from `capture-pane --window`.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\gutter-bar.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh).
#
# Output: one PASS/FAIL line per check, then 'GUTTER BAR: ALL PASS' or
# 'GUTTER BAR: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="GUTTER BAR"

log=/tmp/gutter-bar-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "B1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "B2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

# A 400px minimum: two panes fit side by side, four stack (stacked-panes.sh).
MIN=400
cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
printf 'macos-pane-min-width = %s\nmacos-pane-min-height = 100\nwindow-width = 150\nwindow-height = 30\n' "$MIN" > "$cfg_dir/config.ghostty"

export SHELL=/bin/sh
# No glides: every layout lands at once, so each step reads where it settles.
GHOZTTY_STACK_SLIDE_MS=0 hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "B3 the app serves its socket" $?

first=$(hl_first_pane "$app")
st() { hl_ipc pane-stack "--target=$first" "$@"; }
# sq <reply> <python expr>: s the stage, r the reply, b the bar, G the
# gutters, shown/mini the panes on show / minimized, P panes by id, and
# inside(a, b): rect a lies within rect b.
sq() {
    printf '%s' "$1" | python3 -I -c '
import json, sys
r = json.loads(sys.stdin.read()); s = r.get("stage") or {}
b = s.get("bar"); G = s.get("gutters", [])
P = {p["pane"]: p for p in s.get("panes", [])}
shown = [p for p in s.get("panes", []) if not p["minimized"]]
mini = [p for p in s.get("panes", []) if p["minimized"]]
def inside(a, o): return a[0] >= o[0] and a[1] >= o[1] and a[0] + a[2] <= o[0] + o[2] and a[1] + a[3] <= o[1] + o[3]
def gut(kind, d): return [g for g in G if g["kind"] == kind and g["direction"] == d]
def mid(rc): return (rc[0] + rc[2] // 2, rc[1] + rc[3] // 2)
print(eval(sys.argv[1]))' "$2" 2>/dev/null
}
# id_of <name>: a pane's id by its +list name.
id_of() {
    cli +list --json 2>/dev/null | python3 -I -c '
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
            if l.get("name") == sys.argv[1]: print(l["id"]); sys.exit(0)
' "$1" 2>/dev/null
}
# px_at <x> <y>: the window's own render at stage point (x, y), 'r g b'.
shot=0
px_at() {
    local r ox oy
    r=$(st)
    ox=$(sq "$r" 's["origin"][0]'); oy=$(sq "$r" 's["origin"][1]')
    shot=$((shot + 1))
    local f="$HL_RUNTIME/bar-$shot.png"
    hl_screenshot "$first" "$f" --window > /dev/null 2>&1 || { echo off; return; }
    hl_png_pixel "$f" $((ox + $1)) $((oy + $2))
}
# accent <r g b>: libadwaita's default accent (#3584e4) within 45 a channel.
accent() {
    [ "$1" != off ] || return 1
    set -- $1
    [ $(( ($1 - 53) * ($1 - 53) < 2025 && ($2 - 132) * ($2 - 132) < 2025 && ($3 - 228) * ($3 - 228) < 2025 )) = 1 ]
}

# ---- 1. hover: half strength, in the gutter, gone on leave -----------------
cli +split --target="$first" --direction=right --name=p2 > /dev/null 2>&1
for _ in $(seq 1 50); do
    [ "$(sq "$(st)" 'len(gut("divider", "horizontal"))')" = 1 ] && break
    sleep 0.2
done
r=$(st)
dv=$(sq "$r" 'gut("divider", "horizontal")[0]["rect"]')
read -r dx dy <<< "$(sq "$r" '"%d %d" % mid(gut("divider", "horizontal")[0]["rect"])')"
rest_px=$(px_at "$dx" "$dy")
r=$(st "--hover=$dx,$dy")
[ "$(sq "$r" 'b and b["kind"] == "divider" and b["strength"] == "hover"')" = True ]
hl_check "B4 the pointer over a divider lights its bar at half strength" $? "divider=$dv $r"
[ "$(sq "$r" 'b and inside(b["core"], b["gutter"]) and b["core"][2] == 4 and b["core"][3] == b["gutter"][3]')" = True ]
hl_check "B5 the bar is 4px wide, down the middle of the gutter, its whole length" $? "$r"
r=$(st "--hover=$((dx - 120)),$dy")
[ "$(sq "$r" 'b is None')" = True ]
hl_check "B6 over a card instead, no gutter shows a bar" $? "$r"
r=$(st "--hover=$dx,$dy" "--leave")
[ "$(sq "$r" 'b is None')" = True ]
hl_check "B7 the pointer leaving the stage puts the bar out" $? "$r"

# ---- 2. dragged: full strength, in the gutter, drawn --------------------------
r=$(st "--hover=$dx,$dy" "--press=$dx,$dy" "--drag=40,0")
[ "$(sq "$r" 'r["press"] == "divider" and b and b["strength"] == "drag"')" = True ]
hl_check "B8 a held divider shows its bar at full strength" $? "$r"
[ "$(sq "$r" 'b and b["gutter"] == gut("divider", "horizontal")[0]["rect"] and b["gutter"][0] >= '"$((dx - 5 + 30))"'')" = True ]
hl_check "B9 the bar moves with the gutter as the layout leaves it" $? "$r"
read -r hx hy <<< "$(sq "$r" '"%d %d" % mid(b["core"])')"
sleep 0.4
held_px=$(px_at "$hx" "$hy")
accent "$held_px" && ! accent "$rest_px"
hl_check "B10 the window draws the accent in the gutter while the drag is held (not at rest)" $? "held=$held_px rest=$rest_px at $hx,$hy"
r=$(st "--drag=4000,0")
[ "$(sq "$r" 'len(mini) >= 1 and b is not None and b["strength"] == "drag" and b["kind"] == "edge" and inside(b["core"], b["gutter"])')" = True ]
hl_check "B11 dragged until a pane tucks away, the bar is on the grip that took the divider's place" $? "$r"
r=$(st "--drag=0,0" "--release=0,0" "--leave")
[ "$(sq "$r" 'b is None and len(mini) == 0')" = True ]
hl_check "B12 let go and the pointer gone, no bar; the row is back" $? "$r"
sleep 0.4
read -r dx dy <<< "$(sq "$r" '"%d %d" % mid(gut("divider", "horizontal")[0]["rect"])')"
gone_px=$(px_at "$dx" "$dy")
! accent "$gone_px"
hl_check "B13 the window no longer draws the bar once it is out" $? "px=$gone_px at $dx,$dy"

# ---- 3. double-click a divider: evens out across it ---------------------------
r=$(st "--press=$dx,$dy" "--drag=80,0" "--release=80,0")
uneven=$(sq "$r" 'abs(shown[0]["frame"][2] - shown[1]["frame"][2])')
read -r dx dy <<< "$(sq "$r" '"%d %d" % mid(gut("divider", "horizontal")[0]["rect"])')"
r=$(st "--press=$dx,$dy" "--release=0,0" "--press=$dx,$dy" "--release=0,0")
[ "$(sq "$r" 'r["press"]')" = even ] && [ "$(sq "$r" 'abs(shown[0]["frame"][2] - shown[1]["frame"][2]) <= 2')" = True ] && [ "${uneven:-0}" -ge 100 ]
hl_check "B14 a double-click on a divider evens out the panes across it" $? "uneven by $uneven, then $r"

# A column on the right: p2 over p5. Its divider runs the other way.
# (`--pane` splits that exact pane; `--target` names a window, docs/claude/cli.md.)
cli +split --pane=p2 --direction=down --name=p5 > /dev/null 2>&1
for _ in $(seq 1 50); do
    [ "$(sq "$(st)" 'len(gut("divider", "vertical"))')" = 1 ] && break
    sleep 0.2
done
r=$(st)
read -r dx dy <<< "$(sq "$r" '"%d %d" % mid(gut("divider", "horizontal")[0]["rect"])')"
r=$(st "--press=$dx,$dy" "--drag=100,0" "--release=100,0")
read -r vx vy <<< "$(sq "$r" '"%d %d" % mid(gut("divider", "vertical")[0]["rect"])')"
r=$(st "--press=$vx,$vy" "--drag=0,60" "--release=0,60")
p2=$(id_of p2); p5=$(id_of p5)
# The column's two panes, and the widths of every pane on show.
heights='abs(P["'"$p2"'"]["frame"][3] - P["'"$p5"'"]["frame"][3])'
widths='sorted((p["frame"][0], p["frame"][2]) for p in shown)'
[ "$(sq "$r" 'P["'"$p2"'"]["frame"][0] == P["'"$p5"'"]["frame"][0] and P["'"$p2"'"]["frame"][0] > P["'"$first"'"]["frame"][0]')" = True ]
hl_check "B15 p2 and p5 make a column to the right of the first pane" $? "p2=$p2 p5=$p5 $r"
w_before=$(sq "$r" "$widths")
h_uneven=$(sq "$r" "$heights")
read -r vx vy <<< "$(sq "$r" '"%d %d" % mid(gut("divider", "vertical")[0]["rect"])')"
r=$(st "--press=$vx,$vy" "--release=0,0" "--press=$vx,$vy" "--release=0,0")
[ "$(sq "$r" 'r["press"]')" = even ] && [ "$(sq "$r" "$heights <= 2")" = True ] && [ "${h_uneven:-0}" -ge 60 ]
hl_check "B15b a double-click on a divider running across a column evens its heights" $? "uneven by $h_uneven, then $r"
[ "$(sq "$r" "$widths")" = "$w_before" ]
hl_check "B16 ... and leaves every width as it was set" $? "widths before=$w_before after=$(sq "$r" "$widths")"
cli +close --target=p5 > /dev/null 2>&1

# ---- 4. a stacked run: a grip's double-click evens the run --------------------
cli +split --pane=p2 --direction=right --name=p3 > /dev/null 2>&1
cli +split --pane=p3 --direction=right --name=p4 > /dev/null 2>&1
for _ in $(seq 1 50); do
    [ "$(sq "$(st)" 'len(s.get("panes", [])) == 4 and len(mini) >= 1')" = True ] && break
    sleep 0.2
done
r=$(st)
ngrip=$(sq "$r" 'len(gut("grip", "horizontal"))')
if [ "${ngrip:-0}" -ge 1 ]; then
    read -r gx gy <<< "$(sq "$r" '"%d %d" % mid(gut("grip", "horizontal")[0]["rect"])')"
    r=$(st "--hover=$gx,$gy")
    [ "$(sq "$r" 'b and b["kind"] == "grip" and b["strength"] == "hover"')" = True ]
    hl_check "B17 a grip between two cards lights its bar under the pointer" $? "$r"
    r=$(st "--leave" "--press=$gx,$gy" "--drag=60,0")
    [ "$(sq "$r" 'b and b["strength"] == "drag" and b["kind"] == "grip" and inside(b["core"], b["gutter"])')" = True ]
    hl_check "B18 a held grip's bar is full strength, in its gutter" $? "$r"
    r=$(st "--release=60,0")
    spread=$(sq "$r" 'max(p["frame"][2] for p in shown) - min(p["frame"][2] for p in shown)')
    [ "${spread:-0}" -ge 20 ] && [ "$(sq "$r" 'len(gut("grip", "horizontal"))')" -ge 1 ]
    hl_check "B19 the grip's drag left the run uneven (the double-click has something to even)" $? "spread=$spread $r"
    read -r gx gy <<< "$(sq "$r" '"%d %d" % mid(gut("grip", "horizontal")[0]["rect"])')"
    r=$(st "--press=$gx,$gy" "--release=0,0" "--press=$gx,$gy" "--release=0,0")
    [ "$(sq "$r" 'r["press"]')" = even ] && [ "$(sq "$r" 'max(p["frame"][2] for p in shown) - min(p["frame"][2] for p in shown) <= 2')" = True ]
    hl_check "B19b a double-click on a grip between two cards evens out the run on show" $? "spread $spread, then $r"
else
    hl_check "B17 a stacked run shows a grip between two cards" 1 "$r"
fi
r=$(st)
nedge=$(sq "$r" 'len(gut("edge", "horizontal"))')
if [ "${nedge:-0}" -ge 1 ]; then
    read -r ex ey <<< "$(sq "$r" '"%d %d" % mid(gut("edge", "horizontal")[0]["rect"])')"
    r=$(st "--press=$ex,$ey" "--release=0,0" "--press=$ex,$ey")
    [ "$(sq "$r" 'r["press"]')" = grip ]
    hl_check "B20 the grip where a run meets its strips has no double-click: the second press is a drag" $? "$r"
    st "--release=0,0" > /dev/null
else
    hl_check "B20 a stacked run shows the grip where it meets its strips" 1 "$r"
fi

! grep -E "without calling gtk_widget_measure|Allocation (width|height) too small|Gtk-CRITICAL" "$APP_LOG" > /dev/null
hl_check "B21 the app logged no GTK allocation warnings or criticals" $? "$(grep -m3 -E 'gtk_widget_measure|too small|Gtk-CRITICAL' "$APP_LOG")"

hl_finish "$L"
