#!/usr/bin/env bash
# viewer-screenshot.sh - L9j-4 (T3546) acceptance: pictures in the GTK viewer's
# feedback composer (docs/reference/viewer-feedback.md, "Composer" and
# "Report output"). The composer's + button and Ctrl+Shift+S take a screenshot
# of the pane from the app's OWN render (Wayland and the headless Weston have
# no global capture); a paste in the shared composer page hands up a PNG; each
# lands as an atomic [Image #N] chip with a STABLE number and a tile in the
# thumbnail strip; deleting a chip takes its picture out of the strip and the
# report; and a send writes images/image-N.png beside report.json with the
# pixel size and byte count, linked from the body.
# Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-screenshot.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Everything runs inside
# the private headless Weston (test/linux/lib/headless.sh), driven by the
# debug build's GHOZTTY_TEST_VIEWER_STEPS seam (src/apprt/gtk/Viewer.zig):
# `click feedback-shot` is the + button, `composer-key ctrl+shift+S` the chord,
# `thumb <n>` clicks a tile, `composer` prints `images= tiles= sel= shots=
# shot=WxH` beside the text.
#
# Output: one PASS/FAIL line per check, then 'VIEWER SCREENSHOT: ALL PASS' or
# 'VIEWER SCREENSHOT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER SCREENSHOT"

log=/tmp/viewer-screenshot-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "S1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "S2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"
sock="$XDG_RUNTIME_DIR/ghostty-debug-$(id -u).sock"

# ---- fixture: a repo with one markdown file ---------------------------------
fx="$HL_RUNTIME/fx"
repo="$fx/repo"
mkdir -p "$repo/docs"
g() { env -u GIT_DIR -u GIT_WORK_TREE git -C "$repo" -c user.email=t@example.invalid -c user.name=t "$@"; }
env -u GIT_DIR -u GIT_WORK_TREE git init -q -b sbranch "$repo" || echo "git init failed"
printf '# Shot Me\n\nSome **bold** text and a list:\n\n- one\n- two\n' > "$repo/docs/doc.md"
g add docs/doc.md && g commit -q -m init || echo "git commit failed"
queue="$repo/temp/feedback/new"

lsdir=$(dirname "$(find "$PWD/zig-out" "$PWD/.zig-cache" -name 'libgtk4-layer-shell.so*' -print -quit 2>/dev/null)")
cli() { (cd "$fx" && env -u GHOZTTY_IPC_SOCKET -u GHOZTTY_PANE_ID LD_LIBRARY_PATH="$lsdir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$app" "$@"); }

H="(function(){var h=document.querySelector('#content h1')||document.querySelector('h1');return h?h.textContent:'NOH1'})()"
# The chips the composer PAGE holds as nodes, by number.
CHIPS="Array.prototype.map.call(document.querySelectorAll('#c .i'),function(n){return n.getAttribute('data-img')}).join(',')||'none'"
# A 30x20 PNG made by a canvas, pasted into the composer as a clipboard would
# (a ClipboardEvent carrying a File); if this engine will not build one, the
# same File arrives as a drop. Either way it is the page's own image path.
PASTE="(function(){var cv=document.createElement('canvas');cv.width=30;cv.height=20;var x=cv.getContext('2d');x.fillStyle='#d00';x.fillRect(0,0,30,20);x.fillStyle='#00d';x.fillRect(0,0,15,10);var u=cv.toDataURL('image/png');var b=atob(u.split(',')[1]);var a=new Uint8Array(b.length);for(var i=0;i<b.length;i++)a[i]=b.charCodeAt(i);var f=new File([a],'p.png',{type:'image/png'});var dt=new DataTransfer();dt.items.add(f);var c=document.getElementById('c');c.focus();var e;try{e=new ClipboardEvent('paste',{clipboardData:dt,bubbles:true,cancelable:true})}catch(_){e=null}if(e&&e.clipboardData){c.dispatchEvent(e);if(e.defaultPrevented)return 'pasted'}var d=new DragEvent('drop',{dataTransfer:dt,bubbles:true,cancelable:true});c.dispatchEvent(d);return d.defaultPrevented?'dropped':'ignored'})()"
# Delete chip #2 the way a selection + Delete would.
DEL2="(function(){var n=document.querySelector('#c .i[data-img=\"2\"]');if(!n)return 'none';var r=document.createRange();r.selectNode(n);var s=getSelection();s.removeAllRanges();s.addRange(r);document.execCommand('delete');return 'deleted'})()"
SELTEXT="String(getSelection())"

steps="$HL_RUNTIME/steps"
out="$HL_RUNTIME/steps.out"
cat > "$steps" <<EOF
feedback
click feedback
composer
composer-type before
sleep 400
click feedback-shot
sleep 800
composer
composer-probe $CHIPS
composer-key ctrl+shift+S
sleep 800
composer
composer-probe $PASTE
sleep 1200
composer
composer-probe $DEL2
sleep 600
composer
thumb 3
sleep 400
composer-probe $SELTEXT
composer
composer-key Escape
sleep 300
composer
click feedback
composer
composer-probe $CHIPS
composer-key ctrl+Enter
composer
sleep 2500
composer
EOF

dump="$HL_RUNTIME/viewer-dump"
export SHELL=/bin/sh
export GHOZTTY_TEST_VIEWER_DUMP="$dump"
export GHOZTTY_TEST_VIEWER_PROBE="$H"
export GHOZTTY_TEST_VIEWER_STEPS="$steps"
export GHOZTTY_TEST_VIEWER_STEPS_OUT="$out"
hl_launch APP "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'PS1="hl$ " exec /bin/sh -i'
unset GHOZTTY_TEST_VIEWER_DUMP GHOZTTY_TEST_VIEWER_PROBE GHOZTTY_TEST_VIEWER_STEPS GHOZTTY_TEST_VIEWER_STEPS_OUT
hl_wait_for 30 test -S "$sock"
hl_check "S3 the app serves its socket" $?

o=$(cli +split --view="$repo/docs/doc.md" --name=doc 2>&1)
hl_check "S4 +split --view=<repo file> opens a viewer pane" $? "$o"
hl_wait_for 40 test -s "$dump"
[ "$(cat "$dump" 2>/dev/null)" = "OK Shot Me" ]
hl_check "S5 the pane renders its file" $? "dump: $(cat "$dump" 2>/dev/null)"

hl_wait_for 120 grep -qs '^done' "$out"
hl_check "S6 every step ran to the end" $? "$(tail -3 "$out" 2>/dev/null | tr '\n' ' ')"

nth() { grep "^$1" "$out" | sed -n "${2}p"; }
co() { nth 'composer ' "$1"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }

s=$(co 1)
has "$s" "open=true view=true ready=true" && has "$s" "images=- tiles=- " && has "$s" "shots=0"
hl_check "S7 the composer opens with no pictures and no strip" $? "$s"

s=$(co 2)
has "$s" "images=1 tiles=1 sel=1 shots=1" && has "$s" 'text=before [Image #1] '
hl_check "S8 the + button takes a screenshot: chip [Image #1] at the caret, one tile, ringed" $? "$s"

shot=$(printf '%s' "$(co 2)" | sed -n 's/.* shot=\([0-9]*x[0-9]*\) .*/\1/p')
case "$shot" in 0x0|'') false ;; *) true ;; esac
hl_check "S9 the screenshot has a real size ($shot)" $? "$(co 2)"

[ "$(nth probe 1)" = "probe OK 1" ]
hl_check "S10 the page holds the chip as one node numbered 1" $? "$(nth probe 1)"

s=$(co 3)
has "$s" "images=1,2 tiles=1,2 sel=2 shots=2" && has "$s" '[Image #1] [Image #2] '
hl_check "S11 Ctrl+Shift+S in the composer takes the next one: [Image #2]" $? "$s"

p=$(nth probe 2)
s=$(co 4)
{ [ "$p" = "probe OK pasted" ] || [ "$p" = "probe OK dropped" ]; } && has "$s" "images=1,2,3 tiles=1,2,3"
hl_check "S12 a picture pasted into the page arrives as [Image #3] with its tile" $? "$p / $s"

s=$(co 5)
has "$s" "images=1,3 tiles=1,3" && ! has "$s" "[Image #2]"
hl_check "S13 deleting chip #2 takes its tile and its picture out; 1 and 3 keep their numbers" $? "$s"

[ "$(nth thumb 1)" = "thumb 3 found=true" ] && [ "$(nth probe 4)" = "probe OK [Image #3]" ] && has "$(co 6)" "sel=3"
hl_check "S14 clicking tile #3 selects its chip, whole, in the page and rings the tile" $? "$(nth thumb 1) / $(nth probe 4) / $(co 6)"

s=$(co 7)
has "$s" "open=false view=false" && has "$s" "images=1,3"
hl_check "S15 Escape closes the composer; the pictures stay with the text" $? "$s"

[ "$(nth probe 5)" = "probe OK 1,3" ] && has "$(co 8)" "tiles=1,3"
hl_check "S16 reopening rebuilds both chips as nodes and the strip" $? "$(nth probe 5) / $(co 8)"

s=$(co 10)
has "$s" "sends=1" && has "$s" "images=- tiles=- " && has "$s" "status=Filed temp/feedback/new/"
hl_check "S17 Ctrl+Enter files the report; the strip and the pictures clear" $? "$s"

# ---- the report on disk -----------------------------------------------------
n=$(find "$queue" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
[ "$n" = 1 ]
hl_check "S18 one report folder landed" $? "found $n"

dir="$queue/$(ls "$queue" 2>/dev/null | head -1)"
check_report() {
    python3 - "$dir" "$shot" <<'PY'
import json, os, struct, sys, zlib
d, shot = sys.argv[1], sys.argv[2]
r = json.load(open(os.path.join(d, "report.json")))
bad = []
def want(name, cond):
    if not cond: bad.append(name)

def pixels(path):
    """Decode a non-interlaced 8-bit RGB/RGBA PNG; answer (w, h, distinct colours)."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, w = 8, b"", 0
    while pos < len(data):
        ln, = struct.unpack(">I", data[pos:pos+4]); typ = data[pos+4:pos+8]; body = data[pos+8:pos+8+ln]
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, inter = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat += body
        pos += 12 + ln
    if depth != 8 or inter != 0 or ctype not in (2, 6):
        return w, h, -1
    bpp = 4 if ctype == 6 else 3
    raw = zlib.decompress(idat); stride = w * bpp
    prev = bytearray(stride); colours = set(); i = 0
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
        for x in range(0, stride, bpp * 7):
            colours.add(bytes(line[x:x+bpp]))
        prev = line
    return w, h, len(colours)

body = r.get("body", "")
want("body links 1", "![Image #1](images/image-1.png)" in body)
want("body links 3", "![Image #3](images/image-3.png)" in body)
want("body drops 2", "Image #2" not in body)
want("body text", body.startswith("before"))
imgs = r.get("images") or []
want("two images", [i.get("number") for i in imgs] == [1, 3])
for im in imgs:
    p = os.path.join(d, im.get("path", ""))
    want("path %d" % im["number"], im.get("path") == "images/image-%d.png" % im["number"] and os.path.isfile(p))
    if os.path.isfile(p):
        want("bytes %d" % im["number"], im.get("bytes") == os.path.getsize(p))
        w, h, n = pixels(p)
        want("size %d" % im["number"], (im.get("pixelWidth"), im.get("pixelHeight")) == (w, h))
        if im["number"] == 1:
            want("shot size", "%dx%d" % (w, h) == shot)
            want("shot is the pane (viewport)", r["source"].get("viewport") == "%dx%d" % (w, h))
            want("shot is not blank (%d colours)" % n, n >= 3)
        else:
            want("pasted 30x20", (w, h) == (30, 20))
want("no image-2 file", not os.path.exists(os.path.join(d, "images", "image-2.png")))
print("bad=" + ",".join(bad) if bad else "ok")
PY
}
res=$(check_report 2>&1)
[ "$res" = ok ]
hl_check "S19 the folder holds images/image-1.png (the pane, at its viewport size, not blank) and image-3.png (30x20); report.json lists both with size and bytes and the body links them" $? "$res :: $(head -c 700 "$dir/report.json" 2>/dev/null)"

grep -q 'viewer feedback: image=#1 via=screenshot' "$APP_LOG" && grep -q 'viewer feedback: image=#3 via=paste' "$APP_LOG"
hl_check "S20 the app logged each picture and how it came" $? "$(grep 'viewer feedback: image' "$APP_LOG" | tr '\n' ' ')"

grep -E 'panic|reached unreachable' "$APP_LOG" > /dev/null 2>&1
[ $? != 0 ] && kill -0 "$APP" 2>/dev/null
hl_check "S21 no panic, the app is still up" $? "$(grep -m2 -E 'panic|unreachable' "$APP_LOG" 2>/dev/null | tr '\n' ' ')"

if [ "$HL_FAILS" != 0 ]; then
    echo "---- steps output ----"
    cat "$out" 2>/dev/null
    echo "---- app log (viewer lines) ----"
    grep -iE 'viewer|webkit|critical|error|snapshot' "$APP_LOG" 2>/dev/null | grep -v 'Portal not found' | tail -40
fi

hl_finish "$L"
