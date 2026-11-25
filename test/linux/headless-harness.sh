#!/usr/bin/env bash
# headless-harness.sh - T3333 (Linux L4) acceptance for test/linux/lib/headless.sh,
# the harness every Linux GUI test runs inside. Run it ONLY through the wrapper:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\headless-harness.sh
#
# It proves the harness both WORKS (the app reaches the private compositor) and
# REFUSES (a WSLg-shaped environment never gets a launch), so the rule "a Linux
# GUI test never opens a window on the user's screen" is a checked property,
# not a habit. Builds the GTK debug app first (the committed HEAD, -Repo clone).
#
# H22-H25 (T3620) cover hl_start_seat, the headless sway that HAS a wl_seat.
#
# Output: PASS/FAIL per check, then 'HEADLESS HARNESS: ALL PASS' or
# 'HEADLESS HARNESS: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
# wsl-run.ps1 inlines a -CommandFile as the step's text, so $0 is not this
# file; the step's cwd is the repo root.
lib="$PWD/test/linux/lib/headless.sh"
[ -f "$lib" ] || { echo "run from the repo root (lib not at $lib)"; echo "HEADLESS HARNESS: 1 FAILURE(S)"; exit 1; }
. "$lib"
hl_check_init

# ---- H1-H3: refusals, before anything is started ------------------------------
# H1: a WSLg-shaped environment (what a wsl-run step inherits) is named as unsafe.
why=$(DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir GDK_BACKEND= bash -c ". '$lib'; hl_isolation_problem")
[ -n "$why" ]
hl_check "H1 a WSLg environment is reported as not isolated" $? "$why"

# H2: hl_launch under that environment exits 4 and never runs the command.
marker=$(mktemp -u /tmp/hl-h2.XXXXXX)
DISPLAY=:0 XDG_RUNTIME_DIR=/mnt/wslg/runtime-dir bash -c ". '$lib'; hl_launch x touch '$marker'" 2>/tmp/hl-h2.err
rc=$?
[ $rc = 4 ] && [ ! -e "$marker" ] && grep -q 'HEADLESS REFUSED' /tmp/hl-h2.err
hl_check "H2 hl_launch refuses (exit 4) and launches nothing outside the harness" $? "rc=$rc $(head -1 /tmp/hl-h2.err)"
rm -f "$marker" /tmp/hl-h2.err

# H3: a harness that is up but has DISPLAY put back is refused too (each launch re-checks).
out=$(bash -c ". '$lib'; hl_start || exit 9; export DISPLAY=:0; hl_launch x true; echo LAUNCHED" 2>&1)
rc=$?
[ $rc = 4 ] && ! printf '%s' "$out" | grep -q LAUNCHED
hl_check "H3 a launch is refused when DISPLAY reappears after hl_start" $? "rc=$rc"

# ---- H4: the PATH trap --------------------------------------------------------
fake=$(mktemp -d /tmp/hl-fake.XXXXXX); mkdir -p "$fake/zig-out/bin"
printf 'MZ\x90\x00not-an-elf' > "$fake/zig-out/bin/ghoztty"; chmod +x "$fake/zig-out/bin/ghoztty"
! hl_ghoztty "$fake" >/dev/null 2>&1
hl_check "H4 hl_ghoztty refuses a binary that is not a Linux ELF" $?
rm -rf "$fake"

# ---- build ---------------------------------------------------------------------
log=/tmp/headless-harness-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "H5 the GTK debug build succeeds" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "HEADLESS HARNESS"
app=$(hl_ghoztty)
hl_check "H6 hl_ghoztty names the Linux build by absolute path" $? "$app"

# ---- H7-H11: the harness works ------------------------------------------------
hl_start
hl_check "H7 hl_start brings up a private headless Weston" $?
why=$(hl_isolation_problem)
[ -z "$why" ] && case "$XDG_RUNTIME_DIR" in /tmp/ghoztty-hl.*) true ;; *) false ;; esac
hl_check "H8 the environment is isolated (private runtime dir, no DISPLAY, GDK_BACKEND=wayland)" $? "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR ${why}"

before=$(hl_weston_sockets)
mark="$HL_RUNTIME/shell-ran"
# The pane paints itself pure red (24-bit background + erase display), so
# H16-H21's screenshots have something exact to find.
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c "tty > $mark; printf '\\033[48;2;255;0;0m\\033[2J\\033[H'; sleep 60"
hl_wait_for 20 test -s "$mark"
grep -q '^/dev/pts/' "$mark" 2>/dev/null
hl_check "H9 the app's shell ran on a pty inside the harness" $? "mark=$(cat "$mark" 2>/dev/null)"
after=$(hl_weston_sockets)
[ "$after" -gt "$before" ]
hl_check "H10 the app connected to the PRIVATE Weston (its socket fds $before -> $after)" $?
hl_env_is_private "$APP"
hl_check "H11 the app's own environment names only the private compositor" $?
! grep -qE '^(panic|thread [0-9]+ panic)|reached unreachable' "$APP_LOG"
hl_check "H12 no panic in the app log" $?

# ---- H16-H21: screenshots from the app's own render (T3359) ---------------------
# Weston headless offers no capture, so hl_screenshot asks the app (the
# debug-only capture-pane seam, win32's wire shape).
hl_wait_for 30 test -S "$(hl_socket)"
pane=""; for _ in $(seq 1 50); do pane=$(hl_first_pane "$app"); [ -n "$pane" ] && break; sleep 0.2; done
shot="$HL_RUNTIME/pane.png"
red_fill() {   # retry: the first frame may predate the shell's paint
    reply=$(hl_screenshot "$pane" "$shot") || return 1
    stats=$(hl_png_stats "$shot" 255 0 0) || return 1
    awk -v m="$(printf '%s' "$stats" | sed -n 's/.*match=\([0-9.]*\).*/\1/p')" 'BEGIN{exit !(m > 0.5)}'
}
hl_wait_for 15 red_fill
rc=$?
hl_check "H16 capture-pane of a terminal pane writes a PNG of the pane's own render" "$( [ -s "$shot" ] && head -c4 "$shot" | grep -q PNG; echo $?)" "pane=$pane ${reply:-no reply}"
hl_check "H17 the picture shows what the pane drew (over half its pixels are the shell's red)" $rc "${stats:-}"
rw=$(printf '%s' "$reply" | sed -n 's/.*"width":\([0-9]*\).*/\1/p'); rh=$(printf '%s' "$reply" | sed -n 's/.*"height":\([0-9]*\).*/\1/p')
printf '%s' "$stats" | grep -q "^w=$rw h=$rh "
hl_check "H18 the reply's width/height are the PNG's own" $? "reply=${rw}x${rh} png=${stats%% colors*}"

wshot="$HL_RUNTIME/window.png"
wreply=$(hl_screenshot "$pane" "$wshot" --window); rc=$?
wstats=$(hl_png_stats "$wshot" 255 0 0 2>/dev/null)
ww=$(printf '%s' "$wstats" | sed -n 's/^w=\([0-9]*\).*/\1/p'); wh=$(printf '%s' "$wstats" | sed -n 's/.* h=\([0-9]*\).*/\1/p')
px=$(printf '%s' "$reply" | sed -n 's/.*"x":\(-\{0,1\}[0-9]*\).*/\1/p'); py=$(printf '%s' "$reply" | sed -n 's/.*"y":\(-\{0,1\}[0-9]*\).*/\1/p')
[ $rc = 0 ] && printf '%s' "$wreply" | grep -q '"scope":"window"' \
    && [ "${ww:-0}" -ge "${rw:-1}" ] && [ "${wh:-0}" -gt "${rh:-1}" ] \
    && [ "${px:--1}" -ge 0 ] && [ "${py:--1}" -ge 0 ] \
    && [ $(( px + rw )) -le "$ww" ] && [ $(( py + rh )) -le "$wh" ]
hl_check "H19 --window captures the whole window, and the pane's x/y place it inside" $? "window=${ww}x${wh} pane=${rw}x${rh}@${px},${py} ${wstats}"

sshot="$HL_RUNTIME/sized.png"
hl_screenshot "$pane" "$sshot" --width=200 --height=100 > /dev/null
sstats=$(hl_png_stats "$sshot" 255 0 0 2>&1)
printf '%s' "$sstats" | grep -q '^w=200 h=100 ' \
    && awk -v m="$(printf '%s' "$sstats" | sed -n 's/.*match=\([0-9.]*\).*/\1/p')" 'BEGIN{exit !(m > 0.5)}'
hl_check "H20 --width/--height render the whole pane, scaled, at the size asked" $? "$sstats"

nf=$(hl_ipc capture-pane --target=no-such-pane "--path=$HL_RUNTIME/x.png")
np=$(hl_ipc capture-pane "--target=$pane")
printf '%s' "$nf" | grep -q "not found" && printf '%s' "$np" | grep -q -- "--path is required" && [ ! -e "$HL_RUNTIME/x.png" ]
hl_check "H21 capture-pane refuses an unknown pane and a missing --path, writing nothing" $? "$nf | $np"

# ---- H13: two harnesses never share a socket ------------------------------------
other=$(bash -c ". '$lib'; hl_start >/dev/null 2>&1 || exit 9; echo \"\$XDG_RUNTIME_DIR/\$WAYLAND_DISPLAY\"")
[ -n "$other" ] && [ "$other" != "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]
hl_check "H13 a second harness gets its own runtime dir and socket" $? "$other"
[ -n "$other" ] && [ ! -e "$(dirname "$other")" ]
hl_check "H14 a harness that exits normally removes its runtime dir" $?

# ---- H15: a killed harness still cleans up ---------------------------------------
info=$(mktemp /tmp/hl-h15.XXXXXX)
bash -c ". '$lib'; hl_start || exit 9; hl_launch S sleep 300; echo \"\$HL_RUNTIME \$HL_WESTON_PID \$S\" > '$info'; sleep 300 & wait \$!" &
child=$!
hl_wait_for 10 test -s "$info"
read -r crt cwp csl < "$info"
kill -TERM "$child"; wait "$child" 2>/dev/null
sleep 0.5
gone=0
[ -n "${crt:-}" ] && [ ! -e "$crt" ] || gone=1
[ -n "${cwp:-}" ] && ! kill -0 "$cwp" 2>/dev/null || gone=1
[ -n "${csl:-}" ] && ! kill -0 "$csl" 2>/dev/null || gone=1
hl_check "H15 a SIGTERMed harness kills its app and Weston and removes its dir" $gone "dir=${crt:-?} weston=${cwp:-?} app=${csl:-?}"
rm -f "$info"

# ---- H22-H25: the seat compositor, hl_start_seat (T3620) --------------------------
# gtk_has_seat: 'yes' when a GTK 4 client on the current WAYLAND_DISPLAY is given
# a wl_seat (a selection can only be offered to other clients through one).
gtk_has_seat() {
    timeout 15 python3 -I -c 'import gi; gi.require_version("Gdk","4.0"); gi.require_version("Gtk","4.0")
from gi.repository import Gdk, Gtk
Gtk.init(); d = Gdk.Display.get_default()
print("yes" if d is not None and d.get_default_seat() is not None else "no")' 2>/dev/null
}
export -f gtk_has_seat
hl_key_serial 2> /tmp/hl-h22.err
rc=$?
[ $rc != 0 ] && grep -q 'needs hl_start_seat' /tmp/hl-h22.err
hl_check "H22 hl_key_serial refuses under the Weston harness (no seat to type into)" $? "rc=$rc $(head -1 /tmp/hl-h22.err)"
s=$(gtk_has_seat)
[ "$s" = no ]
hl_check "H23 control: a GTK client under the default Weston harness gets NO seat" $? "seat=${s:-?}"
seat=$(bash -c ". '$lib'; hl_start_seat >/dev/null 2>&1 || exit 9; why=\$(hl_isolation_problem); echo \"\${why:-isolated}|\$WAYLAND_DISPLAY|\$(gtk_has_seat)\"")
[ "${seat%%|*}" = isolated ] && [ "${seat##*|}" = yes ] && case "$seat" in *'|wayland-0|'*) false ;; *) true ;; esac
hl_check "H24 hl_start_seat comes up isolated, on a private socket, and a GTK client there HAS a seat" $? "$seat"
info=$(mktemp /tmp/hl-h25.XXXXXX)
bash -c ". '$lib'; hl_start_seat || exit 9; hl_launch S sleep 300; echo \"\$HL_RUNTIME \$HL_WESTON_PID \$S\" > '$info'; sleep 300 & wait \$!" &
child=$!
hl_wait_for 10 test -s "$info"
read -r crt cwp csl < "$info"
kill -TERM "$child"; wait "$child" 2>/dev/null
sleep 0.5
gone=0
[ -n "${crt:-}" ] && [ ! -e "$crt" ] || gone=1
[ -n "${cwp:-}" ] && ! kill -0 "$cwp" 2>/dev/null || gone=1
[ -n "${csl:-}" ] && ! kill -0 "$csl" 2>/dev/null || gone=1
hl_check "H25 a SIGTERMed seat harness kills its app and sway and removes its dir" $gone "dir=${crt:-?} sway=${cwp:-?} app=${csl:-?}"
rm -f "$info" /tmp/hl-h22.err

hl_finish "HEADLESS HARNESS"
