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
#   - Weston itself renders with GALLIUM_DRIVER=d3d12 when /dev/dxg exists
#     (WSLg's GPU; Mesa picks llvmpipe otherwise - measured 2026-11-21,
#     docs/claude/linux.md). The variable is NOT exported to the app: since
#     T3350 the app picks the GPU on its own, and a test that exported it
#     would only ever exercise the user-choice path.
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
HL_WESTON_PID=""      # the private compositor's pid - Weston, or sway under hl_start_seat
HL_RUNTIME=""
HL_COMPOSITOR=""

# hl_start [width] [height]: start the private headless Weston and export the
# environment a GTK app needs to reach it - and only it. Returns 0 when the
# socket is up, 1 (with the Weston log tail on stderr) when it is not.
#
# Weston headless has NO wl_seat, so nothing that needs a seat can be proven
# under it (a cross-client paste above all). hl_start_seat is the other
# compositor, for exactly that.
hl_start() {
    local w=${1:-1280} h=${2:-800}
    HL_COMPOSITOR=${HL_WANT_COMPOSITOR:-weston}
    if [ "$HL_COMPOSITOR" = sway ]; then
        command -v sway >/dev/null 2>&1 || { echo "hl_start_seat: sway is not installed (run scripts/linux/setup-distro.sh)" >&2; return 1; }
    else
        command -v weston >/dev/null 2>&1 || { echo "hl_start: weston is not installed (run scripts/linux/setup-distro.sh)" >&2; return 1; }
    fi
    HL_RUNTIME=$(mktemp -d /tmp/ghoztty-hl.XXXXXX) || return 1
    chmod 0700 "$HL_RUNTIME"
    HL_SOCKET="wayland-hl-$$"
    HL_WESTON_LOG="$HL_RUNTIME/$HL_COMPOSITOR.log"
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
    local _
    if [ "$HL_COMPOSITOR" = sway ]; then
        hl_start_sway_ "$w" "$h" || return 1
    else
        local wgpu=""
        if [ -e /dev/dxg ]; then wgpu="GALLIUM_DRIVER=d3d12"; fi
        env $wgpu weston --backend=headless --renderer=gl --socket="$HL_SOCKET" \
            --width="$w" --height="$h" --idle-time=0 > "$HL_WESTON_LOG" 2>&1 &
        HL_WESTON_PID=$!
        for _ in $(seq 1 100); do [ -S "$HL_RUNTIME/$HL_SOCKET" ] && break; sleep 0.1; done
    fi
    if [ ! -S "$HL_RUNTIME/$HL_SOCKET" ]; then
        echo "hl_start: headless $HL_COMPOSITOR did not come up: $(tail -2 "$HL_WESTON_LOG" | tr '\n' ' ')" >&2
        return 1
    fi
    export WAYLAND_DISPLAY="$HL_SOCKET" GDK_BACKEND=wayland
    return 0
}

# hl_start_seat [width] [height] (T3620): hl_start, but the private compositor
# is a headless sway, which HAS a wl_seat - so a selection the app sets can be
# offered to another client, and `wl-paste` (wlr-data-control) reads it with
# no focus of its own. Same isolation, same refusals, same cleanup as hl_start.
# No input devices (WLR_LIBINPUT_NO_DEVICES=1), no Xwayland, the pixman
# renderer (wlroots' GL renderer wants a DRM render node, which WSL does not
# have). A selection still needs one key serial first - see hl_key_serial.
hl_start_seat() { HL_WANT_COMPOSITOR=sway hl_start "$@"; }

# hl_start_sway_ <w> <h>: hl_start's sway half. sway 1.9 cannot be told a
# socket name, so it picks one inside the private runtime dir and HL_SOCKET is
# read back from there (never wayland-0: hl_isolation_problem refuses that
# name, which is WSLg's).
hl_start_sway_() {
    local _ s
    printf 'xwayland disable\noutput HEADLESS-1 resolution %sx%s\n' "$1" "$2" > "$HL_RUNTIME/sway.cfg"
    env -u WAYLAND_DISPLAY -u SWAYSOCK -u I3SOCK WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 \
        WLR_RENDERER=pixman sway -c "$HL_RUNTIME/sway.cfg" > "$HL_WESTON_LOG" 2>&1 &
    HL_WESTON_PID=$!
    for _ in $(seq 1 100); do
        s=$(cd "$HL_RUNTIME" && ls -1 2>/dev/null | grep -E '^wayland-[0-9]+$' | head -1)
        [ -n "$s" ] && [ -S "$HL_RUNTIME/$s" ] && break
        kill -0 "$HL_WESTON_PID" 2>/dev/null || break
        sleep 0.1
    done
    [ -n "$s" ] || return 1
    HL_SOCKET=$s
    SWAYSOCK=$(ls -1 "$HL_RUNTIME"/sway-ipc.*.sock 2>/dev/null | head -1)
    export SWAYSOCK
    return 0
}

# hl_key_serial: give the focused window ONE real key event (Shift_L, through
# a short-lived virtual keyboard - wtype), under hl_start_seat only. Why: GTK
# claims a selection with its last key-press/button serial, and wlroots rejects
# a set_selection whose serial the client was never given ("serial 0 was never
# given to client") - with no input devices that serial is 0 until this runs,
# so every copy stays app-local. A modifier-only tap is not enough (it sends
# wl_keyboard.modifiers, not .key). Shift alone types nothing into a pane.
hl_key_serial() {
    [ "${HL_COMPOSITOR:-}" = sway ] || { echo "hl_key_serial: needs hl_start_seat (Weston headless has no seat)" >&2; return 1; }
    command -v wtype >/dev/null 2>&1 || { echo "hl_key_serial: wtype is not installed (run scripts/linux/setup-distro.sh)" >&2; return 1; }
    hl_assert_isolated
    wtype -k Shift_L
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

# hl_socket: the debug app's IPC socket inside this harness (the derivation
# in src/os/ipc_client.zig: $XDG_RUNTIME_DIR/ghostty-debug-<uid>.sock).
hl_socket() { printf '%s\n' "$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"; }

# hl_ipc <action> [arg...]: send one raw IPC request (4-byte big-endian length
# + JSON, both ways) to the harness's app and print the reply JSON. For the
# DEBUG-ONLY seams that have no CLI verb, such as capture-pane. Exit 1 when
# nothing answered.
hl_ipc() {
    python3 -I - "$(hl_socket)" "$@" <<'PY'
import json, socket, struct, sys
path, action, args = sys.argv[1], sys.argv[2], sys.argv[3:]
body = json.dumps({"action": action, "arguments": args}).encode()
try:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    s.connect(path)
    s.sendall(struct.pack(">I", len(body)) + body)
    def take(n):
        out = b""
        while len(out) < n:
            c = s.recv(n - len(out))
            if not c: raise EOFError("short read")
            out += c
        return out
    n = struct.unpack(">I", take(4))[0]
    sys.stdout.write(take(n).decode())
    sys.stdout.write("\n")
except Exception as e:
    sys.stderr.write("hl_ipc: %s\n" % e)
    sys.exit(1)
PY
}

# hl_first_pane <app>: the id of the first pane the app lists, or nothing.
hl_first_pane() {
    env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$1" +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"].get("id", "")
for w in d["windows"]:
    for t in w["tabs"]:
        for i in walk(t["splits"]):
            if i: print(i); sys.exit(0)
' 2>/dev/null
}

# hl_screenshot <target> <file.png> [--window] [--width=N] [--height=N]:
# a PNG of a pane (pane id, pane name or window name), or with --window its
# whole window, from the app's OWN render via the debug-only capture-pane
# seam (T3359) - the headless Weston offers no capture and Wayland has no
# global one. Prints the reply JSON; 0 only when the app says success AND the
# file is a PNG.
hl_screenshot() {
    local target=$1 file=$2; shift 2
    local reply
    reply=$(hl_ipc capture-pane "--target=$target" "--path=$file" "$@") || return 1
    printf '%s\n' "$reply"
    printf '%s' "$reply" | grep -q '"success":true' || return 1
    [ "$(head -c 8 "$file" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = 89504e470d0a1a0a ]
}

# hl_png_stats <file.png> [r g b]: decode a PNG (8-bit RGB/RGBA, any filter)
# and print 'w=<W> h=<H> colors=<distinct> match=<fraction of pixels equal to
# r,g,b within 8 per channel>'. Pure python3, no PIL.
hl_png_stats() {
    python3 -I - "$@" <<'PY'
import struct, sys, zlib
path = sys.argv[1]
want = tuple(int(v) for v in sys.argv[2:5]) if len(sys.argv) >= 5 else None
d = open(path, "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
pos, idat, w = 8, b"", 0
while pos < len(d):
    ln, typ = struct.unpack(">I4s", d[pos:pos+8]); chunk = d[pos+8:pos+8+ln]; pos += 12 + ln
    if typ == b"IHDR": w, h, depth, ctype = struct.unpack(">IIBB", chunk[:10])
    elif typ == b"IDAT": idat += chunk
assert depth == 8 and ctype in (2, 6), "unsupported PNG depth=%d type=%d" % (depth, ctype)
bpp = 3 if ctype == 2 else 4
raw, stride = zlib.decompress(idat), w * bpp
prev, rows, i = bytearray(stride), [], 0
for _ in range(h):
    f = raw[i]; line = bytearray(raw[i+1:i+1+stride]); i += 1 + stride
    for x in range(stride):
        a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
        if f == 1: line[x] = (line[x] + a) & 255
        elif f == 2: line[x] = (line[x] + b) & 255
        elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(line); prev = line
colors, match = set(), 0
for line in rows:
    for x in range(0, stride, bpp):
        px = tuple(line[x:x+3]); colors.add(px)
        if want and all(abs(px[k] - want[k]) <= 8 for k in range(3)): match += 1
print("w=%d h=%d colors=%d match=%.3f" % (w, h, len(colors), match / float(w * h)))
PY
}

# hl_png_pixel <file.png> <x> <y> [<x> <y> ...]: the pixel at each point, one
# 'r g b' line per point (T3566). Same decoder as hl_png_stats; a point off
# the image prints 'off'.
hl_png_pixel() {
    python3 -I - "$@" <<'PY'
import struct, sys, zlib
path = sys.argv[1]
pts = [(int(sys.argv[i]), int(sys.argv[i + 1])) for i in range(2, len(sys.argv) - 1, 2)]
d = open(path, "rb").read()
assert d[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
pos, idat, w = 8, b"", 0
while pos < len(d):
    ln, typ = struct.unpack(">I4s", d[pos:pos+8]); chunk = d[pos+8:pos+8+ln]; pos += 12 + ln
    if typ == b"IHDR": w, h, depth, ctype = struct.unpack(">IIBB", chunk[:10])
    elif typ == b"IDAT": idat += chunk
assert depth == 8 and ctype in (2, 6), "unsupported PNG depth=%d type=%d" % (depth, ctype)
bpp = 3 if ctype == 2 else 4
raw, stride = zlib.decompress(idat), w * bpp
prev, rows, i = bytearray(stride), [], 0
for _ in range(h):
    f = raw[i]; line = bytearray(raw[i+1:i+1+stride]); i += 1 + stride
    for x in range(stride):
        a = line[x-bpp] if x >= bpp else 0; b = prev[x]; c = prev[x-bpp] if x >= bpp else 0
        if f == 1: line[x] = (line[x] + a) & 255
        elif f == 2: line[x] = (line[x] + b) & 255
        elif f == 3: line[x] = (line[x] + (a + b) // 2) & 255
        elif f == 4:
            p = a + b - c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
            line[x] = (line[x] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    rows.append(line); prev = line
for (x, y) in pts:
    if 0 <= x < w and 0 <= y < h:
        print("%d %d %d" % tuple(rows[y][x*bpp:x*bpp+3]))
    else:
        print("off")
PY
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
#
# A process gets HL_STOP_GRACE seconds (default 10) after SIGTERM and is then
# SIGKILLed, with a line on stderr naming it. A bare `wait` here hung the run
# forever when the GTK app stalled in its own SIGTERM quit (T3563: a window
# holding a cancelled close dialog, T3677) - the test had already printed its
# verdict, but wsl-run never returned and every such run leaked an app.
hl_stop() {
    local p i
    for p in $HL_PIDS; do pkill -TERM -P "$p" 2>/dev/null; kill "$p" 2>/dev/null; done
    for p in $HL_PIDS; do
        for i in $(seq 1 $(( ${HL_STOP_GRACE:-10} * 10 ))); do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
        if kill -0 "$p" 2>/dev/null; then
            echo "hl_stop: pid $p ($(tr '\0' ' ' < /proc/$p/cmdline 2>/dev/null | cut -c1-80)) ignored SIGTERM for ${HL_STOP_GRACE:-10}s - SIGKILL" >&2
            pkill -KILL -P "$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null
        fi
        wait "$p" 2>/dev/null
    done
    HL_PIDS=""
    hl_stop_agent
    if [ -n "${HL_WESTON_PID:-}" ]; then kill "$HL_WESTON_PID" 2>/dev/null; wait "$HL_WESTON_PID" 2>/dev/null; HL_WESTON_PID=""; fi
    if [ -n "${HL_RUNTIME:-}" ] && [ -d "$HL_RUNTIME" ]; then
        case "$HL_RUNTIME" in /tmp/ghoztty-hl.*) rm -rf "$HL_RUNTIME" ;; esac
    fi
    return 0
}
