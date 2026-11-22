#!/usr/bin/env bash
# headless.sh - T3333 (Linux L4): the shared headless-compositor harness, the
# Linux analog of test/win32/lib/TestDesktop.ps1. Source it from a test/linux
# script that runs through scripts\linux\wsl-run.ps1:
#
#   . "$PWD/test/linux/lib/headless.sh"   # a -CommandFile step's cwd is the repo root
#   hl_check_init                       # PASS/FAIL counter (hl_check, hl_finish)
#   hl_start                            # private headless Weston; exports the env
#   app=$(hl_ghoztty)                   # the LINUX binary, by full path
#   hl_launch app "$app" --gtk-single-instance=false -e /bin/sh -c 'sleep 60'
#   ...                                 # assertions with hl_check
#   hl_finish "MY SCRIPT"               # stops everything, prints the verdict
#
# Why: WSLg gives every Linux GUI app a Wayland compositor that draws into an
# ordinary Windows window on the user's desktop - and takes focus there. go.md's
# top rule is NEVER PULL FOCUS FROM THE USER, so a Linux GUI test must never
# reach WSLg. hl_start runs a private `weston --backend=headless` with its own
# XDG_RUNTIME_DIR and socket, unsets DISPLAY (WSLg's XWayland) and pins
# GDK_BACKEND=wayland, so GTK has nowhere to go but the private compositor.
# hl_assert_isolated re-proves that before every launch and REFUSES the launch
# (exit 4) when anything points back at WSLg.
#
# What it guarantees:
#   - XDG_RUNTIME_DIR is a fresh mktemp dir (mode 0700) under /tmp, so two
#     harnesses running at once never share a socket (wayland-hl-<pid>).
#   - DISPLAY and WAYLAND_SOCKET are unset; WAYLAND_DISPLAY names the private
#     socket; GDK_BACKEND=wayland (GTK may not fall back to X11).
#   - GALLIUM_DRIVER=d3d12 when /dev/dxg exists (WSLg's GPU; Mesa picks
#     llvmpipe otherwise - measured 2026-11-21, docs/claude/linux.md).
#   - hl_ghoztty names zig-out/bin/ghoztty by absolute path and refuses a
#     binary that is not a Linux ELF, so interop can never hand a test the
#     user's Windows ghoztty.exe (the PATH trap in docs/claude/linux.md).
#   - an EXIT trap kills every process hl_launch started, then Weston, then
#     removes the runtime dir - a test that dies half-way leaves nothing behind.
#
# Exit codes it uses: 4 = isolation refused (never launches anything).

# ---- check counter -----------------------------------------------------------
hl_check_init() { HL_FAILS=0; HL_CHECKS=0; }
# hl_check <name> <exit-code-of-condition> [detail]
hl_check() {
    HL_CHECKS=$((HL_CHECKS+1))
    if [ "$2" = 0 ]; then echo "PASS $1${3:+ - $3}"; else echo "FAIL $1${3:+ - $3}"; HL_FAILS=$((HL_FAILS+1)); fi
}
# hl_finish <LABEL>: stop everything, print '<LABEL>: ALL PASS' or
# '<LABEL>: <n> FAILURE(S)', exit 0 only on ALL PASS (and at least one check).
hl_finish() {
    hl_stop
    if [ "${HL_FAILS:-1}" = 0 ] && [ "${HL_CHECKS:-0}" -gt 0 ]; then echo "$1: ALL PASS"; exit 0; fi
    [ "${HL_CHECKS:-0}" -gt 0 ] || HL_FAILS=1
    echo "$1: ${HL_FAILS} FAILURE(S)"; exit 1
}

# ---- compositor ---------------------------------------------------------------
HL_PIDS=""
HL_WESTON_PID=""
HL_RUNTIME=""

# hl_start [width] [height]: start the private headless Weston and export the
# environment a GTK app needs to reach it - and only it. Returns 0 when the
# socket is up, 1 (with the Weston log tail on stderr) when it is not.
hl_start() {
    local w=${1:-1280} h=${2:-800}
    command -v weston >/dev/null 2>&1 || { echo "hl_start: weston is not installed (run scripts/linux/setup-distro.sh)" >&2; return 1; }
    HL_RUNTIME=$(mktemp -d /tmp/ghoztty-hl.XXXXXX) || return 1
    chmod 0700 "$HL_RUNTIME"
    HL_SOCKET="wayland-hl-$$"
    HL_WESTON_LOG="$HL_RUNTIME/weston.log"
    trap 'hl_stop' EXIT
    trap 'exit 143' TERM; trap 'exit 130' INT    # so a killed test still runs the EXIT trap
    export XDG_RUNTIME_DIR="$HL_RUNTIME"
    # T3337: a private config root, so the app reads no user config and the
    # ghoztty-agent it spawns keeps its socket, roster and log under the
    # harness dir (local_agent_paths honors XDG_CONFIG_HOME on Linux), never
    # in the user's ~/.config. hl_stop reaps that agent.
    export XDG_CONFIG_HOME="$HL_RUNTIME/config"
    mkdir -p "$XDG_CONFIG_HOME"
    unset DISPLAY WAYLAND_SOCKET
    if [ -e /dev/dxg ]; then export GALLIUM_DRIVER=d3d12; fi
    weston --backend=headless --renderer=gl --socket="$HL_SOCKET" \
        --width="$w" --height="$h" --idle-time=0 > "$HL_WESTON_LOG" 2>&1 &
    HL_WESTON_PID=$!
    local _
    for _ in $(seq 1 100); do [ -S "$HL_RUNTIME/$HL_SOCKET" ] && break; sleep 0.1; done
    if [ ! -S "$HL_RUNTIME/$HL_SOCKET" ]; then
        echo "hl_start: headless Weston did not come up: $(tail -2 "$HL_WESTON_LOG" | tr '\n' ' ')" >&2
        return 1
    fi
    export WAYLAND_DISPLAY="$HL_SOCKET" GDK_BACKEND=wayland
    return 0
}

# hl_isolation_problem: print the first reason the current environment could
# reach the user's desktop, or nothing when it is isolated. Pure: reads the
# environment, starts nothing. hl_assert_isolated is the refusing form.
hl_isolation_problem() {
    if [ -n "${DISPLAY:-}" ]; then echo "DISPLAY=$DISPLAY is set (WSLg's XWayland is on the user's desktop)"; return; fi
    if [ -n "${WAYLAND_SOCKET:-}" ]; then echo "WAYLAND_SOCKET is set (an inherited compositor fd)"; return; fi
    if [ "${GDK_BACKEND:-}" != wayland ]; then echo "GDK_BACKEND='${GDK_BACKEND:-}' is not 'wayland' (GTK could fall back to X11)"; return; fi
    case "${XDG_RUNTIME_DIR:-}" in
        ''|/mnt/wslg*|/run/user/*) echo "XDG_RUNTIME_DIR='${XDG_RUNTIME_DIR:-}' is not a private harness dir"; return ;;
    esac
    [ -n "${HL_RUNTIME:-}" ] && [ "$XDG_RUNTIME_DIR" = "$HL_RUNTIME" ] || { echo "XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR' is not the dir hl_start made"; return; }
    [ "${XDG_CONFIG_HOME:-}" = "$HL_RUNTIME/config" ] || { echo "XDG_CONFIG_HOME='${XDG_CONFIG_HOME:-}' is not the harness config dir (an agent would land in the user's ~/.config)"; return; }
    case "${WAYLAND_DISPLAY:-}" in
        ''|/*|wayland-0) echo "WAYLAND_DISPLAY='${WAYLAND_DISPLAY:-}' is not the private socket"; return ;;
    esac
    [ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] || { echo "no socket at $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY"; return; }
    [ -L "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ] && { echo "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY is a symlink"; return; }
    [ -n "${HL_WESTON_PID:-}" ] && kill -0 "$HL_WESTON_PID" 2>/dev/null || { echo "the private Weston is not running"; return; }
}

# hl_assert_isolated: refuse (exit 4) when the environment is not isolated.
hl_assert_isolated() {
    local why
    why=$(hl_isolation_problem)
    if [ -n "$why" ]; then echo "HEADLESS REFUSED: $why - nothing was launched" >&2; hl_stop; exit 4; fi
}

# hl_ghoztty [repo-root]: print the absolute path of the Linux debug build, or
# fail when it is missing or is not a Linux ELF.
hl_ghoztty() {
    local root=${1:-$PWD} bin
    bin="$root/zig-out/bin/ghoztty"
    [ -x "$bin" ] || { echo "hl_ghoztty: no executable at $bin (build first)" >&2; return 1; }
    case "$(file -b "$bin" 2>/dev/null)" in
        ELF*) ;;
        *) echo "hl_ghoztty: $bin is not a Linux ELF" >&2; return 1 ;;
    esac
    printf '%s\n' "$bin"
}

# hl_launch <varname> <cmd> [args...]: assert isolation, start <cmd> in the
# background with its output in $HL_RUNTIME/<varname>.log, record its pid in
# <varname> (and the log path in <varname>_LOG) and in the cleanup list.
hl_launch() {
    local var=$1; shift
    hl_assert_isolated
    local log="$HL_RUNTIME/$var.log"
    "$@" > "$log" 2>&1 &
    local pid=$!
    HL_PIDS="$HL_PIDS $pid"
    printf -v "$var" '%s' "$pid"
    printf -v "${var}_LOG" '%s' "$log"
}

# hl_wait_for <seconds> <command...>: poll every 0.1 s until the command
# succeeds; 0 when it did, 1 on timeout.
hl_wait_for() {
    local secs=$1; shift
    local n=$((secs*10)) i
    for i in $(seq 1 "$n"); do "$@" && return 0; sleep 0.1; done
    return 1
}

# hl_weston_sockets: how many socket fds the private Weston holds. Weston
# accepts one fd per Wayland client, so this rising after a launch is proof a
# client connected HERE (and therefore not to WSLg).
hl_weston_sockets() {
    [ -n "${HL_WESTON_PID:-}" ] || { echo 0; return; }
    find "/proc/$HL_WESTON_PID/fd" -maxdepth 1 -lname 'socket:*' 2>/dev/null | wc -l
}

# hl_env_is_private <pid>: 0 when <pid>'s environment names the private socket
# and runtime dir, and carries no DISPLAY.
hl_env_is_private() {
    local env
    env=$(tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null) || return 1
    printf '%s\n' "$env" | grep -qx "WAYLAND_DISPLAY=$HL_SOCKET" || return 1
    printf '%s\n' "$env" | grep -qx "XDG_RUNTIME_DIR=$HL_RUNTIME" || return 1
    ! printf '%s\n' "$env" | grep -q '^DISPLAY='
}

# hl_tree <pid>: <pid> and every descendant, one per line (parents first).
hl_tree() {
    local root=$1
    ps -e -o pid=,ppid= 2>/dev/null | awk -v r="$root" '
        { kids[$2] = kids[$2] " " $1 }
        END { q[1] = r; n = 1; for (i = 1; i <= n; i++) { print q[i]; c = split(kids[q[i]], k, " "); for (j = 1; j <= c; j++) q[++n] = k[j] } }'
}

# hl_agent_pid: the pid of the ghoztty-agent the app spawned under this
# harness's config dir (its info file), or nothing. Only a live process whose
# executable is a ghoztty-agent counts, so a stale file never names a
# stranger.
hl_agent_pid() {
    local f pid exe
    for f in "${XDG_CONFIG_HOME:-/nonexistent}"/ghoztty/local-agent*/port.json; do
        [ -s "$f" ] || continue
        pid=$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "$f")
        [ -n "$pid" ] || continue
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || continue
        case "$exe" in */ghoztty-agent) printf '%s\n' "$pid"; return 0 ;; esac
    done
    return 1
}

# hl_stop_agent: TERM (then KILL) the harness's agent and every pane it hosts.
# The agent is not hl_launch's child (it runs in its own session, reparented
# to init), so nothing else would reap it.
hl_stop_agent() {
    local a pids p
    a=$(hl_agent_pid) || return 0
    pids=$(hl_tree "$a")
    for p in $pids; do kill -TERM "$p" 2>/dev/null; done
    for _ in $(seq 1 20); do kill -0 "$a" 2>/dev/null || break; sleep 0.1; done
    for p in $pids; do kill -KILL "$p" 2>/dev/null; done
    return 0
}

# hl_stop: kill everything hl_launch started (children too), then the agent
# the app spawned, then Weston, then remove the runtime dir. Idempotent; it is
# also the EXIT trap.
hl_stop() {
    local p
    for p in $HL_PIDS; do pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    for p in $HL_PIDS; do wait "$p" 2>/dev/null; done
    HL_PIDS=""
    hl_stop_agent
    if [ -n "${HL_WESTON_PID:-}" ]; then kill "$HL_WESTON_PID" 2>/dev/null; wait "$HL_WESTON_PID" 2>/dev/null; HL_WESTON_PID=""; fi
    if [ -n "${HL_RUNTIME:-}" ] && [ -d "$HL_RUNTIME" ]; then
        case "$HL_RUNTIME" in /tmp/ghoztty-hl.*) rm -rf "$HL_RUNTIME" ;; esac
    fi
    return 0
}
