#!/usr/bin/env bash
# stack-glide.sh - T3625 acceptance for stacked-pane glides on the GTK debug
# app (docs/reference/stacked-panes.md "Glides"; Linux L11e-2): a change in
# what is on show - a strip clicked, a pane closed - is a glide. Every card
# and strip eases from where it is drawn toward where the layout puts it, a
# pane going into its strip narrows into it with its content fading out (and
# coming out, the reverse), the content is held at its size inside the card
# for the whole motion, and each terminal is resized at most once, after it.
#
# The glide is stretched (GHOZTTY_STACK_SLIDE_MS, win32's knob) so a sampler
# can catch it mid-motion: one Python process polls the debug-only
# `pane-stack` seam every ~40ms and records each frame's `drawn` rect, `fade`,
# the content's real allocated width and every terminal's resize count. The
# headless harness has no seat, so the strip click goes through the seam's
# press/release, the same functions the stage's real gesture calls.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\stack-glide.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh).
#
# Output: one PASS/FAIL line per check, then 'STACK GLIDE: ALL PASS' or
# 'STACK GLIDE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="STACK GLIDE"

log=/tmp/stack-glide-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "G1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "G2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

# Four panes at a 400px minimum cannot fit in a row (stacked-panes.sh).
MIN=400
cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
printf 'macos-pane-min-width = %s\nmacos-window-gradient = ocean\nwindow-width = 150\nwindow-height = 30\n' "$MIN" > "$cfg_dir/config.ghostty"

export SHELL=/bin/sh
# 3000: a glide about eight times Mac's, ~2.5s to land - long enough to see.
GHOZTTY_STACK_SLIDE_MS=3000 hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "G3 the app serves its socket" $?

first=$(hl_first_pane "$app")
st() { hl_ipc pane-stack "--target=$first" "$@"; }
sq() {
    printf '%s' "$1" | python3 -I -c '
import json, sys
r = json.loads(sys.stdin.read()); s = r.get("stage") or {}
P = {p["pane"]: p for p in s.get("panes", [])}
shown = [p for p in s.get("panes", []) if not p["minimized"]]
mini = [p for p in s.get("panes", []) if p["minimized"]]
print(eval(sys.argv[1]))' "$2" 2>/dev/null
}
# settle: wait (up to 10s) until no glide is under way.
settle() {
    for _ in $(seq 1 100); do
        [ "$(sq "$(st)" 's.get("gliding")')" = False ] && return 0
        sleep 0.1
    done
    return 1
}
# sample <out> <seconds> [first seam args...]: one process that sends the
# first request with the given args (a press/release), then polls the plain
# seam every ~40ms for <seconds>, writing {"t": ms, "r": reply} lines.
sample() {
    local out=$1 secs=$2; shift 2
    python3 -I - "$(hl_socket)" "$first" "$secs" "$out" "$@" <<'PY'
import json, socket, struct, sys, time
path, target, secs, out, first_args = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4], sys.argv[5:]
def ask(args):
    body = json.dumps({"action": "pane-stack", "arguments": ["--target=" + target] + args}).encode()
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(15)
    s.connect(path)
    s.sendall(struct.pack(">I", len(body)) + body)
    def take(n):
        b = b""
        while len(b) < n:
            c = s.recv(n - len(b))
            if not c: raise EOFError
            b += c
        return b
    n = struct.unpack(">I", take(4))[0]
    r = json.loads(take(n).decode())
    s.close()
    return r
t0 = time.monotonic()
with open(out, "w") as f:
    f.write(json.dumps({"t": 0, "r": ask(first_args)}) + "\n")
    while time.monotonic() - t0 < secs:
        time.sleep(0.04)
        f.write(json.dumps({"t": int((time.monotonic() - t0) * 1000), "r": ask([])}) + "\n")
PY
}
# judge <samples> <before reply> <python expr>: evaluate over the samples.
# In scope: S (list of (t, stage)), B (the stage before), Bp (its panes by id),
# A (the last stage), Ap.
judge() {
    python3 -I - "$1" "$2" "$3" <<'PY' 2>/dev/null
import json, sys
S = [(j["t"], j["r"]["stage"]) for j in map(json.loads, open(sys.argv[1])) if j["r"].get("stage")]
B = json.loads(sys.argv[2])["stage"]
Bp = {p["pane"]: p for p in B["panes"]}
A = S[-1][1]
Ap = {p["pane"]: p for p in A["panes"]}
def pane(stage, pid):
    for p in stage["panes"]:
        if p["pane"] == pid: return p
G = [(t, s) for t, s in S if s["gliding"]]
print(eval(sys.argv[3]))
PY
}

cli +split --target="$first" --direction=right --name=p2 > /dev/null 2>&1
cli +split --target=p2 --direction=right --name=p3 > /dev/null 2>&1
cli +split --target=p3 --direction=right --name=p4 > /dev/null 2>&1
sleep 1
settle
r=$(st)
[ "$(sq "$r" 'len(s["panes"]) == 4 and len(mini) >= 1 and not s["gliding"] and all(p["drawn"] == p["frame"] for p in shown)')" = True ]
hl_check "G4 four panes stack; at rest every card is drawn where the layout puts it" $? "$r"

# ---- 1. a strip click glides ------------------------------------------------
target=$(sq "$r" 'mini[0]["pane"]')
cx=$(sq "$r" 'mini[0]["strip"][0] + mini[0]["strip"][2] // 2')
cy=$(sq "$r" 'mini[0]["strip"][1] + mini[0]["strip"][3] // 2')
before=$r
samples="$HL_RUNTIME/click.jsonl"
sample "$samples" 5 "--press=$cx,$cy" "--release=0,0"
n=$(judge "$samples" "$before" 'len(S)')
hl_check "G5 the sampler recorded the glide ($n frames)" $([ "${n:-0}" -ge 20 ]; echo $?)

# Who gave way: on show before, minimized after.
gave=$(judge "$samples" "$before" '[p for p in Bp if not Bp[p]["minimized"] and Ap[p]["minimized"]][0]')
[ "$(judge "$samples" "$before" 'len(G) >= 5')" = True ]
hl_check "G6 a strip click starts a glide that lasts several frames (not a jump)" $? "$(judge "$samples" "$before" '[(t, s["gliding"]) for t, s in S[:8]]')"

[ "$(judge "$samples" "$before" '
any(pane(s, "'"$target"'")["gliding"] and
    Bp["'"$target"'"]["strip"][2] < pane(s, "'"$target"'")["drawn"][2] < Ap["'"$target"'"]["frame"][2]
    for t, s in G)')" = True ]
hl_check "G7 the pane brought forward widens out of its strip: seen between strip and card width" $? \
    "$(judge "$samples" "$before" '[(t, pane(s, "'"$target"'")["drawn"]) for t, s in G[:6]]')"

[ "$(judge "$samples" "$before" '
(lambda d: all(b <= a + 1 for a, b in zip(d, d[1:])))(
  [sum(abs(x - y) for x, y in zip(pane(s, "'"$target"'")["drawn"], Ap["'"$target"'"]["frame"])) for t, s in G])')" = True ]
hl_check "G8 it eases monotonically toward its slot (never overshoots, never snaps back)" $?

[ -n "$gave" ] && [ "$(judge "$samples" "$before" '
any(pane(s, "'"$gave"'")["gliding"] and pane(s, "'"$gave"'")["fade"] is not None
    and 0 < pane(s, "'"$gave"'")["fade"] < 1 for t, s in G)')" = True ]
hl_check "G9 the pane giving way narrows into its strip, its content part-faded on the way" $? \
    "gave=$gave $(judge "$samples" "$before" '[(t, pane(s, "'"$gave"'")["drawn"], pane(s, "'"$gave"'")["fade"]) for t, s in G[:6]]')"

[ -n "$gave" ] && [ "$(judge "$samples" "$before" '
any(pane(s, "'"$gave"'")["gliding"] and pane(s, "'"$gave"'")["drawn"][2] < Bp["'"$gave"'"]["frame"][2] - 20
    and abs(pane(s, "'"$gave"'")["content_w"] - Bp["'"$gave"'"]["frame"][2]) <= 2 for t, s in G)')" = True ]
hl_check "G10 its content is held at its size on show inside the narrowing card (cut, not squeezed)" $? \
    "$(judge "$samples" "$before" '[(pane(s, "'"$gave"'")["drawn"][2], pane(s, "'"$gave"'")["content_w"]) for t, s in G[:6]]')"

[ "$(judge "$samples" "$before" 'all(p["resizes"] == Bp[p["pane"]]["resizes"] for t, s in G for p in s["panes"] if p["gliding"])')" = True ]
hl_check "G11 no terminal is resized while its card is on the move" $? \
    "$(judge "$samples" "$before" '[(t, [(p["pane"][-4:], p["resizes"]) for p in s["panes"]]) for t, s in G[:4]]')"

[ "$(judge "$samples" "$before" 'not A["gliding"] and all(p["drawn"] == p["frame"] for p in A["panes"] if not p["minimized"])')" = True ]
hl_check "G12 the glide lands: every card on show exactly at its slot" $? "$(judge "$samples" "$before" 'A')"

[ "$(judge "$samples" "$before" 'all(Ap[p]["resizes"] - Bp[p]["resizes"] <= 1 for p in Bp)')" = True ]
hl_check "G13 each terminal is resized at most once by the whole glide" $? \
    "$(judge "$samples" "$before" '[(p[-4:], Bp[p]["resizes"], Ap[p]["resizes"]) for p in Bp]')"

[ "$(judge "$samples" "$before" 'not Ap["'"$target"'"]["minimized"] and Ap["'"$target"'"]["focused"]')" = True ]
hl_check "G14 the clicked pane ends on show and focused" $?

# ---- 2. closing a pane on show glides the row together ----------------------
settle
before=$(st)
victim=$(sq "$before" '[p["pane"] for p in shown if not p["focused"]][0]')
vname=$(cli +list --json 2>/dev/null | python3 -I -c '
import json, sys
d = json.load(sys.stdin)["data"]
def walk(n):
    if n["type"] == "split":
        yield from walk(n["left"]); yield from walk(n["right"])
    else:
        yield n["terminal"]
for w in d["windows"]:
    for t in w["tabs"]:
        for l in walk(t["splits"]):
            if l["id"] == sys.argv[1]: print(l.get("name") or l["id"])
' "$victim" 2>/dev/null)
cli +close --target="$vname" > /dev/null 2>&1
samples="$HL_RUNTIME/close.jsonl"
sample "$samples" 5
[ "$(judge "$samples" "$before" 'len(G) >= 3 and not A["gliding"] and all(p["drawn"] == p["frame"] for p in A["panes"] if not p["minimized"])')" = True ]
hl_check "G15 closing a pane on show brings a strip's pane out in a glide that lands" $? \
    "victim=$vname $(judge "$samples" "$before" '[(t, s["gliding"]) for t, s in S[:6]]')"

# ---- 3. a fold under the hand glides, and settles after the release ---------
settle
before=$(st)
gx=$(sq "$before" '[g for g in s["gutters"] if g["kind"] in ("divider", "grip") and g["direction"] == "horizontal"][0]["rect"][0] + 2')
gy=$(sq "$before" '[g for g in s["gutters"] if g["kind"] in ("divider", "grip") and g["direction"] == "horizontal"][0]["rect"][1] + 20')
samples="$HL_RUNTIME/drag.jsonl"
# Pressed, dragged far past the far pane's minimum and let go: the pane folds
# into its strip, and the glide runs on after the hand (the 50ms tail).
sample "$samples" 5 "--press=$gx,$gy" "--drag=2000,0" "--release=0,0"
[ -n "$gx" ] && [ "$(judge "$samples" "$before" '
sum(1 for p in A["panes"] if p["minimized"]) > sum(1 for p in B["panes"] if p["minimized"])
and len(G) >= 3 and not A["gliding"]
and all(p["drawn"] == p["frame"] for p in A["panes"] if not p["minimized"])')" = True ]
hl_check "G17 a drag that folds a pane away glides it into its strip and settles after the release" $? \
    "gutter=$gx,$gy $(judge "$samples" "$before" '[(t, s["gliding"], sum(p["minimized"] for p in s["panes"])) for t, s in S[:6]]')"

# ---- 4. a pane mid-glide still renders, at the size it is held at ------------
settle
r=$(st)
if [ "$(sq "$r" 'len(mini)')" -ge 1 ] 2>/dev/null; then
    t2=$(sq "$r" 'mini[0]["pane"]')
    cx=$(sq "$r" 'mini[0]["strip"][0] + mini[0]["strip"][2] // 2')
    cy=$(sq "$r" 'mini[0]["strip"][1] + mini[0]["strip"][3] // 2')
    st "--press=$cx,$cy" "--release=0,0" > /dev/null
    sleep 0.4
    cap=$(hl_screenshot "$t2" "$HL_RUNTIME/mid.png" 2>&1)
    r=$(st)
    cw=$(printf '%s' "$cap" | python3 -I -c '
import json, sys
print(json.loads(sys.stdin.readline())["data"]["width"])' 2>/dev/null)
    hw=$(sq "$r" 'P["'"$t2"'"]["content_w"]')
    [ "$(sq "$r" 'P["'"$t2"'"]["gliding"]')" = True ] && [ -n "$cw" ] && [ -n "$hw" ] && [ $((cw - hw)) -ge -2 ] && [ $((cw - hw)) -le 2 ]
    hl_check "G18 a pane captured mid-glide renders a frame at its held size" $? "capture=$cap held=$hw $(sq "$r" 'P["'"$t2"'"]')"
else
    hl_check "G18 a pane captured mid-glide renders a frame at its held size" 1 "no minimized pane to click: $r"
fi
settle

! grep -E "without calling gtk_widget_measure|Allocation (width|height) too small|Gtk-CRITICAL|gtk_widget_queue|during size allocation" "$APP_LOG" > /dev/null
hl_check "G16 the app logged no GTK allocation warnings or criticals" $? \
    "$(grep -m3 -E 'gtk_widget_measure|too small|Gtk-CRITICAL|gtk_widget_queue|during size allocation' "$APP_LOG")"

hl_finish "$L"
