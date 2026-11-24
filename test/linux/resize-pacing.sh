#!/usr/bin/env bash
# resize-pacing.sh - T3568 acceptance for terminal resize pacing on the GTK
# debug app (docs/reference/terminal-resize.md; Linux L11f): a divider drag
# reaches a running program as a few paced SIGWINCHes, not one per frame of
# the drag, and folding / unfolding a banner reaches it as exactly one each.
#
# The program is a SIGWINCH counter (python3) that logs the size it sees on
# every signal. The view is resized on every drag step - each step runs the
# stage's real gesture code through the debug-only `pane-stack` seam (the
# headless harness has no seat) and the reply's frame proves the pane moved -
# while the debounce in the shared core (src/termio/Thread.zig Coalesce:
# 100ms settle, 350ms cap) decides what the program is told.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\resize-pacing.sh
#
# NEGATIVE=1 drags in steps 250ms apart - longer than the settle - so every
# step reaches the program on its own, and must FAIL R6 (1 failure): the
# counter really counts, and R6 can tell a paced drag from a per-frame one.
# Output: one PASS/FAIL line per check, then 'RESIZE PACING: ALL PASS' or
# 'RESIZE PACING: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="RESIZE PACING"

STEPS=30; GAP=0; DX=8
if [ "${NEGATIVE:-0}" = 1 ]; then STEPS=8; GAP=0.25; DX=25; fi

log=/tmp/resize-pacing-build.log
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
printf 'macos-pane-min-width = 200\nwindow-width = 150\nwindow-height = 30\n' > "$cfg_dir/config.ghostty"

# The counter: one line per SIGWINCH, "<cols> <rows>", the size it read.
winch_py=$(mktemp /tmp/resize-pacing-XXXXXX.py)
winch_log=$(mktemp /tmp/resize-pacing-XXXXXX.log)
: > "$winch_log"
cat > "$winch_py" <<'PY'
import os, signal, sys
log = sys.argv[1]
def on_winch(sig, frame):
    c, r = os.get_terminal_size(0)
    with open(log, "a") as f:
        f.write("%d %d\n" % (c, r))
signal.signal(signal.SIGWINCH, on_winch)
sys.stdout.write("winch counter running\r\n")
sys.stdout.flush()
while True:
    signal.pause()
PY

export SHELL=/bin/sh
hl_launch APP "$app" --gtk-single-instance=false -e python3 -I "$winch_py" "$winch_log"
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "R0c the app serves its socket" $?

first=$(hl_first_pane "$app")
st() { hl_ipc pane-stack "--target=$first" "$@"; }
sq() {
    printf '%s' "$1" | python3 -I -c '
import json, sys
r = json.loads(sys.stdin.read()); s = r.get("stage") or {}
P = {p["pane"]: p for p in s.get("panes", [])}
D = [g for g in s.get("gutters", []) if g["kind"] == "divider"]
print(eval(sys.argv[1]))' "$2" 2>/dev/null
}
winches() { wc -l < "$winch_log" | tr -d ' '; }
# settled: wait until the counter has been quiet for 600ms (past any pending
# debounce), at most 6s.
settled() {
    local n last=-1 quiet=0
    for _ in $(seq 1 60); do
        n=$(winches)
        if [ "$n" = "$last" ]; then quiet=$((quiet + 1)); else quiet=0; fi
        [ $quiet -ge 6 ] && return 0
        last=$n; sleep 0.1
    done
    return 0
}

# ---- 1. a divider drag -----------------------------------------------------
cli +split --target="$first" --direction=right --name=p2 > /dev/null 2>&1
for _ in $(seq 1 50); do
    [ "$(sq "$(st)" 'len(D)')" = 1 ] && break
    sleep 0.2
done
settled
r=$(st)
[ "$(sq "$r" 'len(D)')" = 1 ]
hl_check "R1 two panes side by side with one divider between them" $? "$r"

w0=$(sq "$r" 'P["'"$first"'"]["frame"][2]')
cx=$(sq "$r" 'D[0]["rect"][0] + D[0]["rect"][2] // 2')
cy=$(sq "$r" 'D[0]["rect"][1] + D[0]["rect"][3] // 2')
before=$(winches)
[ -s "$winch_log" ] && sizes0=$(tail -1 "$winch_log") || sizes0=""

r=$(st "--press=$cx,$cy")
[ "$(sq "$r" 'r["press"]')" = divider ]
hl_check "R2 a press on the divider takes hold of it" $? "$r"

widths="$w0"
t0=$(date +%s%N)
for i in $(seq 1 $STEPS); do
    r=$(st "--drag=$((i * DX)),0")
    widths="$widths $(sq "$r" 'P["'"$first"'"]["frame"][2]')"
    [ "$GAP" = 0 ] || sleep "$GAP"
done
r=$(st "--release=$((STEPS * DX)),0")
t1=$(date +%s%N)
drag_ms=$(( (t1 - t0) / 1000000 ))
w1=$(sq "$r" 'P["'"$first"'"]["frame"][2]')
settled
after=$(winches)
n=$((after - before))
distinct=$(printf '%s\n' $widths | sort -u | wc -l | tr -d ' ')

[ "$w1" -gt "$w0" ] 2>/dev/null
hl_check "R3 the drag widened the pane ($w0 -> $w1 px)" $? "widths=$widths"
[ "$distinct" -ge $((STEPS * 2 / 3)) ]
hl_check "R4 the pane was laid out anew on the drag's frames ($distinct distinct widths over $STEPS steps)" $? "widths=$widths"
[ "$n" -ge 1 ] && [ "$(tail -1 "$winch_log")" != "$sizes0" ]
hl_check "R5 the program was told the new size ($n SIGWINCH, now $(tail -1 "$winch_log" 2>/dev/null))" $? "before=[$sizes0]"
# One SIGWINCH per 350ms cap window, plus the release's settle - and never
# anything like one per frame.
cap=$(( drag_ms / 350 + 2 ))
[ "$n" -le "$cap" ] && [ $((n * 3)) -le "$STEPS" ]
hl_check "R6 the drag reached the program paced: $n SIGWINCH for $STEPS frames over ${drag_ms}ms (at most $cap, and at most one per 3 frames)" $? "$(tr '\n' '|' < "$winch_log")"

# ---- 2. a banner fold and unfold -------------------------------------------
text='## Resize pacing\nthe body line\n- [x] one\n- [ ] two\n- [ ] three'
cli +set-banner --target="$first" "$text" > /dev/null 2>&1
for _ in $(seq 1 50); do
    [ "$(hl_ipc pane-banner "--target=$first" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["banner"]["collapsible"])' 2>/dev/null)" = True ] && break
    sleep 0.2
done
settled
rows_open=$(tail -1 "$winch_log" | cut -d' ' -f2)

before=$(winches)
hl_ipc pane-banner "--target=$first" --click=chevron > /dev/null
settled
n=$(( $(winches) - before ))
rows_shut=$(tail -1 "$winch_log" | cut -d' ' -f2)
[ "$n" = 1 ] && [ "$rows_shut" -gt "$rows_open" ] 2>/dev/null
hl_check "R7 folding the banner is one SIGWINCH, with the rows given back ($rows_open -> $rows_shut)" $? "n=$n"

before=$(winches)
hl_ipc pane-banner "--target=$first" --click=chevron > /dev/null
settled
n=$(( $(winches) - before ))
rows_back=$(tail -1 "$winch_log" | cut -d' ' -f2)
[ "$n" = 1 ] && [ "$rows_back" = "$rows_open" ]
hl_check "R8 unfolding it is one SIGWINCH, back to the expanded rows ($rows_back)" $? "n=$n"

grep -q 'resize pace=debounce' "$APP_LOG"
hl_check "R9 the core paced those resizes as a running program's (pace=debounce on the log)" $? "$(grep -m3 'resize pace=' "$APP_LOG" | tr '\n' '|')"

rm -f "$winch_py" "$winch_log"
hl_finish "$L"
