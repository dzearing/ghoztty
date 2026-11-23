#!/usr/bin/env bash
# cli-reload.sh - L7e (T3369) acceptance for `+reload --config` against the
# GTK debug app: the app reads its config files again and applies them to the
# panes already open, answering the Mac's/win32's success (`--config` names no
# pane, so the shape is the shared verbs.reload body's). The observable is the
# pane's background colour, read back from the app's own render through the
# debug-only capture-pane seam (T3359): it is one value in the config file,
# changed on disk, and it only reaches an open pane if the reload happened.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\cli-reload.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), whose private
# XDG_CONFIG_HOME is where the config file is written - never the user's.
#
# Output: one PASS/FAIL line per check, then 'CLI RELOAD: ALL PASS' or
# 'CLI RELOAD: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="CLI RELOAD"

log=/tmp/cli-reload-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "C1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "C2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

cfg_dir="$XDG_CONFIG_HOME/ghostty"
cfg="$cfg_dir/config.ghostty"
mkdir -p "$cfg_dir"
# write_cfg <hex>: the whole config file, one background colour. Written to a
# temp file and renamed, so the app never reads a half-written file.
write_cfg() {
    printf 'background = %s\nbackground-opacity = 1\nwindow-padding-color = background\n' "$1" > "$cfg.tmp" && mv -f "$cfg.tmp" "$cfg"
}
write_cfg '#203040'

export SHELL=/bin/sh
# A shell that paints nothing, so the pane is the configured background.
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "C3 the app serves its socket" $?
pane=""; for _ in $(seq 1 50); do pane=$(hl_first_pane "$app"); [ -n "$pane" ] && break; sleep 0.2; done
[ -n "$pane" ]
hl_check "C4 the app lists its pane" $? "pane=$pane"

shot="$HL_RUNTIME/pane.png"
# fill_of <r> <g> <b>: the fraction of the pane's pixels that are that colour.
fill_of() {
    hl_screenshot "$pane" "$shot" > /dev/null || { echo 0; return; }
    hl_png_stats "$shot" "$1" "$2" "$3" | sed -n 's/.*match=\([0-9.]*\).*/\1/p'
}
# mostly <r> <g> <b>: over half the pane is that colour (retried by callers:
# a frame may predate the change).
mostly() { awk -v m="$(fill_of "$@")" 'BEGIN{exit !(m > 0.5)}'; }

hl_wait_for 15 mostly 32 48 64
hl_check "C5 the pane starts in the config file's background (#203040)" $? "fill=$(fill_of 32 48 64)"

# ---- the file changes; nothing has asked the app to look yet --------------
write_cfg '#a05010'
sleep 2
mostly 32 48 64
hl_check "C6 editing the file alone does not change the open pane (no reload yet)" $? "old=$(fill_of 32 48 64) new=$(fill_of 160 80 16)"

o=$(cli +reload --config 2>&1); rc=$?
[ $rc = 0 ] && ! printf '%s' "$o" | grep -qi 'not served\|T3369\|error'
hl_check "C7 +reload --config succeeds (no 'not served' sentence)" $? "rc=$rc $o"
hl_wait_for 10 mostly 160 80 16
hl_check "C8 the open pane now shows the file's new background (#a05010)" $? "new=$(fill_of 160 80 16) old=$(fill_of 32 48 64)"

# ---- a second round, so C8 is not a one-off ---------------------------------
write_cfg '#105020'
o=$(cli +reload --config 2>&1); rc=$?
hl_wait_for 10 mostly 16 80 32
r=$?
[ $rc = 0 ] && [ $r = 0 ]
hl_check "C9 a second edit + reload applies too (#105020)" $? "rc=$rc $o fill=$(fill_of 16 80 32)"

# ---- a config with a mistake in it still reloads, as on Mac and win32 -------
# (a bad line is a diagnostic, not a failed reload; the good lines apply)
printf 'background = #405060\nthis-is-not-a-key = 1\n' > "$cfg.tmp" && mv -f "$cfg.tmp" "$cfg"
o=$(cli +reload --config 2>&1); rc=$?
hl_wait_for 10 mostly 64 80 96
r=$?
[ $rc = 0 ] && [ $r = 0 ]
hl_check "C10 a config with an unknown key still reloads and applies its good lines" $? "rc=$rc $o fill=$(fill_of 64 80 96)"

# ---- the refusals stay what verbs.reload says (R28 of viewer-reload.sh) ----
o=$(cli +reload --config --target=anything 2>&1); rc=$?
[ $rc != 0 ] && printf '%s' "$o" | grep -q -- "--config cannot be combined with --target"
hl_check "C11 +reload --config --target is still refused" $? "rc=$rc $o"

# ---- a new pane opened after the reload gets the reloaded config ------------
o=$(cli +new-window --target=after 2>&1)
hl_check "C12 a window opens after the reload" $? "$o"
sleep 1
shot2="$HL_RUNTIME/after.png"
after_fill() {
    hl_screenshot after "$shot2" > /dev/null || return 1
    awk -v m="$(hl_png_stats "$shot2" 64 80 96 | sed -n 's/.*match=\([0-9.]*\).*/\1/p')" 'BEGIN{exit !(m > 0.5)}'
}
hl_wait_for 15 after_fill
hl_check "C13 the new window starts in the reloaded background (#405060)" $? "$(hl_png_stats "$shot2" 64 80 96 2>&1)"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "C14 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- app log (config lines) ----"
    grep -iE 'config|reload|error' "$APP_LOG" 2>/dev/null | tail -40
fi

hl_finish "$L"
