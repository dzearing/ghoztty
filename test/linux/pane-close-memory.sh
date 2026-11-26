#!/usr/bin/env bash
# pane-close-memory.sh - T3572 acceptance (Linux L11j, docs/reference/
# memory.md): closing a pane, a tab or a window on the GTK debug app gives
# back everything it held - its renderer and IO threads, its pty and other
# fds, its shell, its viewer's WebKit processes, and its memory, GL
# textures included.
#
# HOW. One app, one window that stays open the whole run (win32's
# pane-close-memory.ps1 shape). Each SCENARIO runs WARMUP cycles (one-time
# costs: font atlases, shader compiles, WebKit's shared processes, malloc
# arenas; 8 by default - measured over 30 split cycles, the app's private
# memory climbs ~15 MB in the first ten and then sits within noise, the
# shape of allocator and GTK caches filling, not of a per-pane leak, which
# would be ~6.5 MB a cycle forever), samples a BASELINE, runs CYCLES (12)
# more, samples the END, and asserts
# the growth per cycle, (end - baseline) / cycles, against a budget that is a
# small fraction of what one open pane costs (the PEAK sample, taken with
# cycle 1's pane open). Every close waits out `undo-timeout` (1 s here), so
# what is measured is the real teardown, not a pane parked for Ctrl+Shift+Z.
#
#   split   +split a terminal, let its shell start, +close it.
#   rapid   +split and +close at once: the close lands while the new pane's
#           renderer and IO threads are still starting.
#   tab     a new tab (new_tab keybind through the press-key seam), +close it.
#   window  +new-window --name, +close it (its only pane, so the window).
#   viewer  +split --view a markdown file, let it render, +close it - and its
#           WebKit web process must go with it.
#
# Sampled from /proc: the app's private memory (smaps_rollup Private_*),
# threads, fds, and its descendant processes (count and private memory).
# The app runs on Mesa's software rasterizer (LIBGL_ALWAYS_SOFTWARE=1), so
# every GL texture and buffer a pane holds lives in the app's own memory and
# a leaked render target shows up in M1; on the d3d12 driver the same memory
# sits on the Windows host where nothing here can read it. M6 reads the
# session agent's LIVE heap from its own allocator (T3646, the `heap:` lines
# a Debug agent writes to agent.log): private memory cannot tell a leaked
# session from the DebugAllocator keeping a page that one live slot pins.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\pane-close-memory.sh
#
# NEGATIVE=1 leaves every measured pane OPEN instead of closing it: the
# budget checks MUST go red, the proof that this meter can see a retained
# pane at all. SCENARIOS="split window" runs a subset; CYCLES / WARMUP
# override the counts; REPORT=1 prints every sample.
# Output: one PASS/FAIL line per check, then 'PANE CLOSE MEMORY: ALL PASS'
# or 'PANE CLOSE MEMORY: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="PANE CLOSE MEMORY"
CYCLES=${CYCLES:-12}
WARMUP=${WARMUP:-8}
SCENARIOS=${SCENARIOS:-split rapid tab window viewer}
NEG=${NEGATIVE:-0}

log=/tmp/pane-close-memory-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "P0 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "P0b a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
cat > "$cfg_dir/config.ghostty" <<'CFG'
window-width = 100
window-height = 30
undo-timeout = 1s
cursor-style-blink = false
keybind = ctrl+shift+f3=new_tab
CFG
md="$HL_RUNTIME/view.md"
printf '# Memory\n\nA viewer pane, opened and closed.\n\n- one\n- two\n' > "$md"

export SHELL=/bin/sh
export LIBGL_ALWAYS_SOFTWARE=1
hl_launch APP "$app" --gtk-single-instance=false
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "P0c the app serves its socket" $?
p1=$(hl_first_pane "$app")
grep -q 'wslg: GPU driver left to the environment' "$APP_LOG" && ! grep -q 'd3d12\|dxcore' "/proc/$APP/maps"
hl_check "P0d the app renders on Mesa's software rasterizer (no d3d12 driver mapped), so GL memory is the app's own" $? "$(grep -m2 'wslg:' "$APP_LOG" | tr '\n' '|') $(grep -o '/[^ ]*\(d3d12\|dxcore\|gallium\|swrast\)[^ ]*' "/proc/$APP/maps" | sort -u | tr '\n' ' ')"

# ---- sampling ----------------------------------------------------------------
descendants() {
    # every process under $1, breadth-first, not $1 itself
    local q="$1" out="" next p
    while [ -n "$q" ]; do
        next=""
        for p in $q; do
            for c in $(cat /proc/"$p"/task/*/children 2>/dev/null); do
                out="$out $c"; next="$next $c"
            done
        done
        q="$next"
    done
    echo "$out"
}
priv_kb() { awk '/^Private_(Clean|Dirty):/ { s += $2 } END { print s + 0 }' "/proc/$1/smaps_rollup" 2>/dev/null || echo 0; }
# The Debug agent's own count of heap bytes it has handed out and not had
# back (T3646, src/remote/agent/heap_stats.zig): the newest `heap:` line in
# its agent.log, or -1 when there is none (a release agent keeps no count).
# Private memory cannot tell a leak from the DebugAllocator pinning a page
# under one long-lived slot; this can.
agent_heap() {
    local v
    v=$(cat "${XDG_CONFIG_HOME:-/nonexistent}"/ghoztty/local-agent*/agent.log 2>/dev/null \
        | sed -n 's/.*(heap): .*live_bytes=\([0-9]*\).*/\1/p' | tail -1)
    echo "${v:--1}"
}
# sample -> "priv_kb threads fds procs proc_kb": the app's own private memory,
# threads and fds; then every process under the app (viewer web processes)
# and under the session agent (pane shells), and their private memory plus
# the agent's own (its per-session ring and emulator).
sample() {
    local d procs=0 pkb=0 p ag
    ag=$(hl_agent_pid)
    d="$(descendants "$APP") ${ag:+$(descendants "$ag")}"
    for p in $d; do procs=$((procs + 1)); pkb=$((pkb + $(priv_kb "$p"))); done
    [ -n "$ag" ] && pkb=$((pkb + $(priv_kb "$ag")))
    echo "$(priv_kb "$APP") $(ls /proc/"$APP"/task | wc -l) $(ls /proc/"$APP"/fd | wc -l) $procs $pkb $(agent_heap)"
}
# settle: let threads join, GL deletes land and malloc trim, then sample
settled() { sleep "${1:-1.5}"; sample; }

# Every pane's id and (when it has one) name, space separated.
panes() {
    cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
out = []
for w in d["windows"]:
    for t in w["tabs"]:
        for leaf in walk(t["splits"]):
            for k in ("id", "name"):
                if leaf.get(k): out.append(str(leaf[k]))
print(" ".join(sorted(set(out))))' 2>/dev/null
}
gone() { ! panes | tr ' ' '\n' | grep -qx "$1"; }

# One cycle of a scenario. $2 = cycle number; $3 = "peak" samples PEAK with
# the pane open. Leaves the pane open under
# NEGATIVE=1. Prints nothing; returns non-zero when the open itself failed.
cycle() {
    local kind="$1" n="$2" name="m-$1-$2" before after new
    case "$kind" in
        split)
            cli +split --target="$p1" --name="$name" > /dev/null 2>&1 || return 1
            sleep 0.8 ;;
        rapid)
            cli +split --target="$p1" --name="$name" > /dev/null 2>&1 || return 1 ;;
        window)
            cli +new-window --name="$name" > /dev/null 2>&1 || return 1
            sleep 0.8 ;;
        viewer)
            cli +split --target="$p1" --name="$name" --view="$md" > /dev/null 2>&1 || return 1
            sleep 1.5 ;;
        tab)
            before=$(panes)
            hl_ipc press-key "--target=$p1" --key=ctrl+shift+f3 > /dev/null 2>&1
            new=""
            for _ in $(seq 1 40); do
                after=$(panes)
                new=$(comm -13 <(echo "$before" | tr ' ' '\n' | sort) <(echo "$after" | tr ' ' '\n' | sort) | head -1)
                [ -n "$new" ] && break
                sleep 0.1
            done
            [ -n "$new" ] || return 1
            name="$new"
            sleep 0.8 ;;
    esac
    [ "${3:-}" = peak ] && PEAK=$(settled 1)
    [ "$NEG" = 1 ] && return 0
    cli +close --target="$name" > /dev/null 2>&1
    for _ in $(seq 1 40); do gone "$name" && break; sleep 0.1; done
    # past undo-timeout, so the parked pane is really freed
    sleep 1.3
}

per() { python3 -I -c "print(round(($2 - $1) / $3, 2))"; }
show() { [ "${REPORT:-0}" = 1 ] && echo "    $1: priv=$(echo "$2" | cut -d' ' -f1)KB threads=$(echo "$2" | cut -d' ' -f2) fds=$(echo "$2" | cut -d' ' -f3) procs=$(echo "$2" | cut -d' ' -f4) procKB=$(echo "$2" | cut -d' ' -f5) agentHeap=$(echo "$2" | cut -d' ' -f6)B"; return 0; }

summary=""
for kind in $SCENARIOS; do
    ok=1
    for i in $(seq 1 "$WARMUP"); do cycle "$kind" "w$i" || ok=0; done
    BASE=$(settled 2.5); show "$kind base" "$BASE"
    for i in $(seq 1 "$CYCLES"); do
        # the first measured cycle also samples PEAK, with its pane open
        cycle "$kind" "$i" "$([ "$i" = 1 ] && echo peak)" || ok=0
        [ "$i" = 1 ] && show "$kind peak" "$PEAK"
        [ "${REPORT:-0}" = 1 ] && show "$kind $i" "$(sample)"
    done
    END=$(settled 2.5); show "$kind end" "$END"
    hl_check "P1 $kind: every one of the $((CYCLES + WARMUP)) opens succeeded" $((1 - ok))
    set -- $BASE; b_priv=$1 b_thr=$2 b_fd=$3 b_procs=$4 b_pkb=$5 b_heap=$6
    set -- $END; e_priv=$1 e_thr=$2 e_fd=$3 e_procs=$4 e_pkb=$5 e_heap=$6
    set -- $PEAK; k_priv=$1 k_thr=$2 k_fd=$3 k_procs=$4 k_heap=$6
    pane_kb=$((k_priv - b_priv))
    m=$(per "$b_priv" "$e_priv" "$CYCLES")
    t=$(per "$b_thr" "$e_thr" "$CYCLES")
    f=$(per "$b_fd" "$e_fd" "$CYCLES")
    pr=$(per "$b_procs" "$e_procs" "$CYCLES")
    pm=$(per "$b_pkb" "$e_pkb" "$CYCLES")
    summary="$summary\n    $kind: one open pane ~${pane_kb}KB/$((k_thr - b_thr)) threads/$((k_fd - b_fd)) fds/$((k_procs - b_procs)) procs; per closed: ${m}KB ${t} threads ${f} fds ${pr} procs ${pm}KB in them, $(per "$b_heap" "$e_heap" "$CYCLES")B agent live heap"
    python3 -I -c "import sys; sys.exit(0 if $m <= 1024 else 1)"
    hl_check "M1 $kind: private memory per closed pane <= 1 MB (left ${m} KB; one open pane cost ~${pane_kb} KB)" $? "base=$BASE end=$END peak=$PEAK"
    python3 -I -c "import sys; sys.exit(0 if $t <= 0.5 else 1)"
    hl_check "M2 $kind: threads per closed pane <= 0.5 - every renderer/IO thread joined (left $t)" $? "base=$BASE end=$END"
    python3 -I -c "import sys; sys.exit(0 if $f <= 0.5 else 1)"
    hl_check "M3 $kind: fds per closed pane <= 0.5 - its pty and pipes closed (left $f)" $? "base=$BASE end=$END"
    python3 -I -c "import sys; sys.exit(0 if $pr <= 0.2 else 1)"
    hl_check "M4 $kind: child processes per closed pane <= 0.2 - its shell (and web process) ended (left $pr)" $? "base=$BASE end=$END"
    python3 -I -c "import sys; sys.exit(0 if $pm <= 1024 else 1)"
    hl_check "M5 $kind: child private memory per closed pane <= 1 MB (left ${pm} KB)" $? "base=$BASE end=$END"
    # T3646: the agent's LIVE heap (bytes its allocator handed out and did not
    # get back), the leak oracle M5 cannot be. M5's agent share climbs ~27 KB
    # a session in a Debug agent with nothing leaked, because the
    # DebugAllocator never reuses a freed slot and keeps a page while any slot
    # on it lives. One open session costs ~10 KB of live heap, so a session
    # left behind in any form - table entry, ring, buffers - breaks 1 KB.
    # -1 means the agent logged no count: the counter is gone, which fails.
    hp=$(per "$b_heap" "$e_heap" "$CYCLES")
    [ "$b_heap" -ge 0 ] && [ "$e_heap" -ge 0 ] && python3 -I -c "import sys; sys.exit(0 if $hp <= 1024 else 1)"
    hl_check "M6 $kind: the session agent's live heap per closed pane <= 1 KB - nothing of the session kept (left ${hp} B; one open pane held ~$((k_heap - b_heap)) B)" $? "base=$BASE end=$END peak=$PEAK"
    if [ "$NEG" = 1 ]; then
        # leave nothing open for the next scenario's baseline
        for v in $(panes); do [ "$v" = "$p1" ] || cli +close --target="$v" > /dev/null 2>&1; done
        sleep 2
    fi
done
printf "  measured:%b\n" "$summary"

kill -0 "$APP" 2>/dev/null
hl_check "P2 the app is still running after every scenario" $?
hl_finish "$L"
