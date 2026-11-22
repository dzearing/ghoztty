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
#
# Pick lanes with FLOOR_LANES (default "lib none"), e.g. FLOOR_LANES=none.
# Each lane is bounded by FLOOR_LANE_TIMEOUT seconds (default 1800), so a
# wedged lane ends as STALL rather than holding the wrapper forever.
#
# Prerequisite: scripts/linux/setup-distro.sh has run once.
# Output: one 'LANE <name> PASS|FAIL|STALL' line per lane (with its first
# error lines on a red one), then 'LINUX FLOOR: ALL PASS' or
# 'LINUX FLOOR: <n> FAILURE(S)'. Exit 0 only on ALL PASS. Full lane logs are
# /tmp/linux-floor-<lane>.log inside the distro.
set -u
lanes=${FLOOR_LANES:-lib none}
limit=${FLOOR_LANE_TIMEOUT:-1800}
fails=0

lane_args() {
    case "$1" in
        lib) echo "-Dapp-runtime=none" ;;
        none) echo "test -Dapp-runtime=none" ;;
        *) return 1 ;;
    esac
}

echo "LINUX FLOOR at $(git rev-parse --short HEAD 2>/dev/null || echo '?') lanes='$lanes' jobs=${GHOZTTY_WSL_JOBS:-default}"
for lane in $lanes; do
    if ! args=$(lane_args "$lane"); then
        echo "LANE $lane FAIL - unknown lane (known: lib none)"
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
