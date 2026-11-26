#!/usr/bin/env bash
# frame-release.sh - T3645 acceptance for "panes that are not drawing give
# back their frames" on the GTK debug app (docs/reference/memory.md, GTK
# half): a terminal pane that has drawn nothing for 3 s (idle), or that
# nobody can see (a background tab: hidden), releases its swap-chain render
# targets and font atlas copies; the picture stays while it is idle; and the
# first frame back draws in full. GTK draws on the main thread through the
# pane's GtkGLArea, so the release runs there (`queueFrameRelease`).
#
# Oracles: the debug-only `pane-seen` seam's per-pane `frames` (what the
# frames hold: target_bytes, atlas_bytes, released), the app's log lines, the
# app's private memory (it runs on Mesa's software rasterizer,
# LIBGL_ALWAYS_SOFTWARE=1, so GL textures are its own memory, as in
# pane-close-memory.sh), and the pane's picture from its own render
# (capture-pane).
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\frame-release.sh
#
# NEGATIVE=1 runs the app with GHOZTTY_IDLE_FRAME_RELEASE=0, which turns the
# idle release off, and must FAIL R1 and R2 alone (2 failures): the oracle can
# tell released frames from held ones.
# Output: one PASS/FAIL line per check, then 'FRAME RELEASE: ALL PASS' or
# 'FRAME RELEASE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="FRAME RELEASE"

log=/tmp/frame-release-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "R0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "R0b a private headless Weston is up" $?
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
export LIBGL_ALWAYS_SOFTWARE=1
if [ "${NEGATIVE:-0}" = 1 ]; then export GHOZTTY_IDLE_FRAME_RELEASE=0; fi
hl_launch APP "$app" --gtk-single-instance=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "R0c the app serves its socket" $?

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
fr() { q "$(seen)" 'P["'"$1"'"]["frames"]["'"$2"'"]'; }
press() { hl_ipc press-key "--target=$1" "--key=$2" > /dev/null 2>&1; }
type_line() { cli +send-keys --target="$1" "$2" Enter > /dev/null 2>&1; }
priv_kb() { awk '/^Private_(Clean|Dirty):/ { s += $2 } END { print s + 0 }' "/proc/$APP/smaps_rollup" 2>/dev/null || echo 0; }
white_of() { hl_png_stats "$1" 255 255 255 2>&1 | sed -n 's/.*match=\([0-9.]*\).*/\1/p'; }
# A screen of reverse-video blank rows: white on the black background.
fill_white() { type_line "$1" "clear; i=0; while [ \$i -lt 26 ]; do printf '\\\\033[7m%100s\\\\033[0m\\\\n' ''; i=\$((i+1)); done"; }
shot=/tmp/frame-release-shot.png

grep -q 'wslg: GPU driver left to the environment' "$APP_LOG" && ! grep -q 'd3d12\|dxcore' "/proc/$APP/maps"
hl_check "R0d the app renders on Mesa's software rasterizer, so GL memory is the app's own" $? "$(grep -m2 'wslg:' "$APP_LOG" | tr '\n' '|')"

# ---- 1. an idle pane on screen gives its frames back, the picture stays ------
fill_white "$p1"
sleep 0.5
# Drawing now: the frames hold real targets.
held=$(fr "$p1" target_bytes)
rel=""
for _ in $(seq 1 40); do rel=$(fr "$p1" released); [ "$rel" = True ] && break; sleep 0.2; done
after=$(fr "$p1" target_bytes)
[ "$rel" = True ] && [ "${after:-99}" -le 12 ] && grep -q 'released idle render targets' "$APP_LOG"
hl_check "R1 a pane that drew nothing for 3s releases its frames (targets ${held:-?} -> ${after:-?} bytes; log: $(grep -m1 -o 'released idle render targets.*' "$APP_LOG"))" $? "$(seen)"

hl_screenshot "$p1" "$shot" > /dev/null
w=$(white_of "$shot")
python3 -I -c "import sys; sys.exit(0 if float('${w:-0}') >= 0.3 else 1)" && [ "$rel" = True ]
hl_check "R2 released while idle, the pane still shows its last picture (white ${w:-?})" $? "released=$rel white=$w"

# ---- 2. the first frame back draws in full -----------------------------------
type_line "$p1" "clear"
back=""
for _ in $(seq 1 20); do back=$(fr "$p1" released); [ "$back" = False ] && break; sleep 0.1; done
sleep 0.3
hl_screenshot "$p1" "$shot" > /dev/null
w=$(white_of "$shot")
[ "$back" = False ] && python3 -I -c "import sys; sys.exit(0 if float('${w:-1}') <= 0.05 else 1)"
hl_check "R3 new output after an idle release draws in full (released=$back, white ${w:-?} after clear)" $? "$(seen)"

# ---- 3. a background tab's busy pane gives its frames back -----------------
press "$p1" ctrl+shift+f3
p2=""
for _ in $(seq 1 50); do
    r=$(seen)
    p2=$(q "$r" '[p["pane"] for p in r["panes"] if p["pane"] != "'"$p1"'"][0] if len(r["panes"]) > 1 else ""')
    [ -n "$p2" ] && [ "$(q "$r" 'P["'"$p2"'"]["seen"]')" = True ] && break
    sleep 0.2
done
press "$p2" ctrl+shift+f1
for _ in $(seq 1 30); do [ "$(q "$(seen)" 'P["'"$p1"'"]["seen"]')" = True ] && break; sleep 0.1; done

busy_py=$(mktemp /tmp/frame-release-XXXXXX.py)
cat > "$busy_py" <<'PY'
import random, string, sys, time
rows = 28
while True:
    sys.stdout.write("\x1b[H" + "\r\n".join("".join(random.choice(string.ascii_letters) for _ in range(90)) for _ in range(rows)))
    sys.stdout.flush()
    time.sleep(0.01)
PY
type_line "$p1" "python3 -I $busy_py"
# Let the second tab's pane go idle and give its frames back, so only the
# busy pane holds targets when it is sampled.
for _ in $(seq 1 50); do [ "$(fr "$p2" released)" = True ] && break; sleep 0.2; done
sleep 1
busy_t=$(fr "$p1" target_bytes); busy_a=$(fr "$p1" atlas_bytes); busy_rel=$(fr "$p1" released)
m_shown=$(priv_kb)
press "$p1" ctrl+shift+f2
hid=""
for _ in $(seq 1 40); do
    r=$(seen)
    [ "$(q "$r" 'not P["'"$p1"'"]["seen"] and P["'"$p1"'"]["frames"]["released"]')" = True ] && { hid=1; break; }
    sleep 0.2
done
hid_t=$(fr "$p1" target_bytes)
[ -n "$hid" ] && [ "$busy_rel" = False ] && [ "${busy_t:-0}" -gt 100000 ] && [ "${hid_t:-99}" -le 12 ] && grep -q 'released hidden render targets' "$APP_LOG"
hl_check "R4 a busy pane sent to a background tab releases its frames (targets $busy_t -> ${hid_t:-?} bytes, atlases ${busy_a:-?} bytes; log: $(grep -m1 -o 'released hidden render targets.*' "$APP_LOG"))" $? "busy_rel=$busy_rel $(seen)"

# The second tab is on screen now and draws once, then goes idle again.
for _ in $(seq 1 50); do [ "$(fr "$p2" released)" = True ] && break; sleep 0.2; done
sleep 1
m_hidden=$(priv_kb)
drop=$((m_shown - m_hidden))
want=$(( (${busy_t:-0} + ${busy_a:-0}) / 1024 / 2 ))
[ "$want" -gt 0 ] && [ "$drop" -ge "$want" ]
hl_check "R5 the app's private memory drops by at least half of what the busy pane's frames held (${m_shown} -> ${m_hidden} KB, -${drop} KB; frames held $(( (${busy_t:-0} + ${busy_a:-0}) / 1024 )) KB)" $? "shown=$m_shown hidden=$m_hidden want=$want"

# ---- 4. shown again, the pane draws what it has now ------------------------
cli +send-keys --target="$p1" C-c > /dev/null 2>&1
sleep 0.3
fill_white "$p1"
sleep 1
press "$p2" ctrl+shift+f1
for _ in $(seq 1 30); do [ "$(q "$(seen)" 'P["'"$p1"'"]["seen"]')" = True ] && break; sleep 0.1; done
sleep 0.5
hl_screenshot "$p1" "$shot" > /dev/null
w=$(white_of "$shot")
python3 -I -c "import sys; sys.exit(0 if float('${w:-0}') >= 0.3 else 1)" && grep -q 'redrawing after a hidden release' "$APP_LOG"
hl_check "R6 shown again after a hidden release, the pane draws in full what was written while hidden (white ${w:-?})" $? "$(grep -m2 'redrawing after' "$APP_LOG" | tr '\n' '|')"

! grep -q 'frame release: could not make the GL context current\|could not release' "$APP_LOG"
hl_check "R7 no release failed (no GL context or release warnings in the log)" $? "$(grep -m3 'frame release:\|could not release' "$APP_LOG" | tr '\n' '|')"

rm -f "$busy_py" "$shot"
hl_finish "$L"
