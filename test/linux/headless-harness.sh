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
hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c "tty > $mark; sleep 60"
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

hl_finish "HEADLESS HARNESS"
