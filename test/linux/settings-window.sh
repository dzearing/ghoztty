#!/usr/bin/env bash
# settings-window.sh - L11g (T3569) acceptance for the Settings window on the
# GTK debug app: `open_config` opens a window (not the file) that edits the
# config with ONE surgical edit per change, the Mac rules of
# docs/reference/settings.md, through win32's shared model. Driven by the
# debug-only `settings` seam (IpcHandlers.settingsSeam), whose ops call what
# the window's own signal handlers call. P1-P23 (T3631) cover the curated
# pages: each op moves the row's real libadwaita widget and reads it back.
# L1-L10 (T3632) cover list keys: chips and an "add a value" field, curated
# and under All Settings.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\settings-window.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), whose private
# XDG_CONFIG_HOME holds every config file written here - never the user's.
#
# Output: one PASS/FAIL line per check, then 'SETTINGS WINDOW: ALL PASS' or
# 'SETTINGS WINDOW: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="SETTINGS WINDOW"

log=/tmp/settings-window-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "W1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "W2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"

cfg_dir="$XDG_CONFIG_HOME/ghostty"
shared="$cfg_dir/config.ghostty"      # the installed release's file
dev="$cfg_dir/config-debug.ghostty"   # the debug build's own file
later="$cfg_dir/later.ghostty"        # an include, which loads after both
mkdir -p "$cfg_dir"
printf '# the release config - Settings in a debug build must never write here\nbackground-opacity = 1\n' > "$shared"
printf '# my settings\nfont-size = 12\n\n# colours\nbackground = #203040\nwindow-padding-color = background\nunfocused-split-opacity = 1\nconfig-file = ?later.ghostty\n# end\n' > "$dev"
printf 'cursor-style = underline\n' > "$later"
shared_before=$(cat "$shared")
export GHOZTTY_SETTINGS_BACKUP_DIR="$HL_RUNTIME/settings-backups"

# jget <json> <python expr over d>: one field of a seam reply.
jget() { printf '%s' "$1" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); v=eval(sys.argv[1]); print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$2" 2>/dev/null; }
st() { hl_ipc settings "$@"; }

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "W3 the app serves its socket" $?
pane=""; for _ in $(seq 1 50); do pane=$(hl_first_pane "$app"); [ -n "$pane" ] && break; sleep 0.2; done

o=$(st --op=state)
[ "$(jget "$o" 'd["open"]')" = false ]
hl_check "W4 no Settings window before open_config" $? "$o"

# ---- open_config opens the window, on the debug build's own file -----------
o=$(st --op=action)
o2=$(st --op=state)
[ "$(jget "$o2" 'd["open"]')" = true ]
hl_check "W5 open_config opens the Settings window (not the file)" $? "$o2"
[ "$(jget "$o2" 'd["file"]')" = "$dev" ]
hl_check "W6 it edits the debug build's config-debug.ghostty, not the release's config.ghostty" $? "file=$(jget "$o2" 'd["file"]')"
m=$(jget "$o2" 'd["matched"]')
[ -n "$m" ] && [ "$m" -gt 100 ]
hl_check "W7 All Settings lists the generated catalog (>100 keys, no hand-kept list)" $? "matched=$m"

# ---- one surgical edit: only that key's line changes ----------------------
o=$(st --op=set --key=font-size --value=15)
expect=$(printf '# my settings\nfont-size = 15\n\n# colours\nbackground = #203040\nwindow-padding-color = background\nunfocused-split-opacity = 1\nconfig-file = ?later.ghostty\n# end')
[ "$(jget "$o" 'd["ok"]')" = true ] && [ "$(cat "$dev")" = "$expect" ]
hl_check "W8 set font-size=15 rewrites only that line; comments, blanks and the include stay" $? "$(jget "$o" 'd.get("ok")') file=$(tr '\n' '|' < "$dev")"
o=$(st --op=state --key=font-size)
[ "$(jget "$o" 'd["key"]["value"]')" = 15 ] && [ "$(jget "$o" 'd["key"]["set_in_file"]')" = true ]
hl_check "W9 the row reads the new value straight from the file" $? "$(jget "$o" 'd["key"]')"

# ---- an invalid value is never written ------------------------------------
before=$(cat "$dev")
o=$(st --op=set --key=font-size --value=not-a-number)
p=$(jget "$o" 'd["key"]["problem"]' 2>/dev/null); [ -z "$p" ] && p=$(jget "$(st --op=state --key=font-size)" 'd["key"]["problem"]')
[ "$(jget "$o" 'd["ok"]')" = false ] && [ "$(cat "$dev")" = "$before" ] && [ -n "$p" ] && [ "$p" != null ]
hl_check "W10 an invalid value is refused, the file untouched, the row says why" $? "ok=$(jget "$o" 'd.get("ok")') problem=$p"

# ---- a new key is one added line; a change applies live --------------------
shot="$HL_RUNTIME/pane.png"
fill_of() {
    hl_screenshot "$pane" "$shot" > /dev/null || { echo 0; return; }
    hl_png_stats "$shot" "$1" "$2" "$3" | sed -n 's/.*match=\([0-9.]*\).*/\1/p'
}
mostly() { awk -v m="$(fill_of "$@")" 'BEGIN{exit !(m > 0.5)}'; }
hl_wait_for 15 mostly 32 48 64
hl_check "W11 the pane starts in the file's background (#203040)" $? "fill=$(fill_of 32 48 64)"
o=$(st --op=set --key=background --value='#a05010')
hl_wait_for 10 mostly 160 80 16
hl_check "W12 setting background in Settings applies live to the open pane" $? "ok=$(jget "$o" 'd.get("ok")') fill=$(fill_of 160 80 16)"
n_before=$(wc -l < "$dev")
o=$(st --op=set --key=window-padding-x --value=4)
[ "$(jget "$o" 'd["ok"]')" = true ] && [ "$(grep -c '^window-padding-x = 4$' "$dev")" = 1 ] && [ "$(wc -l < "$dev")" = $((n_before + 1)) ]
hl_check "W13 a key the file did not set is one added line" $? "lines $n_before -> $(wc -l < "$dev")"

# ---- Reset removes the key's lines and nothing else -----------------------
o=$(st --op=reset --key=font-size)
[ "$(jget "$o" 'd["ok"]')" = true ] && ! grep -q '^font-size' "$dev" && grep -q '^# my settings$' "$dev" && grep -q '^# end$' "$dev"
hl_check "W14 Reset removes font-size and leaves the comments" $? "file=$(tr '\n' '|' < "$dev")"

# ---- a key a later file sets is read-only here ----------------------------
before=$(cat "$dev")
o=$(st --op=set --key=cursor-style --value=block)
ov=$(jget "$(st --op=state --key=cursor-style)" 'd["key"]["override"]')
printf '%s' "$o" | grep -q 'loads later' && [ "$(cat "$dev")" = "$before" ] && printf '%s' "$ov" | grep -q 'later.ghostty'
hl_check "W15 a key later.ghostty overrides is refused and the row names that file" $? "reply=$o override=$ov"

# ---- search -----------------------------------------------------------------
o=$(st --op=search --value=font-size)
m=$(jget "$o" 'd["matched"]')
[ -n "$m" ] && [ "$m" -ge 1 ] && [ "$m" -lt 20 ]
hl_check "W16 searching narrows All Settings" $? "matched=$m"
hl_wait_for 5 sh -c "[ \"\$(printf '%s' \"\$(hl_ipc settings --op=state 2>/dev/null)\" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(d[\"rows\"]==d[\"matched\"])')\" = True ]" 2>/dev/null
r=$?
o=$(st --op=state)
[ $r = 0 ] || [ "$(jget "$o" 'd["rows"]')" = "$(jget "$o" 'd["matched"]')" ]
hl_check "W17 the list shows exactly the matched rows" $? "rows=$(jget "$o" 'd["rows"]') matched=$(jget "$o" 'd["matched"]')"

# ---- the release's file and the backups -----------------------------------
[ "$(cat "$shared")" = "$shared_before" ]
hl_check "W18 the release config.ghostty was never written" $?
nb=$(ls "$GHOZTTY_SETTINGS_BACKUP_DIR" 2>/dev/null | grep -c '^config-debug.ghostty\.')
grep -q '^font-size = 12$' "$GHOZTTY_SETTINGS_BACKUP_DIR"/config-debug.ghostty.* 2>/dev/null
r=$?
[ "$nb" = 1 ] && [ $r = 0 ]
hl_check "W19 one backup of the file as it was before the first change" $? "backups=$nb"

# ---- the curated pages (T3631) ----------------------------------------------
# Every op below moves the row's real widget (a switch, a combo row, a spin
# row, a scale, a flag switch, a field) and the widget's own signal writes;
# the reply reads the widget back ("display") beside the model's answer
# ("expected").
st --op=search --value= > /dev/null
cur() { jget "$(st --op=state --key="$1")" "d['key']['curated']['$2']"; }
line_of() { grep "^$1 = " "$dev" | tail -1 | sed "s/^$1 = //"; }

o=$(st --op=state)
pg=$(jget "$o" '",".join(p["id"] for p in d["pages"])')
[ "$pg" = "appearance,panes,terminal,keyboard,session,updates,advanced" ]
hl_check "P1 the sidebar lists the curated pages in Mac's order, then Advanced (no empty Remote page)" $? "pages=$pg"
n=$(jget "$o" 'd["curated"]')
[ -n "$n" ] && [ "$n" -gt 40 ]
hl_check "P2 the pages carry the shared catalog's rows (>40 curated rows)" $? "curated=$n"
o=$(st --op=state --page=terminal)
[ "$(jget "$o" 'd["page"]')" = terminal ] && [ "$(jget "$o" 'd["visible_page"]')" = terminal ]
hl_check "P3 a sidebar pick shows that page" $? "page=$(jget "$o" 'd["page"]') visible=$(jget "$o" 'd["visible_page"]')"
dr=$(jget "$o" '[g["drawn"] for g in d["groups"] if g["title"]=="Copy & paste"][0]')
[ "$dr" = "Copy & paste" ]
hl_check "P4 a section title with & draws as Mac's words (markup escaped once)" $? "drawn=$dr"

# A switch.
o=$(st --op=toggle --key=font-thicken)
[ "$(line_of font-thicken)" = true ] && [ "$(cur font-thicken display)" = On ] && [ "$(cur font-thicken dot)" = true ] && [ "$(cur font-thicken reset)" = true ]
hl_check "P5 flipping a switch writes key = true; the switch, dot and reset follow" $? "line=$(line_of font-thicken) display=$(cur font-thicken display) dot=$(cur font-thicken dot)"
st --op=curated-reset --key=font-thicken > /dev/null
! grep -q '^font-thicken' "$dev" && [ "$(cur font-thicken display)" = Off ] && [ "$(cur font-thicken dot)" = false ] && [ "$(cur font-thicken reset)" = false ]
hl_check "P6 the row's reset removes the line; the switch goes back and the dot clears" $? "file=$(grep -c '^font-thicken' "$dev") display=$(cur font-thicken display) dot=$(cur font-thicken dot)"

# A popup, with every schema value listed.
o=$(st --op=choose --key=right-click-action --value=ignore)
[ "$(line_of right-click-action)" = ignore ] && [ "$(cur right-click-action display)" = Nothing ] && [ "$(cur right-click-action expected)" = Nothing ]
hl_check "P7 a popup pick writes the value; the row shows its curated label" $? "line=$(line_of right-click-action) display=$(cur right-click-action display)"
lbl=$(jget "$(st --op=state --key=copy-on-select)" '[c["label"] for c in d["key"]["curated"]["choices"] if c["value"]=="true"][0]')
[ "$lbl" = "To the selection clipboard" ]
hl_check "P8 Linux words: copy-on-select = true reads 'To the selection clipboard'" $? "label=$lbl"
st --op=choose --key=cursor-style-blink --value=false > /dev/null
a=$(line_of cursor-style-blink)
st --op=choose --key=cursor-style-blink --value= > /dev/null
! grep -q '^cursor-style-blink' "$dev" && [ "$a" = false ] && [ "$(cur cursor-style-blink display)" = "App decides" ]
hl_check "P9 an optional popup's unset item removes the key" $? "after-false=$a display=$(cur cursor-style-blink display)"

# A key a later file owns is dimmed with the file named.
sub=$(cur cursor-style subtitle)
[ "$(cur cursor-style sensitive)" = false ] && printf '%s' "$sub" | grep -q later.ghostty
hl_check "P10 a curated key later.ghostty overrides is dimmed and says so" $? "sensitive=$(cur cursor-style sensitive) subtitle=$sub"

# Number fields: a stepper and a size in MB.
b=$(cur macos-pane-min-width expected)
st --op=step --key=macos-pane-min-width --value=up > /dev/null
[ "$(line_of macos-pane-min-width)" = $((b + 5)) ] && [ "$(cur macos-pane-min-width display)" = $((b + 5)) ]
hl_check "P11 one spin-row arrow writes the next step" $? "before=$b line=$(line_of macos-pane-min-width) display=$(cur macos-pane-min-width display)"
mb=$(cur scrollback-limit display)
st --op=step --key=scrollback-limit --value=up > /dev/null
[ "$(line_of scrollback-limit)" = $(( (mb + 1) * 1000000 )) ] && [ "$(cur scrollback-limit display)" = $((mb + 1)) ]
hl_check "P12 the scrollback size is edited in MB and written in bytes" $? "mb=$mb line=$(line_of scrollback-limit)"

# A slider (Dim unfocused panes keeps the opacity a pane KEEPS).
st --op=slide --key=unfocused-split-opacity --value=0.6 > /dev/null
[ "$(line_of unfocused-split-opacity)" = 0.6 ] && [ "$(cur unfocused-split-opacity display)" = "40%" ]
hl_check "P13 a slider writes its snapped value once it settles; it reads 40% dimmed" $? "line=$(line_of unfocused-split-opacity) display=$(cur unfocused-split-opacity display)"

# A row's condition.
st --op=choose --key=macos-pane-style --value=flat > /dev/null
g1=$(cur macos-pane-glass sensitive); s1=$(cur macos-pane-glass subtitle); d1=$(cur split-divider-color sensitive)
st --op=choose --key=macos-pane-style --value=elevated > /dev/null
g2=$(cur macos-pane-glass sensitive)
[ "$g1" = false ] && [ "$s1" = "Elevated style only" ] && [ "$d1" = true ] && [ "$g2" = true ]
hl_check "P14 Glass panes dims off the Elevated style and says why" $? "flat: glass=$g1 '$s1' divider=$d1; elevated: glass=$g2"

# Packed flags: every schema flag written explicitly.
st --op=flag --key=shell-integration-features --value=sudo:true > /dev/null
fl=$(line_of shell-integration-features)
printf '%s' "$fl" | tr ',' '\n' | grep -qx sudo && printf '%s' "$fl" | grep -q 'no-' && [ "$(cur shell-integration-features display)" = "$fl" ]
hl_check "P15 a flag's switch writes every flag explicitly; the switches match the line" $? "line=$fl display=$(cur shell-integration-features display)"

# The shell picker only accepts an executable that exists.
before=$(cat "$dev")
o=$(st --op=choose --key=command --value=/bin/nope-shell)
sub=$(cur command subtitle)
[ "$(jget "$o" 'd["ok"]')" = false ] && [ "$(cat "$dev")" = "$before" ] && printf '%s' "$sub" | grep -q "isn't an executable file" && [ "$(cur command other_visible)" = true ]
hl_check "P16 a shell that does not exist is refused, the file untouched, the row says why" $? "ok=$(jget "$o" 'd.get("ok")') subtitle=$sub"
st --op=choose --key=command --value='sh -c true' > /dev/null
[ "$(line_of command)" = 'sh -c true' ] && [ "$(cur command display)" = 'sh -c true' ]
hl_check "P17 Other... takes a shell found on PATH" $? "line=$(line_of command) display=$(cur command display)"
st --op=choose --key=command --value= > /dev/null
! grep -q '^command' "$dev" && [ "$(cur command display)" = "Your login shell" ]
hl_check "P18 the default item removes command and reads 'Your login shell'" $? "display=$(cur command display)"

# A text row is validated like All Settings.
st --op=text --key=notify-on-command-finish-after --value=10s > /dev/null
ok1=$(line_of notify-on-command-finish-after)
before=$(cat "$dev")
st --op=text --key=notify-on-command-finish-after --value=not-a-duration > /dev/null
sub=$(cur notify-on-command-finish-after subtitle)
p=$(jget "$(st --op=state --key=notify-on-command-finish-after)" 'd["key"]["problem"]')
[ "$ok1" = 10s ] && [ "$(cat "$dev")" = "$before" ] && [ -n "$p" ] && [ "$p" != null ] && [ "$sub" = "$p" ]
hl_check "P19 a curated text row writes a valid value and refuses a bad one in its subtitle" $? "first=$ok1 problem=$p subtitle=$sub"

# The sidebar counts, the filter and the link to a page.
o=$(st --op=state)
tc=$(jget "$o" '[p for p in d["pages"] if p["id"]=="terminal"][0]')
[ "$(jget "$o" '[p["count"] for p in d["pages"] if p["id"]=="terminal"][0]')" -ge 3 ] && [ "$(jget "$o" 'all((str(p["count"]) if p["count"] else "") == p["drawn"] for p in d["pages"])')" = true ]
hl_check "P20 each sidebar count is the page's keys the file sets, as drawn" $? "terminal=$tc"
m1=$(jget "$(st --op=search --value=right-click-action --filter=uncovered)" 'd["matched"]')
m2=$(jget "$(st --op=state --filter=all)" 'd["matched"]')
[ "$m1" = 0 ] && [ "$m2" = 1 ]
hl_check "P21 'Not on other pages' hides a curated key that All shows" $? "uncovered=$m1 all=$m2"
st --op=search --value= --filter=all > /dev/null
o=$(st --op=reveal --key=scrollbar)
[ "$(jget "$o" 'd["visible_page"]')" = terminal ]
hl_check "P22 All Settings' page link opens the key's page" $? "visible=$(jget "$o" 'd["visible_page"]')"
o=$(st --op=state --key=auto-update)
[ "$(jget "$o" 'd["key"]["curated"]')" = null ] && [ "$(jget "$(st --op=state --page=keyboard)" 'd["visible_page"]')" = keyboard ]
hl_check "P23 Updates offers no auto-update on Linux; the Keyboard page is there" $? "auto-update curated=$(jget "$o" 'd["key"]["curated"]')"

# ---- list keys (T3632): chips and an "add a value" field --------------------
# Mac's ListControl, on a curated row (Font features, the Font row's family
# list) and on All Settings' list rows. Every op types into the real field and
# emits its Return, or emits the chip's x button's clicked; the reply reads
# the chip labels back.
lines_of() { grep "^$1 = " "$dev" | sed "s/^$1 = //" | tr '\n' '|'; }
lst() { jget "$(st --op=state --key="$1")" "d['key']['list']['$2']"; }
# A hand-written run, with its comment, that the window has not drawn yet.
printf '# ligatures off\nfont-feature = -calt\nfont-feature = ss01\n' >> "$dev"
o=$(st --op=list-add --key=font-feature --value=-liga)
[ "$(cur font-feature kind)" = list ] && [ "$(lines_of font-feature)" = '-calt|ss01|-liga|' ] && [ "$(cur font-feature display)" = '-calt, ss01, -liga' ] && [ "$(cur font-feature field)" = '' ]
hl_check "L1 Font features is a chip list; adding -liga keeps the file's run (written since) and appends" $? "kind=$(cur font-feature kind) lines=$(lines_of font-feature) chips=$(cur font-feature display) field=$(cur font-feature field)"
grep -A1 '^# ligatures off$' "$dev" | grep -q '^font-feature = -calt$'
hl_check "L2 the run's comment stays above it" $? "file=$(tr '\n' '|' < "$dev")"
st --op=list-remove --key=font-feature --index=1 > /dev/null
[ "$(lines_of font-feature)" = '-calt|-liga|' ] && [ "$(cur font-feature display)" = '-calt, -liga' ] && [ "$(cur font-feature dot)" = true ]
hl_check "L3 a chip's x removes that value only; the chips follow" $? "lines=$(lines_of font-feature) chips=$(cur font-feature display)"
st --op=curated-reset --key=font-feature > /dev/null
! grep -q '^font-feature' "$dev" && [ "$(cur font-feature display)" = '' ] && [ "$(cur font-feature dot)" = false ]
hl_check "L4 the row's reset removes every value; no chips, no dot" $? "lines=$(lines_of font-feature) chips=$(cur font-feature display)"
st --op=list-add --key=font-family --value='DejaVu Sans Mono' > /dev/null
[ "$(cur font-family kind)" = list ] && [ "$(lines_of font-family)" = 'DejaVu Sans Mono|' ] && [ "$(cur font-family display)" = 'DejaVu Sans Mono' ]
hl_check "L5 the Font row edits the family list as chips too" $? "kind=$(cur font-family kind) lines=$(lines_of font-family)"

# All Settings' list rows.
st --op=search --value=keybind > /dev/null
o=$(st --op=add --key=keybind --value=ctrl+alt+j=new_window)
ie=$(lst keybind in_effect)
[ "$(jget "$o" 'd["ok"]')" = true ] && [ "$(lines_of keybind)" = 'ctrl+alt+j=new_window|' ] && [ "$(jget "$(st --op=state --key=keybind)" 'd["key"]["list"]["chips"]')" = '["ctrl+alt+j=new_window"]' ] && [ "$(lst keybind field)" = '' ]
hl_check "L6 All Settings: a binding typed into keybind's field is one added line and one chip" $? "ok=$(jget "$o" 'd.get("ok")') lines=$(lines_of keybind) list=$(jget "$(st --op=state --key=keybind)" 'd["key"]["list"]')"
case "$ie" in "In effect: "*) true ;; *) false ;; esac && [ "$(lst keybind removable)" = true ]
hl_check "L7 a list row says what is in effect, and its chips can be removed" $? "in_effect=$ie"
before=$(cat "$dev")
o=$(st --op=add --key=keybind --value=ctrl+alt+k=not_an_action)
p=$(jget "$(st --op=state --key=keybind)" 'd["key"]["problem"]')
[ "$(jget "$o" 'd["ok"]')" = false ] && [ "$(cat "$dev")" = "$before" ] && [ -n "$p" ] && [ "$p" != null ] && [ "$(lst keybind field)" = 'ctrl+alt+k=not_an_action' ]
hl_check "L8 a binding Ghostty refuses is not written; the row says why and keeps the text" $? "ok=$(jget "$o" 'd.get("ok")') problem=$p field=$(lst keybind field)"
st --op=remove --key=keybind --index=0 > /dev/null
! grep -q '^keybind' "$dev" && [ "$(jget "$(st --op=state --key=keybind)" 'd["key"]["list"]["chips"]')" = '[]' ]
hl_check "L9 the chip's x removes the binding" $? "lines=$(lines_of keybind)"
st --op=search --value=palette > /dev/null
st --op=add --key=palette --value='3=#112233' > /dev/null
[ "$(lines_of palette)" = '3=#112233|' ] && [ "$(jget "$(st --op=state --key=palette)" 'd["key"]["list"]["chips"]')" = '["3=#112233"]' ]
hl_check "L10 a keyed list (palette) takes an entry the same way" $? "lines=$(lines_of palette)"
st --op=search --value= > /dev/null

# ---- close ------------------------------------------------------------------
st --op=close > /dev/null
o=$(st --op=state)
[ "$(jget "$o" 'd["open"]')" = false ] && kill -0 "$APP" 2>/dev/null
hl_check "W20 closing the window leaves the app running" $? "$o"

hl_finish "$L"
