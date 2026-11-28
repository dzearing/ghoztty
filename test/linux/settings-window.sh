#!/usr/bin/env bash
# settings-window.sh - L11g (T3569) acceptance for the Settings window on the
# GTK debug app: `open_config` opens a window (not the file) that edits the
# config with ONE surgical edit per change, the Mac rules of
# docs/reference/settings.md, through win32's shared model. Driven by the
# debug-only `settings` seam (IpcHandlers.settingsSeam), whose ops call what
# the window's own signal handlers call. P1-P23 (T3631) cover the curated
# pages: each op moves the row's real libadwaita widget and reads it back.
# L1-L10 (T3632; L5 became F1-F8) cover list keys: chips and an "add a
# value" field, curated and under All Settings. F1-F8 (T3765) cover the Font
# row, Mac's installed-font picker, against fc-list's monospaced families.
# C1-C13 (T3633) cover Advanced > Config file and the change toast: the
# file row, the other files, Restore... and its confirmation, the current
# file, a link, and the toast's Show Change / Undo / x / timed exit.
# K1-K12 (T3759) cover the color wells (Mac's ColorControl) and the
# starting-folder picker (Mac's FolderControl, Choose Folder... included).
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
# Open in Editor / Show in Folder / Open record what they would launch
# instead of launching it (the seam's "last_shell").
export GHOZTTY_SETTINGS_SHELL_DRY=1

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
# Since T3760 a search is Mac's searchResults: every page's matching rows
# under "<Page> > <Section>", then the keys no page shows (S1-S12 below).
o=$(st --op=search --value=font-size)
sec=$(jget "$o" '[s["title"] for s in d["search"]["sections"] if "font-size" in s["keys"]]')
[ "$(jget "$o" 'd["searching"]')" = true ] && [ "$(jget "$o" 'd["search"]["shown"]')" = true ] && [ "$(jget "$o" '[s["title"] for s in d["search"]["sections"] if "font-size" in s["keys"]] == ["Appearance › Font"]')" = true ]
hl_check "W16 searching shows the results, font-size's row under Appearance > Font" $? "sections=$(jget "$o" '[(s["title"],s["keys"]) for s in d["search"]["sections"]]')"
m=$(jget "$o" 'd["matched"]')
[ "$(jget "$o" 'd["rows"]')" = "$(( m < 40 ? m : 40 ))" ] && [ "$(jget "$o" '"font-size" in d["listed"]')" = false ]
hl_check "W17 the results' All settings lists only keys no page shows, at most 40" $? "rows=$(jget "$o" 'd["rows"]') matched=$m"

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
[ "$pg" = "appearance,panes,terminal,keyboard,session,remote,updates,advanced" ]
hl_check "P1 the sidebar lists the curated pages in Mac's order, then Advanced (Remote Machines since T3635)" $? "pages=$pg"
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
m1=$(jget "$(st --op=state --page=advanced --filter=uncovered)" '"right-click-action" in d["listed"]')
m2=$(jget "$(st --op=state --filter=all)" '"right-click-action" in d["listed"]')
[ "$m1" = false ] && [ "$m2" = true ]
hl_check "P21 'Not on other pages' hides a curated key that All shows" $? "uncovered=$m1 all=$m2"
st --op=search --value= --filter=all > /dev/null
o=$(st --op=reveal --key=scrollbar)
[ "$(jget "$o" 'd["visible_page"]')" = terminal ]
hl_check "P22 All Settings' page link opens the key's page" $? "visible=$(jget "$o" 'd["visible_page"]')"
o=$(st --op=state --key=auto-update)
[ "$(jget "$o" 'd["key"]["curated"]')" = null ] && [ "$(jget "$(st --op=state --page=keyboard)" 'd["visible_page"]')" = keyboard ]
hl_check "P23 Updates offers no auto-update on Linux; the Keyboard page is there" $? "auto-update curated=$(jget "$o" 'd["key"]["curated"]')"

# ---- color wells and the folder picker (T3759) ------------------------------
# Mac's ColorControl: the default's name while the key has no hex color, a
# well (GtkColorDialogButton) that writes #rrggbb, and "Use <default>" while
# the file sets one. Mac's FolderControl: Home folder / Where Ghoztty was
# launched / the chosen folder with ~ / Choose Folder... (GtkFileDialog; the
# seam answers the dialog the way its own reply is handled).
both() { [ "$(cur "$1" display)" = "$2" ] && [ "$(cur "$1" expected)" = "$2" ]; }
o=$(st --op=state --key=cursor-color)
[ "$(cur cursor-color kind)" = color ] && both cursor-color Theme && [ "$(cur cursor-color none_text)" = Theme ] && [ "$(cur cursor-color use)" = null ] && [ "$(cur cursor-color well)" = "#808080" ]
hl_check "K1 an unset color row reads its default's name beside a grey well, no Use link" $? "kind=$(cur cursor-color kind) display=$(cur cursor-color display) none=$(cur cursor-color none_text) use=$(cur cursor-color use) well=$(cur cursor-color well)"
o=$(st --op=color --key=cursor-color --value=#FF8800)
[ "$(jget "$o" 'd["ok"]')" = true ] && [ "$(line_of cursor-color)" = "#ff8800" ] && both cursor-color "#ff8800" && [ "$(cur cursor-color well)" = "#ff8800" ] && [ "$(cur cursor-color use)" = "Use Theme" ] && [ "$(cur cursor-color none_text)" = null ] && [ "$(cur cursor-color dot)" = true ]
hl_check "K2 the well's pick writes #ff8800; the well, Use Theme and the dot follow" $? "line=$(line_of cursor-color) display=$(cur cursor-color display) well=$(cur cursor-color well) use=$(cur cursor-color use)"
st --op=color-use --key=cursor-color > /dev/null
! grep -q '^cursor-color' "$dev" && both cursor-color Theme && [ "$(cur cursor-color use)" = null ] && [ "$(cur cursor-color well)" = "#808080" ]
hl_check "K3 Use Theme takes cursor-color out of the file and the row reads Theme again" $? "file=$(grep -c '^cursor-color' "$dev") display=$(cur cursor-color display) use=$(cur cursor-color use)"
st --op=set --key=cursor-color --value=cell-foreground > /dev/null
[ "$(line_of cursor-color)" = cell-foreground ] && both cursor-color cell-foreground && [ "$(cur cursor-color use)" = null ]
r=$?
d4="display=$(cur cursor-color display) use=$(cur cursor-color use)"
st --op=reset --key=cursor-color > /dev/null
hl_check "K4 a color that is not hex (cell-foreground) is shown as written, with no Use link" $r "$d4"
st --op=choose --key=macos-pane-style --value=elevated > /dev/null
st --op=color --key=split-divider-color --value=#112233 > /dev/null
a1=$(grep -c '^split-divider-color' "$dev")
s1=$(cur split-divider-color sensitive); sub=$(cur split-divider-color subtitle)
st --op=choose --key=macos-pane-style --value=flat > /dev/null
st --op=color --key=split-divider-color --value=#112233 > /dev/null
l2=$(line_of split-divider-color)
st --op=curated-reset --key=split-divider-color > /dev/null
st --op=curated-reset --key=macos-pane-style > /dev/null
[ "$s1" = false ] && [ "$sub" = "Flat style only" ] && [ "$a1" = 0 ] && [ "$l2" = "#112233" ]
hl_check "K5 Divider color's well is dimmed off the Flat style, and writes once it is Flat" $? "elevated: sensitive=$s1 '$sub' lines=$a1; flat: line=$l2"

o=$(st --op=state --page=terminal --key=working-directory)
ch=$(jget "$o" '"|".join(c["label"] for c in d["key"]["curated"]["choices"])')
[ "$(cur working-directory kind)" = folder ] && both working-directory "Home folder" && [ "$ch" = "Home folder|Where Ghoztty was launched" ] && [ "$(cur working-directory selected)" = 0 ]
hl_check "K6 Start new windows in is a popup: Home folder (unset), Where Ghoztty was launched" $? "kind=$(cur working-directory kind) display=$(cur working-directory display) items=$ch"
st --op=choose --key=working-directory --value=inherit > /dev/null
[ "$(line_of working-directory)" = inherit ] && both working-directory "Where Ghoztty was launched" && [ "$(cur working-directory selected)" = 1 ]
hl_check "K7 Where Ghoztty was launched writes inherit" $? "line=$(line_of working-directory) display=$(cur working-directory display)"
proj="$HOME/.cache/gz-t3759-proj"
mkdir -p "$proj"
st --op=folder-choose --key=working-directory > /dev/null
[ "$(cur working-directory folder_dialog)" = true ] && [ "$(line_of working-directory)" = inherit ] && [ "$(cur working-directory display)" = "Choose Folder…" ]
hl_check "K8 Choose Folder... opens the folder dialog and writes nothing yet" $? "dialog=$(cur working-directory folder_dialog) line=$(line_of working-directory) display=$(cur working-directory display)"
o=$(st --op=folder-answer --key=working-directory --value="$proj")
ch=$(jget "$(st --op=state --key=working-directory)" '"|".join(c["label"] for c in d["key"]["curated"]["choices"])')
[ "$(line_of working-directory)" = "$proj" ] && both working-directory "~/.cache/gz-t3759-proj" && [ "$(cur working-directory folder_dialog)" = false ] && [ "$(cur working-directory selected)" = 2 ] && [ "$ch" = "Home folder|Where Ghoztty was launched|~/.cache/gz-t3759-proj" ]
hl_check "K9 the chosen folder is written, listed with ~ and selected" $? "line=$(line_of working-directory) display=$(cur working-directory display) items=$ch"
before=$(cat "$dev")
st --op=folder-choose --key=working-directory > /dev/null
st --op=folder-answer --key=working-directory --value=cancel > /dev/null
[ "$(cat "$dev")" = "$before" ] && [ "$(cur working-directory folder_dialog)" = false ] && both working-directory "~/.cache/gz-t3759-proj" && [ "$(cur working-directory selected)" = 2 ]
hl_check "K10 a cancelled dialog writes nothing and the popup goes back to the folder" $? "display=$(cur working-directory display) selected=$(cur working-directory selected)"
o=$(st --op=folder-answer --key=working-directory --value=/tmp)
[ "$(jget "$o" 'd.get("error","")' | grep -c 'no Choose Folder dialog')" = 1 ] && [ "$(cat "$dev")" = "$before" ]
r=$?
st --op=choose --key=working-directory --value= > /dev/null
ch=$(jget "$(st --op=state --key=working-directory)" 'len(d["key"]["curated"]["choices"])')
! grep -q '^working-directory' "$dev" && [ $r = 0 ] && both working-directory "Home folder" && [ "$ch" = 2 ]
hl_check "K11 Home folder takes the key out (the folder item goes); an answer with no dialog is refused" $? "refused=$r file=$(grep -c '^working-directory' "$dev") items=$ch"
st --op=set --key=working-directory --value=home > /dev/null
[ "$(line_of working-directory)" = home ] && both working-directory "Home folder" && [ "$(cur working-directory selected)" = 0 ]
r=$?
st --op=reset --key=working-directory > /dev/null
rmdir "$proj" 2>/dev/null
hl_check "K12 working-directory = home in the file reads as Home folder" $r "display=$(cur working-directory display) selected=$(cur working-directory selected)"

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

# ---- the Font row (T3765): Mac's installed-font picker -----------------------
# The items are fontconfig's monospaced families; fc-list is the oracle. A
# face's first family name is its own (later ones are localized aliases).
fc_mono=$(fc-list :spacing=mono family; fc-list :spacing=charcell family)
fc_mono=$(printf '%s\n' "$fc_mono" | sed 's/,.*//' | grep -v '^\.' | grep -v '^$' | sort -u)
ch=$(cur font-family choices)
fams=$(printf '%s' "$ch" | python3 -I -c 'import json,sys; print("\n".join(c["value"] for c in json.load(sys.stdin)[1:]))')
first=$(printf '%s' "$ch" | python3 -I -c 'import json,sys; c=json.load(sys.stdin)[0]; print(c["value"]+"|"+c["label"])')
[ "$(cur font-family kind)" = font ] && [ "$first" = '|Default (JetBrains Mono)' ] && [ -n "$fams" ] && [ "$fams" = "$fc_mono" ] && [ "$(cur font-family display)" = 'Default (JetBrains Mono)' ] && [ "$(cur font-family other_visible)" = false ]
hl_check "F1 the Font row is a picker: Default (JetBrains Mono), then exactly fc-list's monospaced families; no fallback row while unset" $? "kind=$(cur font-family kind) first=$first n=$(printf '%s\n' "$fams" | wc -l) fc=$(printf '%s\n' "$fc_mono" | wc -l) diff=$(diff <(printf '%s\n' "$fams") <(printf '%s\n' "$fc_mono") | tr '\n' ' ' | cut -c1-300)"
fam1=$(printf '%s\n' "$fams" | grep -m1 -x 'DejaVu Sans Mono' || printf '%s\n' "$fams" | head -1)
fam2=$(printf '%s\n' "$fams" | grep -v -x "$fam1" | head -1)
o=$(st --op=choose --key=font-family --value="$fam1")
[ "$(jget "$o" 'd["ok"]')" = true ] && [ "$(lines_of font-family)" = "$fam1|" ] && [ "$(cur font-family display)" = "$fam1" ] && [ "$(cur font-family dot)" = true ] && [ "$(cur font-family fallback)" = null ] && [ "$(cur font-family other_visible)" = true ]
hl_check "F2 picking '$fam1' writes one font-family line; the picker shows it; the fallback row opens" $? "lines=$(lines_of font-family) display=$(cur font-family display) fallback=$(cur font-family fallback)"
st --op=list-add --key=font-family --value='Symbols Nerd Font' > /dev/null
[ "$(lines_of font-family)" = "$fam1|Symbols Nerd Font|" ] && [ "$(cur font-family fallback)" = '+1 fallback' ] && [ "$(cur font-family fallback_tooltip)" = 'Symbols Nerd Font' ] && [ "$(cur font-family fallback_chips)" = '["Symbols Nerd Font"]' ] && [ "$(cur font-family display)" = "$fam1" ]
hl_check "F3 a fallback added under it follows the font; '+1 fallback' beside the picker names it" $? "lines=$(lines_of font-family) fallback=$(cur font-family fallback) tip=$(cur font-family fallback_tooltip) chips=$(cur font-family fallback_chips)"
[ -n "$fam2" ] && st --op=choose --key=font-family --value="$fam2" > /dev/null
[ -n "$fam2" ] && [ "$(lines_of font-family)" = "$fam2|Symbols Nerd Font|" ] && [ "$(cur font-family display)" = "$fam2" ] && [ "$(cur font-family fallback)" = '+1 fallback' ]
hl_check "F4 picking another family ('$fam2') replaces only the first value; the fallback stays" $? "lines=$(lines_of font-family) display=$(cur font-family display) (needs two monospaced families installed)"
st --op=list-remove --key=font-family --index=0 > /dev/null
[ "$(lines_of font-family)" = "$fam2|" ] && [ "$(cur font-family fallback)" = null ] && [ "$(cur font-family fallback_chips)" = '[]' ]
hl_check "F5 a fallback chip's x removes that fallback, not the font" $? "lines=$(lines_of font-family) fallback=$(cur font-family fallback)"
# A font this box does not have, named by hand (All Settings' list row).
st --op=curated-reset --key=font-family > /dev/null
# font-family is on a page, so a search shows its curated row, not All
# Settings' (T3760): Advanced's list holds every key.
st --op=state --page=advanced --filter=all > /dev/null
st --op=add --key=font-family --value='Nowhere Mono' > /dev/null
st --op=add --key=font-family --value="$fam1" > /dev/null
st --op=search --value= > /dev/null
sub=$(cur font-family subtitle)
[ "$(lines_of font-family)" = "Nowhere Mono|$fam1|" ] && [ "$(cur font-family display)" = 'Nowhere Mono (not installed)' ] && [ "$sub" = "Nowhere Mono isn't installed — Ghoztty uses the next font." ] && [ "$(cur font-family fallback)" = '+1 fallback' ] && [ "$(cur font-family display)" = "$(cur font-family expected)" ]
hl_check "F6 a font that is not installed is listed '(not installed)' and the row says Ghoztty uses the next font" $? "lines=$(lines_of font-family) display=$(cur font-family display) subtitle=$sub"
st --op=choose --key=font-family --value="$fam1" > /dev/null
sub=$(cur font-family subtitle)
[ "$(lines_of font-family)" = "$fam1|$fam1|" ] && [ "$sub" != "Nowhere Mono isn't installed — Ghoztty uses the next font." ] && [ "$(jget "$(cur font-family choices)" 'any("not installed" in c["label"] for c in d)')" = false ]
hl_check "F7 picking an installed family over it clears the warning and the '(not installed)' item" $? "lines=$(lines_of font-family) subtitle=$sub"
st --op=choose --key=font-family --value= > /dev/null
! grep -q '^font-family' "$dev" && [ "$(cur font-family display)" = 'Default (JetBrains Mono)' ] && [ "$(cur font-family dot)" = false ] && [ "$(cur font-family other_visible)" = false ]
hl_check "F8 Default removes every font-family line, fallbacks included" $? "lines=$(lines_of font-family) display=$(cur font-family display)"

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

# ---- Advanced > Config file and the change toast (T3633) --------------------
adv() { jget "$(st --op=state)" "d[\"advanced\"]$1"; }
toast() { jget "$(st --op=state)" "d[\"toast\"]$1"; }
case "$dev" in "$HOME"/*) dev_disp="~${dev#"$HOME"}" ;; *) dev_disp="$dev" ;; esac
st --op=dismiss > /dev/null
[ "$(adv '["title"]')" = config-debug.ghostty ] && [ "$(adv '["display"]')" = "$dev_disp" ] && [ "$(adv '["link"]')" = null ] && [ "$(adv '["error"]')" = null ]
hl_check "C1 the file row names config-debug.ghostty and its path (~ for home); no link, no problem" $? "title=$(adv '["title"]') display=$(adv '["display"]') link=$(adv '["link"]')"
srcs=$(adv '["sources"]')
[ "$(jget "$srcs" '"|".join(s["name"]+":"+s["kind"] for s in d)')" = 'config.ghostty:also loaded|later.ghostty:included' ] \
  && [ "$(jget "$srcs" 'all(s["drawn"]==s["name"] for s in d)')" = true ] \
  && [ "$(jget "$srcs" 'd[0]["note"]')" = 'Loaded before your config; your settings override it.' ] \
  && [ "$(jget "$srcs" 'd[1]["note"]')" = 'Loaded after your config through config-file, so the keys it sets win. Settings shows those keys read-only.' ]
hl_check "C2 every other file Ghostty loads is listed in load order, with Mac's pill and sentence" $? "$srcs"
st --op=open_editor > /dev/null; e1=$(adv '["last_shell"]')
st --op=reveal_file > /dev/null; e2=$(adv '["last_shell"]')
st --op=open_source --index=1 > /dev/null; e3=$(adv '["last_shell"]')
[ "$e1" = "editor $dev" ] && [ "$e2" = "reveal $dev" ] && [ "$e3" = "open $later" ]
hl_check "C3 Open in Editor, Show in Folder and a file's Open launch the right files" $? "editor=[$e1] reveal=[$e2] open=[$e3]"
bk=$(adv '["backups"]'); menu=$(adv '["menu"]')
lab=$(jget "$bk" 'd[0]["label"]')
[ "$(jget "$bk" 'len(d)')" = 1 ] && printf '%s' "$lab" | grep -Eq '^[A-Z][a-z]{2} [0-9]{1,2}, [0-9]{4} at [0-9]{1,2}:[0-9]{2} [AP]M$' \
  && [ "$(jget "$menu" '"|".join(d)')" = "$lab|-|Show Backups in Folder" ] \
  && [ "$(adv '["backups_note"]')" = 'Saved a copy before this session’s first change.' ]
hl_check "C4 Backups: the session's backup is listed as a date, then Show Backups in Folder" $? "backups=$bk menu=$menu note=$(adv '["backups_note"]')"
st --op=backups_folder > /dev/null
[ "$(adv '["last_shell"]')" = "folder $GHOZTTY_SETTINGS_BACKUP_DIR" ]
hl_check "C4b Show Backups in Folder opens the backups folder" $? "$(adv '["last_shell"]')"

st --op=toast_ms --value=600000 > /dev/null
st --op=set --key=font-size --value=13 > /dev/null
o=$(st --op=state)
[ "$(jget "$o" 'd["toast"]["shown"]')" = true ] && [ "$(jget "$o" 'd["toast"]["drawn"]["message"]==d["toast"]["message"]')" = true ] \
  && [ "$(jget "$o" '"font-size" in d["toast"]["message"]')" = true ] \
  && [ "$(jget "$o" 'd["toast"]["drawn"]["detail"]')" = 'applied live · backed up first' ] && [ "$(jget "$o" 'd["toast"]["drawn"]["show"]')" = 'Show Change' ]
hl_check "C5 a write raises the toast: its change, 'applied live · backed up first', Show Change" $? "$(jget "$o" 'd["toast"]')"
st --op=show_change > /dev/null
o=$(st --op=state)
[ "$(jget "$o" 'd["toast"]["drawn"]["diff"]==["\u2212 "+l for l in d["toast"]["removed"]]+["+ "+l for l in d["toast"]["added"]]')" = true ] \
  && [ "$(jget "$o" '"+ font-size = 13" in d["toast"]["drawn"]["diff"]')" = true ] && [ "$(jget "$o" 'd["toast"]["drawn"]["show"]')" = 'Hide Change' ]
hl_check "C6 Show Change lists the removed and added lines; the link reads Hide Change" $? "$(jget "$o" 'd["toast"]["drawn"]')"
before_undo=$(grep -c '^font-size' "$dev")
st --op=undo > /dev/null
o=$(st --op=state)
! grep -q '^font-size' "$dev" && [ "$before_undo" = 1 ] && [ "$(jget "$o" 'd["toast"]')" = null ] && [ "$(jget "$o" 'd["advanced"]["undo"]')" = undone ] && [ "$(jget "$o" 'd["toast_motion"]["shown"]')" = false ]
hl_check "C7 Undo puts the file back and takes the toast away at once" $? "undo=$(jget "$o" 'd["advanced"]["undo"]') lines=$(grep -c '^font-size' "$dev") toast=$(jget "$o" 'd["toast"]')"
st --op=set --key=font-size --value=14 > /dev/null
printf '# typed in an editor\n' >> "$dev"
edited=$(cat "$dev")
st --op=undo > /dev/null
o=$(st --op=state)
cs='The config file changed since — open it to undo by hand.'
[ "$(cat "$dev")" = "$edited" ] && [ "$(jget "$o" 'd["advanced"]["undo"]')" = changed_since ] && [ "$(jget "$o" 'd["toast"]["drawn"]["refused"]')" = "$cs" ] \
  && [ "$(jget "$o" 'd["advanced"]["error"]')" = "⚠ $cs" ] && [ "$(jget "$o" 'd["toast"]["shown"]')" = true ]
hl_check "C8 Undo after an editor changed the file is refused: the file is kept, the toast and the section say why" $? "undo=$(jget "$o" 'd["advanced"]["undo"]') refused=$(jget "$o" 'd["toast"]["drawn"]["refused"]') error=$(jget "$o" 'd["advanced"]["error"]')"
st --op=dismiss > /dev/null
o=$(st --op=state)
[ "$(jget "$o" 'd["toast"]')" = null ] && [ "$(jget "$o" 'd["toast_motion"]["shown"]')" = false ]
hl_check "C9 the toast's x takes it away" $? "$(jget "$o" 'd["toast"]')"

# Restore...: a pick asks first; Cancel keeps the file, Restore replaces it.
before_restore=$(cat "$dev")
st --op=restore-ask --index=0 > /dev/null
o=$(st --op=state)
lab=$(jget "$o" 'd["advanced"]["backups"][0]["label"]')
[ "$(jget "$o" 'd["advanced"]["confirm"]["heading"]')" = 'Restore this backup?' ] \
  && [ "$(jget "$o" 'd["advanced"]["confirm"]["body"]')" = "Your config file will be replaced with the copy from $lab. The current file is backed up first." ]
hl_check "C10 picking a backup asks first, in Mac's words" $? "$(jget "$o" 'd["advanced"]["confirm"]')"
st --op=restore-answer --value=cancel > /dev/null
o=$(st --op=state)
[ "$(cat "$dev")" = "$before_restore" ] && [ "$(jget "$o" 'd["advanced"]["confirm"]')" = null ]
r1=$?
backup_text=$(cat "$(jget "$o" 'd["advanced"]["backups"][-1]["path"]')")
st --op=restore-ask --index="$(jget "$o" 'len(d["advanced"]["backups"])-1')" > /dev/null
st --op=restore-answer --value=restore > /dev/null
o=$(st --op=state)
[ $r1 = 0 ] && [ "$(cat "$dev")" = "$backup_text" ] && grep -q '^font-size = 12$' "$dev" && [ "$(jget "$o" 'd["toast"]["message"].startswith("Restored config-debug.ghostty.")')" = true ] && [ "$(jget "$o" 'd["advanced"]["confirm"]')" = null ]
hl_check "C11 Cancel keeps the file; Restore puts the backup back and the toast says so" $? "cancel=$r1 toast=$(jget "$o" 'd["toast"]["message"]') file=$(tr '\n' '|' < "$dev")"
st --op=undo > /dev/null
[ "$(cat "$dev")" = "$before_restore" ]
hl_check "C11b the restore is itself a change Undo takes back" $? "file=$(tr '\n' '|' < "$dev")"
st --op=current_file > /dev/null
o=$(st --op=state)
[ "$(jget "$o" 'd["advanced"]["show_file"]')" = true ] && [ "$(jget "$o" 'd["advanced"]["current_file"]')" = "$(cat "$dev")" ]
hl_check "C12 Current file opens on the file's text" $? "show=$(jget "$o" 'd["advanced"]["show_file"]')"

# The timed exit: untouched, the toast slides down and fades; expanded, it stays.
st --op=toast_ms --value=400 > /dev/null
st --op=set --key=font-size --value=16 > /dev/null
gone() { [ "$(jget "$(st --op=state)" 'd["toast"] is None and not d["toast_motion"]["leaving"]')" = true ]; }
hl_wait_for 8 gone
r=$?
o=$(st --op=state); tm=$(jget "$o" 'd["toast_motion"]')
if [ "$(jget "$tm" 'd["animates"]')" = true ]; then
    [ $r = 0 ] && [ "$(jget "$tm" 'd["completed"] and len(d["frames"])>=3 and d["frames"][-1]==0 and all(a>=b for a,b in zip(d["frames"],d["frames"][1:]))')" = true ] && [ "$(jget "$tm" 'd["shown"]')" = false ]
else
    [ $r = 0 ] && [ "$(jget "$tm" 'd["instant"]')" = true ]
fi
hl_check "C13 untouched, the toast leaves on its own, fading to nothing frame by frame" $? "gone=$r motion=$tm"
st --op=set --key=font-size --value=17 > /dev/null
st --op=show_change > /dev/null
sleep 1.2
o=$(st --op=state)
[ "$(jget "$o" 'd["toast"]["shown"]')" = true ] && [ "$(jget "$o" 'd["toast"]["expanded"]')" = true ]
hl_check "C13b an expanded toast stays past its time until dismissed" $? "$(jget "$o" 'd["toast"]')"
st --op=dismiss > /dev/null
st --op=reset --key=font-size > /dev/null
st --op=dismiss > /dev/null

# A link: Settings names the target and writes through it.
real="$cfg_dir/real-config.ghostty"
st --op=close > /dev/null
mv "$dev" "$real" && ln -s "$real" "$dev"
st --op=action > /dev/null
case "$real" in "$HOME"/*) real_disp="~${real#"$HOME"}" ;; *) real_disp="$real" ;; esac
o=$(st --op=state)
[ "$(jget "$o" 'd["advanced"]["title"]')" = real-config.ghostty ] && [ "$(jget "$o" 'd["advanced"]["link"]')" = "A link to $real_disp — Settings writes through it." ]
r1=$?
st --op=set --key=font-size --value=18 > /dev/null
[ $r1 = 0 ] && [ -L "$dev" ] && grep -q '^font-size = 18$' "$real"
hl_check "C14 a linked config names its target, says Settings writes through it, and does" $? "title=$(jget "$o" 'd["advanced"]["title"]') link=$(jget "$o" 'd["advanced"]["link"]') symlink=$([ -L "$dev" ] && echo yes || echo no)"

# ---- search across the pages (T3760): Mac's searchResults ---------------------
# A search lists each page's matching curated rows - the row's own widget,
# moved - under "<Page> > <Section>", sections with their own UI that match
# their words, then "Advanced > All settings (N)" capped at 40.
st --op=state --page=terminal > /dev/null
o=$(st --op=search --value=scroll)
secs=$(jget "$o" '[s["title"] for s in d["search"]["sections"]]')
drawn=$(jget "$o" 'all(s["drawn"] == s["title"] for s in d["search"]["sections"])')
[ "$(jget "$o" 'd["visible_page"]')" = search ] && [ "$(jget "$o" '"Terminal › Scrollback" in [s["title"] for s in d["search"]["sections"]]')" = true ] && [ "$drawn" = true ]
hl_check "S1 a search shows a results page, each section headed '<Page> > <Section>' as drawn" $? "visible=$(jget "$o" 'd["visible_page"]') sections=$secs drawn=$drawn"
k=$(jget "$o" '[s["keys"] for s in d["search"]["sections"] if s["title"]=="Terminal › Scrollback"][0]')
[ "$(jget "$(st --op=state --key=scrollbar)" 'd["key"]["curated"]["in_search"]')" = true ] && printf '%s' "$k" | grep -q '"scrollbar"' && [ "$(jget "$o" 'd["search"]["curated_hits"]')" -ge 2 ]
hl_check "S2 the curated rows that match are listed in the results, the page's own widgets" $? "keys=$k hits=$(jget "$o" 'd["search"]["curated_hits"]')"
o=$(st --op=search --value=font-size)
st --op=step --key=font-size --value=up > /dev/null
o=$(st --op=state --key=font-size)
[ "$(line_of font-size)" = 18.5 ] && [ "$(jget "$o" 'd["key"]["curated"]["display"]')" = "$(jget "$o" 'd["key"]["curated"]["expected"]')" ] && [ "$(jget "$o" 'd["key"]["curated"]["in_search"]')" = true ] && [ "$(jget "$o" 'd["searching"]')" = true ]
hl_check "S3 a row in the results is the live control: its arrow writes, and it stays listed" $? "line=$(line_of font-size) display=$(jget "$o" 'd["key"]["curated"]["display"]')"
o=$(st --op=search --value=18.5)
[ "$(jget "$o" '[s["title"] for s in d["search"]["sections"] if "font-size" in s["keys"]] == ["Appearance › Font"]')" = true ]
hl_check "S4 a search matches a row by the value the file gives it" $? "sections=$(jget "$o" '[(s["title"],s["keys"]) for s in d["search"]["sections"]]') searching=$(jget "$o" 'd["searching"]') query=$(jget "$o" 'd["query"]') shown=$(jget "$o" 'd["search"]["shown"]') visible=$(jget "$o" 'd["visible_page"]')"
o=$(st --op=search --value=)
c1=$(jget "$(st --op=state --key=font-size)" 'd["key"]["curated"]')
c2=$(jget "$(st --op=state --key=scrollbar)" 'd["key"]["curated"]')
[ "$(jget "$o" 'd["searching"]')" = false ] && [ "$(jget "$o" 'd["visible_page"]')" = terminal ] && [ "$(jget "$o" 'd["search"]["shown"]')" = false ] && [ "$(jget "$c1" 'd["in_search"]')" = false ] && [ "$(jget "$c1" 'd["in_place"]')" = true ] && [ "$(jget "$c2" 'd["in_place"]')" = true ]
hl_check "S5 clearing the search puts the page back, every row in its own place" $? "visible=$(jget "$o" 'd["visible_page"]') font-size=$(jget "$c1" '(d["in_search"],d["in_place"])') scrollbar=$(jget "$c2" '(d["in_search"],d["in_place"])')"
o=$(st --op=state --key=font-family)
[ "$(jget "$o" 'd["key"]["curated"]["in_place"]')" = true ] && [ "$(jget "$o" 'd["key"]["curated"]["other_visible"]')" != null ]
hl_check "S6 a row with a second row under it (the Font row's fallbacks) comes back whole" $? "$(jget "$o" 'd["key"]["curated"]["in_place"]')"
o=$(st --op=search --value=e)
m=$(jget "$o" 'd["matched"]')
[ "$m" -gt 40 ] && [ "$(jget "$o" 'd["rows"]')" = 40 ] && [ "$(jget "$o" 'd["search"]["more"]')" = "$((m - 40)) more — keep typing to narrow." ]
hl_check "S7 a broad search lists 40 keys no page shows, then 'N more - keep typing to narrow.'" $? "matched=$m rows=$(jget "$o" 'd["rows"]') more=$(jget "$o" 'd["search"]["more"]')"
o=$(st --op=search --value=zzqqxxnothing)
[ "$(jget "$o" 'd["search"]["empty"]')" = 'No settings match “zzqqxxnothing”.' ] && [ "$(jget "$o" 'len(d["search"]["sections"])')" = 0 ] && [ "$(jget "$o" 'd["rows"]')" = 0 ]
hl_check "S8 a search that matches nothing says so" $? "empty=$(jget "$o" 'd["search"]["empty"]') searching=$(jget "$o" 'd["searching"]') query=$(jget "$o" 'd["query"]') shown=$(jget "$o" 'd["search"]["shown"]') visible=$(jget "$o" 'd["visible_page"]')"
o=$(st --op=search --value=backup)
i=$(jget "$o" '[i for i,s in enumerate(d["search"]["sections"]) if s["custom"]=="config_file"][0]')
[ -n "$i" ] && [ "$i" != null ] && [ "$(jget "$o" 'd["search"]["sections"]['"$i"']["title"]')" = 'Advanced › Config file' ]
r1=$?
o=$(st --op=search-link --index="$i")
[ $r1 = 0 ] && [ "$(jget "$o" 'd["visible_page"]')" = advanced ] && [ "$(jget "$o" 'd["searching"]')" = false ] && [ "$(jget "$o" 'd["query"]')" = '' ]
hl_check "S9 a section with its own UI matches its words, and its link shows its page" $? "index=$i visible=$(jget "$o" 'd["visible_page"]') query=$(jget "$o" 'd["query"]')"
o=$(st --op=search --value=preview)
[ "$(jget "$o" 'd["searching"]')" = true ] && [ "$(jget "$o" '"preview" in [s["custom"] for s in d["search"]["sections"]]')" = false ]
hl_check "S10 the preview is never a search result (Mac)" $? "customs=$(jget "$o" '[s["custom"] for s in d["search"]["sections"]]')"
st --op=search --value=scroll > /dev/null
o=$(st --op=state --page=keyboard)
[ "$(jget "$o" 'd["visible_page"]')" = keyboard ] && [ "$(jget "$o" 'd["searching"]')" = false ] && [ "$(jget "$o" 'd["query"]')" = '' ] && [ "$(jget "$(st --op=state --key=scrollbar)" 'd["key"]["curated"]["in_place"]')" = true ]
hl_check "S11 picking a page in the sidebar ends the search (Mac's onChange(of: selection))" $? "visible=$(jget "$o" 'd["visible_page"]') query=$(jget "$o" 'd["query"]')"
st --op=search --value=scroll > /dev/null
st --op=search-stop > /dev/null
hl_wait_for 5 sh -c "[ \"\$(hl_ipc settings --op=state 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)[\"searching\"])')\" = False ]" 2>/dev/null
o=$(st --op=state)
[ "$(jget "$o" 'd["searching"]')" = false ] && [ "$(jget "$o" 'd["visible_page"]')" = keyboard ]
hl_check "S12 Esc in the search field clears the search and the page comes back" $? "searching=$(jget "$o" 'd["searching"]') visible=$(jget "$o" 'd["visible_page"]')"
grep -E "settings: (search|set|opened|closed|reading)|gtk_settings" "$HL_RUNTIME/APP.log" 2>/dev/null | tail -40 | sed "s/^/APPLOG /"

# ---- close ------------------------------------------------------------------
st --op=close > /dev/null
o=$(st --op=state)
[ "$(jget "$o" 'd["open"]')" = false ] && kill -0 "$APP" 2>/dev/null
hl_check "W20 closing the window leaves the app running" $? "$o"

hl_finish "$L"
