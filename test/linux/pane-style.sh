#!/usr/bin/env bash
# pane-style.sh - T3566 acceptance for the elevated pane style on the GTK
# debug app (docs/reference/pane-style.md; Linux L11d): every pane is a raised
# rounded card on the window's gradient desk, one gutter between the cards and
# around the edge, the focused pane of several is backlit with a brighter rim,
# `macos-pane-style = flat` (on a reload too) puts the panes back square, one
# 6px flat gutter apart (Mac flatGap), and `+new-window --color=random` gives the window its own gradient
# instead of tinting the terminal. Read from the window's OWN render through
# the debug-only capture-pane seam (T3359), so it is what the window draws.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\pane-style.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh).
#
# Output: one PASS/FAIL line per check, then 'PANE STYLE: ALL PASS' or
# 'PANE STYLE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PANE STYLE"

log=/tmp/pane-style-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "S2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

# A known terminal background, so the desk is told apart from it; the shared
# ocean for every window (deterministic: its blue leads its red); no dimming,
# which would change the pane's colour under test. S5-S15 measure SOLID cards
# (glass off), so a card's middle is exactly its terminal; the glass section
# (G1-G8, T3622) turns glass on with a reload.
cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
base_cfg='background = #203040\nforeground = #e0e0e0\nbackground-opacity = 1\nwindow-padding-color = background\nunfocused-split-opacity = 1\nmacos-window-gradient = ocean\nmacos-pane-glass = false\n'
printf "$base_cfg" > "$cfg_dir/config.ghostty"

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "S3 the app serves its socket" $?

# leaf <window-target> <pane-name|*> <field>: one field of that pane's +list
# leaf ('*' = the window's first pane), or nothing.
leaf() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
want_w, want_p, field = sys.argv[1], sys.argv[2], sys.argv[3]
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    if want_w != "" and (w.get("target") or "") != want_w: continue
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if want_p == "*" or l.get("name") == want_p:
                print(l.get(field, "")); sys.exit(0)
' "$1" "$2" "$3" 2>/dev/null
}
id_of() { leaf "$1" "$2" id; }

# geom <pane-id>: 'x y w h' of the pane inside its window (device pixels).
geom() {
    hl_screenshot "$1" "$HL_RUNTIME/g.png" 2>/dev/null | python3 -I -c '
import json, sys
d = json.loads(sys.stdin.readline())["data"]
print(d["x"], d["y"], d["width"], d["height"])' 2>/dev/null
}
wshot="$HL_RUNTIME/w.png"
# px <pane-id> <x> <y>: 'r g b' of the pane's whole window at (x, y).
px() {
    hl_screenshot "$1" "$wshot" --window > /dev/null 2>&1 || { echo off; return; }
    hl_png_pixel "$wshot" "$2" "$3"
}
# near <r g b> <R> <G> <B>: within 8 per channel.
near() { awk -v a="$1" -v b="$2" -v c="$3" -v x="$4" -v y="$5" -v z="$6" 'function d(p,q){return p>q?p-q:q-p} BEGIN{exit !(d(a,x)<=8 && d(b,y)<=8 && d(c,z)<=8)}'; }
sum() { echo $(( $1 + $2 + $3 )); }

o=$(cli +new-window --target=ps 2>&1); rc=$?
a=""; for _ in $(seq 1 50); do a=$(id_of ps '*'); [ -n "$a" ] && break; sleep 0.2; done
o2=$(cli +split --target=ps --name=b 2>&1); rc2=$?
b=""; for _ in $(seq 1 50); do b=$(id_of ps b); [ -n "$b" ] && break; sleep 0.2; done
[ $rc = 0 ] && [ $rc2 = 0 ] && [ -n "$a" ] && [ -n "$b" ]
hl_check "S4 a window with two panes side by side (a focused, b not)" $? "rc=$rc/$rc2 a=$a b=$b $o $o2"
sleep 1

read -r ax ay aw ah <<< "$(geom "$a")"
read -r bx by bw bh <<< "$(geom "$b")"
gap=$(( ${bx:-0} - ${ax:-0} - ${aw:-0} ))
[ "$gap" -ge 9 ] && [ "$gap" -le 13 ]
hl_check "S5 elevated (the default): the cards sit a ~10px gutter apart" $? "a=$ax,$ay ${aw}x$ah b=$bx,$by ${bw}x$bh gap=$gap"

midy=$(( ay + ah / 2 ))
read -r cr cg cb <<< "$(px "$a" $(( ax + aw / 2 )) $midy)"
near "$cr" "$cg" "$cb" 32 48 64
hl_check "S6 control: the middle of a card is its terminal (#203040)" $? "center=$cr,$cg,$cb"

# Beside the card, and dead centre of the gutter where GtkPaned's separator
# sits: no divider line is drawn over the desk in the elevated style.
read -r gr gg gb <<< "$(px "$a" $(( ax + aw + 2 )) $midy)"
read -r sr sg sb <<< "$(px "$a" $(( ax + aw + gap / 2 )) $midy)"
! near "$gr" "$gg" "$gb" 32 48 64 && [ $(( gb - gr )) -ge 10 ] && [ $(( sb - sr )) -ge 10 ]
hl_check "S7 the gutter between the cards is the ocean desk with no divider line (blue leads red)" $? "beside=$gr,$gg,$gb centre=$sr,$sg,$sb"

read -r lr lg lb <<< "$(px "$a" $(( ax - 3 )) $midy)"
! near "$lr" "$lg" "$lb" 32 48 64 && [ $(( lb - lr )) -ge 10 ]
hl_check "S8 the desk runs round the window's edge too (left of the first card)" $? "edge=$lr,$lg,$lb ax=$ax"

read -r kr kg kb <<< "$(px "$a" $(( ax + 1 )) $(( ay + 1 )))"
! near "$kr" "$kg" "$kb" 32 48 64
hl_check "S9 a card's corner is rounded: its corner pixel shows the desk, not the terminal" $? "corner=$kr,$kg,$kb"

# ---- focus: the focused card of several is backlit with a brighter rim -----
lit_edge=$(sum $lr $lg $lb)
read -r rr rg rb <<< "$(px "$a" "$ax" $midy)"
lit_rim=$(sum $rr $rg $rb)
o=$(cli +split --pane=b --name=c --focus 2>&1); rc=$?
c=""; for _ in $(seq 1 50); do c=$(id_of ps c); [ -n "$c" ] && break; sleep 0.2; done
sleep 1
read -r ax2 ay2 aw2 ah2 <<< "$(geom "$a")"
read -r ur ug ub <<< "$(px "$a" $(( ax2 - 3 )) $midy)"
read -r ir ig ib <<< "$(px "$a" "$ax2" $midy)"
dim_edge=$(sum $ur $ug $ub); dim_rim=$(sum $ir $ig $ib)
[ $rc = 0 ] && [ "$ax2" = "$ax" ] && [ $(( lit_edge - dim_edge )) -ge 6 ]
hl_check "S10 the desk beside the focused card is lit by its glow, and goes dark when focus leaves" $? "rc=$rc lit=$lit_edge dim=$dim_edge ($lr,$lg,$lb -> $ur,$ug,$ub) ax=$ax/$ax2"
[ $(( lit_rim - dim_rim )) -ge 20 ]
hl_check "S11 the focused card's rim is brighter than an unfocused one's" $? "lit=$lit_rim ($rr,$rg,$rb) dim=$dim_rim ($ir,$ig,$ib)"

# ---- the flat style, on a reload: a 6px gutter between panes, no desk ---------------
printf "${base_cfg}macos-pane-style = flat\n" > "$cfg_dir/config.ghostty"
o=$(cli +reload --config 2>&1); rc=$?
sleep 1
read -r fx fy fw fh <<< "$(geom "$a")"
read -r gx2 gy2 gw2 gh2 <<< "$(geom "$b")"
fgap=$(( ${gx2:-0} - ${fx:-0} - ${fw:-0} ))
[ $rc = 0 ] && [ "$fgap" -ge 5 ] && [ "$fgap" -le 7 ] && [ "${fx:-99}" -lt "$ax" ]
hl_check "S12 macos-pane-style = flat on a reload: the panes sit one 6px flat gutter apart (Mac flatGap; T3567 stage)" $? "rc=$rc a=$fx ${fw} b=$gx2 gap=$fgap (elevated a.x=$ax) $o"
read -r fr fg fb <<< "$(px "$a" $(( fx + 1 )) $(( fy + 1 )))"
near "$fr" "$fg" "$fb" 32 48 64
hl_check "S13 flat: the pane's corner is square terminal again" $? "corner=$fr,$fg,$fb"
printf "$base_cfg" > "$cfg_dir/config.ghostty"
cli +reload --config > /dev/null 2>&1
sleep 1

# ---- --color=random is the window's gradient, not a tint --------------------
o=$(cli +new-window --target=rnd --color=random 2>&1); rc=$?
r=""; for _ in $(seq 1 50); do r=$(id_of rnd '*'); [ -n "$r" ] && break; sleep 0.2; done
sleep 1
[ $rc = 0 ] && [ -z "$(leaf rnd '*' background_tint)" ]
hl_check "S14 elevated --color=random lists no terminal tint" $? "rc=$rc tint='$(leaf rnd '*' background_tint)' $o"
read -r rx ry rw rh <<< "$(geom "$r")"
read -r tr tg tb <<< "$(px "$r" $(( rx + rw / 2 )) $(( ry + rh / 2 )))"
read -r dr dg db <<< "$(px "$r" $(( rx - 3 )) $(( ry + rh / 2 )))"
near "$tr" "$tg" "$tb" 32 48 64 && ! near "$dr" "$dg" "$db" 32 48 64
hl_check "S15 its terminal keeps the theme colour and sits on a desk of its own" $? "terminal=$tr,$tg,$tb desk=$dr,$dg,$db"

# ---- glass panes (T3622; pane-style.md "Glass panes") ------------------------
# mix <alpha> <r g b desk>: what a sheet of the terminal's #203040 at <alpha>
# over that desk pixel composites to. dist <r g b> <r g b>: sum of |deltas|.
mix() { awk -v t="$1" -v r="$2" -v g="$3" -v b="$4" 'BEGIN{printf "%d %d %d\n", 32*t+r*(1-t)+0.5, 48*t+g*(1-t)+0.5, 64*t+b*(1-t)+0.5}'; }
dist() { awk -v a="$1" -v b="$2" -v c="$3" -v x="$4" -v y="$5" -v z="$6" 'function d(p,q){return p>q?p-q:q-p} BEGIN{print d(a,x)+d(b,y)+d(c,z)}'; }
# centre_vs_mix <pane-id>: 'dist r g b' - the card's middle against 40% of the
# terminal over the desk just left of the card on the same row.
centre_vs_mix() {
    local x y w h r g b dr dg db
    read -r x y w h <<< "$(geom "$1")"
    read -r r g b <<< "$(px "$1" $(( x + w / 2 )) $(( y + h / 2 )))"
    read -r dr dg db <<< "$(px "$1" $(( x - 3 )) $(( y + h / 2 )))"
    echo "$(dist $r $g $b $(mix 0.40 $dr $dg $db)) $r $g $b desk=$dr,$dg,$db"
}
read -r bx by bw bh <<< "$(geom "$b")"
wash_cfg='unfocused-split-opacity = 0.5\nunfocused-split-fill = #ff0000\n'

# Control: solid cards keep upstream's unfocused wash (a red one here).
printf "${base_cfg}${wash_cfg}" > "$cfg_dir/config.ghostty"
cli +reload --config > /dev/null 2>&1
sleep 1
read -r wr wg wb <<< "$(px "$b" $(( bx + bw / 2 )) $(( by + bh / 2 )))"
[ "${wr:-0}" -ge 90 ]
hl_check "G1 control: elevated WITHOUT glass keeps the unfocused wash (b goes red)" $? "b=$wr,$wg,$wb"

printf "${base_cfg}${wash_cfg}macos-pane-glass = true\n" > "$cfg_dir/config.ghostty"
o=$(cli +reload --config 2>&1); rc=$?
sleep 1
read -r ga gr gg gb gd <<< "$(centre_vs_mix "$a")"
[ $rc = 0 ] && ! near "$gr" "$gg" "$gb" 32 48 64 && [ "${ga:-999}" -le 24 ]
hl_check "G2 glass on a reload: a card's middle is 40% terminal over the desk, not the terminal" $? "rc=$rc dist=$ga centre=$gr,$gg,$gb $gd $o"
read -r cy cr cg cb cd <<< "$(centre_vs_mix "$c")"
read -r by2 br2 bg2 bb2 bd2 <<< "$(centre_vs_mix "$b")"
[ "${cy:-999}" -le 24 ] && [ "${by2:-999}" -le 24 ]
hl_check "G3 the focused pane (c) and an unfocused one (b) are the same glass" $? "c dist=$cy $cr,$cg,$cb $cd | b dist=$by2 $br2,$bg2,$bb2 $bd2"
[ "${br2:-999}" -lt 90 ]
hl_check "G4 no unfocused wash on glass (b is not red under unfocused-split-opacity = 0.5)" $? "b=$br2,$bg2,$bb2"

# A banner card: the pane's sheet thins to 25% under it, and the card draws
# no wash of its own.
read -r ax ay aw ah <<< "$(geom "$a")"
cli +set-banner --target="$a" 'glass banner' > /dev/null 2>&1
sleep 1
read -r nr ng nb <<< "$(px "$a" $(( ax + 10 )) $(( ay + 10 )))"
read -r ndr ndg ndb <<< "$(px "$a" $(( ax - 3 )) $(( ay + 10 )))"
d25=$(dist $nr $ng $nb $(mix 0.25 $ndr $ndg $ndb)); d40=$(dist $nr $ng $nb $(mix 0.40 $ndr $ndg $ndb))
[ "$d25" -le 16 ] && [ "$d25" -lt "$d40" ]
hl_check "G5 under a banner card the sheet is the thinner 25% glass, no wash" $? "banner=$nr,$ng,$nb desk=$ndr,$ndg,$ndb d25=$d25 d40=$d40"
read -r ga2 _ <<< "$(centre_vs_mix "$a")"
[ "${ga2:-999}" -le 24 ]
hl_check "G6 below the banner the pane is still the 40% sheet" $? "dist=$ga2"
cli +set-banner --target="$a" '' > /dev/null 2>&1

# A template viewer page goes see-through: the sheet is its background.
doc="$HL_RUNTIME/glass.md"
printf '# Glass\n\nA line.\n' > "$doc"
cli +split --pane=b --name=gv --direction=down --view="$doc" > /dev/null 2>&1
v=""; for _ in $(seq 1 50); do v=$(id_of ps gv); [ -n "$v" ] && break; sleep 0.2; done
sleep 3
read -r vx vy vw vh <<< "$(geom "${v:-x}")"
read -r vr vg vb <<< "$(px "${v:-x}" $(( ${vx:-0} + ${vw:-0} / 2 )) $(( ${vy:-0} + ${vh:-0} - 12 )))"
read -r vdr vdg vdb <<< "$(px "${v:-x}" $(( ${vx:-0} - 3 )) $(( ${vy:-0} + ${vh:-0} - 12 )))"
vd=$(dist ${vr:-0} ${vg:-0} ${vb:-0} $(mix 0.40 ${vdr:-0} ${vdg:-0} ${vdb:-0}))
[ -n "$v" ] && [ "$vd" -le 24 ]
hl_check "G7 a markdown viewer's page is see-through over the pane's sheet (not white)" $? "v=$v page=$vr,$vg,$vb desk=$vdr,$vdg,$vdb dist=$vd"

# Flat has no glass: with macos-pane-glass still true, the terminal draws its
# own background again.
printf "${base_cfg}macos-pane-glass = true\nmacos-pane-style = flat\n" > "$cfg_dir/config.ghostty"
cli +reload --config > /dev/null 2>&1
sleep 1
read -r ax ay aw ah <<< "$(geom "$a")"
read -r fr fg fb <<< "$(px "$a" $(( ax + aw / 2 )) $(( ay + ah / 2 )))"
near "$fr" "$fg" "$fb" 32 48 64
hl_check "G8 flat with macos-pane-glass = true: the terminal is solid #203040 again" $? "centre=$fr,$fg,$fb"
printf "$base_cfg" > "$cfg_dir/config.ghostty"
cli +reload --config > /dev/null 2>&1

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "S16 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- app log (tail) ----"
    tail -40 "$APP_LOG" 2>/dev/null
fi

hl_finish "$L"
