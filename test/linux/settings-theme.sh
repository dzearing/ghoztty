#!/usr/bin/env bash
# settings-theme.sh - T3636 (Linux L11g4) acceptance for the GTK Settings
# window's Appearance theme picker and live preview - Mac ThemeSection and
# SettingsPreview (win32 SettingsWindow.paintTheme, settings_preview_view):
#
#   K1-K3   the catalog: bundled plus the user's themes folder (a user theme
#           wins a name clash), split light / dark by background luminance;
#           the tab follows the system appearance until one is clicked.
#   G1-G6   the grid: a tab lists ONLY its kind, 11 tiles then "All N <kind>
#           themes...", All expands, a tab click collapses again, the filter
#           folds case, an unmatched filter says so.
#   P1-P4   One theme: a tile click writes `theme = <name>`, the tile is ringed
#           and listed first, and a name not in the catalog is refused.
#   M1-M5   Light & dark: the switch seeds the other slot from the same family
#           (Latte <-> Mocha), the tabs carry the two names, a tile fills the
#           tab's own slot, the other kind is not drawn on a tab, back to One
#           theme keeps the slot the system shows.
#   X1      a hand-edited light:<dark theme> is warned about in Mac's words.
#   V1-V7   the preview: theme colors, the terminal's rgba, the caption, font
#           family and size, the cursor style, the blink only while shown,
#           the elevated backdrop.
#   S1-S4   the pixels (T3769): --op=shot renders the window, and the tiles'
#           backgrounds, the picked ring and the preview terminal (opaque,
#           then blended at 80% over the backdrop) are sampled from it at the
#           rects the state reports.
#   O1-O2   a later file that sets theme makes the whole section read-only.
#   R1      the section survives a close and reopen.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\settings-theme.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), whose private
# XDG_CONFIG_HOME holds every config and theme file written here.
#
# NEGATIVE=1 makes M1 expect the switch to seed "Catppuccin Frappe" (a DARK
# theme) for the light slot: M1 must FAIL. NEGATIVE=2 makes S1 expect the
# BUNDLED Catppuccin Mocha's #1e1e2e where the user's #101820 is drawn: S1
# and S3 must FAIL (the pixel check tells two dark backgrounds apart).
#
# Output: one PASS/FAIL line per check, then 'SETTINGS THEME: ALL PASS' or
# 'SETTINGS THEME: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="SETTINGS THEME"

log=/tmp/settings-theme-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "B1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "B2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"

cfg_dir="$XDG_CONFIG_HOME/ghostty"
dev="$cfg_dir/config-debug.ghostty"
later="$cfg_dir/later.ghostty"
mkdir -p "$cfg_dir/themes"
printf '# mine\nfont-size = 13\nconfig-file = ?later.ghostty\n' > "$dev"
: > "$later"
# A user theme that shadows a bundled one, and one of the user's own.
printf 'background = #101820\nforeground = #eeeeee\npalette = 2=#00ff00\ncursor-color = #ff8800\n' > "$cfg_dir/themes/Catppuccin Mocha"
printf 'background = #fafafa\nforeground = #111111\n' > "$cfg_dir/themes/Zz Test Light"
export GHOZTTY_SETTINGS_BACKUP_DIR="$HL_RUNTIME/settings-backups"

jget() { printf '%s' "$1" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1]); print(json.dumps(v, ensure_ascii=False) if isinstance(v,(dict,list,bool)) or v is None else v)' "$2" 2>/dev/null; }
st() { hl_ipc settings "$@"; }
th() { jget "$1" "d['theme']$2"; }
pv() { jget "$1" "d['preview']$2"; }
theme_line() { grep -E '^theme *=' "$dev" | tail -1 | sed -E 's/^theme *= *//'; }

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
st --op=action > /dev/null
o=$(st --op=state --page=appearance)

# ---- the catalog --------------------------------------------------------
lc=$(th "$o" '["light_count"]'); dc=$(th "$o" '["dark_count"]')
[ "$(jget "$o" 'd["visible_page"]')" = appearance ] && [ "$lc" -gt 10 ] && [ "$dc" -gt 10 ] \
  && [ "$(jget "$o" '[g["drawn"] for g in d["groups"] if g["title"]=="Theme"][0]')" = Theme ] \
  && [ "$(th "$o" '["drawn"] is not None')" = true ] && [ "$(pv "$o" '["drawn"] is not None')" = true ]
hl_check "K1 Appearance draws the Theme section and the preview; the catalog has both kinds ($lc light, $dc dark, read in $(th "$o" '["load_ms"]') ms)" $? "groups=$(jget "$o" '[g["title"] for g in d["groups"] if g["page"]=="appearance"]')"
cat_of() { jget "$o" "[t for t in d['theme']['catalog'] if t['name']=='$1'][0]['$2']"; }
[ "$(cat_of 'Catppuccin Mocha' user)" = true ] && [ "$(cat_of 'Catppuccin Mocha' background)" = '#101820' ] \
  && [ "$(cat_of 'Zz Test Light' user)" = true ] && [ "$(cat_of 'Zz Test Light' light)" = true ] \
  && [ "$(cat_of 'Catppuccin Latte' user)" = false ] && [ "$(cat_of 'Catppuccin Latte' light)" = true ]
hl_check "K2 the user's themes folder is read and wins a clash (its Catppuccin Mocha is #101820); light vs dark by luminance" $? "mocha=$(cat_of 'Catppuccin Mocha' background) zz=$(cat_of 'Zz Test Light' light)"
sysd=$(th "$o" '["system_dark"]'); want_tab=light; [ "$sysd" = true ] && want_tab=dark
[ "$(th "$o" '["tab"]')" = $want_tab ] && [ "$(th "$o" '["drawn"]["tab_active"]')" = $want_tab ] \
  && [ "$(th "$o" '["follows"]')" = false ] && [ "$(th "$o" '["drawn"]["one_active"]')" = true ] \
  && [ "$(th "$o" '["drawn"]["use_caption"]')" = "One theme, whatever the system appearance." ] \
  && [ "$(th "$o" '["drawn"]["tab_caption"]')" = "Filter only — the theme you pick is used all the time." ] \
  && [ "$(jget "$o" '"|".join(d["theme"]["drawn"]["tab_labels"])')" = "☀  Light themes|☾  Dark themes" ]
hl_check "K3 no theme set: One theme, Mac's captions, the tab follows the system (dark=$sysd)" $? "$(th "$o" '["drawn"]')"

# ---- the grid -----------------------------------------------------------
o=$(st --op=theme-tab --value=dark)
names_ok() { [ "$(jget "$1" '[t["name"] for t in d["theme"]["drawn"]["tiles"]] == d["theme"]["tiles"]')" = true ]; }
[ "$(th "$o" '["drawn"]["tab_active"]')" = dark ] && [ "$(jget "$o" 'len(d["theme"]["drawn"]["tiles"])')" = 11 ] \
  && [ "$(jget "$o" 'all(not t["light"] for t in d["theme"]["drawn"]["tiles"])')" = true ] && names_ok "$o" \
  && [ "$(th "$o" '["drawn"]["all"]')" = "All $dc dark themes…" ]
hl_check "G1 the dark tab lists only dark themes: 11 tiles, then 'All $dc dark themes…'" $? "tiles=$(jget "$o" '[t["name"] for t in d["theme"]["drawn"]["tiles"]]') all=$(th "$o" '["drawn"]["all"]')"
o=$(st --op=theme-all)
[ "$(jget "$o" 'len(d["theme"]["drawn"]["tiles"])')" = "$dc" ] && [ "$(th "$o" '["drawn"]["all"]')" = null ] && names_ok "$o"
hl_check "G2 'All…' draws every dark theme ($dc) and goes away" $? "drawn=$(jget "$o" 'len(d["theme"]["drawn"]["tiles"])')"
o=$(st --op=theme-tab --value=light)
[ "$(th "$o" '["show_all"]')" = false ] && [ "$(jget "$o" 'len(d["theme"]["drawn"]["tiles"])')" = 11 ] \
  && [ "$(jget "$o" 'all(t["light"] for t in d["theme"]["drawn"]["tiles"])')" = true ] \
  && [ "$(th "$o" '["drawn"]["all"]')" = "All $lc light themes…" ] && names_ok "$o"
hl_check "G3 a tab click collapses again; the light tab lists only light themes" $? "all=$(th "$o" '["drawn"]["all"]')"
st --op=theme-tab --value=dark > /dev/null
o=$(st --op=theme-filter --value=MOCHA)
[ "$(jget "$o" '[t["name"] for t in d["theme"]["drawn"]["tiles"]]')" = '["Catppuccin Mocha"]' ] \
  && [ "$(th "$o" '["drawn"]["filter"]')" = MOCHA ] && [ "$(th "$o" '["drawn"]["all"]')" = null ]
hl_check "G4 the filter folds case: MOCHA on the dark tab draws Catppuccin Mocha alone" $? "$(jget "$o" '[t["name"] for t in d["theme"]["drawn"]["tiles"]]')"
o=$(st --op=theme-filter --value=zzqq)
[ "$(jget "$o" 'len(d["theme"]["drawn"]["tiles"])')" = 0 ] && [ "$(th "$o" '["drawn"]["empty"]')" = "No dark themes match “zzqq”." ]
hl_check "G5 an unmatched filter says so in Mac's words" $? "empty=$(th "$o" '["drawn"]["empty"]')"
o=$(st --op=theme-filter --value=)
[ "$(jget "$o" 'len(d["theme"]["drawn"]["tiles"])')" = 11 ] && [ "$(th "$o" '["drawn"]["empty"]')" = null ]
hl_check "G6 clearing the filter brings the collapsed grid back" $? "n=$(jget "$o" 'len(d["theme"]["drawn"]["tiles"])')"

# ---- One theme: pick a tile ---------------------------------------------
st --op=theme-filter --value=catppuccin > /dev/null
o=$(st --op=theme-tile '--value=Catppuccin Mocha')
[ "$(jget "$o" 'd["ok"]')" = true ] && [ "$(theme_line)" = "Catppuccin Mocha" ] \
  && [ "$(th "$o" '["follows"]')" = false ] && [ "$(th "$o" '["light"]')" = "Catppuccin Mocha" ]
hl_check "P1 a tile click writes 'theme = Catppuccin Mocha' to the user's file" $? "file theme=$(theme_line)"
[ "$(jget "$o" '[t["name"] for t in d["theme"]["drawn"]["tiles"] if t["picked"]]')" = '["Catppuccin Mocha"]' ] \
  && [ "$(th "$o" '["drawn"]["tiles"][0]["name"]')" = "Catppuccin Mocha" ]
hl_check "P2 the picked tile is ringed and listed first" $? "$(jget "$o" '[(t["name"],t["picked"]) for t in d["theme"]["drawn"]["tiles"]]')"
o=$(st --op=theme-filter --value=)
[ "$(th "$o" '["tiles"][0]')" = "Catppuccin Mocha" ] && [ "$(th "$o" '["drawn"]["tiles"][0]["picked"]')" = true ]
hl_check "P3 unfiltered, the pick still comes first among the 11" $? "first=$(th "$o" '["tiles"][0]')"
before=$(cat "$dev")
o=$(st --op=theme-pick --key=dark '--value=No Such Theme')
[ "$(jget "$o" 'd["ok"]')" = false ] && [ "$(cat "$dev")" = "$before" ]
hl_check "P4 only a catalog theme is taken: a made-up name writes nothing" $? "ok=$(jget "$o" 'd["ok"]')"

# ---- Light & dark -------------------------------------------------------
want_light="Catppuccin Latte"; [ "${NEGATIVE:-}" = 1 ] && want_light="Catppuccin Frappe"
o=$(st --op=theme-mode --value=true)
[ "$(theme_line)" = "light:$want_light,dark:Catppuccin Mocha" ] && [ "$(th "$o" '["follows"]')" = true ] \
  && [ "$(th "$o" '["drawn"]["follow_active"]')" = true ]
hl_check "M1 Light & dark seeds the light slot from the same family: theme = light:$want_light,dark:Catppuccin Mocha" $? "file theme=$(theme_line)"
[ "$(jget "$o" '"|".join(d["theme"]["drawn"]["tab_labels"])')" = "☀  Catppuccin Latte|☾  Catppuccin Mocha" ] \
  && [ "$(th "$o" '["drawn"]["tab_caption"]')" = "Showing dark themes — your pick is used in dark mode." ] \
  && [ "$(th "$o" '["drawn"]["use_caption"]')" = "Switches between a light and a dark theme with the system appearance." ]
hl_check "M2 the tabs carry the two picked names; Mac's captions for light & dark" $? "$(th "$o" '["drawn"]["tab_labels"]') / $(th "$o" '["drawn"]["tab_caption"]')"
st --op=theme-tab --value=light > /dev/null
st --op=theme-filter --value=zz > /dev/null
o=$(st --op=theme-tile '--value=Zz Test Light')
[ "$(theme_line)" = "light:Zz Test Light,dark:Catppuccin Mocha" ] \
  && [ "$(jget "$o" '[t["name"] for t in d["theme"]["drawn"]["tiles"] if t["picked"]]')" = '["Zz Test Light"]' ] \
  && [ "$(th "$o" '["drawn"]["tab_caption"]')" = "Showing light themes — your pick is used in light mode." ]
hl_check "M3 on the light tab a tile fills the light slot and keeps the dark one" $? "file theme=$(theme_line)"
o=$(st --op=theme-filter --value=)
r=$(st --op=theme-tile '--value=Catppuccin Mocha')
[ "$(jget "$o" 'all(t["light"] for t in d["theme"]["drawn"]["tiles"])')" = true ] \
  && printf '%s' "$r" | grep -q 'does not draw' && [ "$(theme_line)" = "light:Zz Test Light,dark:Catppuccin Mocha" ]
hl_check "M4 the light tab draws no dark theme, so the slots cannot be mixed" $? "reply=$r"
want_one="Zz Test Light"; [ "$sysd" = true ] && want_one="Catppuccin Mocha"
o=$(st --op=theme-mode --value=false)
[ "$(theme_line)" = "$want_one" ] && [ "$(th "$o" '["drawn"]["one_active"]')" = true ]
hl_check "M5 back to One theme keeps the slot the system shows ($want_one)" $? "file theme=$(theme_line)"

# ---- a hand-edited mismatch ---------------------------------------------
sed -i -E 's/^theme *=.*/theme = light:Catppuccin Mocha,dark:Catppuccin Mocha/' "$dev"
st --op=set --key=font-size --value=13.5 > /dev/null   # any write re-reads the file
o=$(st --op=state)
[ "$(th "$o" '["mismatch"]')" = light ] \
  && [ "$(jget "$o" '"⚠ Catppuccin Mocha is a dark theme but is set for light mode. Pick a light theme to fix it." in d["theme"]["drawn"]["notices"]')" = true ]
hl_check "X1 light:<a dark theme> is warned about in Mac's words" $? "notices=$(th "$o" '["drawn"]["notices"]')"

# ---- the preview --------------------------------------------------------
st --op=theme-mode --value=false > /dev/null
st --op=theme-pick --key=dark '--value=Catppuccin Mocha' > /dev/null
o=$(st --op=state)
[ "$(pv "$o" '["theme"]')" = "Catppuccin Mocha" ] && [ "$(pv "$o" '["background"]')" = '#101820' ] \
  && [ "$(pv "$o" '["cursor_color"]')" = '#ff8800' ] \
  && printf '%s' "$(pv "$o" '["drawn"]["lines"][0]')" | grep -q 'foreground="#00ff00"'
hl_check "V1 the preview draws in the picked theme: its background, cursor and ANSI green (#00ff00 from the user's file)" $? "bg=$(pv "$o" '["background"]') line0=$(pv "$o" '["drawn"]["lines"][0]')"
st --op=set --key=background-opacity --value=0.8 > /dev/null
st --op=set --key=font-size --value=15 > /dev/null
o=$(st --op=choose --key=font-family '--value=DejaVu Sans Mono')
fam=$(pv "$o" '["family"]')
cap="DejaVu Sans Mono 15pt · Catppuccin Mocha · 80% opaque"
[ "$(pv "$o" '["drawn"]["term_rule"]')" = ".gz-preview-term { background-color: rgba(16,24,32,0.80); }" ] \
  && [ "$(pv "$o" '["caption"]')" = "$cap" ] && [ "$(pv "$o" '["drawn"]["caption"]')" = "$cap" ]
hl_check "V2 the terminal is the theme's background at the configured opacity, and the corner caption says so" $? "rule=$(pv "$o" '["drawn"]["term_rule"]') caption=$(pv "$o" '["drawn"]["caption"]')"
[ "$fam" = "DejaVu Sans Mono" ] && printf '%s' "$(pv "$o" '["drawn"]["lines"][2]')" | grep -q 'font_family="DejaVu Sans Mono" size="13824"'
hl_check "V3 the lines are in the configured family at Mac's 0.9 x size (15pt -> 13.5pt)" $? "line2=$(pv "$o" '["drawn"]["lines"][2]')"
# ---- the pixels (T3769): --op=shot, sampled at the rects the state names --
# shot: the window's own render to a fresh PNG, its path printed.
# The tiles are laid out on the next frame after a grid change, so shot first
# waits (3 s at most) for the first tile to have a real size, and the rects
# used are the ones the shot's OWN reply reports (saved beside it as .json).
shots=0
shot() {
    shots=$((shots + 1))
    local f="$HL_RUNTIME/settings-theme-$shots.png" i r
    rm -f "$f"
    for i in $(seq 30); do
        r=$(st --op=state)
        [ "$(rq "$r" 'len(T) == 0 or T[0]["rect"][2] > 20')" = True ] && break
        sleep 0.1
    done
    st --op=shot --path="$f" > "$f.json"
    [ -s "$f" ] && echo "$f"
}
# rq <reply> <python expr>: T the drawn tiles, C the preview's drawn card,
# k the scale, and pt(x, y) a logical point as 'x y' shot pixels.
rq() {
    printf '%s' "$1" | python3 -I -c '
import json, sys
d = json.load(sys.stdin); t = d["theme"]["drawn"]; T = t["tiles"]; C = d["preview"]["drawn"]; k = t["scale"] or 1
def pt(x, y): return "%d %d" % (round(x * k), round(y * k))
def tile_bg(i): r, n = T[i]["rect"], T[i]["name_rect"]; return pt(r[0] + 4, (r[1] + n[1]) / 2)
def tile_ring(i): r, n = T[i]["rect"], T[i]["name_rect"]; return pt(r[0] + 1, (r[1] + n[1]) / 2)
def term_px(): r = C["term_rect"]; return pt(r[0] + 3, r[1] + r[3] / 2)
def desk_px(): r = C["term_rect"]; return pt(r[0] - 3, r[1] + r[3] / 2)
print(eval(sys.argv[1]))' "$2" 2>/dev/null
}
# near <"r g b"> <#rrggbb> <tol>: every channel within tol.
near() { [ -n "$1" ] && [ "$1" != off ] && python3 -I -c '
import sys
p = [int(v) for v in sys.argv[1].split()]; h = sys.argv[2].lstrip("#"); t = int(sys.argv[3])
sys.exit(0 if all(abs(a - int(h[i:i + 2], 16)) <= t for a, i in zip(p, (0, 2, 4))) else 1)' "$1" "$2" "$3"; }
# blend <#fg> <alpha> <"r g b" under>: the #rrggbb the compositor should show.
blend() { python3 -I -c '
import sys
h = sys.argv[1].lstrip("#"); a = float(sys.argv[2]); u = [int(v) for v in sys.argv[3].split()]
print("#" + "".join("%02x" % round(a * int(h[i:i + 2], 16) + (1 - a) * b) for i, b in zip((0, 2, 4), u)))' "$1" "$2" "$3"; }
# accent <r g b>: libadwaita's default @accent_color - #3584e4 in a light
# scheme, #78aeed in a dark one - within 30 a channel.
accent() { [ -n "$1" ] && [ "$1" != off ] && { near "$1" '#3584e4' 30 || near "$1" '#78aeed' 30; }; }

st --op=theme-tab --value=dark > /dev/null
st --op=theme-filter --value=catppuccin > /dev/null
st --op=set --key=macos-pane-style --value=elevated > /dev/null
st --op=set --key=background-opacity --value=1 > /dev/null
f=$(shot); o=$(cat "$f.json" 2>/dev/null)
t0=$(rq "$o" 'T[0]["name"]'); t1=$(rq "$o" 'T[1]["name"]'); t1bg=$(rq "$o" 'T[1]["background"]')
want_mocha='#101820'; [ "${NEGATIVE:-}" = 2 ] && want_mocha='#1e1e2e'   # the BUNDLED Mocha: S1 must FAIL
px0=$(hl_png_pixel "$f" $(rq "$o" 'tile_bg(0)')); px1=$(hl_png_pixel "$f" $(rq "$o" 'tile_bg(1)'))
[ -n "$f" ] && [ "$t0" = "Catppuccin Mocha" ] && near "$px0" "$want_mocha" 4 && near "$px1" "$t1bg" 4
hl_check "S1 --op=shot draws each tile in its own theme's background: Catppuccin Mocha is the user's $want_mocha, $t1 its $t1bg" $? "shot=$f px0=$px0 px1=$px1 rect0=$(rq "$o" 'T[0]["rect"]') stats=$([ -n "$f" ] && hl_png_stats "$f")"
ring0=$(hl_png_pixel "$f" $(rq "$o" 'tile_ring(0)')); ring1=$(hl_png_pixel "$f" $(rq "$o" 'tile_ring(1)'))
[ "$(rq "$o" 'T[0]["picked"]')" = True ] && accent "$ring0" && ! accent "$ring1"
hl_check "S2 the picked tile's ring is drawn in the accent color; the unpicked one beside it has none" $? "ring0=$ring0 ring1=$ring1"
tp=$(hl_png_pixel "$f" $(rq "$o" 'term_px()'))
[ "$(pv "$o" '["opacity"] == 1')" = true ] && near "$tp" "$want_mocha" 4
hl_check "S3 fully opaque, the preview terminal is drawn in the theme's background ($want_mocha)" $? "term=$tp rect=$(rq "$o" 'C["term_rect"]')"
st --op=set --key=background-opacity --value=0.8 > /dev/null
f=$(shot); o=$(cat "$f.json" 2>/dev/null)
tp=$(hl_png_pixel "$f" $(rq "$o" 'term_px()')); dp=$(hl_png_pixel "$f" $(rq "$o" 'desk_px()'))
want=$(blend '#101820' 0.8 "$dp")
near "$tp" "$want" 6 && ! near "$tp" '#101820' 4
hl_check "S4 at 80% the terminal is the theme's background blended over the backdrop beside it ($want), not the opaque color" $? "term=$tp desk=$dp want=$want"

st --op=set --key=cursor-style-blink --value=false > /dev/null
o=$(st --op=set --key=cursor-style --value=bar)
[ "$(pv "$o" '["cursor_style"]')" = bar ] && printf '%s' "$(pv "$o" '["drawn"]["lines"][3]')" | grep -q 'foreground="#ff8800" alpha="100%">▏</span>' \
  && [ "$(pv "$o" '["drawn"]["blinking"]')" = false ]
hl_check "V4 a bar cursor in the theme's cursor color; blink off holds it steady" $? "line3=$(pv "$o" '["drawn"]["lines"][3]') blinking=$(pv "$o" '["drawn"]["blinking"]')"
o=$(st --op=reset --key=cursor-style-blink)
[ "$(pv "$o" '["blink"]')" = true ] && [ "$(pv "$o" '["drawn"]["blinking"]')" = true ] && [ "$(pv "$o" '["drawn"]["mapped"]')" = true ]
hl_check "V5 the cursor blinks (Mac's default) while the card is on screen" $? "blink=$(pv "$o" '["blink"]') blinking=$(pv "$o" '["drawn"]["blinking"]')"
st --op=state --page=terminal > /dev/null
sleep 1.5
o=$(st --op=state)
off_page=$(pv "$o" '["drawn"]["blinking"]'); off_mapped=$(pv "$o" '["drawn"]["mapped"]')
o=$(st --op=state --page=appearance)
[ "$off_page" = false ] && [ "$off_mapped" = false ] && [ "$(pv "$o" '["drawn"]["blinking"]')" = true ]
hl_check "V6 on another page the blink stops; it starts again when Appearance is shown" $? "away blinking=$off_page mapped=$off_mapped back=$(pv "$o" '["drawn"]["blinking"]')"
o=$(st --op=set --key=macos-pane-style --value=flat)
flat_el=$(pv "$o" '["drawn"]["elevated"]'); flat_m=$(pv "$o" '["drawn"]["text_margin"]')
o=$(st --op=set --key=macos-pane-style --value=elevated)
[ "$flat_el" = false ] && [ "$(pv "$o" '["elevated"]')" = true ] && [ "$(pv "$o" '["drawn"]["elevated"]')" = true ] && [ -n "$flat_m" ]
hl_check "V7 the elevated pane style draws the gradient backdrop; flat does not" $? "flat=$flat_el elevated=$(pv "$o" '["drawn"]["elevated"]')"

# ---- a later file owns theme --------------------------------------------
before=$(theme_line)
printf 'theme = Dracula\n' > "$later"
st --op=set --key=font-size --value=14 > /dev/null
o=$(st --op=state)
[ "$(th "$o" '["editable"]')" = false ] && [ "$(th "$o" '["drawn"]["mode_sensitive"]')" = false ] \
  && [ "$(jget "$o" 'all(not t["sensitive"] for t in d["theme"]["drawn"]["tiles"])')" = true ] \
  && [ "$(jget "$o" '"Set in a file that loads after your config - edit it there." in d["theme"]["drawn"]["notices"]')" = true ]
hl_check "O1 a later file that sets theme dims the switch and every tile, and says where to edit it" $? "notices=$(th "$o" '["drawn"]["notices"]')"
r=$(st --op=theme-mode --value=true); r2=$(st --op=theme-pick --key=light '--value=Catppuccin Latte')
printf '%s' "$r" | grep -q 'not editable' && [ "$(jget "$r2" 'd["ok"]')" = false ] && [ "$(theme_line)" = "$before" ]
hl_check "O2 ...and nothing writes theme to the user's file" $? "mode=$r pick_ok=$(jget "$r2" 'd["ok"]') file=$(theme_line)"
: > "$later"

# ---- close and reopen ---------------------------------------------------
st --op=close > /dev/null
st --op=action > /dev/null
o=$(st --op=state --page=appearance)
[ "$(th "$o" '["drawn"] is not None')" = true ] && [ "$(th "$o" '["light_count"]')" = "$lc" ] \
  && [ -n "$(pv "$o" '["drawn"]["term_rule"]')" ] && kill -0 "$APP" 2>/dev/null
hl_check "R1 closed and reopened, the section and the preview are drawn again and the app is up" $? "drawn=$(th "$o" '["drawn"] is not None') rule=$(pv "$o" '["drawn"]["term_rule"]')"

hl_finish "$L"
