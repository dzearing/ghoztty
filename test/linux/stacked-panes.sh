#!/usr/bin/env bash
# stacked-panes.sh - T3567 acceptance for stacked panes on the GTK debug app
# (docs/reference/stacked-panes.md; Linux L11e): a split tab is one stage the
# shared stacked-panes layout places, so a pane is never narrower than the
# configured minimum, a row that cannot fit becomes a run on show plus
# minimized strips, focusing a pane (by name, or by clicking its strip)
# brings it forward while focusing one already on show moves nothing, and a
# gutter drag resizes, tucks a pane away past its minimum and is undone by
# dragging back. Geometry from the debug-only `pane-stack` seam (the stage as
# laid out; its press/drag/release run the real gesture's code - the headless
# harness has no seat) and the window's own render (`capture-pane`).
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\stacked-panes.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh).
#
# Output: one PASS/FAIL line per check, then 'STACKED PANES: ALL PASS' or
# 'STACKED PANES: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="STACKED PANES"

log=/tmp/stacked-panes-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "S2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

# A 400px minimum makes a four-pane row stack in any window this harness
# opens (it cannot fit 4 x 400 + gutters), and two panes fit side by side.
MIN=400
cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
printf 'macos-pane-min-width = %s\nmacos-window-gradient = ocean\nwindow-width = 150\nwindow-height = 30\n' "$MIN" > "$cfg_dir/config.ghostty"

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "S3 the app serves its socket" $?

first=$(hl_first_pane "$app")
# st [seam args...]: the pane-stack seam's reply for the window's tab.
st() { hl_ipc pane-stack "--target=$first" "$@"; }
# sq <reply> <python expr over s (the stage), r (the reply)>: print it.
sq() {
    printf '%s' "$1" | python3 -I -c '
import json, sys
r = json.loads(sys.stdin.read()); s = r.get("stage") or {}
P = {p["pane"]: p for p in s.get("panes", [])}
shown = [p for p in s.get("panes", []) if not p["minimized"]]
mini = [p for p in s.get("panes", []) if p["minimized"]]
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
# listed_minimized: the ids +list reports minimized, sorted, space-joined.
listed_minimized() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
out = []
for w in d["windows"]:
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if l.get("minimized"): out.append(l["id"])
print(" ".join(sorted(out)))' 2>/dev/null
}

# ---- 1. two panes fit side by side ------------------------------------------
cli +split --target="$first" --direction=right --name=p2 > /dev/null 2>&1
for _ in $(seq 1 50); do
    [ "$(sq "$(st)" 'len(s.get("panes", []))')" = 2 ] && break
    sleep 0.2
done
r=$(st)
[ "$(sq "$r" 'len(shown), len(mini)')" = "(2, 0)" ]
hl_check "S4 two panes in a row are both on show" $? "$r"
[ "$(sq "$r" 'all(p["frame"][2] >= '$MIN' for p in shown)')" = True ]
hl_check "S5 each is at least the configured minimum wide" $? "$r"
[ "$(sq "$r" 'sum(1 for g in s["gutters"] if g["kind"] == "divider")')" = 1 ]
hl_check "S6 the divider between them takes the mouse in its gutter" $? "$r"

# ---- 2. a row that cannot fit stacks ---------------------------------------
cli +split --target=p2 --direction=right --name=p3 > /dev/null 2>&1
cli +split --target=p3 --direction=right --name=p4 > /dev/null 2>&1
sleep 1
r=$(st)
[ "$(sq "$r" 'len(s["panes"]) == 4 and len(mini) >= 1 and len(shown) >= 1')" = True ]
hl_check "S7 four panes that cannot fit at the minimum stack: some on show, the rest minimized" $? "$r"
[ "$(sq "$r" 'all(p["frame"][2] >= '$MIN' for p in shown)')" = True ]
hl_check "S8 no pane on show is squeezed below the minimum" $? "$r"
[ "$(sq "$r" 'all(p["strip"] and 0 < p["strip"][2] <= 60 and p["strip"][0] >= 0 and p["strip"][0] + p["strip"][2] <= s["width"] for p in mini)')" = True ]
hl_check "S9 every minimized pane shows a strip inside the stage" $? "$r"
[ "$(sq "$r" 'any(p["focused"] for p in shown)')" = True ]
hl_check "S10 the focused pane is on show" $? "$r"
want=$(sq "$r" '" ".join(sorted(p["pane"] for p in mini))')
got=$(listed_minimized)
[ -n "$want" ] && [ "$want" = "$got" ]
hl_check "S11 +list reports exactly those panes minimized" $? "stage=[$want] list=[$got]"

# ---- 3. focus brings a pane forward ----------------------------------------
target=$(sq "$r" 'mini[0]["pane"]')
cx=$(sq "$r" 'mini[0]["strip"][0] + mini[0]["strip"][2] // 2')
cy=$(sq "$r" 'mini[0]["strip"][1] + mini[0]["strip"][3] // 2')
n_mini=$(sq "$r" 'len(mini)')
r=$(st "--press=$cx,$cy" "--release=0,0")
[ "$(sq "$r" 'r["press"]')" = strip ]
hl_check "S12 a press on a strip takes hold of the strip" $? "$r"
[ "$(sq "$r" 'not P["'"$target"'"]["minimized"] and P["'"$target"'"]["focused"]')" = True ]
hl_check "S13 clicking a strip focuses its pane and brings it on show" $? "$r"
[ "$(sq "$r" 'len(mini)')" = "$n_mini" ]
hl_check "S14 another pane gives way, so as many stay minimized" $? "$r"
[ "$(sq "$r" 'all(p["frame"][2] >= '$MIN' for p in shown)')" = True ]
hl_check "S15 the row is still at the minimum or wider after it" $? "$r"

# name_where <python predicate over p, a stage pane>: the first of the NAMED
# panes (p2..p4; the first pane has none) the stage reports it true for.
name_where() {
    local rr; rr=$(st)
    for n in p2 p3 p4; do
        local i; i=$(id_of "$n")
        [ -n "$i" ] || continue
        [ "$(sq "$rr" 'P.get("'"$i"'") is not None and (lambda p: '"$1"')(P["'"$i"'"])')" = True ] && { echo "$n"; return 0; }
    done
    return 1
}

before=$(sq "$r" '" ".join(sorted(p["pane"] for p in shown))')
other_name=$(name_where 'not p["minimized"] and not p["focused"]')
# The CLI's idempotent focus: a named target that exists is focused (--focus).
[ -n "$other_name" ] && cli +split --name="$other_name" --focus > /dev/null 2>&1
sleep 0.5
r=$(st)
after=$(sq "$r" '" ".join(sorted(p["pane"] for p in shown))')
[ -n "$other_name" ] && [ "$(sq "$r" 'P["'"$(id_of "$other_name")"'"]["focused"]')" = True ] && [ "$before" = "$after" ]
hl_check "S16 focusing a pane already on show moves nothing" $? "before=[$before] after=[$after] name=$other_name"

# Focus a minimized pane by name: it comes out.
mname=$(name_where 'p["minimized"]')
cli +split --name="$mname" --focus > /dev/null 2>&1
sleep 0.5
r=$(st)
mid=$(id_of "$mname")
[ -n "$mid" ] && [ "$(sq "$r" 'not P["'"$mid"'"]["minimized"]')" = True ]
hl_check "S17 focusing a minimized pane by name brings it forward" $? "name=$mname id=$mid $r"

# ---- 4. a gutter drag resizes, tucks past the minimum, and undoes ----------
r=$(st)
g=$(sq "$r" '[g for g in s["gutters"] if g["kind"] in ("divider", "grip") and g["direction"] == "horizontal"][0]["rect"]')
gx=$(sq "$r" '[g for g in s["gutters"] if g["kind"] in ("divider", "grip") and g["direction"] == "horizontal"][0]["rect"][0] + 2')
gy=$(sq "$r" '[g for g in s["gutters"] if g["kind"] in ("divider", "grip") and g["direction"] == "horizontal"][0]["rect"][1] + 20')
shown0=$(sq "$r" 'sorted((p["frame"][0], p["frame"][2]) for p in shown)')
left_w=$(sq "$r" '[w for x, w in sorted((p["frame"][0], p["frame"][2]) for p in shown) if x < '"$gx"'][-1]')
r=$(st "--press=$gx,$gy" "--drag=40,0")
held=$(sq "$r" 'r["press"]')
[ "$held" = divider ] || [ "$held" = grip ]
hl_check "S18 a press in the gutter between two cards on show takes hold of it" $? "gutter=$g $r"
new_w=$(sq "$r" '[w for x, w in sorted((p["frame"][0], p["frame"][2]) for p in shown) if x < '"$gx"'][-1]')
[ -n "$left_w" ] && [ -n "$new_w" ] && [ $((new_w - left_w)) -ge 30 ] && [ $((new_w - left_w)) -le 50 ]
hl_check "S19 dragged 40px, the card before the gutter grows by about that much" $? "before=$left_w after=$new_w"
n_before=$(sq "$r" 'len(mini)')
r=$(st "--drag=2000,0")
[ "$(sq "$r" 'len(mini) > '"$n_before")" = True ] && [ "$(sq "$r" 'all(p["frame"][2] >= '$MIN' for p in shown)')" = True ]
hl_check "S20 dragged past the far pane's minimum, that pane tucks away (nothing squeezed)" $? "$r"
r=$(st "--drag=0,0" "--release=0,0")
[ "$(sq "$r" 'sorted((p["frame"][0], p["frame"][2]) for p in shown)')" = "$shown0" ]
hl_check "S21 dragged back to where it began, the row is as the drag found it" $? "want=$shown0 $r"

# ---- 5. what the window draws is what the layout says ------------------------
r=$(st)
fid=$(sq "$r" '[p["pane"] for p in shown if p["focused"]][0]')
fw=$(sq "$r" 'P["'"$fid"'"]["frame"][2]')
cw=$(hl_screenshot "$fid" "$HL_RUNTIME/f.png" 2>/dev/null | python3 -I -c '
import json, sys
print(json.loads(sys.stdin.readline())["data"]["width"])' 2>/dev/null)
[ -n "$cw" ] && [ -n "$fw" ] && [ $((cw - fw)) -ge -2 ] && [ $((cw - fw)) -le 2 ]
hl_check "S22 the focused card is drawn at the width the layout gave it" $? "layout=$fw drawn=$cw"

# ---- 6. closing panes until the row fits unfolds it --------------------------
cli +close --target=p4 > /dev/null 2>&1
cli +close --target=p3 > /dev/null 2>&1
sleep 1
r=$(st)
[ "$(sq "$r" 'len(s["panes"]), len(mini)')" = "(2, 0)" ]
hl_check "S23 two panes left fit side by side again: nothing minimized" $? "$r"
[ -z "$(listed_minimized)" ]
hl_check "S24 +list reports no pane minimized" $?

! grep -E "without calling gtk_widget_measure|Allocation (width|height) too small|Gtk-CRITICAL" "$APP_LOG" > /dev/null
hl_check "S25 the app logged no GTK allocation warnings or criticals" $? "$(grep -m3 -E 'gtk_widget_measure|too small|Gtk-CRITICAL' "$APP_LOG")"

hl_finish "$L"
