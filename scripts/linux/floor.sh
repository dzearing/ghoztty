#!/usr/bin/env bash
# floor.sh - the Linux floor (T3331, L2): the shared-core lanes that
# scripts\floor-lane.ps1 runs as `lib` and `none` on Windows, run natively in
# WSL. Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile scripts\linux\floor.sh
#
# (-Repo clone, the default, tests the committed HEAD in ~/ghoztty-l. zig build
# does not work on /mnt - its cache rename is refused - so there is no -Repo mnt
# form of this script.)
#
# Lanes, the same commands as floor-lane.ps1's lanes of the same name:
#   lib   zig build -Dapp-runtime=none        compiles libghostty for Linux
#   none  zig build test -Dapp-runtime=none   the pure-logic unit tests
#   agentx zig build agent        builds ghoztty-agent for Linux (T3332)
#   agent  zig build test-agent   the agent's tests, incl. real-pty (T3332)
#   gtk    zig build test -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell
#          the GTK frontend's own test blocks (T3605): upstream's gtk.zig test
#          root (key, portal, ext, gsettings, gtk_version, class/*) and every
#          gtk module only a gtk build compiles. No other lane on any platform
#          runs them - the none lane takes only the std-only gtk/*.zig halves
#          that apprt/unit_tests.zig references. -fno-sys=gtk4-layer-shell
#          builds the vendored copy, since Ubuntu 24.04 packages none.
#
# The agent lanes take the DEFAULT runtime (gtk on Linux) on purpose: the agent
# is GUI-free and gets runtime-none deps on a gtk build (SharedDeps.guiFree,
# T3358), so it must build without the system gtk4-layer-shell Ubuntu 24.04 does
# not package. Adding -Dapp-runtime=none here would hide a regression of that.
#
# Pick lanes with FLOOR_LANES (default "lib none agentx agent gtk"), e.g. FLOOR_LANES=none.
# Each lane is bounded by FLOOR_LANE_TIMEOUT seconds (default 1800), so a
# wedged lane ends as STALL rather than holding the wrapper forever.
#
# Prerequisite: scripts/linux/setup-distro.sh has run once.
# Output: one 'LANE <name> PASS|FAIL|STALL' line per lane (with its first
# error lines on a red one), then 'LINUX FLOOR: ALL PASS' or
# 'LINUX FLOOR: <n> FAILURE(S)'. Exit 0 only on ALL PASS. Full lane logs are
# /tmp/linux-floor-<lane>.log inside the distro.
set -u
lanes=${FLOOR_LANES:-lib none agentx agent gtk}
limit=${FLOOR_LANE_TIMEOUT:-1800}
fails=0

lane_args() {
    case "$1" in
        lib) echo "-Dapp-runtime=none" ;;
        none) echo "test -Dapp-runtime=none" ;;
        agentx) echo "agent" ;;
        agent) echo "test-agent" ;;
        gtk) echo "test -Dapp-runtime=gtk -fno-sys=gtk4-layer-shell" ;;
        *) return 1 ;;
    esac
}

echo "LINUX FLOOR at $(git rev-parse --short HEAD 2>/dev/null || echo '?') lanes='$lanes' jobs=${GHOZTTY_WSL_JOBS:-default}"
for lane in $lanes; do
    if ! args=$(lane_args "$lane"); then
        echo "LANE $lane FAIL - unknown lane (known: lib none agentx agent gtk)"
        fails=$((fails+1)); continue
    fi
    log=/tmp/linux-floor-$lane.log
    start=$(date +%s)
    # shellcheck disable=SC2086 # $args is a word list on purpose
    timeout --kill-after=30 "$limit" zig build $args > "$log" 2>&1
    rc=$?
    secs=$(( $(date +%s) - start ))
    summary=$(grep -m1 '^Build Summary' "$log")
    if [ $rc = 0 ]; then
        echo "LANE $lane PASS ${secs}s - zig build $args${summary:+ - $summary}"
    elif [ $rc = 124 ] || [ $rc = 137 ]; then
        echo "LANE $lane STALL after ${secs}s (limit ${limit}s) - zig build $args"
        tail -5 "$log" | sed 's/^/    /'
        fails=$((fails+1))
    else
        echo "LANE $lane FAIL rc=$rc ${secs}s - zig build $args${summary:+ - $summary}"
        # The compile errors and failed tests first; the tail when there are none.
        # (A bare 'failed' also matches the tests' own warn lines; the
        # compile errors and the runner's verdicts all carry 'error: '.)
        if grep -qE '(^|: )error: ' "$log"; then
            grep -m12 -E '(^|: )error: ' "$log" | sed 's/^/    /'
        else
            tail -8 "$log" | sed 's/^/    /'
        fi
        fails=$((fails+1))
    fi
done

if [ $fails = 0 ]; then echo "LINUX FLOOR: ALL PASS"; exit 0; fi
echo "LINUX FLOOR: $fails FAILURE(S)"; exit 1
