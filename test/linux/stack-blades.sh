#!/usr/bin/env bash
# stack-blades.sh - T3729 acceptance: stacked-pane strips are blades on the
# GTK debug app (docs/reference/stacked-panes.md "Gutters": Strips are
# blades). A strip with another between it and the run is drawn at its whole
# tab and reaches 12px (Mac `Metrics.bladeTuck`) under that one, its title
# giving way on the tucked side; every strip casts a light shadow leaning
# AWAY from the run onto the blade behind it, and a card gliding into its
# strip brings that shadow on with its collapse. Geometry from the debug-only
# `pane-stack` seam (`face`, `tuck`, `shadow`, `shadow_collapse`), pixels from
# the window's own render (`capture-pane --window`).
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\stack-blades.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh).
#
# Negative control: on a build before T3729 the seam has no face/shadow
# fields and the faces are trimmed, so B5-B11 fail. `NEGATIVE=1` reads the
# "shadow" pixel deep inside the blade behind, beside the reference pixel,
# and must fail B9 (the threshold needs a real shadow to pass).
#
# Output: one PASS/FAIL line per check, then 'STACK BLADES: ALL PASS' or
# 'STACK BLADES: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="STACK BLADES"

log=/tmp/stack-blades-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "B1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "B2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
cli() { env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID "$app" "$@"; }

# Six panes at a 400px minimum cannot fit in a row, so all but the run on
# show become strips, several of them on the side away from the focused pane.
MIN=400
cfg_dir="$XDG_CONFIG_HOME/ghostty"
mkdir -p "$cfg_dir"
printf 'macos-pane-min-width = %s\nmacos-window-gradient = ocean\nwindow-width = 150\nwindow-height = 30\n' "$MIN" > "$cfg_dir/config.ghostty"

export SHELL=/bin/sh
# 3000: a glide about eight times Mac's, ~2.5s to land - long enough to sample.
GHOZTTY_STACK_SLIDE_MS=3000 hl_launch APP "$app" --gtk-single-instance=false -e /bin/sh -c 'exec sleep 600'
hl_wait_for 30 test -S "$(hl_socket)"
hl_check "B3 the app serves its socket" $?

first=$(hl_first_pane "$app")
st() { hl_ipc pane-stack "--target=$first" "$@"; }
sq() {
    printf '%s' "$1" | python3 -I -c '
import json, sys
r = json.loads(sys.stdin.read()); s = r.get("stage") or {}
P = {p["pane"]: p for p in s.get("panes", [])}
shown = [p for p in s.get("panes", []) if not p["minimized"]]
mini = [p for p in s.get("panes", []) if p["minimized"]]
run_l = min((p["frame"][0] for p in shown), default=0)
lead = sorted([p for p in mini if p["strip"][0] < run_l], key=lambda p: p["strip"][0])
trail = sorted([p for p in mini if p["strip"][0] >= run_l], key=lambda p: p["strip"][0])
# Each side as (nearer the run, the one behind it): leading strips run
# left to right toward the run, trailing ones right to left.
pairs = [(lead[i + 1], lead[i]) for i in range(len(lead) - 1)] + [(trail[i], trail[i + 1]) for i in range(len(trail) - 1)]
def ov(a, b):
    return min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
print(eval(sys.argv[1]))' "$2" 2>/dev/null
}
settle() {
    for _ in $(seq 1 100); do
        [ "$(sq "$(st)" 's.get("gliding")')" = False ] && return 0
        sleep 0.1
    done
    return 1
}

# ---- 1. a row of six stacks into blades ------------------------------------
prev=$first
for n in 2 3 4 5 6; do
    cli +split --target="$prev" --direction=right --name=p$n > /dev/null 2>&1
    prev=p$n
done
for _ in $(seq 1 50); do
    [ "$(sq "$(st)" 'len(s.get("panes", []))')" = 6 ] && break
    sleep 0.2
done
settle
r=$(st)
[ "$(sq "$r" 'len(s["panes"]) == 6 and len(mini) >= 3 and len(pairs) >= 1')" = True ]
hl_check "B4 six panes that cannot fit stack: at least three strips, two of them side by side" $? "$r"

# ---- 2. faces are whole tabs that overlap by the tuck ----------------------
[ "$(sq "$r" 'all(p["face"] == p["strip"] for p in mini)')" = True ]
hl_check "B5 every strip's face is its whole tab, not trimmed by its tuck" $? "$r"
[ "$(sq "$r" 'all(ov(n["strip"], f["strip"]) == 12 for n, f in pairs)')" = True ]
hl_check "B6 a strip behind another reaches exactly 12px under it" $? "$r"
[ "$(sq "$r" 'sorted(f["pane"] for n, f in pairs) == sorted(p["pane"] for p in mini if p["tuck"] != "none")')" = True ]
hl_check "B7 exactly the strips with one in front give way on their tucked side" $? "$r"

# ---- 3. every strip casts its shadow ---------------------------------------
[ "$(sq "$r" 'all(p["shadow"] == p["strip"] and p["shadow_collapse"] == 1 for p in mini) and all(p["shadow"] is None for p in shown)')" = True ]
hl_check "B8 every strip (and no card on show) casts a blade shadow from its own tab, at full strength" $? "$r"

# The window's own render: the strip in front darkens the blade behind it
# just past its edge AWAY from the run, and not deep inside that blade. Rows
# a third of the way down, clear of the centred title.
ox=$(sq "$r" 's["origin"][0]'); oy=$(sq "$r" 's["origin"][1]')
shot="$HL_RUNTIME/blades.png"
hl_screenshot "$first" "$shot" --window > /dev/null 2>&1
shot_ok=$?
spec=$(sq "$r" '(lambda n, f, lead: (
    (n["strip"][0] - 2 if lead else n["strip"][0] + n["strip"][2] + 1),
    (n["strip"][0] - 20 if lead else n["strip"][0] + n["strip"][2] + 19),
    (n["strip"][0] + n["strip"][2] + 1 if lead else n["strip"][0] - 2),
    n["strip"][1] + n["strip"][3] // 3))(pairs[0][0], pairs[0][1], pairs[0][0] in lead)')
set -- $(printf '%s' "$spec" | tr -d '(),')
near_x=${1:-0}; deep_x=${2:-0}; toward_x=${3:-0}; py=${4:-0}
[ "${NEGATIVE:-}" = 1 ] && near_x=$((deep_x + 1))
lum() { set -- $1; echo $(( ${1:-0} + ${2:-0} + ${3:-0} )); }
near=$(lum "$(hl_png_pixel "$shot" $((ox + near_x)) $((oy + py)))")
deep=$(lum "$(hl_png_pixel "$shot" $((ox + deep_x)) $((oy + py)))")
[ $shot_ok = 0 ] && [ $((deep - near)) -ge 9 ]
hl_check "B9 the render shows the shadow on the blade behind, just past the front strip's edge" $? "spec=[$spec] near=$near deep=$deep shot=$shot_ok"

# ---- 4. the shadow follows collapse in a glide -----------------------------
# Click the strip nearest the run on show: it comes out, and a card glides
# into its strip. Mid-glide that card casts the blade shadow at its collapse.
target=$(sq "$r" 'pairs[0][0]["pane"]')
cx=$(sq "$r" 'P["'"$target"'"]["strip"][0] + P["'"$target"'"]["strip"][2] // 2')
cy=$(sq "$r" 'P["'"$target"'"]["strip"][1] + P["'"$target"'"]["strip"][3] // 2')
out="$HL_RUNTIME/blade-glide.jsonl"
python3 -I - "$(hl_socket)" "$first" 3 "$out" "--press=$cx,$cy" "--release=0,0" <<'PY'
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
glide=$(python3 -I - "$out" <<'PY' 2>/dev/null
import json, sys
S = [j["r"]["stage"] for j in map(json.loads, open(sys.argv[1])) if j["r"].get("stage")]
mid = [p for s in S for p in s["panes"] if p.get("fade") is not None and 0.05 < p["fade"] < 0.95]
cast = [p for p in mid if p.get("shadow_collapse") is not None]
# The seam's fade is read between frames and the shadow's collapse is the
# last frame's, so they agree to within a frame's step of the glide.
ok = len(cast) >= 1 and all(0 < p["shadow_collapse"] < 1 and abs(p["shadow_collapse"] - p["fade"]) < 0.2 for p in cast)
vals = sorted(set(round(p["shadow_collapse"], 2) for p in cast))
print("ok" if ok and len(vals) >= 2 else "bad", len(mid), len(cast), vals[:6])
PY
)
case "$glide" in ok*) true ;; *) false ;; esac
hl_check "B10 a card gliding into its strip casts the shadow at its collapse, coming on as it narrows" $? "$glide"
settle
r=$(st)
[ "$(sq "$r" 'not P["'"$target"'"]["minimized"] and all(p["shadow"] == p["strip"] and p["face"] == p["strip"] for p in mini)')" = True ]
hl_check "B11 after the glide the clicked strip is on show and every strip is a blade again" $? "$r"

! grep -E "without calling gtk_widget_measure|Allocation (width|height) too small|Gtk-CRITICAL" "$APP_LOG" > /dev/null
hl_check "B12 the app logged no GTK allocation warnings or criticals" $? "$(grep -m3 -E 'gtk_widget_measure|too small|Gtk-CRITICAL' "$APP_LOG")"

hl_finish "$L"
