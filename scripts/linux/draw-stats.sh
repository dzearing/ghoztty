#!/usr/bin/env bash
# draw-stats.sh [--reset] - T3792: what the Linux Ghoztty that
# scripts\linux\open.ps1 put on the real WSLg screen has spent on its frames
# and resizes, from the debug pane-seen seam's `draw` block
# (src/apprt/gtk/draw_stats.zig). A PERSON's command, through
# `open.ps1 -DrawStats [-Reset]`: reset, drag the window edge for a few
# seconds, read. The headless measurement is test/linux/resize-frame-cost.sh;
# this is the same numbers off the real compositor, where the frame gap is
# what a person actually saw.
#
# It talks only to the debug socket of the open.ps1 app (the derivation in
# src/os/ipc_client.zig: $XDG_RUNTIME_DIR, else $TMPDIR, else /tmp, then
# ghostty-debug-<uid>.sock) and changes nothing but the counters.
set -u
bin=/root/ghoztty-l/zig-out/bin/ghoztty
dir=${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}
sock="$dir/ghostty-debug-$(id -u).sock"
[ -S "$sock" ] || { echo "DRAW STATS FAILED no Linux Ghoztty socket at $sock (open it with open.ps1)"; exit 1; }
reset=""
[ "${1:-}" = --reset ] && reset="--reset-draw"
GHOZTTY_IPC_SOCKET="$sock" LD_LIBRARY_PATH=/root/ghoztty-l/zig-out/lib "$bin" +list --json 2>/dev/null |
python3 -I -c '
import json, socket, struct, sys
sock, reset = sys.argv[1], sys.argv[2:]
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"].get("id", "")
panes = [i for w in d["windows"] for t in w["tabs"] for i in walk(t["splits"]) if i]
if not panes:
    print("DRAW STATS FAILED the app lists no pane"); sys.exit(1)
def ipc(action, args):
    body = json.dumps({"action": action, "arguments": args}).encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(15); s.connect(sock)
    s.sendall(struct.pack(">I", len(body)) + body)
    def take(n):
        out = b""
        while len(out) < n:
            c = s.recv(n - len(out))
            if not c: raise EOFError("short read")
            out += c
        return out
    return json.loads(take(struct.unpack(">I", take(4))[0]))
seen = set()
for pane in panes:
    r = ipc("pane-seen", ["--target=" + pane] + reset)
    for p in r.get("data", {}).get("panes", []):
        if p["pane"] in seen or "draw" not in p: continue
        seen.add(p["pane"])
        g = p["draw"]
        f = lambda k: "%s n=%d mean=%.1fms max=%.1fms" % (k, g[k]["count"], g[k]["mean_us"] / 1000, g[k]["max_us"] / 1000)
        print("DRAW STATS pane=%s %s | %s | %s" % (p["pane"][:8], f("draws"), f("resizes"), f("resize_gaps")))
print("DRAW STATS %s (%d pane(s))" % ("reset" if reset else "read", len(seen)))
' "$sock" $reset
