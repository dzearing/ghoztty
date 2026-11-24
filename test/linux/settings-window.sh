#!/usr/bin/env bash
# settings-window.sh - L11g (T3569) acceptance for the Settings window on the
# GTK debug app: `open_config` opens a window (not the file) that edits the
# config with ONE surgical edit per change, the Mac rules of
# docs/reference/settings.md, through win32's shared model. Driven by the
# debug-only `settings` seam (IpcHandlers.settingsSeam), whose ops call what
# the window's own signal handlers call.
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

# ---- close ------------------------------------------------------------------
st --op=close > /dev/null
o=$(st --op=state)
[ "$(jget "$o" 'd["open"]')" = false ] && kill -0 "$APP" 2>/dev/null
hl_check "W20 closing the window leaves the app running" $? "$o"

hl_finish "$L"
