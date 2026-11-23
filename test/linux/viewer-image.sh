#!/usr/bin/env bash
# viewer-image.sh - L9g (T3416) acceptance: GTK image viewer panes.
#
# docs/reference/viewer-image-and-diff.md "Image panes", on Linux:
# - a picture opens at best-fit, and best-fit never upscales (a 32px icon
#   stays 32px);
# - Ctrl+0 is 100%, Ctrl+plus/minus step by 1.25x, and the PAGE zoom is left
#   alone; a picture declines find (Ctrl+F);
# - double-click toggles fit <-> 100%, and for a picture smaller than the pane
#   fit <-> 200% (the toggle always toggles);
# - narrowing the pane re-fits a fitted picture and keeps a chosen zoom;
# - a save at the SAME pixel size re-decodes keeping zoom and scroll; a save
#   at another size re-fits;
# - TIFF (which WebKit cannot draw) is decoded on the host and served as
#   PNG; an .icns shows its largest embedded PNG; an SVG draws;
# - an undecodable file shows the "Cannot display this image" card, and a
#   real HEIF container nothing here decodes names the loader to install;
# - Ctrl+C (and Ctrl+Insert) copies the picture and its file (T3534): a
#   texture, text/uri-list and x-special/gnome-copied-files, read back
#   through GDK; Ctrl+Shift+C and the address field's Ctrl+C are not it;
# - +list reports the pane as a viewer at its file.
#
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-image.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh); the pane is driven
# and read back through the debug build's GHOZTTY_TEST_VIEWER_STEPS seam
# (src/apprt/gtk/Viewer.zig; its `image` step reads ViewerImage's state), and
# the driving script edits the fixtures at the steps' `mark` sync points.
#
# Output: one PASS/FAIL line per check, then 'VIEWER IMAGE: ALL PASS' or
# 'VIEWER IMAGE: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER IMAGE"

log=/tmp/viewer-image-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "I1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "I2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- fixtures --------------------------------------------------------------
# Written by a small Python helper (no imaging library needed): solid-colour
# PNGs of a given size, a baseline uncompressed RGB TIFF, an icon set holding
# a 16px and a 64px PNG, a HEIF container header with nothing decodable
# behind it, and a file named .png that is not a picture.
fx="$HL_RUNTIME/fx"
mkdir -p "$fx"
cat > "$HL_RUNTIME/fixtures.py" <<'PY'
import struct, sys, zlib

def png(w, h, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))

def tiff(w, h, rgb):
    pixels = bytes(rgb) * (w * h)
    entries = [(256, 3, 1, w), (257, 3, 1, h), (258, 3, 3, 8 + 2 + 12 * 12 + 4), (259, 3, 1, 1),
               (262, 3, 1, 2), (273, 4, 1, 0), (277, 3, 1, 3), (278, 3, 1, h), (279, 4, 1, len(pixels)),
               (282, 5, 1, 0), (283, 5, 1, 0), (296, 3, 1, 1)]
    ifd_at = 8
    after_ifd = ifd_at + 2 + 12 * len(entries) + 4
    bps_at = after_ifd
    res_at = bps_at + 6
    data_at = res_at + 16
    out = bytearray(b"II*\x00" + struct.pack("<I", ifd_at))
    out += struct.pack("<H", len(entries))
    for tag, typ, count, value in entries:
        if tag == 258: value = bps_at
        if tag == 273: value = data_at
        if tag == 282: value = res_at
        if tag == 283: value = res_at + 8
        if typ == 3 and count == 1:
            out += struct.pack("<HHIHH", tag, typ, count, value, 0)
        else:
            out += struct.pack("<HHII", tag, typ, count, value)
    out += struct.pack("<I", 0)
    out += struct.pack("<HHH", 8, 8, 8)
    out += struct.pack("<IIII", 72, 1, 72, 1)
    out += pixels
    return bytes(out)

def icns(*pngs):
    body = b""
    for kind, data in pngs:
        body += kind + struct.pack(">I", 8 + len(data)) + data
    return b"icns" + struct.pack(">I", 8 + len(body)) + body

kind, path = sys.argv[1], sys.argv[2]
if kind == "png":
    w, h, r, g, b = map(int, sys.argv[3:8]); data = png(w, h, (r, g, b))
elif kind == "tiff":
    w, h = map(int, sys.argv[3:5]); data = tiff(w, h, (0, 128, 255))
elif kind == "icns":
    data = icns((b"icp4", png(16, 16, (255, 0, 0))), (b"ic12", png(64, 64, (0, 255, 0))))
elif kind == "heic":
    data = b"\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic" + b"\x00" * 64
else:
    data = b"this is not a picture\n"
open(path + ".tmp", "wb").write(data)
import os; os.replace(path + ".tmp", path)
PY
fixture() { python3 "$HL_RUNTIME/fixtures.py" "$@"; }
fixture png "$fx/big.png" 4000 3000 200 30 30
fixture png "$fx/small.png" 32 32 30 200 30
fixture tiff "$fx/photo.tiff" 300 200
fixture icns "$fx/icon.icns"
fixture heic "$fx/fake.heic"
fixture broken "$fx/broken.png"
printf '<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="#36c"/></svg>\n' > "$fx/logo.svg"

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }

# A double-click in the middle of the picture's stage, as image.js hears one.
DBL="(function(){var s=document.querySelector('.viewer-image-stage');if(!s)return 'NOSTAGE';var r=s.getBoundingClientRect();s.dispatchEvent(new MouseEvent('dblclick',{bubbles:true,cancelable:true,clientX:r.left+r.width/2,clientY:r.top+r.height/2}));return 'dbl'})()"
SCROLL_SET="(function(){var s=document.querySelector('.viewer-image-stage');s.scrollLeft=500;s.scrollTop=300;return s.scrollLeft+'|'+s.scrollTop})()"
SCROLL="(function(){var s=document.querySelector('.viewer-image-stage');return s?Math.round(s.scrollLeft)+'|'+Math.round(s.scrollTop):'NOSTAGE'})()"
CARD="document.body.innerText.replace(/\\s+/g,' ')"

# ---- the steps the pane runs once it has rendered --------------------------
steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
image
mark narrow
sleep 2000
image
key <Control>0
sleep 400
image
key <Control>plus
sleep 400
image
key <Control>minus
sleep 400
image
state
key <Control>f
key <Control>plus
sleep 400
probe $SCROLL_SET
mark same-size
wait
sleep 400
image
probe $SCROLL
mark narrow-again
sleep 2000
image
mark other-size
wait
image
probe $DBL
sleep 400
image
probe $DBL
sleep 400
image
key <Control>l
type $fx/small.png
activate
wait
image
probe $DBL
sleep 400
image
probe $DBL
sleep 400
image
key <Control>c
clipboard
key <Control><Shift>c
key <Control>l
key <Control>c
clipboard
key <Control>l
type $fx/photo.tiff
activate
wait
image
key <Control>l
type $fx/icon.icns
activate
wait
image
key <Control>Insert
clipboard
key <Control>l
type $fx/logo.svg
activate
wait
image
key <Control>l
type $fx/broken.png
activate
wait
probe $CARD
key <Control>l
type $fx/fake.heic
activate
wait
probe $CARD
EOF

dump="$HL_RUNTIME/viewer-dump"
export SHELL=/bin/sh
export GHOZTTY_TEST_VIEWER_DUMP="$dump"
export GHOZTTY_TEST_VIEWER_PROBE="(function(){var i=document.querySelector('.viewer-image');return i?'IMG '+i.naturalWidth+'x'+i.naturalHeight:'NOIMG'})()"
export GHOZTTY_TEST_VIEWER_STEPS="$steps"
export GHOZTTY_TEST_VIEWER_STEPS_OUT="$out"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_VIEWER_DUMP GHOZTTY_TEST_VIEWER_PROBE GHOZTTY_TEST_VIEWER_STEPS GHOZTTY_TEST_VIEWER_STEPS_OUT
hl_wait_for 30 test -S "$sock"
hl_check "I3 the app serves its socket" $?

o=$(cli +split --view=big.png --name=img 2>&1)
hl_check "I4 +split --view=big.png opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK IMG 4000x3000" ]
hl_check "I5 the pane draws the picture (decoded at its natural size)" $? "dump: $(cat "$dump" 2>/dev/null)"

# The leaf named `img` in +list --json, as 'type|url|title'.
img_leaf() {
    cli +list --json 2>/dev/null | python3 -c '
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
            if l.get("name") == "img":
                print("%s|%s|%s" % (l.get("type"), l.get("url") or "", l.get("title") or ""))
' 2>/dev/null
}
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
lf=$(img_leaf)
[ "$lf" = "viewer|$fx/big.png|big.png" ]
hl_check "I6 +list reports the pane as a viewer at its file, titled by its name" $? "leaf: $lf"

# ---- the driving script's half of the sync points ----------------------------
hl_wait_for 60 grep -q '^mark narrow$' "$out"
o=$(cli +split --pane=img 2>&1); split1_rc=$?
hl_wait_for 60 grep -q '^mark same-size' "$out"
fixture png "$fx/big.png" 4000 3000 30 30 200
hl_wait_for 60 grep -q '^mark narrow-again' "$out"
# Down, not right: the nav bar holds the pane at its minimum width by now.
o2=$(cli +split --pane=img --direction=down 2>&1); split2_rc=$?
hl_wait_for 60 grep -q '^mark other-size' "$out"
fixture png "$fx/big.png" 2000 1000 30 200 200
hl_wait_for 120 grep -q '^done' "$out"
hl_check "I7 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
im() { nth "image " "$1"; }
pr() { nth probe "$1"; }
wt() { nth wait "$1"; }
field() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p" | head -1; }
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 < b + 0) }'; }
eq() { awk -v a="$1" -v b="$2" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d < 0.001) }'; }

i1=$(im 1)
f1=$(field "$i1" fit)
has "$i1" "natural=4000x3000" && has "$i1" "fitting=true" && lt "$f1" 1 && eq "$(field "$i1" zoom)" "$f1"
hl_check "I8 a large picture opens at best-fit (fit < 100%)" $? "$i1"

i2=$(im 2)
[ $split1_rc = 0 ] && has "$i2" "fitting=true" && lt "$(field "$i2" fit)" "$f1" && eq "$(field "$i2" zoom)" "$(field "$i2" fit)"
hl_check "I9 narrowing the pane re-fits a fitted picture" $? "rc=$split1_rc out=$o $i2 (before: fit=$f1)"

i3=$(im 3)
eq "$(field "$i3" zoom)" 1 && has "$i3" "fitting=false"
hl_check "I10 Ctrl+0 is 100% (Actual Size), not fit" $? "$i3"
eq "$(field "$(im 4)" zoom)" 1.25 && eq "$(field "$(im 5)" zoom)" 1
hl_check "I11 Ctrl+plus / Ctrl+minus step the picture by 1.25x" $? "$(im 4) / $(im 5)"
has "$(nth state 1)" "zoom=1.000"
hl_check "I12 the chords zoom the picture, never the page" $? "$(nth state 1)"
grep -q '^key <Control>f handled=false' "$out"
hl_check "I13 a picture declines find (Ctrl+F falls through)" $? "$(grep '^key <Control>f' "$out")"

i6=$(im 6)
[ "$(wt 1)" = "wait ok=true" ] && has "$i6" "rev=2" && eq "$(field "$i6" zoom)" 1.25 && has "$i6" "fitting=false"
hl_check "I14 a save at the same pixel size re-decodes and keeps the zoom" $? "$(wt 1) / $i6"
[ "$(pr 1)" = "probe OK 500|300" ] && [ "$(pr 2)" = "probe OK 500|300" ]
hl_check "I15 ... and keeps the scroll position" $? "$(pr 1) / $(pr 2)"
grep -q 'viewer image served rev=2 .*mime=image/png route=browser' "$APP_LOG"
hl_check "I16 the re-decode is a new revision WebKit fetched fresh" $? "$(grep 'viewer image served' "$APP_LOG" | head -3 | tr '\n' ' ')"

i7=$(im 7)
vh() { field "$1" viewport | cut -dx -f2; }
[ $split2_rc = 0 ] && lt "$(vh "$i7")" "$(vh "$i6")" && eq "$(field "$i7" zoom)" 1.25 && has "$i7" "fitting=false"
hl_check "I17 shrinking the pane keeps a zoom the user chose" $? "rc=$split2_rc out=$o2 $i7 (before: $i6)"

i8=$(im 8)
[ "$(wt 2)" = "wait ok=true" ] && has "$i8" "natural=2000x1000" && has "$i8" "fitting=true"
hl_check "I18 a save at another pixel size re-fits" $? "$(wt 2) / $i8"
eq "$(field "$(im 9)" zoom)" 1 && has "$(im 10)" "fitting=true"
hl_check "I19 double-click toggles fit -> 100% -> fit" $? "$(pr 3) $(im 9) / $(im 10)"

i11=$(im 11)
has "$i11" "natural=32x32" && eq "$(field "$i11" zoom)" 1 && has "$i11" "fitting=true"
hl_check "I20 a small picture opens at 100%: best-fit never upscales" $? "$i11"
eq "$(field "$(im 12)" zoom)" 2 && has "$(im 13)" "fitting=true"
hl_check "I21 ...and its double-click goes to 200% and back (the toggle always toggles)" $? "$(im 12) / $(im 13)"

i14=$(im 14)
has "$i14" "route=wic" && has "$i14" "natural=300x200"
hl_check "I22 a TIFF (which WebKit cannot draw) is decoded on the host" $? "$i14"
grep -q 'viewer image served rev=[0-9]* bytes=[0-9]* mime=image/png route=wic decode_ms=' "$APP_LOG"
hl_check "I23 ...off the main thread, served as PNG" $? "$(grep 'route=wic' "$APP_LOG" | head -2 | tr '\n' ' ')"

i15=$(im 15)
has "$i15" "route=icns" && has "$i15" "natural=64x64"
hl_check "I24 an .icns shows its largest embedded PNG" $? "$i15"

i16=$(im 16)
has "$i16" "route=browser" && has "$i16" "natural=120x80" && has "$i16" "fitting=true"
hl_check "I25 an SVG draws, at its intrinsic size" $? "$i16"

p=$(pr 7)
has "$p" "Cannot display this image" && grep -q 'viewer image retry .*route=wic' "$APP_LOG"
hl_check "I26 an undecodable file gets one host retry, then the 'Cannot display this image' card" $? "$p"
p=$(pr 8)
has "$p" "heif-gdk-pixbuf"
hl_check "I27 a real HEIF container nothing here decodes names the loader to install" $? "$p"

# ---- Ctrl+C copies the picture and its file (T3534) ---------------------------
cb() { grep '^clipboard ' "$out" | sed -n "${1}p"; }
ct() { grep '^clipboard-texture' "$out" | sed -n "${1}p"; }
c1=$(cb 1)
grep -q '^key <Control>c handled=true' "$out" && has "$c1" "copies=1 ok=true size=32x32 file=true"
hl_check "I29 Ctrl+C at a picture copies it (claimed ahead of the page's empty selection)" $? "$(grep '^key <Control>c' "$out" | head -1) / $c1"
has "$c1" "GdkTexture" && has "$c1" "text/uri-list" && has "$c1" "x-special/gnome-copied-files"
hl_check "I30 ...offering the picture, a uri-list and a file manager's copied-files list" $? "$c1"
has "$c1" "local=true" && has "$c1" "image/png" && [ "$(ct 1)" = "clipboard-texture 32x32" ]
hl_check "I31 ...on the clipboard: a reader gets the 32x32 picture back as PNG" $? "$c1 / $(ct 1)"
grep -q "viewer image copy ok=true size=32x32 file=true route=browser offered=.* path=$fx/small.png" "$APP_LOG"
hl_check "I32 ...and the log names the copy and the file" $? "$(grep -m2 'viewer image copy' "$APP_LOG" | tr '\n' ' ')"
c2=$(cb 2)
grep -q '^key <Control><Shift>c handled=false' "$out" && has "$c2" "copies=1 "
hl_check "I33 Ctrl+Shift+C is not the picture's copy, and the address field keeps its own Ctrl+C" $? "$(grep -E '^key <Control>(<Shift>)?c' "$out" | tr '\n' ' ') / $c2"
c3=$(cb 3)
grep -q '^key <Control>Insert handled=true' "$out" && has "$c3" "copies=2 ok=true size=64x64 file=true" && [ "$(ct 3)" = "clipboard-texture 64x64" ]
hl_check "I34 Ctrl+Insert copies too, and an .icns copies its largest embedded PNG" $? "$c3 / $(ct 3)"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "I28 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- steps output ----"
    cat "$out" 2>/dev/null
    echo "---- app log (viewer lines) ----"
    grep -iE 'viewer|webkit|critical|error' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -60
fi

hl_finish "$L"
