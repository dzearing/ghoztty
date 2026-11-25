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
# T3629 adds: a strip relabels live (+set-banner, OSC 2), a strip drag has a
# strip's own targets (`pane-drag --blade`: a slot, a window edge, nothing
# over a card), and a column stacks with strips lying across it.
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
# A 200px minimum HEIGHT makes a five-pane column stack (T3629, section 10).
MINH=200
cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
printf 'macos-pane-min-width = %s\nmacos-pane-min-height = %s\nmacos-window-gradient = ocean\nwindow-width = 150\nwindow-height = 30\n' "$MIN" "$MINH" > "$cfg_dir/config.ghostty"

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
# At rest: the drag back in S21 glides the folded pane out (T3625), and a
# card mid-glide is drawn where the glide has it, not at its slot.
for _ in $(seq 1 50); do
    [ "$(sq "$(st)" 's.get("gliding")')" = False ] && break
    sleep 0.1
done
r=$(st)
fid=$(sq "$r" '[p["pane"] for p in shown if p["focused"]][0]')
fw=$(sq "$r" 'P["'"$fid"'"]["frame"][2]')
cap=$(hl_screenshot "$fid" "$HL_RUNTIME/f.png" 2>&1)
cw=$(printf '%s' "$cap" | python3 -I -c '
import json, sys
print(json.loads(sys.stdin.readline())["data"]["width"])' 2>/dev/null)
[ -n "$cw" ] && [ -n "$fw" ] && [ $((cw - fw)) -ge -2 ] && [ $((cw - fw)) -le 2 ]
hl_check "S22 the focused card is drawn at the width the layout gave it" $? "layout=$fw drawn=$cw reply=$cap"

# ---- 6. closing panes until the row fits unfolds it --------------------------
cli +close --target=p4 > /dev/null 2>&1
cli +close --target=p3 > /dev/null 2>&1
sleep 1
r=$(st)
[ "$(sq "$r" 'len(s["panes"]), len(mini)')" = "(2, 0)" ]
hl_check "S23 two panes left fit side by side again: nothing minimized" $? "$r"
[ -z "$(listed_minimized)" ]
hl_check "S24 +list reports no pane minimized" $?

# ---- 7. a side pane opened without focus comes on show (T3628) ---------------
# An agent's +split leaves the caret where it is (focus is opt-in). In a row
# with no room it is still the one put on show - the featured pane - and the
# pane with the caret keeps it.
r=$(st)
caret=$(sq "$r" '[p["pane"] for p in s["panes"] if p["focused"]][0]')
cli +split --target="$caret" --direction=right --name=p5 > /dev/null 2>&1
cli +split --target=p5 --direction=right --name=p6 > /dev/null 2>&1
cli +split --target=p6 --direction=right --name=p7 > /dev/null 2>&1
sleep 1
r=$(st)
p7=$(id_of p7)
[ -n "$p7" ] && [ "$(sq "$r" 'len(s["panes"]) == 5 and len(mini) >= 1')" = True ]
hl_check "S26 five panes in a row that cannot fit stack" $? "$r"
[ -n "$p7" ] && [ "$(sq "$r" 'P.get("'"$p7"'") is not None and not P["'"$p7"'"]["minimized"]')" = True ]
hl_check "S27 the side pane split last without focus is on show, not born a strip" $? "p7=$p7 $r"
[ -n "$caret" ] && [ "$(sq "$r" 'P["'"$caret"'"]["focused"] and not P["'"$p7"'"]["focused"]')" = True ]
hl_check "S28 the pane that had the caret keeps it" $? "caret=$caret $r"

# Only the user brings a minimized pane back out: a side pane split off a
# strip goes in beside the pane on show nearest it, and the strips stay.
m_id=$(sq "$r" '[p["pane"] for p in mini if p["pane"] != "'"$caret"'"][0]')
m_name=$m_id
mini_before=$(sq "$r" '" ".join(sorted(p["pane"] for p in mini))')
[ -n "$m_name" ] && cli +split --target="$m_name" --direction=right --name=p8 > /dev/null 2>&1
sleep 1
r=$(st)
p8=$(id_of p8)
[ -n "$p8" ] && [ "$(sq "$r" 'P.get("'"$p8"'") is not None and not P["'"$p8"'"]["minimized"]')" = True ]
hl_check "S29 a side pane split off a minimized pane is on show" $? "target=$m_name ($m_id) p8=$p8 $r"
[ -n "$m_id" ] && [ "$(sq "$r" 'P["'"$m_id"'"]["minimized"]')" = True ]
hl_check "S30 the minimized pane it was split off stays minimized" $? "target=$m_id before=[$mini_before] $r"
[ -n "$p8" ] && [ "$(sq "$r" 'all(P[i]["minimized"] for i in "'"$mini_before"'".split() if i in P and i != "'"$caret"'")')" = True ]
hl_check "S31 no strip is pulled back out with it" $? "before=[$mini_before] $r"


# ---- 8. a strip's label is live (T3629) --------------------------------------
# docs/reference/stacked-panes.md "Strip labels": +set-banner, OSC 7778 and a
# retitle rename a showing strip at once - read straight after the verb, with
# no layout in between to do it.
r=$(st)
lm=$(sq "$r" '[p["pane"] for p in mini if p["label"] is not None and p["pane"] != "'"$first"'"][0]')
label0=$(sq "$r" 'P["'"$lm"'"]["label"]')
cli +set-banner --target="$lm" '## Fix strip labels' > /dev/null 2>&1
r=$(st)
[ -n "$lm" ] && [ "$(sq "$r" 'P["'"$lm"'"]["label"]')" = "Fix strip labels" ]
hl_check "S32 +set-banner renames the strip at once, by the banner's title" $? "pane=$lm before=[$label0] $r"
cli +set-banner --target="$lm" --clear > /dev/null 2>&1
r=$(st)
[ -n "$lm" ] && [ "$(sq "$r" 'P["'"$lm"'"]["label"]')" = "$label0" ]
hl_check "S33 clearing the banner brings the pane's own name back" $? "pane=$lm want=[$label0] $r"
# (S34, the OSC 2 retitle, needs a pane running a shell: section 10's.)

# ---- 9. dragging a strip has a strip's own targets (T3629) -------------------
# The drop half of a strip drag, through the seam (`pane-drag --blade`, the
# headless harness has no seat): `SplitTree.dropPaneAt` with the strip's
# targets, as the face's drag source's drop does.
pd() { hl_ipc pane-drag "$@"; }
dq() {
    printf '%s' "$1" | python3 -I -c '
import json, sys
r = json.loads(sys.stdin.read()); d = r.get("drop") or {}
print(eval(sys.argv[1]))' "$2" 2>/dev/null
}
# order: the tab's leaves in tree order, by id.
order() {
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
        ids = [l["id"] for l in walk(t["splits"])]
        if sys.argv[1] in ids: print(" ".join(ids)); sys.exit(0)
' "$1" 2>/dev/null
}
r=$(st)
bm=$(sq "$r" 'mini[0]["pane"]')
# A wide card on show, not the strip's neighbour in the tree.
card=$(sq "$r" 'max(shown, key=lambda p: p["frame"][2])["pane"]')
mx=$(sq "$r" 'P["'"$card"'"]["frame"][0] + P["'"$card"'"]["frame"][2] // 2')
my=$(sq "$r" 'P["'"$card"'"]["frame"][1] + P["'"$card"'"]["frame"][3] // 2')
d=$(pd "--target=$bm" --blade "--drop-at=$mx,$my")
[ "$(dq "$d" 'd.get("target"), d.get("outcome")')" = "('none', 'none')" ]
hl_check "S35 a strip let go over the middle of a card is no drop (no split quadrants, no swap)" $? "strip=$bm card=$card $d"
d=$(pd "--target=$bm" "--drop-at=$mx,$my")
[ "$(dq "$d" 'd.get("target")')" != none ]
hl_check "S36 the same point is a target for the same pane dragged by its header (the control)" $? "$d"
# The leading edge of the SECOND card on show is the slot between two cards
# (the only one when one card shows): the strip moves there. A strip is never
# between two cards on show, so this is never the strip's own place.
r=$(st)
card=$(sq "$r" 'sorted(shown, key=lambda p: p["frame"][0])[min(1, len(shown) - 1)]["pane"]')
caret0=$(sq "$r" '[p["pane"] for p in s["panes"] if p["focused"]][0]')
lx=$(sq "$r" 'P["'"$card"'"]["frame"][0] + 2')
order0=$(order "$bm")
d=$(pd "--target=$bm" --blade "--drop-at=$lx,$my")
order1=$(order "$bm")
[ "$(dq "$d" 'd.get("target"), d.get("outcome")')" = "('reorder', 'moved')" ]
hl_check "S37 a strip let go in the slot before a card reorders it beside that card" $? "strip=$bm card=$card $d"
[ -n "$order1" ] && [ "$(printf '%s' "$order1" | python3 -I -c 'import sys; o = sys.stdin.read().split(); print(o.index(sys.argv[2]) + 1 == o.index(sys.argv[1]))' "$card" "$bm")" = True ] && [ "$order0" != "$order1" ]
hl_check "S38 the tree now has the strip's pane just before that card" $? "before=[$order0] after=[$order1]"
# Mac `PaneMoveCoordinator.reorder`: a pane that lands among the cards on
# show is focused; one that lands among the strips stays one and the caret
# stays where it was. Either way, never a focused strip.
ok=1
for _ in $(seq 1 25); do
    [ "$(sq "$(st)" '(not P["'"$bm"'"]["minimized"] and P["'"$bm"'"]["focused"]) or (P["'"$bm"'"]["minimized"] and P["'"$caret0"'"]["focused"])')" = True ] && { ok=0; break; }
    sleep 0.2
done
hl_check "S39 the dropped pane is focused on show, or stays a strip with the caret unmoved" $ok "caret0=$caret0 $(st)"
# A window's edge band, away from every slot: a top-level insert.
r=$(st)
bm2=$(sq "$r" 'mini[0]["pane"]')
card2=$(sq "$r" 'max(shown, key=lambda p: p["frame"][2])["pane"]')
tx=$(sq "$r" 'P["'"$card2"'"]["frame"][0] + P["'"$card2"'"]["frame"][2] // 2')
d=$(pd "--target=$bm2" --blade "--drop-at=$tx,3")
[ "$(dq "$d" 'd.get("target"), d.get("side"), d.get("outcome")')" = "('top_level', 'up', 'moved')" ]
hl_check "S40 a strip let go at the window's top edge spans the window above the row" $? "strip=$bm2 $d"

# ---- 10. a column stacks with horizontal strips (T3629) ----------------------
cli +new-window --target=wcol --name=c1 --command="sleep 600" > /dev/null 2>&1
for _ in $(seq 1 50); do [ -n "$(id_of c1)" ] && break; sleep 0.2; done
for n in 2 3 4 5; do
    cli +split --target=c$((n - 1)) --direction=down --name=c$n --command=/bin/sh > /dev/null 2>&1
done
sleep 1
cs() { hl_ipc pane-stack "--target=$(id_of c1)" "$@"; }
r=$(cs)
[ "$(sq "$r" 'len(s.get("panes", [])) == 5 and len(mini) >= 1 and len(shown) >= 1')" = True ]
hl_check "S41 five panes in a column that cannot fit at the minimum height stack" $? "$r"
[ "$(sq "$r" 'all(p["frame"][3] >= '$MINH' for p in shown)')" = True ]
hl_check "S42 no card on show in the column is under the minimum height" $? "$r"
[ "$(sq "$r" 'all(p["strip"] and p["strip"][2] > p["strip"][3] and 0 < p["strip"][3] <= 60 for p in mini)')" = True ]
hl_check "S43 a column's strips lie across it (wider than tall)" $? "$r"
[ "$(sq "$r" 'any(g["direction"] == "vertical" for g in s["gutters"])')" = True ]
hl_check "S44 the column's gutters run vertically (rows of cards stacked down)" $? "$r"
# A retitle (OSC 2) from a minimized pane's own program renames its strip
# while it stays minimized. c2..c5 run a shell, so the keys reach one.
c1id=$(id_of c1)
rm_=$(sq "$r" '[p["pane"] for p in mini if p["pane"] != "'"$c1id"'"][0]')
cli +send-keys --target="$rm_" "printf '\033]2;retitled-strip\007'" Enter > /dev/null 2>&1
ok=1
for _ in $(seq 1 25); do
    [ "$(sq "$(cs)" 'P["'"$rm_"'"]["minimized"] and P["'"$rm_"'"]["label"] == "retitled-strip"')" = True ] && { ok=0; break; }
    sleep 0.2
done
hl_check "S34 an OSC 2 retitle renames the strip while the pane stays minimized" $ok "pane=$rm_ $(cli +read --target="$rm_" --lines=4 2>&1 | tr '\n' '|' | head -c 200) $(cs)"
! grep -E "without calling gtk_widget_measure|Allocation (width|height) too small|Gtk-CRITICAL" "$APP_LOG" > /dev/null
hl_check "S25 the app logged no GTK allocation warnings or criticals" $? "$(grep -m3 -E 'gtk_widget_measure|too small|Gtk-CRITICAL' "$APP_LOG")"

hl_finish "$L"
