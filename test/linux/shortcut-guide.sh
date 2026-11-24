#!/usr/bin/env bash
# shortcut-guide.sh - L11h (T3570) acceptance for the keyboard shortcut guide
# on the GTK debug app: `show_keyboard_shortcuts` (Ctrl+Shift+/ on Linux)
# opens one guide window whose rows come from the LIVE keybind table through
# win32's shared catalog (docs/reference/keyboard-shortcuts.md), with
# key-combo search, categories, the unbound toggle, Up/Down/Return/Escape and
# Run. Driven by the debug-only `shortcut-guide` seam
# (IpcHandlers.shortcutGuideSeam: win32's op names and reply shape), whose
# ops call what the window's own signal handlers call, and by `press-key`,
# which feeds a chord through the pane's real keybind table.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\shortcut-guide.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh); the config and the
# guide's remembered toggle live in that run's private XDG dirs.
#
# NEGATIVE=1 presses Ctrl+/ instead of Ctrl+Shift+/ (the shell's ^_), so G5
# must go red: the check can fail.
#
# Output: one PASS/FAIL line per check, then 'SHORTCUT GUIDE: ALL PASS' or
# 'SHORTCUT GUIDE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="SHORTCUT GUIDE"

log=/tmp/shortcut-guide-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "G1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "G2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

cfg_dir="$XDG_CONFIG_HOME/ghostty"
dev="$cfg_dir/config-debug.ghostty"
mkdir -p "$cfg_dir"
printf '# no keybinds yet\n' > "$dev"
export XDG_STATE_HOME="$HL_RUNTIME/state"
pref="$XDG_STATE_HOME/ghoztty/shortcut-guide-unbound-debug"

# jget <json> <python expr over d (the reply's data)>: one field.
jget() { printf '%s' "$1" | python3 -I -c 'import json,sys; r=json.load(sys.stdin); d=r.get("data",r); v=eval(sys.argv[1]); print(json.dumps(v) if isinstance(v,(dict,list,bool)) or v is None else v)' "$2" 2>/dev/null; }
sg() { hl_ipc shortcut-guide "$@"; }
# row <json> <id> <field>: one field of the row with that id.
row() { jget "$1" "next((r[\"$3\"] for r in d[\"rows\"] if r[\"id\"]==\"$2\"), \"<no row>\")"; }

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "G3 the app serves its socket" $?
pane=""; for _ in $(seq 1 50); do pane=$(hl_first_pane "$app"); [ -n "$pane" ] && break; sleep 0.2; done

o=$(sg --op=state)
printf '%s' "$o" | grep -q 'not open'
hl_check "G4 no guide before it is asked for" $? "$o"

# ---- the chord, through the pane's real keybind table -----------------------
chord=ctrl+shift+/
[ "${NEGATIVE:-0}" = 1 ] && chord=ctrl+/
p=$(hl_ipc press-key --target="$pane" --key="$chord")
is_open() { [ "$(jget "$(sg --op=state)" 'd["open"]')" = true ]; }
hl_wait_for 5 is_open
hl_check "G5 Ctrl+Shift+/ in a terminal pane opens the guide" $? "press=$p"
grep -q 'shortcut guide: opened' "$APP_LOG"
hl_check "G6 the app log names the open" $?

# ---- rows from the live keybind table ---------------------------------------
o=$(sg --op=state)
b=$(jget "$o" 'd["bound"]'); n=$(jget "$o" 'len(d["rows"])'); c=$(jget "$o" 'd["customized"]')
[ -n "$b" ] && [ "$b" -gt 40 ] && [ "$n" -gt 40 ] && [ "$c" = 0 ]
hl_check "G7 the guide lists the live bindings (>40 bound, none customized)" $? "bound=$b rows=$n customized=$c"
k=$(row "$o" show_keyboard_shortcuts keys)
printf '%s' "$k" | grep -q '"Ctrl+Shift+/"'
hl_check "G8 its own row shows Ctrl+Shift+/ (the Linux default)" $? "keys=$k"
[ "$(row "$o" new_tab runnable)" = true ] && [ "$(row "$o" quit runnable)" = false ] && [ "$(row "$o" quit title)" = "Quit Ghoztty" ]
hl_check "G9 New Tab may be run from the guide; Quit (titled the Linux way) may not" $? "new_tab=$(row "$o" new_tab runnable) quit=$(row "$o" quit runnable)/$(row "$o" quit title)"
[ "$(jget "$o" 'sum(d["counts"].values())')" = "$n" ] && [ "$(jget "$o" 'd["all_count"]')" = "$n" ]
hl_check "G10 the sidebar counts add up to the rows shown" $? "counts=$(jget "$o" 'd["counts"]') rows=$n"

# ---- categories and search ----------------------------------------------------
o=$(sg --op=state --category=app)
[ "$(jget "$o" 'd["category"]')" = app ] && [ "$(jget "$o" 'all(r["category"]=="app" for r in d["rows"])')" = true ] && [ "$(jget "$o" 'len(d["rows"])')" = "$(jget "$o" 'd["counts"]["app"]')" ]
hl_check "G11 picking App shows only App rows, as many as its count" $? "rows=$(jget "$o" 'len(d["rows"])') count=$(jget "$o" 'd["counts"]["app"]')"
o=$(sg --op=state --query='ctrl shift /')
[ "$(jget "$o" 'd["category"]')" = null ] && [ "$(jget "$o" 'd["selected"]')" = show_keyboard_shortcuts ]
hl_check "G12 a key-combo query searches every category and selects the match" $? "category=$(jget "$o" 'd["category"]') selected=$(jget "$o" 'd["selected"]') rows=$(jget "$o" '[r["id"] for r in d["rows"]]')"
o=$(sg --op=state --query='shift+ctrl+/')
[ "$(jget "$o" 'd["selected"]')" = show_keyboard_shortcuts ]
hl_check "G13 modifier order does not matter" $? "selected=$(jget "$o" 'd["selected"]')"
o=$(sg --op=state --query='keyboard')
[ "$(jget "$o" 'any(r["id"]=="show_keyboard_shortcuts" for r in d["rows"])')" = true ]
hl_check "G14 a word query matches the plain-language title" $?

# ---- Up/Down and Escape --------------------------------------------------------
o=$(sg --op=state --query=)
o=$(sg --op=select --down=2)
s1=$(jget "$o" 'd["selected"]'); r1=$(jget "$o" '[r["id"] for r in d["rows"]].index(d["selected"]) if d["selected"] else -1')
o=$(sg --op=select --down=1)
r2=$(jget "$o" '[r["id"] for r in d["rows"]].index(d["selected"]) if d["selected"] else -1')
[ "$s1" != null ] && [ "$r2" = $((r1 + 1)) ]
hl_check "G15 Down moves the selection one row" $? "first=$s1@$r1 then @$r2"
o=$(sg --op=select --down=3 --query=split)
sleep 1 # the search field reports its change after the fact
o2=$(sg --op=state)
[ "$(jget "$o" 'd["selected"]')" != null ] && [ "$(jget "$o2" 'd["selected"]')" = "$(jget "$o" 'd["selected"]')" ] && [ "$(jget "$o2" '[r["id"] for r in d["rows"]].index(d["selected"])')" = 3 ]
hl_check "G15b a selection made under a query stays put (the field's late change does not reset it)" $? "after=$(jget "$o" 'd["selected"]') later=$(jget "$o2" 'd["selected"]')"
o=$(sg --op=escape --query=new)
o=$(sg --op=state)
[ "$(jget "$o" 'd["query"]')" = "" ] && [ "$(jget "$o" 'd["open"]')" = true ]
hl_check "G16 Escape clears the search first" $? "$(jget "$o" 'd["query"]')"
sg --op=select --down=1 > /dev/null
o=$(sg --op=escape)
[ "$(jget "$o" 'd["selected"]')" = null ] && [ "$(jget "$o" 'd["open"]')" = true ]
hl_check "G17 then the selection" $? "selected=$(jget "$o" 'd["selected"]')"
o=$(sg --op=escape)
[ "$(jget "$o" 'd["open"]')" = false ] && kill -0 "$APP" 2>/dev/null
hl_check "G18 then closes the guide, leaving the app running" $? "$o"

# ---- the app action (main menu, palette) and the unbound toggle -------------
o=$(sg --op=action)
[ "$(jget "$o" 'd["open"]')" = true ]
hl_check "G19 the show_keyboard_shortcuts app action opens it again" $? "open=$(jget "$o" 'd["open"]')"

# ---- the window draws (its own render; SHOT_OUT=<dir> keeps the PNGs) -------
shot="$HL_RUNTIME/guide.png"
# A window just presented has no size until its first frame: retry.
shot_ok() { o=$(sg --op=shot --path="$shot"); printf '%s' "$o" | grep -q '"success":true'; }
hl_wait_for 5 shot_ok
dims=$(python3 -I -c 'import struct,sys; b=open(sys.argv[1],"rb").read(24); print(*struct.unpack(">II", b[16:24])) if b[:8]==b"\x89PNG\r\n\x1a\n" else print(0, 0)' "$shot" 2>/dev/null)
set -- $dims
[ "${1:-0}" -ge 600 ] && [ "${2:-0}" -ge 400 ]
hl_check "G19b the guide window renders (a PNG of at least 600x400)" $? "dims=$dims reply=$(printf '%s' "$o" | head -c 120)"
if [ -n "${SHOT_OUT:-}" ]; then
    mkdir -p "$SHOT_OUT" && cp "$shot" "$SHOT_OUT/guide-all.png"
    sg --op=select --down=3 --query=split > /dev/null
    sleep 1 # the rebuilt rows lay out on the next frame
    sg --op=shot --path="$SHOT_OUT/guide-search.png" > /dev/null
    sg --op=state --query= > /dev/null
fi
n0=$(jget "$(sg --op=state)" 'len(d["rows"])')
o=$(sg --op=state --unbound=1)
n1=$(jget "$o" 'len(d["rows"])')
[ "$(jget "$o" 'd["include_unbound"]')" = true ] && [ "$n1" -gt "$n0" ] && [ "$(cat "$pref" 2>/dev/null)" = 1 ]
hl_check "G20 Show unbound actions lists more rows and is remembered" $? "rows $n0 -> $n1 pref=$(cat "$pref" 2>/dev/null)"
sg --op=close > /dev/null
o=$(sg --op=open)
[ "$(jget "$o" 'd["include_unbound"]')" = true ]
hl_check "G21 a reopened guide keeps the toggle" $?
sg --op=state --unbound=0 > /dev/null

# ---- Run performs the row in the terminal window --------------------------------
tabs() { cli +list --json 2>/dev/null | python3 -I -c 'import json,sys; d=json.load(sys.stdin)["data"]; print(sum(len(w["tabs"]) for w in d["windows"]))'; }
t0=$(tabs)
o=$(sg --op=run --query='new tab')
two() { [ "$(tabs)" = $((t0 + 1)) ]; }
hl_wait_for 5 two
r=$?
[ "$(jget "$o" 'd["ran"]')" = true ] && [ "$(jget "$o" 'd["last_run"]')" = new_tab ] && [ $r = 0 ]
hl_check "G22 Return on New Tab opens a tab in the terminal window" $? "ran=$(jget "$o" 'd["ran"]') last=$(jget "$o" 'd["last_run"]') tabs $t0 -> $(tabs)"
o=$(sg --op=run --query=quit)
[ "$(jget "$o" 'd["ran"]')" = false ] && kill -0 "$APP" 2>/dev/null
hl_check "G23 Return on Quit does nothing (not runnable)" $? "ran=$(jget "$o" 'd["ran"]')"

# ---- a reloaded config shows up live ---------------------------------------------
printf '# custom\nkeybind = ctrl+alt+j=new_window\nkeybind = ctrl+shift+/=unbind\n' > "$dev"
cli +reload --config > /dev/null 2>&1
custom() { [ "$(jget "$(sg --op=state --query=)" 'd["customized"]')" -ge 2 ] 2>/dev/null; }
hl_wait_for 10 custom
r=$?
o=$(sg --op=state --query=)
k=$(row "$o" new_window keys)
[ $r = 0 ] && printf '%s' "$k" | grep -q 'Ctrl+Alt+J' && [ "$(row "$o" new_window customized)" = true ] \
    && [ "$(row "$o" show_keyboard_shortcuts unbound_by_user)" = true ]
hl_check "G24 after +reload the guide shows the rebind (CUSTOM) and the unbind, without reopening" $? "customized=$(jget "$o" 'd["customized"]') new_window=$k unbound=$(row "$o" show_keyboard_shortcuts unbound_by_user)"

# ---- the cheat sheet ---------------------------------------------------------------
o=$(sg --op=cheat-sheet)
f=$(jget "$o" 'd["cheat_sheet"]')
[ -f "$f" ] && grep -q 'Windows &amp; Tabs' "$f" && grep -q 'Ctrl+Alt+J' "$f"
hl_check "G25 Print Cheat Sheet writes every bound shortcut by category" $? "file=$f"

sg --op=close > /dev/null
o=$(sg --op=state)
printf '%s' "$o" | grep -q 'not open' && kill -0 "$APP" 2>/dev/null
hl_check "G26 closing the guide leaves the app running" $? "$o"

hl_finish "$L"
