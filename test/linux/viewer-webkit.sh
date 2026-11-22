#!/usr/bin/env bash
# viewer-webkit.sh - L9a (T3410) acceptance: the GTK app links WebKitGTK 6.0
# and a viewer renders a markdown document, a code file, a local .html page
# and a website through the bundled template and the two custom schemes
# (ghoztty-viewer://, ghoztty-page://), and the rendered result is readable
# back from the page. Run it ONLY through the wrapper, from this box:
#
#   powershell -NoProfile -File scripts\linux\wsl-run.ps1 -CommandFile test\linux\viewer-webkit.sh
#
# (-Repo clone, the default, tests the committed HEAD.) Each viewer opens in
# the debug build's test window (GHOZTTY_TEST_VIEWER, src/apprt/gtk/Viewer.zig)
# inside the private headless Weston (test/linux/lib/headless.sh), so nothing
# reaches WSLg or the user's desktop. Viewer PANES are cli-viewer-panes.sh (T3411).
#
# Output: one PASS/FAIL line per check, then 'VIEWER WEBKIT: ALL PASS' or
# 'VIEWER WEBKIT: <n> FAILURE(S)'. Exit 0 only on ALL PASS.
set -u
. "$PWD/test/linux/lib/headless.sh"
hl_check_init
L="VIEWER WEBKIT"

log=/tmp/viewer-webkit-build.log
zig build -Dapp-runtime=gtk -Doptimize=Debug -fno-sys=gtk4-layer-shell > "$log" 2>&1
rc=$?
hl_check "W1 zig build -Dapp-runtime=gtk -Doptimize=Debug exits 0" $rc "$(grep -m3 'error:' "$log" | tr '\n' ' ')"
[ $rc = 0 ] || hl_finish "$L"

hl_start
hl_check "W2 a private headless Weston is up" $?
app=$(hl_ghoztty) || hl_finish "$L"

ldd "$app" | grep -q 'libwebkitgtk-6.0'
hl_check "W3 the app links libwebkitgtk-6.0" $? "$(ldd "$app" | grep -i webkit | tr '\n' ' ')"

# ---- fixtures --------------------------------------------------------------
fx="$HL_RUNTIME/fx"
mkdir -p "$fx/page" "$fx/site"
printf '# Viewer Heading\n\nSome **bold** text.\n' > "$fx/doc.md"
printf 'TIER2-OK\n' > "$fx/tier2.txt"
printf 'def hello():\n    return 42\n' > "$fx/code.py"
cat > "$fx/page/index.html" <<'EOF'
<!DOCTYPE html>
<html><head><title>Page</title><link rel="stylesheet" href="app.css"><script src="app.js"></script></head>
<body><p>page body</p></body></html>
EOF
printf 'body { color: rgb(1, 2, 3); }\n' > "$fx/page/app.css"
printf 'window.APPJS = "loaded";\n' > "$fx/page/app.js"
printf '<!DOCTYPE html><html><body><h1>Site Up</h1></body></html>\n' > "$fx/site/index.html"

# A website on loopback, so the web mode needs no network.
port=$((20000 + $$ % 20000))
(cd "$fx/site" && exec python3 -m http.server "$port" --bind 127.0.0.1) > "$HL_RUNTIME/http.log" 2>&1 &
HTTP_PID=$!
HL_PIDS="$HL_PIDS $HTTP_PID"
hl_wait_for 10 sh -c "exec 3<>/dev/tcp/127.0.0.1/$port" 2>/dev/null

# view <var> <location> <probe>: open one viewer in a fresh app, wait for the
# probe's answer, stop the app. The answer lands in $<var>_OUT.
n=0
view() {
    local var=$1 loc=$2 probe=$3
    n=$((n + 1))
    local dump="$HL_RUNTIME/dump$n"
    hl_launch "$var" env GHOZTTY_TEST_VIEWER="$loc" GHOZTTY_TEST_VIEWER_PROBE="$probe" \
        GHOZTTY_TEST_VIEWER_DUMP="$dump" \
        "$app" --gtk-single-instance=false --session-persistence=false -e /bin/sh -c 'sleep 120'
    hl_wait_for 60 test -s "$dump"
    printf -v "${var}_OUT" '%s' "$(cat "$dump" 2>/dev/null)"
    local pid=${!var}
    kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

xhr='function get(u){try{var x=new XMLHttpRequest();x.open("GET",u,false);x.send();return x.responseText.length?x.responseText.trim():"REFUSED"}catch(e){return "REFUSED"}}'

# ---- markdown: template, vendor scripts, the file's own directory ----------
view MD "$fx/doc.md" "(function(){$xhr;var h=document.querySelector('#content h1'),b=document.querySelector('#content strong');return [h?h.textContent:'NOH1',b?b.textContent:'NOB',get('tier2.txt'),location.href].join('|')})()"
[ "$MD_OUT" = "OK Viewer Heading|bold|TIER2-OK|ghoztty-viewer://page/viewer.html" ]
hl_check "W4 markdown renders through the template (heading, bold, a file beside it, the template URL)" $? "got: $MD_OUT"

# ---- code: highlight.js colours it by its extension ------------------------
view CODE "$fx/code.py" "(function(){var c=document.querySelector('#content code');if(!c)return 'NOCODE';return [c.className,!!c.querySelector('.hljs-keyword'),c.textContent.indexOf('return 42')>=0].join('|')})()"
[ "$CODE_OUT" = "OK language-python|true|true" ]
hl_check "W5 a code file renders highlighted as its language" $? "got: $CODE_OUT"

# ---- a local .html page: its own CSS and JS, and nothing outside its grant -
view PAGE "$fx/page/index.html" "(function(){$xhr;return [window.APPJS,getComputedStyle(document.body).color,location.href,get('vendor/markdown-it.min.js'),get('../doc.md')].join('|')})()"
[ "$PAGE_OUT" = "OK loaded|rgb(1, 2, 3)|ghoztty-page://page/index.html|REFUSED|REFUSED" ]
hl_check "W6 an .html file loads as a page with its own assets, never the template's or its parent's" $? "got: $PAGE_OUT"

# ---- a website -------------------------------------------------------------
view WEB "http://127.0.0.1:$port/" "document.querySelector('h1').textContent+'|'+location.href"
[ "$WEB_OUT" = "OK Site Up|http://127.0.0.1:$port/" ]
hl_check "W7 a website loads in the viewer" $? "got: $WEB_OUT"

# ---- a missing file is the template's error card ---------------------------
view MISS "$fx/missing.md" "document.getElementById('content').innerText"
case "$MISS_OUT" in "OK "*"Cannot read file"*) true ;; *) false ;; esac
hl_check "W8 a missing file shows the cannot-read card" $? "got: $MISS_OUT"

grep -E 'panic|reached unreachable' "$MD_LOG" "$CODE_LOG" "$PAGE_LOG" "$WEB_LOG" "$MISS_LOG" > /dev/null 2>&1
[ $? != 0 ]
hl_check "W9 no app log carries a panic" $? "$(grep -h -m2 -E 'panic|unreachable' "$MD_LOG" "$CODE_LOG" "$PAGE_LOG" "$WEB_LOG" "$MISS_LOG" 2>/dev/null | tr '\n' ' ')"

# The web process must not inherit WSLg's d3d12 override (its sandbox has no
# /dev/dxg, so it aborts), and taking it away must not take the GPU from the
# terminal beside it: the app brings GDK's GL up on d3d12 first.
if [ "${GALLIUM_DRIVER:-}" = d3d12 ]; then
    grep -q 'kept from WebKit' "$MD_LOG"
    hl_check "W10 the viewer kept GALLIUM_DRIVER=d3d12 from WebKit's web process" $?
    r=$(grep -m1 'loaded OpenGL' "$MD_LOG" | sed 's/.*renderer=//')
    case "$r" in *D3D12*) true ;; *) false ;; esac
    hl_check "W11 the terminal beside the viewer still renders on the GPU (D3D12)" $? "renderer=$r"
fi

if [ "$HL_FAILS" != 0 ]; then
    for v in MD CODE PAGE WEB MISS; do
        lv="${v}_LOG"
        echo "---- $v log (viewer lines) ----"
        grep -iE 'viewer|webkit|bwrap|sandbox|critical|error' "${!lv}" 2>/dev/null | grep -v 'Portal not found' | head -20
    done
    echo "---- MD log (tail) ----"
    tail -40 "$MD_LOG" 2>/dev/null
fi

hl_finish "$L"
