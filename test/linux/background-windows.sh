#!/usr/bin/env bash
# background-windows.sh - T3571 acceptance for "what stops when no one is
# looking" on the GTK debug app (docs/reference/background-windows.md; Linux
# L11i): a pane nobody can see - a background tab, a minimized or suspended
# window - stops building frames and catches up once when it shows; a hidden
# window holds a changing title and lands it when it shows, or within 5s; and
# state (+set-state, +list) never pauses.
#
# Keys reach the app through the debug-only `press-key` seam, and the
# compositor's toplevel state through the debug-only `pane-seen` seam's
# `--toplevel=` stand-in: the headless Weston this runs in (no seat, no shell
# to minimize into) never minimizes or suspends a window. B1 records what the
# compositor itself reports.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\background-windows.sh
#
# NEGATIVE=1 measures the "hidden" CPU with the busy pane's tab selected, so
# it is seen the whole time, and must FAIL B4 (1 failure): the measurement
# can tell a paused pane from a drawing one.
# Output: one PASS/FAIL line per check, then 'BACKGROUND WINDOWS: ALL PASS'
# or 'BACKGROUND WINDOWS: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="BACKGROUND WINDOWS"

log=/tmp/background-windows-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "B0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "B0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
cat > "$cfg_dir/config.ghostty" <<'CFG'
window-width = 100
window-height = 30
background = 000000
foreground = ffffff
cursor-style-blink = false
keybind = ctrl+shift+f3=new_tab
keybind = ctrl+shift+f1=goto_tab:1
keybind = ctrl+shift+f2=goto_tab:2
CFG

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "B0c the app serves its socket" $?

p1=$(hl_first_pane "$app")
seen() { hl_ipc pane-seen "--target=$p1" "$@"; }
# q <json> <python expr over r (the data object)>
q() {
    printf '%s' "$1" | python3 -I -c '
import json, sys
r = json.loads(sys.stdin.read()).get("data") or {}
P = {p["pane"]: p for p in r.get("panes", [])}
W = r.get("window") or {}
print(eval(sys.argv[1]))' "$2" 2>/dev/null
}
press() { hl_ipc press-key "--target=$1" "--key=$2" > /dev/null 2>&1; }
type_line() { cli +send-keys --target="$1" "$2" Enter > /dev/null 2>&1; }
ticks() { awk '{ print $14 + $15 }' "/proc/$APP/stat" 2>/dev/null; }

# ---- 1. one window, one pane: everything is seen ---------------------------
sleep 0.5
r=$(seen)
[ "$(q "$r" 'W["seen"] and P["'"$p1"'"]["seen"]')" = True ]; rc=$?
hl_check "B1 a shown window and its pane read seen (compositor reports minimized=$(q "$r" 'W["reported"]["minimized"]') suspended=$(q "$r" 'W["reported"]["suspended"]'))" $rc "$r"

# ---- 2. a background tab is not seen ---------------------------------------
press "$p1" ctrl+shift+f3
p2=""
for _ in $(seq 1 50); do
    r=$(seen)
    p2=$(q "$r" '[p["pane"] for p in r["panes"] if p["pane"] != "'"$p1"'"][0] if len(r["panes"]) > 1 else ""')
    [ -n "$p2" ] && [ "$(q "$r" 'not P["'"$p1"'"]["seen"] and P["'"$p2"'"]["seen"]')" = True ] && break
    sleep 0.2
done
[ -n "$p2" ] && [ "$(q "$r" 'not P["'"$p1"'"]["seen"] and not P["'"$p1"'"]["mapped"] and P["'"$p2"'"]["seen"]')" = True ]
hl_check "B2 a new tab hides the first tab's pane and shows its own" $? "$r"
grep -q "seen: pane=$p1 seen=false" "$APP_LOG"
hl_check "B3 the core was told the background pane is hidden (log)" $? "$(grep -m3 'seen: ' "$APP_LOG" | tr '\n' '|')"

# ---- 3. a busy pane costs less hidden than shown ---------------------------
busy_py=$(mktemp /tmp/background-windows-XXXXXX.py)
cat > "$busy_py" <<'PY'
import random, string, sys, time
rows = 28
while True:
    sys.stdout.write("\x1b[H" + "\r\n".join("".join(random.choice(string.ascii_letters) for _ in range(90)) for _ in range(rows)))
    sys.stdout.flush()
    time.sleep(0.01)
PY
type_line "$p1" "python3 -I $busy_py"
sleep 1.5
if [ "${NEGATIVE:-0}" = 1 ]; then press "$p2" ctrl+shift+f1; sleep 0.5; fi
t0=$(ticks); sleep 4; t1=$(ticks)
hidden=$((t1 - t0))
press "$p2" ctrl+shift+f1
for _ in $(seq 1 30); do [ "$(q "$(seen)" 'P["'"$p1"'"]["seen"]')" = True ] && break; sleep 0.1; done
sleep 0.5
t0=$(ticks); sleep 4; t1=$(ticks)
shown=$((t1 - t0))
[ "$shown" -gt 0 ] && [ $((hidden * 2)) -le "$shown" ]
hl_check "B4 the busy pane hidden cost at most half its shown cost (hidden $hidden ticks vs shown $shown ticks over 4s)" $? "hidden=$hidden shown=$shown"
cli +send-keys --target="$p1" C-c > /dev/null 2>&1
sleep 0.3

# ---- 4. a pane catches up once when shown -----------------------------------
type_line "$p1" "clear"
sleep 0.5
shot=/tmp/background-windows-catchup.png
hl_screenshot "$p1" "$shot" > /dev/null
base=$(hl_png_stats "$shot" 255 255 255 2>&1)
base_white=$(printf '%s' "$base" | sed -n 's/.*match=\([0-9.]*\).*/\1/p')
press "$p1" ctrl+shift+f2
for _ in $(seq 1 30); do [ "$(q "$(seen)" 'P["'"$p1"'"]["seen"]')" = False ] && break; sleep 0.1; done
# While hidden: fill its screen with reverse-video blanks (white on black).
type_line "$p1" "clear; i=0; while [ \$i -lt 26 ]; do printf '\\\\033[7m%100s\\\\033[0m\\\\n' ''; i=\$((i+1)); done"
sleep 1
press "$p2" ctrl+shift+f1
for _ in $(seq 1 30); do [ "$(q "$(seen)" 'P["'"$p1"'"]["seen"]')" = True ] && break; sleep 0.1; done
sleep 0.5
hl_screenshot "$p1" "$shot" > /dev/null
stats=$(hl_png_stats "$shot" 255 255 255 2>&1)
white=$(printf '%s' "$stats" | sed -n 's/.*match=\([0-9.]*\).*/\1/p')
# The cleared pane is nearly all black; the rows written while hidden cover
# most of it in white (the prompt and line wrap leave the rest).
python3 -I -c "import sys; sys.exit(0 if float('${base_white:-1}') <= 0.05 and float('${white:-0}') >= 0.3 else 1)"
hl_check "B5 shown again, the pane draws what was written while it was hidden (white ${base_white:-?} before hiding -> ${white:-?} after showing)" $? "before: $base | after: $stats"

# ---- 5. a minimized window: panes hidden, title held, state goes on ---------
r=$(seen --toplevel=minimized)
[ "$(q "$r" 'not W["seen"] and all(not p["seen"] for p in r["panes"])')" = True ]
hl_check "B6 a minimized window hides every pane in it" $? "$r"

title_osc() { cli +send-keys --target="$p1" "printf '\\\\033]2;$1\\\\007'" Enter > /dev/null 2>&1; }
title_osc held-one
sleep 0.5
title_osc held-two
held=""
for _ in $(seq 1 20); do
    r=$(seen); held=$(q "$r" 'W["held_title"]')
    [ "$held" = held-two ] && break
    sleep 0.1
done
[ "$held" = held-two ] && [ "$(q "$r" 'W["title"]')" != held-two ]
hl_check "B7 a hidden window holds a title that changed within 5s of the last one" $? "$r"
lt=$(cli +list --json 2>/dev/null | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["data"]["windows"][0]["title"])' 2>/dev/null)
[ "$lt" = held-two ]
hl_check "B8 +list reads the held title at once" $? "list title=$lt"

cli +set-state --target="$p1" --state=busy > /dev/null 2>&1
sleep 0.3
r=$(seen)
case "$(q "$r" 'W["held_title"] or W["title"]')" in *"(busy)"*) true ;; *) false ;; esac
hl_check "B9 state never pauses: +set-state busy reaches a minimized window's title" $? "$r"
cli +set-state --target="$p1" --state=idle > /dev/null 2>&1

sleep 6
r=$(seen)
[ "$(q "$r" 'W["held_title"]')" = None ] && [ "$(q "$r" 'W["title"]')" = held-two ]
hl_check "B10 a held title lands within 5s while the window stays hidden" $? "$r"

title_osc held-three
for _ in $(seq 1 20); do [ "$(q "$(seen)" 'W["held_title"]')" = held-three ] && break; sleep 0.1; done
r=$(seen --toplevel=shown)
[ "$(q "$r" 'W["seen"] and W["held_title"] is None and W["title"] == "held-three" and P["'"$p1"'"]["seen"] and not P["'"$p2"'"]["seen"]')" = True ]
hl_check "B11 shown again: the held title lands at once and the selected tab's pane is seen" $? "$r"

r=$(seen --toplevel=suspended)
[ "$(q "$r" 'not W["seen"] and all(not p["seen"] for p in r["panes"])')" = True ]
hl_check "B12 a suspended (covered) window hides every pane in it" $? "$r"
r=$(seen --toplevel=real)
[ "$(q "$r" 'W["seen"] and P["'"$p1"'"]["seen"]')" = True ]
hl_check "B13 back to the compositor's own state, the window is seen again" $? "$r"

rm -f "$busy_py" "$shot"
hl_finish "$L"
